-- Jira, over acli. Imports adapters, adf, flight, spawn, row and item;
-- adapters for ME and NOBODY alone, the two values assign() takes besides an
-- identifier. Every flag here is one acli's own `--help` lists; the argument
-- lists are written out rather than assembled, so that what runs can be read
-- off this file.
--
-- A work item and its thread arrive in one `view` call, because `view` takes
-- a field list and `comment` is a field. The thread is never read through
-- `comment list`: its `author` is a display name with no `accountId`, and
-- `accountId` is the one field a comment's author and the account's own user
-- object share, so it is the ownership test. `search` holds `--fields` to a
-- list of its own, which ROW_FIELDS' comment describes, and `comment` is
-- outside it, so a row never carries a comment count.
--
-- Writes send a document, never text. Plain text through `--body-file` came
-- back as one paragraph whatever it held, so each write serialises the
-- region through adf and hands acli a file holding the tree: `comment create
-- --body-file`, `comment update --body-adf`, and `--description-file` on
-- `edit` and `create`.
-- UNVERIFIED: no document has been written yet. `--body-adf` is documented as
-- taking one. `--body-file` and `--description-file` are documented as taking
-- "plain text or Atlassian Document Format", and whether they parse a file
-- holding a document as one, rather than posting its JSON as text, is
-- unobserved. What adf.serialise writes for two paragraphs is
--
--   {"type":"doc","version":1,"content":[
--     {"type":"paragraph","content":[{"type":"text","text":"one"}]},
--     {"type":"paragraph","content":[{"type":"text","text":"two"}]}]}
--
-- and a file holding it, posted with `acli jira workitem comment create --key
-- <KEY> --body-file <FILE>` on a work item where a test comment does no harm
-- and read back with `acli jira workitem view <KEY> --fields comment --json`,
-- settles it: two paragraphs back means the file was parsed, a comment reading
-- as JSON means it was not.
-- `--yes` goes on `transition` and `edit` because both prompt without it,
-- and a prompt behind a pipe is a hang. `create` lists no `--yes` and gets
-- none; spawn gives every client a closed standard input, so a build that did
-- stop to ask would fail with its own message rather than hold the editor.
--
-- The account's own identifier comes from a query, since `auth status` prints
-- no identifier and `acli jira` has no user command: the assignee on any row
-- of `assignee = currentUser()` is the account itself, and when nothing is
-- assigned the reporter of a work item from `reporter = currentUser()` is,
-- read by `view <KEY> --fields reporter`, because `reporter` is outside
-- search's documented default list, the only names known to pass its
-- `--fields` check, and `view` checks no name. The answer is held in this
-- module for as long as the editor runs -- one query per session, nothing on
-- disk -- and dropped by auth_login, since a different account may have
-- signed in. Callers asking while the query runs join it, under flight.lua's
-- rule.
--
-- Transitions cannot be listed: `view --fields transitions` returns null. So
-- states() offers the distinct statuses seen across the project's own rows,
-- and a status the workflow refuses surfaces acli's error.
--
-- Every callback here arrives in a fast-event context, as spawn.run's do.

local adapters = require("docket.adapters")
local adf = require("docket.adf")
local flight = require("docket.flight")
local item = require("docket.item")
local row = require("docket.row")
local spawn = require("docket.spawn")

local M = {}

M.capabilities = {
  "comment_create",
  "comment_update",
  "comment_delete",
  "body_update",
  "complete",
  "states",
  "state_set",
  "assign",
  "item_create",
}

-- A work item key, capturing its project. Nothing but this shape reaches a
-- query or a `--key`: a query reaches acli as written and nothing is ANDed in,
-- so an identifier that is not a key would run as whatever JQL it holds, and
-- `--key` takes a comma-separated list, so `TIG-1,TIG-2` would act on both.
-- The shape is env.KEY_PATTERN's read the other way -- that one captures the
-- whole key off the front of a branch, this one the project off a bare key --
-- and the suite asserts the two accept the same identifiers. `%u[%u%d]+`
-- wants two characters at least, so `A-1` is not a key to either.
M.KEY = "^(%u[%u%d]+)%-%d+$"
-- A project key alone, the same prefix; `--project` takes a list as well.
M.PROJECT = "^%u[%u%d]+$"

-- What `view` is asked for. `view` checks no name -- `--fields transitions`
-- answers null rather than an error -- and its own default list is not
-- `search`'s, so both are named explicitly.
M.VIEW_FIELDS = "summary,status,assignee,reporter,updated,description,comment"
-- What `search` is asked for: the key, the status and the title a row
-- renders, and nothing else. `search` holds `--fields` to a list of its own,
-- which neither its help nor Atlassian's reference prints, and refuses a name
-- outside it: `comment` as `field 'comment' is not allowed`, and `updated` on
-- the pinned 1.3.36 with a refusal naming it whose exact wording was not
-- captured. The one list documented is its default,
-- `issuetype,key,assignee,priority,status,summary`. Its help calls them the
-- fields "to display in the output" and no search payload has been seen, so
-- `key` is asked for rather than assumed. Every search here names fields from
-- that list and the suite holds them to it.
M.ROW_FIELDS = "key,summary,status"

