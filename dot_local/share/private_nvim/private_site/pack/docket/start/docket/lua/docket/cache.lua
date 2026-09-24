-- The dashboard's cached rows: where they live, how old they are, and one
-- request in flight per key. Imports config, flight and row. The dashboard
-- shows cached rows the moment it opens and refreshes behind them, and the age
-- travels with the rows so that a stale view is never presented as live.
--
-- Rows live under config.options.cache_dir, which is `$XDG_CACHE_HOME/docket`.
-- Never under the editor's own cache: what is cached is a query's answer
-- rather than anything of the editor's, so a second front end or a shell
-- command asking the same question shares it. Never in the source tree either:
-- tests/check.py fails on a program-written file there.
--
-- Nothing here raises. A directory that is absent or cannot be written, a file
-- that is not JSON or holds another key, a read that fails part way -- each is
-- a miss, because the cache stands in front of the client and a broken cache
-- must not stop the dashboard from asking. Every function is safe in a
-- fast-event context, which is where a spawn callback lands: the file name is
-- hashed in Lua rather than through vim.fn.sha256, and the directory is made
-- with libuv rather than vim.fn.mkdir, since vim.fn is refused there.
--
-- Transition lists and thread state are never cached; only rows are.

local config = require("docket.config")
local flight = require("docket.flight")
local row = require("docket.row")

local M = {}

-- The request in flight for each key. drop() and clear() move a key on, so an
-- answer to a request started before a write is neither written nor shown:
-- the event loop is pumped by spawn.wait and by every prompt, so a search
-- started before a write can land after the write has dropped the key, and its
-- rows would otherwise be cached as if they followed it. A successful answer
-- that is kept is written before any waiter sees it.
local requests = flight.new({
  refusal = function(key)
    return ("%s: dropped while the request was in flight, so its answer is not shown; refresh to ask again"):format(key)
  end,
  accept = function(key, rows)
    if rows then
      M.write(key, rows)
    end
  end,
})

-- The file mode for a row file and the directory holding it: the rows carry
-- ticket titles from the employer's tracker, on a server other accounts share.
local FILE_MODE = 384 -- 0600
local DIR_MODE = 448 -- 0700

--- The cache key for a section: the adapter's name, what the query is
--- resolved against, and the query itself.
---
--- A review client reads the project from the working directory -- `glab api`
--- substitutes `:id` from the clone it is run in -- so `mr list
--- --reviewer=@me` names a different project in every clone and `scope` is
--- that clone's root for those. A JQL query names its own projects, so Jira's
--- sections share rows whichever repository each is shown in.
---
--- No account is in the key, because building one would cost a client call on
--- the path that assembles the dashboard. auth.login() clears the cache
--- instead: rows the account that signed out fetched cannot be told from the
--- rest, so a login drops every key.
---@param source string the adapter's name
---@param query string|string[] JQL, or a review client's argument list
---@param scope string|nil the clone a review client resolves its project in
---@return string key
function M.key(source, query, scope)
  if type(query) == "table" then
    query = table.concat(query, " ")
  end
  return source .. " " .. (scope and scope .. " " or "") .. query
end

-- A 32-bit multiplicative hash of the text, kept inside double precision:
-- the running value stays below 2^32 and the multiplier below 2^17, so the
-- product never loses bits.
local function hash32(text, seed, multiplier)
  local value = seed
  for index = 1, #text do
    value = (value * multiplier + text:byte(index)) % 4294967296
  end
  return value
end

--- The file name a key is stored under: two 32-bit hashes of the key under
--- different seeds and multipliers, as hexadecimal.
---
--- A key is a query, which carries spaces, quotes and parentheses and can be
--- longer than a file name is allowed to be, so it cannot be the name. The key
--- is written inside the file and checked on read, so a collision between two
--- keys reads as a miss and never as the other key's rows.
---@param key string
---@return string name
function M.name(key)
  return ("%08x%08x"):format(hash32(key, 5381, 33), hash32(key, 0, 65599))
end

--- The file a key's rows are stored in.
---@param key string
---@return string path
function M.path(key)
  return config.options.cache_dir .. "/" .. M.name(key) .. ".json"
end

