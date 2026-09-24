-- The adapter contract, the capability set, and the registry that maps an
-- adapter's name to its module. Imports row, whose SOURCES are the names the
-- registry answers to. A module is loaded the first time it is asked for, so
-- a client this machine lacks costs nothing at startup, and it is checked
-- against the contract once, on that load.
--
-- Prose is not enough to build three adapters against, so the contract is
-- the tables below and verify() holds a module to them. The callers above
-- -- the item buffer, the commands, the health check -- bind only what an
-- adapter declares in its `capabilities` list, which is what keeps the
-- asymmetry between backends out of the buffer: Jira has no diff, no threads
-- and no submit; GitHub implements the row calls and names a `handoff`, which
-- sends its items to octo.nvim; a state change is a status name on Jira and
-- approve, merge, close or reopen on GitLab.
--
-- Every adapter supplies these. auth_login blocks, and so does auth_status
-- when it is given no callback, because the login command runs on the main
-- loop and a prompt has to follow the state check on the same loop. The
-- other calls that cross the network take a callback, which arrives in a
-- fast-event context as every spawn.run callback does, so a caller that
-- touches a buffer schedules that work.
--
--   auth_status(on_done, cwd)   -> { authenticated, missing, detail }
--                                  `missing` when the client is not installed;
--                                  `detail` is the client's own output.
--                                  Without on_done it blocks and returns the
--                                  state. With one it returns nothing and
--                                  hands the state to on_done in a
--                                  fast-event context, or before it returns
--                                  when no process started; the dashboard
--                                  asks this way, so that no host holds its
--                                  first paint. `cwd` is the clone the check
--                                  is about, for a client whose verdict
--                                  follows the host its working directory
--                                  names; the dashboard passes the root it
--                                  shows, so that its check and its rows run
--                                  in one clone whatever the editor's
--                                  directory is by then, and so does `<CR>`
--                                  on one of its rows, so that a merge
--                                  request opens from the clone the row came
--                                  from. Without one the adapter reads the
--                                  editor's directory. Both
--                                  forms run the same command, and both are
--                                  called on the main loop, because an
--                                  adapter given no `cwd` reads that
--                                  directory there
--   auth_login(token, fields)   -> a spawn result; the token goes to the
--                                  client on standard input, never in argv.
--                                  Whatever the adapter cached under the
--                                  account signed in until now is dropped --
--                                  the account's own identifier, and any rows
--                                  a later call would offer as completion
--                                  candidates -- because the account signing
--                                  in may be another one, and because the
--                                  login flow pumps the event loop, so a
--                                  query started under the old account can
--                                  answer during the call. It is dropped
--                                  before the client runs and whatever the
--                                  client answers, since a login it refuses
--                                  may have replaced its stored credentials
--                                  as well
--   auth_fields()               -> { { name, prompt, default }... } the values a
--                                  first login needs besides the token
--   token_url()                 -> the page where a token is minted
--   rows(section, on_done)      -> on_done(rows|nil, err|nil, warning|nil),
--                                  rows built by row.new. `section` is one
--                                  the dashboard shows, carrying `title`,
--                                  `query` and `cwd`, the root of the clone
--                                  it shows, where a client that finds the
--                                  project from its working directory runs
--                                  the query. `warning` names the rows the
--                                  client returned that could not be built,
--                                  while the rest are still given; `err` is
--                                  set only when none could be
--   item(id, on_done)           -> on_done(item|nil, err|nil, me_err|nil),
--                                  built by item.new. `me_err` is why
--                                  whoami() could not answer: the item still
--                                  opens, with every comment read-only for
--                                  want of an ownership test, and the buffer
--                                  shows the reason; nil when the identity is
--                                  known. On a backend that numbers its items
--                                  within a project the item carries
--                                  `project`, the path the answer names, and
--                                  the item buffer refuses an answer whose
--                                  project is not its name's; nil where the
--                                  answer does not say. An adapter with a
--                                  `handoff` opens the item there instead,
--                                  and answers on_done(nil, nil) on success
--   whoami(on_done)             -> on_done(id|nil, err|nil), the account's own
--                                  identifier, asked once per session
--   branch(row)                 -> the branch a row already has, or nil
--   url(row)                    -> where the row is on the web, or nil, err
--   project_of(url)             -> the project path an address names --
--                                  `acme/payments` off a merge request's
--                                  web_url, `owner/repo` off a pull request's
--                                  -- or nil where the adapter cannot say: a
--                                  Jira key names its project itself, and an
--                                  address of another shape than the
--                                  backend's is read as none. The dashboard
--                                  holds a row's against the paths its
--                                  clone's remotes name, through
--                                  repo.same_project(), before a key takes
--                                  the row into the clone, and refuses a row
--                                  none of them names; a row answered nil is
--                                  not refused
--
-- Optional, each named in `capabilities` and implemented only when named.
-- A write's `on_done` may be given a third value, `unsure`, when the client
-- was killed at its timeout after it may have sent the write: the backend may
-- hold what was sent, and sending it again may make it twice.
--
--   comment_create(id, text, on_done)              -> on_done(ok, err)
--   comment_update(id, comment_id, text, on_done)  -> on_done(ok, err)
--   comment_delete(id, comment_id, on_done)        -> on_done(ok, err)
--   body_update(id, text, on_done)                 -> on_done(ok, err)
--   complete(kind, query)                          -> { { id, title }... } for
--                                                     the omnifunc; `kind` is
--                                                     "item" or "user"; blocking
--   states(id, on_done)                            -> on_done({ { label, target }... }|nil, err)
--   state_set(id, target, on_done)                 -> on_done(ok, err)
--   diff(id, on_done)                              -> on_done(diff|nil, err)
--   threads(id, on_done)                           -> on_done(threads|nil, err)
--   line_comment(id, position, text, on_done)      -> on_done(ok, err)
--   thread_resolve(id, thread, on_done)            -> on_done(ok, err)
--   submit(id, verdict, on_done)                   -> on_done(ok, err)
--
-- `text` in every write is the region's buffer text, and the adapter is what
-- serialises it into whatever its backend takes.
--
-- `id` in every call is an identifier string, or a reference, `{ id, cwd }`:
-- the identifier and the directory the call runs in. A client that finds the
-- project from its working directory, as glab does, needs the second, because
-- the same number names a different merge request in another clone, and the
-- directory a state check last recorded belongs to whichever mode was entered
-- last. So the review mode passes a reference for its worktree to every call
-- it makes, and an item() that answers the item with a `ref` has the item
-- buffer pass that reference to every later call about the item -- its
-- saves, its state changes, and the reads that check and follow a save. An
-- adapter that answers no `ref` and has no review calls never meets one.
--
-- An adapter with a `handoff` is given item()'s `id` as the identifier, or
-- as `{ id, url }`, the identifier and the address the row carries, when the
-- dashboard hands one of its rows over: item() names the address to the
-- plugin. `:Docket #12` typed by hand carries no address, and the identifier
-- goes alone.
--
-- Beside the calls, an adapter carries:
--
--   capabilities                -> the OPTIONAL calls the adapter implements
--   handoff                     -> nil, or the name of the plugin an item
--                                  opens in when the adapter renders none of
--                                  its own. The commands then call item()
--                                  directly rather than opening an item
--                                  buffer, with `{ id, url }` for a dashboard
--                                  row, and item() opens it there, on the
--                                  main loop. gh names octo.nvim