M.TOKEN_URL = "https://id.atlassian.com/manage-profile/security/api-tokens"

-- The site, `example.atlassian.net`, read off the `Site:` line of `auth
-- status` or, when that has not run, off the `self` URL of the first row or
-- item read since the last login. url() needs it and nothing else does.
local site = nil

-- The account's own identifier once whoami() has answered.
local identity = nil

-- Bumped by forget(). A list or an item captures the value when it starts and
-- drops what it read when the two no longer agree, because the login flow
-- pumps the event loop: spawn.wait ends in handle:wait(), and vim.fn.confirm
-- and vim.fn.inputsecret wait for a key, and a pending vim.system callback is
-- delivered during any of them. So a search started before `:Docket login`
-- can land inside it, after forget() has run, carrying what the account
-- signed in before it could see.
local generation = 0

-- The whoami() query in flight, under the one key it has. forget() moves the
-- key on, so a query started before a login is neither joined nor remembered.
local WHOAMI = "whoami"
local identity_query = flight.new({
  refusal = "a login ran while the query was in flight, so its answer may be the account that signed out; open the item again",
  accept = function(_, id)
    if id then
      identity = id
    end
  end,
})

-- What complete() answers from: each section's rows by key, under the
-- section's title. Per section because the dashboard runs its Jira sections
-- at once, and one table for all of them would hold whichever section
-- finished last. A section's rows replace its own, so the candidates are the
-- keys the sections are showing: a refresh is what carries a ticket that has
-- left a section, and a summary that has been edited.
local last_rows = {}

-- The document files handed to acli and not yet removed. A client that exits
-- normally, fails, times out or is missing reaches its callback and the file
-- is removed there; a client killed with the editor never calls back, so
-- VimLeavePre removes whatever is still here. Each holds a comment body,
-- which is why it is not left in the temporary directory.
local pending_files = {}

-- Registered at load where the context allows it, and on a scheduled callback
-- only where it does not: the registry loads this module the first time it is
-- asked for, which can be inside a spawn.run callback, where
-- nvim_create_augroup is an error. Scheduling it unconditionally leaves the hook
-- absent for a turn, and a module loaded and a document written in that turn
-- leaves the file behind when the editor exits -- which is the case the hook is
-- for.
local function register_leave_hook()
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("docket_jira_files", { clear = true }),
    callback = function()
      for path in pairs(pending_files) do
        vim.uv.fs_unlink(path)
      end
      pending_files = {}
    end,
  })
end

if vim.in_fast_event() then
  vim.schedule(register_leave_hook)
else
  register_leave_hook()
end

local function acli(args, opts, on_done)
  return spawn.run(vim.list_extend({ "acli", "jira" }, args), opts, on_done)
end

-- An argument list as a line to paste at a prompt, through spawn.shell_line:
-- a JQL clause carries spaces, its `(PAY, TIG)` opens a command substitution
-- in fish when left bare, and `\\` is how JQL escapes a reserved character.
local shell_line = spawn.shell_line

-- A person as item.new takes one, from the user object acli returns.
local function person(user)
  if type(user) ~= "table" then
    return nil
  end
  return { id = user.accountId, name = user.displayName }
end

local function remember_site(self_url)
  if site == nil and type(self_url) == "string" then
    site = self_url:match("^https?://([^/]+)")
  end
end