--- The cached rows for a key and the moment they were fetched, or nil for a
--- miss.
---
--- Every row is held to row.new, and one the dashboard could not render makes
--- the whole file a miss: a row with no `id` or an unknown `source` kills the
--- render inside whatever command opened the dashboard, and the file would
--- stay until it was removed by hand. The entry itself is kept rather than
--- row.new's return, which holds the rendered fields alone, so what an adapter
--- adds beyond them -- `updated` on every row, a merge request's `url` --
--- survives the round trip.
---@param key string
---@return { rows: table[], written: integer }|nil cached
function M.read(key)
  local fd = vim.uv.fs_open(M.path(key), "r", 0)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  local data = stat and vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if type(data) ~= "string" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, data, { luanil = { object = true, array = true } })
  if
    not ok
    or type(decoded) ~= "table"
    or decoded.key ~= key
    or type(decoded.written) ~= "number"
    or not vim.islist(decoded.rows)
  then
    return nil
  end
  local rows = {}
  for index, entry in ipairs(decoded.rows) do
    if not pcall(row.new, entry) then
      return nil
    end
    rows[index] = entry
  end
  return { rows = rows, written = decoded.written }
end

-- Creates a directory and every missing parent, with DIR_MODE. True when it
-- exists afterwards. `vim.fs.dirname` of a root returns the root, which is
-- what ends the recursion on a path nothing can create.
local function mkdir_p(dir)
  local stat = vim.uv.fs_stat(dir)
  if stat then
    return stat.type == "directory"
  end
  local parent = vim.fs.dirname(dir)
  if parent == dir or not mkdir_p(parent) then
    return false
  end
  local ok, err = vim.uv.fs_mkdir(dir, DIR_MODE)
  return ok ~= nil or (type(err) == "string" and err:find("EEXIST", 1, true) ~= nil)
end

--- Stores a key's rows, with the moment they were fetched.
---
--- The file is written beside its final name and renamed into place, so a
--- reader in another process never meets a half-written file. The name of the
--- temporary file carries this process's id, so two front ends writing one key
--- at once do not share it.
---@param key string
---@param rows table[]
---@param now integer|nil the moment, recorded as `written`; os.time() when nil
---@return boolean ok false when nothing could be written, which is a miss at the next read
function M.write(key, rows, now)
  if not mkdir_p(config.options.cache_dir) then
    return false
  end
  local path = M.path(key)
  local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
  local fd = vim.uv.fs_open(tmp, "w", FILE_MODE)
  if not fd then
    return false
  end
  local ok, encoded = pcall(vim.json.encode, { key = key, written = now or os.time(), rows = rows })
  local written = ok and vim.uv.fs_write(fd, encoded) or nil
  vim.uv.fs_close(fd)
  -- fs_write answers with the byte count, so a file system that fills part
  -- way through leaves a short file that would be renamed into place as if it
  -- held every row.
  if not ok or written ~= #encoded then
    vim.uv.fs_unlink(tmp)
    return false
  end
  if not vim.uv.fs_rename(tmp, path) then
    vim.uv.fs_unlink(tmp)
    return false
  end
  return true
end

--- Drops a key: its file, and the answer of any request for it in flight,
--- since that answer predates whatever made the caller drop it. A write to an
--- item calls this for the sections that hold it.
---@param key string
function M.drop(key)
  requests:invalidate(key)
  vim.uv.fs_unlink(M.path(key))
end

--- Drops every key: every row file in the directory, and the answer of every
--- request in flight.
function M.clear()
  requests:invalidate_all()
  local dir = config.options.cache_dir
  local handle = vim.uv.fs_scandir(dir)
  while handle do
    local entry = vim.uv.fs_scandir_next(handle)
    if not entry then
      break
    end
    if entry:match("%.json$") then
      vim.uv.fs_unlink(dir .. "/" .. entry)
    end
  end
end

--- Asks for a key's rows, spawning at most one request per key.
---
--- The join is flight.lua's: a second ask while a request is in flight
--- collects `on_done` rather than calling `request`, and every waiter on one
--- request gets the same answer, once, however often the adapter hands it
--- over. A successful answer is written to the cache first, unless the key was
--- dropped while the request ran: then it is neither written nor shown, and
--- every waiter is told to refresh. A caller arriving after that drop starts a
--- request of its own. A request that raises answers its waiters with the
--- error and frees the key.
---
--- `request` is called on the caller's context; the function it is given, and
--- so `on_done`, run wherever the adapter calls it, which for a client call is
--- a fast-event context.
---@param key string
---@param request fun(deliver: fun(rows: table[]|nil, err: string|nil, warning: string|nil))
---@param on_done fun(rows: table[]|nil, err: string|nil, warning: string|nil)
---@return boolean started false when on_done joined a request already in flight
function M.fetch(key, request, on_done)
  return requests:join(key, request, on_done)
end

--- Whether a request this key's next ask would join is in flight. A request
--- the key has since been dropped from is not one, since the ask starts its
--- own.
---@param key string
---@return boolean
function M.pending(key)
  return requests:pending(key)
end

return M