local row = require("docket.row")

local M = {}

-- The calls every adapter has.
M.REQUIRED = {
  "auth_status",
  "auth_login",
  "auth_fields",
  "token_url",
  "rows",
  "item",
  "whoami",
  "branch",
  "url",
  "project_of",
}

-- The calls an adapter declares in `capabilities`, each named after the
-- function that carries it out. diff.lua's BODY_UPDATE, COMMENT_UPDATE and
-- COMMENT_CREATE are the calls a save makes, so the suite asserts each is
-- here.
M.OPTIONAL = {
  "comment_create",
  "comment_update",
  "comment_delete",
  "body_update",
  "complete",
  "states",
  "state_set",
  "diff",
  "threads",
  "line_comment",
  "thread_resolve",
  "submit",
}

-- How many parameters each call takes, as the signatures above write them.
-- A function is a function whatever its arity, so without this a `rows`
-- written without its callback, or a `comment_update` missing the comment
-- id, passes verify() and fails as a nil callback at the first save.
M.ARITY = {
  auth_status = 2,
  auth_login = 2,
  auth_fields = 0,
  token_url = 0,
  rows = 2,
  item = 2,
  whoami = 1,
  branch = 1,
  url = 1,
  project_of = 1,
  comment_create = 3,
  comment_update = 4,
  comment_delete = 3,
  body_update = 3,
  complete = 2,
  states = 2,
  state_set = 3,
  diff = 2,
  threads = 2,
  line_comment = 4,
  thread_resolve = 3,
  submit = 3,
}

local optional = {}
for _, name in ipairs(M.OPTIONAL) do
  optional[name] = true
end