-- The category of a status: `new`, `indeterminate` or `done`, Jira's own
-- grouping of every workflow's statuses, which a state is coloured by because
-- a status name is the workflow's own word. nil when the payload carries none.
-- UNVERIFIED: the probe printed no status object, so `statusCategory.key`
-- comes from Jira's REST reference rather than from a payload; `acli jira
-- workitem view <KEY> --fields status --json`, with any work item key, prints
-- it.
local function category_of(status)
  local grouping = type(status) == "table" and status.statusCategory or nil
  if type(grouping) == "table" and type(grouping.key) == "string" then
    return grouping.key
  end
  return nil
end

-- The rows in a decoded search payload. Neither shape has been seen: the
-- probe printed a count it computed rather than the payload. Both are read
-- -- a bare list, and an object holding `issues` as the search endpoint
-- returns one and `view --json` passes its own payload through -- and
-- anything else is refused at the decode point with the command to run.
local function rows_of(decoded)
  if vim.islist(decoded) then
    return decoded
  end
  if type(decoded) == "table" and vim.islist(decoded.issues) then
    return decoded.issues
  end
  return nil
end

-- Runs a search and hands the rows to on_done, or the reason there are none.
-- `--paginate` walks every page ("Fetch all work items by paginating through
-- the results" in acli 1.3.39's help; the probe on the pinned release did not
-- print that help). The probe's one search without it returned exactly 30
-- rows, so a count stopping at a round number means it was not honoured.
local function search(jql, fields, paginate, on_done)
  local args = { "workitem", "search", "--jql", jql, "--json", "--fields", fields }
  if paginate then
    args[#args + 1] = "--paginate"
  end
  acli(args, nil, function(result)
    if not result.ok then
      return on_done(nil, spawn.message(result))
    end
    local decoded, err = spawn.decode(result)
    if err then
      return on_done(nil, err)
    end
    local found = rows_of(decoded)
    if not found then
      return on_done(
        nil,
        ("acli: the search printed neither a list nor an object holding `issues`; run\n  %s\nby hand to see what it prints"):format(
          shell_line(result.argv)
        )
      )
    end
    on_done(found)
  end)
end

-- Removes a document file and forgets it.
local function forget_file(path)
  pending_files[path] = nil
  vim.uv.fs_unlink(path)
end

-- Writes a document to a file and hands the path on; the caller removes it
-- with forget_file() once the client has exited. fs_mkstemp rather than
-- vim.fn.tempname() because of the mode: mkstemp creates the file 0600
-- before returning its descriptor, while tempname() returns a name and
-- whatever then opens it does so under the process umask -- and what the
-- file holds is a comment body, on a server other accounts share.
local function document_file(text)
  local template = vim.uv.os_tmpdir() .. "/docket-XXXXXX"
  local fd, path = vim.uv.fs_mkstemp(template)
  if not fd then
    return nil, ("cannot create %s: %s"):format(template, tostring(path))
  end
  pending_files[path] = true
  local json = vim.json.encode(adf.serialise(text))
  local _, err = vim.uv.fs_write(fd, json)
  vim.uv.fs_close(fd)
  if err then
    forget_file(path)
    return nil, ("cannot write %s: %s"):format(path, err)
  end
  return path
end

-- One line for a result entry's `error`. Jira's REST errors are objects --
-- `errorMessages`, a list, and `errors`, a field-to-message map -- and acli
-- passes payloads through as they came, so a string is not the only shape.
local function error_text(err)
  if type(err) ~= "table" then
    return tostring(err)
  end
  local parts = {}
  for _, message in ipairs(vim.islist(err.errorMessages) and err.errorMessages or {}) do
    parts[#parts + 1] = tostring(message)
  end
  if type(err.errors) == "table" then
    local fields = vim.tbl_keys(err.errors)
    table.sort(fields)
    for _, field in ipairs(fields) do
      parts[#parts + 1] = ("%s: %s"):format(field, tostring(err.errors[field]))
    end
  end
  if #parts == 0 then
    return vim.json.encode(err)
  end
  return table.concat(parts, "; ")
end

-- A write's outcome. acli exits non-zero and writes its complaint to stderr
-- when it fails, and with `--json` the bulk commands also print a summary
-- with `successCount` and `totalCount`, so a call that reports no success
-- with exit code zero is refused with the results' own error. UNVERIFIED: the
-- summary's field names -- `successCount`, `totalCount`, `results`, and
-- `error` and `key` on each result -- come from no payload the probe printed,
-- and a payload without `totalCount` is taken as success on the exit code
-- alone. The third value is set when the client was killed at its timeout,
-- when whatever it sent may have reached Jira.
local function outcome(result)
  if not result.ok then
    return false, spawn.message(result), result.timed_out == true
  end
  -- The decode error is dropped on purpose: `comment update` has no `--json`
  -- and `comment delete` prints nothing, so stdout that is not JSON is the
  -- ordinary successful case here, and checking it would fail every one.
  local decoded = spawn.decode(result)
  if type(decoded) == "table" and decoded.totalCount and (decoded.successCount or 0) < decoded.totalCount then
    local reasons = {}
    for _, entry in ipairs(vim.islist(decoded.results) and decoded.results or {}) do
      if entry.error ~= nil then
        local text = error_text(entry.error)
        reasons[#reasons + 1] = entry.key and ("%s: %s"):format(entry.key, text) or text
      end
    end
    if #reasons == 0 then
      reasons[1] = "acli reported no success"
    end
    return false, table.concat(reasons, "\n")
  end
  return true, nil
end

-- Runs a write that takes the region's text through a document file, and
-- removes the file once the client has exited.
local function write_document(args, flag, text, on_done)
  local path, err = document_file(text)
  if not path then
    return on_done(false, err)
  end
  args[#args + 1] = flag
  args[#args + 1] = path
  acli(args, nil, function(result)
    forget_file(path)
    on_done(outcome(result))
  end)
end

-- The state `auth status` reports. The site is kept only while `started` is
-- still the generation: a check that was running when forget() ran reports
-- the account signed in before the login, and its site would replace the one
-- the login named.
local function status_of(result, started)
  local authenticated = result.ok and result.stdout:find("%f[%w]Authenticated%f[%W]") ~= nil
  if authenticated and started == generation then
    local named = result.stdout:match("Site:%s*(%S+)")
    if named then
      site = named
    end
  end
  return {
    authenticated = authenticated,
    missing = result.code == spawn.MISSING,
    detail = result.ok and vim.trim(result.stdout) or spawn.message(result),
  }
end

--- Whether acli has an account signed in.
---
--- `auth status` prints `✓ Authenticated` and then the site, the address and
--- the authentication type, so the word is the test; the site is kept for
--- url(). Read from the output rather than the exit code alone, which is what
--- octo.nvim does with `gh auth status`. Whether an expired token still
--- reports as authenticated is unobserved; `:Docket! login jira` signs in
--- regardless.
---
--- Without on_done this blocks and returns the state; with it, acli runs
--- through spawn.run and the state goes to on_done in a fast-event context.
--- The clone the contract's `cwd` names is not read: acli's verdict is the
--- account's, the same in every directory.
---@param on_done fun(status: { authenticated: boolean, missing: boolean, detail: string })|nil
---@param _ string|nil the contract's `cwd`, unused here
---@return { authenticated: boolean, missing: boolean, detail: string }|nil status nil when on_done is given
function M.auth_status(on_done, _)
  local argv = { "acli", "jira", "auth", "status" }
  local started = generation
  if on_done == nil then
    return status_of(spawn.wait(argv), started)
  end
  spawn.run(argv, nil, function(result)
    on_done(status_of(result, started))
  end)
  return nil
end

--- What a first login needs besides the token.
---@return { name: string, prompt: string, default: string|nil }[]
function M.auth_fields()
  return {
    { name = "site", prompt = "Jira site, as example.atlassian.net", default = site },
    { name = "email", prompt = "Atlassian account email" },
  }
end

--- Logs in with an API token.
---
--- The token goes to acli on standard input, with the newline `< token.txt`
--- would carry, and never in the argument list. The remembered identity is
--- dropped whatever the outcome, because a login the client refuses may have
--- replaced its stored credentials as well. The site is then the one signed in
--- to on success, and on a failure the one known until now.
---@param token string
---@param fields { site: string, email: string }
---@return table result the spawn result
function M.auth_login(token, fields)
  local previous = site
  M.forget()
  local result = spawn.wait(
    { "acli", "jira", "auth", "login", "--site", fields.site, "--email", fields.email, "--token" },
    { stdin = token .. "\n" }
  )
  site = result.ok and fields.site or previous
  return result
end

--- Drops what was learnt under the account signed in until now: the
--- remembered identity, so the next whoami() asks again; the last rows, so
--- complete() offers no key from the previous account's projects; and the
--- site, which the next status or read names again. A query already in flight
--- is told apart by the generation it started in: a whoami() answer is not
--- remembered and a caller asking after this starts a query of its own, and a
--- list or an item that lands afterwards is refused or read without the
--- identity.
function M.forget()
  identity = nil
  last_rows = {}
  site = nil
  generation = generation + 1
  identity_query:invalidate(WHOAMI)
end

--- The page where an API token is minted.
---@return string
function M.token_url()
  return M.TOKEN_URL
end

--- The rows a section's query returns, normalised by row.new.
---
--- A row the client returned that row.new refuses -- one with no status, or
--- no summary -- is left out and named in `warning`, while the rest are
--- given; only when no row survives is the whole section an error, since
--- one broken row out of two hundred is not a reason to show none.
---@param section { title: string|nil, query: string } one the dashboard shows
---@param on_done fun(rows: table[]|nil, err: string|nil, warning: string|nil)
function M.rows(section, on_done)
  -- A search can take seconds, and a login during it drops the rows and the
  -- site the section would otherwise fill back in as the new account's.
  local started = generation
  search(section.query, M.ROW_FIELDS, true, function(found, err)
    if started ~= generation then
      return on_done(
        nil,
        "jira: a login ran while this section was in flight, so its rows are not shown; refresh to ask again"
      )
    end
    if not found then
      return on_done(nil, err)
    end
    local rows, reasons = {}, {}
    for _, entry in ipairs(found) do
      local fields = type(entry.fields) == "table" and entry.fields or {}
      remember_site(entry.self)
      local ok, built = pcall(row.new, {
        source = "jira",
        id = entry.key,
        state = fields.status and fields.status.name or "",
        category = category_of(fields.status),
        title = fields.summary,
      })
      if ok then
        rows[#rows + 1] = built
      else
        reasons[#reasons + 1] = tostring(built)
      end
    end
    if #rows == 0 and #reasons > 0 then
      return on_done(nil, table.concat(reasons, "\n"))
    end
    -- This section's completion candidates, in place of the ones it returned
    -- before, under the title the dashboard identifies a section by; a
    -- section with no title shares one slot with the rest that have none. A
    -- section that failed, or whose every row was refused, exited above and
    -- keeps the candidates it had.
    local seen = {}
    for _, built in ipairs(rows) do
      seen[built.id] = built
    end
    last_rows[section.title or ""] = seen
    on_done(rows, nil, #reasons > 0 and table.concat(reasons, "\n") or nil)
  end)
end

-- The `accountId` of a user object as acli returns one, or nil.
local function identifier_of(user)
  if type(user) == "table" and user.accountId then
    return user.accountId
  end
  return nil
end

-- The identifier off the first row that carries one under `field`.
local function identifier_in(found, field)
  for _, entry in ipairs(found) do
    local id = identifier_of(entry.fields and entry.fields[field])
    if id then
      return id
    end
  end
  return nil
end

-- The key off the first row that carries one of a work item's shape. Only that
-- shape reaches `view`, for the reason KEY states.
local function key_in(found)
  for _, entry in ipairs(found) do
    if type(entry.key) == "string" and entry.key:match(M.KEY) then
      return entry.key
    end
  end
  return nil
end

--- The account's own identifier, asked once per session.
---
--- The assignee on any row of `assignee = currentUser()` is the account
--- itself. With nothing assigned, the reporter of a work item from
--- `reporter = currentUser()` is, read by `view <KEY> --fields reporter`:
--- `reporter` is outside search's documented default list, the only names
--- known to pass its `--fields` check, and `view` checks no name. A view that
--- fails, or prints no JSON, answers with the key it read and acli's own
--- words beneath, and one that prints no reporter with the line to run by
--- hand. With nothing assigned or reported, or with no reported key of a
--- work item's shape, the reason says to assign the account one work item.
--- No failure is remembered, so the next call asks again. Callers during the
--- query join it. An answer landing after forget() has run was asked under
--- whatever account was signed in then, so it is replaced by a reason to open
--- the item again rather than trusted: a login drops the identity whether it
--- succeeded or not, because either way the client's stored credentials may
--- have changed.
---@param on_done fun(id: string|nil, err: string|nil)
function M.whoami(on_done)
  if identity then
    return on_done(identity)
  end
  identity_query:join(WHOAMI, function(settle)
    search("assignee = currentUser()", "assignee", false, function(assigned, err)
      if not assigned then
        return settle(nil, err)
      end
      local id = identifier_in(assigned, "assignee")
      if id then
        return settle(id)
      end
      -- The key alone: `view` is given it, and `key` is in the list
      -- ROW_FIELDS' comment gives.
      search("reporter = currentUser()", "key", false, function(reported, err_reported)
        if not reported then
          return settle(nil, err_reported)
        end
        local key = key_in(reported)
        if not key and #reported > 0 then
          local first = type(reported[1]) == "table" and reported[1].key or reported[1]
          return settle(
            nil,
            ("the account's own identifier is unknown: no work item is assigned to it, and no work item it reported has a key of the shape PROJ-123, the first being %s. Assign it one work item and open the item again"):format(
              tostring(first)
            )
          )
        end
        if not key then
          return settle(
            nil,
            "the account's own identifier is unknown: no work item is assigned to it or reported by it, and acli has no user command. Assign it one work item and open the item again"
          )
        end
        local argv = { "workitem", "view", key, "--fields", "reporter", "--json" }
        acli(argv, nil, function(result)
          -- A failure names the lookup and the key: the reason reaches the
          -- buffer of whatever work item was opened, not `key`'s, and acli's
          -- words alone say nothing about why `key` was read.
          local function unknown(reason)
            return settle(
              nil,
              ("the account's own identifier is unknown: reading the reporter of %s, a work item it reported, failed\n%s"):format(
                key,
                reason
              )
            )
          end
          if not result.ok then
            return unknown(spawn.message(result))
          end
          local decoded, err_decoded = spawn.decode(result)
          if err_decoded then
            return unknown(err_decoded)
          end
          local fields = type(decoded) == "table" and decoded.fields or nil
          id = identifier_of(type(fields) == "table" and fields.reporter or nil)
          if id then
            return settle(id)
          end
          settle(
            nil,
            ("acli: view %s printed no reporter carrying an accountId, so the account's own identifier is unknown; run\n  %s\nby hand to see what it prints"):format(
              key,
              shell_line(result.argv)
            )
          )
        end)
      end)
    end)
  end, on_done)
end

--- One work item with its thread, built by item.new.
---
--- `me` is whoami()'s answer, and nil when it could not answer -- the item
--- still opens, with every comment read-only for want of an ownership test,
--- and `me_err` carries the reason for the buffer to show. A comment's
--- `author` is what ownership is judged by; `updateAuthor`, which the client
--- also returns, is not read, because Jira grants the right to edit a
--- comment by its author.
---@param id string the key, `PROJ-142`
---@param on_done fun(item: table|nil, err: string|nil, me_err: string|nil)
function M.item(id, on_done)
  -- `view` outlives the identity: whoami() answers, and a login while `view`
  -- runs may sign a different account in. So the generation is captured here,
  -- and when it has moved the identity is dropped, which leaves every comment
  -- read-only with the reason beside it, and the site is not read off the
  -- payload.
  local started = generation
  M.whoami(function(me, me_err)
    acli({ "workitem", "view", id, "--fields", M.VIEW_FIELDS, "--json" }, nil, function(result)
      if not result.ok then
        return on_done(nil, spawn.message(result))
      end
      local decoded, err = spawn.decode(result)
      if err then
        return on_done(nil, err)
      end
      if type(decoded) ~= "table" or type(decoded.fields) ~= "table" then
        return on_done(nil, ("acli: view %s printed no `fields` object"):format(id))
      end
      if started ~= generation then
        me, me_err = nil, "a login ran while the item was read; open it again"
      else
        remember_site(decoded.self)
      end
      local fields = decoded.fields
      local thread = type(fields.comment) == "table" and fields.comment or {}
      local comments = {}
      for index, comment in ipairs(vim.islist(thread.comments) and thread.comments or {}) do
        comments[index] = {
          id = comment.id,
          author = person(comment.author),
          created = comment.created,
          updated = comment.updated,
          body = comment.body,
        }
      end
      local key = decoded.key or id
      local ok, built = pcall(item.new, {
        source = "jira",
        id = key,
        title = fields.summary,
        state = fields.status and fields.status.name,
        category = category_of(fields.status),
        url = M.url({ id = key }),
        assignee = person(fields.assignee),
        reporter = person(fields.reporter),
        updated = fields.updated,
        body = fields.description,
        comments = comments,
        total = thread.total,
        start_at = thread.startAt,
        me = me,
      })
      if not ok then
        return on_done(nil, tostring(built))
      end
      on_done(built, nil, me_err)
    end)
  end)
end

--- The branch a row already has: none. A ticket has no branch until the
--- launcher generates one from its key and summary.
---@param _ table the row
---@return nil
function M.branch(_)
  return nil
end

--- Where a row is on the web.
---
--- The site comes from `auth status` or from a row or an item already read,
--- so a call before any of those -- `gx` in an item buffer a session restored
--- and nothing has read -- has nothing to build the address from.
---@param r { id: string }
---@return string|nil url
---@return string|nil err
function M.url(r)
  if not site then
    return nil, "the Jira site is not known until an item or a list has been read; :e reads this one"
  end
  return ("https://%s/browse/%s"):format(site, r.id)
end

--- The project a row's address names: none. A ticket's key names its
--- project, `PAY` in `PAY-1234`, and a clone is bound to Jira projects by
--- its configuration rather than named after one, so there is no clone's
--- project to hold an address against, and the dashboard refuses no ticket
--- row.
---@param _ string|nil the address
---@return nil
function M.project_of(_)
  return nil
end

--- Adds a comment, as a document. UNVERIFIED: whether `--body-file` parses the
--- file as a document is unobserved; the header says what settles it.
---@param id string the key
---@param text string the region's text
---@param on_done fun(ok: boolean, err: string|nil)
function M.comment_create(id, text, on_done)
  write_document({ "workitem", "comment", "create", "--key", id, "--json" }, "--body-file", text, on_done)
end

--- Replaces a comment's body, as a document.
---@param id string the key
---@param comment_id string the comment's `id` as `view --fields comment` returns it
---@param text string the region's text
---@param on_done fun(ok: boolean, err: string|nil)
function M.comment_update(id, comment_id, text, on_done)
  write_document(
    { "workitem", "comment", "update", "--key", id, "--id", comment_id },
    "--body-adf",
    text,
    on_done
  )
end

--- Deletes a comment.
---
--- `comment delete` takes `--key` and `--id` and has no `--yes`, so the
--- delete happens on this call and any confirmation belongs to whatever
--- binds it. spawn gives the client a closed standard input, so a build that
--- did stop to ask would fail with its own message rather than hold the
--- editor.
---@param id string the key
---@param comment_id string
---@param on_done fun(ok: boolean, err: string|nil)
function M.comment_delete(id, comment_id, on_done)
  acli({ "workitem", "comment", "delete", "--key", id, "--id", comment_id }, nil, function(result)
    on_done(outcome(result))
  end)
end

--- Replaces the description, as a document. UNVERIFIED: whether
--- `--description-file` parses the file as a document is unobserved; the
--- header says what settles it.
---@param id string the key
---@param text string the region's text
---@param on_done fun(ok: boolean, err: string|nil)
function M.body_update(id, text, on_done)
  write_document({ "workitem", "edit", "--key", id, "--yes", "--json" }, "--description-file", text, on_done)
end

--- Completion candidates, from the rows each section last returned.
---
--- Item references match the key by prefix, case-insensitively, in the
--- dashboard's own order -- row.sort, by key prefix and then by number -- so
--- the list is the same whichever section finished last, and a key two
--- sections both returned is offered once. Users are not offered: a mention
--- is a `mention` node carrying an `accountId`, and the serialiser emits
--- none, so a completed name would post as its literal characters.
---@param kind string "item" or "user"
---@param query string what has been typed since the trigger
---@return { id: string, title: string }[]
function M.complete(kind, query)
  local found = {}
  if kind ~= "item" then
    return found
  end
  local needle = query:lower()
  local rows, taken = {}, {}
  for _, section_rows in pairs(last_rows) do
    for key, r in pairs(section_rows) do
      if not taken[key] then
        taken[key] = true
        rows[#rows + 1] = r
      end
    end
  end
  for _, r in ipairs(row.sort(rows)) do
    if r.id:lower():sub(1, #needle) == needle then
      found[#found + 1] = { id = r.id, title = r.title }
    end
  end
  return found
end

--- The statuses a transition can be asked for: the distinct ones seen across
--- the project's recently updated rows, sorted, each as `{ label, target }`
--- with both the status name. The project is the key's prefix.
---@param id string the key
---@param on_done fun(states: { label: string, target: string }[]|nil, err: string|nil)
function M.states(id, on_done)
  -- The project is the key's prefix, and only a key's shape reaches the
  -- query, for the reason KEY states.
  local project = id:match(M.KEY)
  if not project then
    return on_done(nil, ("%s is not a work item key, so its project is unknown"):format(id))
  end
  -- One page, not `--paginate`: a workflow's statuses are all present among
  -- the rows updated most recently, and walking every row of a large
  -- project takes minutes or hits spawn's timeout.
  search(("project = %s ORDER BY updated DESC"):format(project), "status", false, function(found, err)
    if not found then
      return on_done(nil, err)
    end
    local seen, names = {}, {}
    for _, entry in ipairs(found) do
      local name = entry.fields and entry.fields.status and entry.fields.status.name
      if name and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
    table.sort(names)
    local states = {}
    for index, name in ipairs(names) do
      states[index] = { label = name, target = name }
    end
    on_done(states)
  end)
end

--- Transitions a work item to a status by name. A status the workflow
--- refuses, or one behind required fields, fails with acli's own message.
---@param id string the key
---@param target string the status name
---@param on_done fun(ok: boolean, err: string|nil)
function M.state_set(id, target, on_done)
  acli({ "workitem", "transition", "--key", id, "--status", target, "--yes", "--json" }, nil, function(result)
    on_done(outcome(result))
  end)
end

-- The `--assignee` value for a person, which `edit --help` and `create --help`
-- both document as an email address or an account identifier, with `@me` for
-- the account signed in. `default`, the project's default assignee, is the
-- other word both take; no identifier Jira issues is that word, so it passes
-- through like one, and nothing in the contract asks for it. nil and the
-- reason for anything that is neither ME nor a non-empty identifier. NOBODY is
-- the caller's to handle, since `edit` spells it `--remove-assignee` and
-- `create` by leaving the flag out.
local function assignee_value(who)
  if who == adapters.ME then
    return "@me"
  end
  if type(who) ~= "string" or who == "" or who == adapters.NOBODY then
    return nil, ("%s is not a person to assign"):format(vim.inspect(who))
  end
  return who
end

--- Assigns a work item to one person, or to nobody.
---
--- `edit --assignee` with `--yes`, which `edit` prompts without, or `edit
--- --remove-assignee` for NOBODY. ME goes to acli as its own `@me`, so it
--- works whether or not whoami() can answer -- which is the account with
--- nothing assigned that most needs it. UNVERIFIED: both flags are in the
--- `edit --help` the pinned release printed, and no edit carrying either has
--- been run; `acli jira workitem edit --key <KEY> --assignee @me --yes --json`
--- on a work item where it does no harm, read back with `acli jira workitem
--- view <KEY> --fields assignee --json`, settles both at once.
---@param id string the key
---@param who string ME, NOBODY, or an `accountId` as a person's `id` carries it
---@param on_done fun(ok: boolean, err: string|nil)
function M.assign(id, who, on_done)
  if type(id) ~= "string" or not id:match(M.KEY) then
    return on_done(false, ("%s is not a work item key"):format(tostring(id)))
  end
  local args = { "workitem", "edit", "--key", id }
  if who == adapters.NOBODY then
    args[#args + 1] = "--remove-assignee"
  else
    local value, err = assignee_value(who)
    if not value then
      return on_done(false, err)
    end
    vim.list_extend(args, { "--assignee", value })
  end
  vim.list_extend(args, { "--yes", "--json" })
  acli(args, nil, function(result)
    on_done(outcome(result))
  end)
end

-- The creates in flight, keyed by everything a create sends, so a second
-- save of the same buffer while the first is running is handed the first's
-- key rather than making a second work item. Nothing invalidates a key here:
-- a create that lands after a login has still made a work item, and refusing
-- its key would invite a second one. The refusal is flight's to require and
-- is never given.
local creating = flight.new({
  refusal = "the create was abandoned; search the project for it before creating it again",
})

-- The key a create printed, or nil. `project` is the one asked for; a key of
-- any other project is not this create's.
--
-- UNVERIFIED: no create has been run, so what `create --json` prints is
-- unobserved. It is read three ways, the first that answers winning: an object
-- carrying `key`, which is what Jira's own create endpoint answers with
-- beside `id` and `self`; the bulk summary outcome() reads, whose `results`
-- carry `key`; and, for any other shape, the output as text, where exactly one
-- distinct key of the project, other than a key the summary itself mentions,
-- is the answer. Two or more is no answer rather than a guess, because the
-- buffer reopens at whatever this returns. `acli jira workitem create
-- --project <KEY> --type Task --summary probe --json`, on a project where a
-- test work item does no harm, prints which shape it is.
local function created_key(result, project, summary)
  local function ours(key)
    return type(key) == "string" and key:match(M.KEY) == project
  end
  -- The decode error is dropped on purpose: output that is not JSON is read
  -- as text below.
  local decoded = spawn.decode(result)
  if type(decoded) == "table" then
    if ours(decoded.key) then
      return decoded.key
    end
    for _, entry in ipairs(vim.islist(decoded.results) and decoded.results or {}) do
      if type(entry) == "table" and ours(entry.key) then
        return entry.key
      end
    end
  end
  local mentioned = {}
  for key in summary:gmatch("%f[%w](%u[%u%d]+%-%d+)%f[^%w]") do
    mentioned[key] = true
  end
  local found, distinct = nil, 0
  local seen = {}
  for key in result.stdout:gmatch("%f[%w](%u[%u%d]+%-%d+)%f[^%w]") do
    if ours(key) and not mentioned[key] and not seen[key] then
      seen[key] = true
      found, distinct = key, distinct + 1
    end
  end
  return distinct == 1 and found or nil
end

--- Creates a work item and answers with its key.
---
--- `create --project --type --summary --json`, with `--assignee` when one is
--- asked for and the body as a document through `--description-file`, as
--- body_update() sends one; a body of blank lines alone sends no description.
--- `project`, `type` and `summary` are required: Jira's create endpoint
--- refuses an item without any of them, and what acli does in their absence --
--- its help also lists `--editor` -- is unobserved. `project` is one project
--- key, because `--project` takes a list and would make an item in each.
---
--- UNVERIFIED: every flag here is read from the `create --help` of acli
--- 1.3.39, a later release than the pinned 1.3.36, whose own help is not
--- recorded; no create has been run against a real instance; and whether
--- `--description-file` parses a document is the question the header leaves
--- open for `edit`. How the key is read off the output is created_key()'s
--- note. A create that acli reports as done and whose key cannot be read, and
--- one killed at the timeout after it was sent, answer with `made` set beside
--- the error, which names the search that lists the project's newest items:
--- the item exists, or may, and creating it again would make a second one.
---@param fields { project: string, type: string, summary: string, assignee: string|nil }
---@param text string the body region's text
---@param on_done fun(id: string|nil, err: string|nil, made: boolean|nil)
function M.item_create(fields, text, on_done)
  if type(fields) ~= "table" then
    return on_done(nil, "a work item needs a project, a type and a summary")
  end
  local missing = {}
  for _, name in ipairs({ "project", "type", "summary" }) do
    if type(fields[name]) ~= "string" or vim.trim(fields[name]) == "" then
      missing[#missing + 1] = name
    end
  end
  if #missing > 0 then
    return on_done(nil, ("a work item needs a %s"):format(table.concat(missing, ", a ")))
  end
  if not fields.project:match(M.PROJECT) then
    return on_done(nil, ("%s is not a project key such as PROJ"):format(fields.project))
  end
  local args = {
    "workitem",
    "create",
    "--project",
    fields.project,
    "--type",
    fields.type,
    "--summary",
    fields.summary,
    "--json",
  }
  if fields.assignee ~= nil and fields.assignee ~= adapters.NOBODY then
    local value, err = assignee_value(fields.assignee)
    if not value then
      return on_done(nil, err)
    end
    vim.list_extend(args, { "--assignee", value })
  end
  local blank = type(text) ~= "string" or text:match("^%s*$") ~= nil
  local request = table.concat({
    fields.project,
    fields.type,
    fields.summary,
    fields.assignee or "",
    blank and "" or text,
  }, "\0")
  creating:join(request, function(settle)
    local path
    if not blank then
      local err
      path, err = document_file(text)
      if not path then
        return settle(nil, err)
      end
      vim.list_extend(args, { "--description-file", path })
    end
    acli(args, nil, function(result)
      if path then
        forget_file(path)
      end
      local search = shell_line({
        "acli",
        "jira",
        "workitem",
        "search",
        "--jql",
        ("project = %s ORDER BY created DESC"):format(fields.project),
        "--fields",
        "summary",
        "--json",
      })
      local ok, err, unsure = outcome(result)
      if unsure then
        return settle(
          nil,
          ("%s\nthe create may have reached Jira before acli was killed; creating it again could make a second one. The project's newest work items come first in\n  %s"):format(
            err,
            search
          ),
          true
        )
      end
      if not ok then
        return settle(nil, err)
      end
      local key = created_key(result, fields.project, fields.summary)
      if key then
        return settle(key)
      end
      local printed = vim.trim(result.stdout)
      settle(
        nil,
        ("acli reported the work item created and printed no key that can be read, so it cannot be opened here; creating it again would make a second one. The project's newest work items come first in\n  %s%s"):format(
          search,
          printed ~= "" and ("\nacli printed:\n" .. printed) or ""
        ),
        true
      )
    end)
  end, on_done)
end

return M