-- The arity complaint for a call, or nil when it takes what the contract
-- says. A vararg function's declared count says nothing about what it reads,
-- so it is not held to one.
local function arity_problem(call, fn)
  if M.ARITY[call] == nil then
    return ("%s is in the contract with no arity, so nothing holds it to one"):format(call)
  end
  local info = debug.getinfo(fn, "u")
  if info.isvararg then
    return nil
  end
  if info.nparams ~= M.ARITY[call] then
    return ("%s takes %d parameters and the contract gives it %d"):format(call, info.nparams, M.ARITY[call])
  end
  return nil
end

--- Holds a module to the contract.
---
--- Every required call has to be a function of the arity ARITY gives it;
--- every declared capability has to be one of OPTIONAL and implemented, at
--- that arity; every OPTIONAL call the module implements has to be declared,
--- so that the declaration is what the callers can trust; and a `handoff`,
--- when there is one, has to be a plugin's name, the one shape the contract
--- gives it. Every shortfall is named in one message rather than the first,
--- because a module being built against the contract wants the whole list.
---@param adapter table
---@param name string the adapter's name, for the message
---@return boolean ok
---@return string|nil err
function M.verify(adapter, name)
  local problems = {}
  if type(adapter) ~= "table" then
    return false, ("adapter %s: the module returned %s rather than a table"):format(name, type(adapter))
  end
  for _, call in ipairs(M.REQUIRED) do
    if type(adapter[call]) ~= "function" then
      problems[#problems + 1] = ("required call %s is missing"):format(call)
    else
      problems[#problems + 1] = arity_problem(call, adapter[call])
    end
  end
  local declared = {}
  if type(adapter.capabilities) ~= "table" then
    problems[#problems + 1] = "capabilities is not a list"
  else
    for _, call in ipairs(adapter.capabilities) do
      declared[call] = true
      if not optional[call] then
        problems[#problems + 1] = ("capability %s is not one the contract names"):format(tostring(call))
      elseif type(adapter[call]) ~= "function" then
        problems[#problems + 1] = ("capability %s is declared and not implemented"):format(call)
      else
        problems[#problems + 1] = arity_problem(call, adapter[call])
      end
    end
  end
  for _, call in ipairs(M.OPTIONAL) do
    if adapter[call] ~= nil and not declared[call] then
      problems[#problems + 1] = ("%s is implemented and not declared in capabilities"):format(call)
    end
  end
  if adapter.handoff ~= nil and (type(adapter.handoff) ~= "string" or adapter.handoff == "") then
    problems[#problems + 1] = ("handoff is %s rather than the name of the plugin an item opens in"):format(
      vim.inspect(adapter.handoff)
    )
  end
  if #problems > 0 then
    return false, ("adapter %s: %s"):format(name, table.concat(problems, "; "))
  end
  return true, nil
end

--- Whether an adapter declares a capability.
---@param adapter table
---@param capability string one of OPTIONAL
---@return boolean
function M.can(adapter, capability)
  for _, name in ipairs(adapter.capabilities) do
    if name == capability then
      return true
    end
  end
  return false
end

-- The modules loaded so far, by name. A name that failed to load or to
-- verify is not kept, so the next call reports the same failure rather than
-- a stale one.
local loaded = {}

local function known(name)
  for _, source in ipairs(row.SOURCES) do
    if source == name then
      return true
    end
  end
  return false
end

--- The adapter of that name, loaded on the first call and verified then.
---
--- The names are row.SOURCES. A name outside them is refused with the list; a
--- name inside them whose module cannot be required, or fails verify(), is
--- refused with that message.
---@param name string
---@return table|nil adapter
---@return string|nil err
function M.get(name)
  if loaded[name] then
    return loaded[name]
  end
  if not known(name) then
    return nil, ("no adapter named %s; the adapters are %s"):format(tostring(name), table.concat(row.SOURCES, ", "))
  end
  local path = "docket.adapters." .. name
  local ok, module = pcall(require, path)
  if not ok then
    -- A backend with no module is a fact about this build, and the paths the
    -- loader searched are not the reader's problem: they reach the command line
    -- as a dump of `no file` lines. The name matched has to be this module's
    -- own: a module that exists and whose own require fails reports the same
    -- "not found" for a different name, and that is a defect whose message is
    -- kept whole rather than read as a backend this build does not carry.
    if tostring(module):find(("module '%s' not found"):format(path), 1, true) then
      return nil, ("%s: no adapter in this build"):format(name)
    end
    return nil, ("adapter %s: %s"):format(name, tostring(module))
  end
  local verified, err = M.verify(module, name)
  if not verified then
    return nil, err
  end
  loaded[name] = module
  return module
end

return M
