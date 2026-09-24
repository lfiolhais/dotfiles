-- The login flow: the state check, the prompts, the login with the token on
-- standard input, and the state a mode reports when a backend is not signed
-- in. Imports cache, config, spawn and the adapter registry. One flow serves
-- every backend because each client takes a token on standard input and each
-- adapter's auth_fields() names what its first login needs besides it.
--
-- login() runs on the main loop, from a user command, which is why the
-- prompts are safe here and would not be inside a mode: vim.fn.inputsecret
-- cannot run in a fast-event context, and every spawn.run callback arrives in
-- one. So login() makes the blocking form of both authentication calls, and
-- the flow is one straight line. A mode asks for the state through ready(),
-- which blocks as well, or through check(), which does not.
--
-- The token is read with inputsecret and handed to the client as its standard
-- input, so it never reaches an argument list, a file, a shell history or the
-- process list. Nothing is stored here: each client keeps its own credential
-- store, and this plugin tracks none of them.

local adapters = require("docket.adapters")
local cache = require("docket.cache")
local config = require("docket.config")
local spawn = require("docket.spawn")

local M = {}

-- The command a mode names when a backend is not signed in, and the form
-- that signs in again. The bang goes on the command name, because Vim reads a
-- bang only there: `:Docket login! jira` passes `login!` as an argument, and
-- the command refuses it.
M.LOGIN_COMMAND = ":Docket login"
M.RELOGIN_COMMAND = ":Docket! login"

-- How many logins have run for each backend, by adapter name. check()
-- compares the count when its answer lands with the count when it asked,
-- because a state check running while a login replaces the account describes
-- the account signed in before it.
local logins = {}

-- The adapter, or nil and the message a mode reports, from the state its
-- check answered. The message names the login command, or says the client is
-- not installed, since a login cannot fix that.
local function verdict(name, adapter, status)
  if status.missing then
    return nil, ("%s: the client is not installed\n%s"):format(name, status.detail)
  end
  if not status.authenticated then
    return nil, ("%s: not signed in; run %s %s\n%s"):format(name, M.LOGIN_COMMAND, name, status.detail)
  end
  return adapter
end

--- The adapter, when its client has an account signed in.
---
--- Every mode asks this, or check(), before it asks for anything else, and
--- reports the message rather than prompting.
---
--- This blocks: auth_status() runs the client through spawn.wait, which is
--- an error in a fast-event context, and every client's state check reaches
--- its host, so the editor waits for that host up to the client timeout. So
--- it runs on the main loop -- from a user command or a keymap, never from a
--- spawn callback -- for a mode that goes no further until it has the answer;
--- such a mode asks it once at entry and then makes only the callback-taking
--- calls.
---
--- `cwd` is the clone the check is about, handed to the adapter as the
--- contract has it: `<CR>` on a dashboard row passes the root the dashboard
--- shows, so that a merge request opens from the clone the row was fetched
--- in. With none the adapter reads the editor's directory, which is what
--- `:Docket <id>` asks for.
---@param name string the adapter's name
---@param cwd string|nil
---@return table|nil adapter
---@return string|nil message
function M.ready(name, cwd)
  local adapter, err = adapters.get(name)
  if not adapter then
    return nil, err
  end
  return verdict(name, adapter, adapter.auth_status(nil, cwd))
end

--- What ready() answers, handed to on_done instead, with the editor free
--- while the client runs. The dashboard asks this way, so that its first
--- paint waits for no host.
---
--- on_done(adapter|nil, message|nil) runs once: in a fast-event context once
--- the client has answered, as a spawn.run callback does, so a caller that
--- touches a buffer schedules that work; or before check returns, on the
--- caller's own context, when no process started -- the adapter did not
--- load, or spawn.run could not start the client. An answer that lands after
--- a login for the same backend has run is replaced by a message saying so,
--- since it describes the account signed in before that login.
---
--- It is called on the main loop, as ready() is, because an adapter given no
--- `cwd` reads the editor's directory when it starts the check. `cwd` is the
--- clone the check is about, handed to the adapter as the contract has it;
--- the dashboard passes the root it shows.
---@param name string the adapter's name
---@param on_done fun(adapter: table|nil, message: string|nil)
---@param cwd string|nil
function M.check(name, on_done, cwd)
  local adapter, err = adapters.get(name)
  if not adapter then
    return on_done(nil, err)
  end
  local asked = logins[name] or 0
  adapter.auth_status(function(status)
    if (logins[name] or 0) ~= asked then
      return on_done(
        nil,
        ("%s: a login ran while the state check was in flight, so its answer is not shown; refresh to ask again"):format(
          name
        )
      )
    end
    on_done(verdict(name, adapter, status))
  end, cwd)
end

-- A field's value: what setup{} carries for this backend, or the answer to a
-- prompt. setup{ jira = { site = ... } } is the shape, keyed by adapter name.
local function field_value(name, field)
  local preset = (config.options[name] or {})[field.name]
  if type(preset) == "string" and preset ~= "" then
    return preset
  end
  -- <C-c> at input() raises "Keyboard interrupt" where inputsecret() answers
  -- "", so it is caught and given the same meaning: an empty answer stops the
  -- flow with nothing changed.
  local ok, value = pcall(vim.fn.input, { prompt = field.prompt .. ": ", default = field.default or "" })
  return ok and value or ""
end

-- Names the token page and offers to open it. The address goes into the
-- message history first, because vim.fn.confirm draws its prompt on the
-- command line and not into :messages: an address shown only in the dialog
-- is gone the moment it is answered, leaving the token prompt with no way
-- to reach the page. A machine with no opener is reported and the flow goes
-- on, since the address is on screen to reach by hand.
local function offer_token_page(url)
  vim.api.nvim_echo({ { ("A token is minted at %s"):format(url) } }, true, {})
  if vim.fn.confirm("Open it?", "&Yes\n&No", 2) == 1 then
    local _, err = vim.ui.open(url)
    if err then
      vim.api.nvim_echo({ { err, "WarningMsg" } }, true, {})
    end
  end
end

--- Logs one backend in.
---
--- The state check runs first: a client with an account signed in -- which
--- includes a token in the environment, `GH_TOKEN`, `GITHUB_TOKEN` or
--- `GITLAB_TOKEN`, since the client then reports itself authenticated and
--- refuses a login -- is left as it is unless `force` is set. `force` is
--- what a re-login asks for, and the command's bang carries it: it signs
--- another account in over one that works, and replaces a token that has
--- stopped working on a client whose state check still passes it. gh and
--- glab test the stored token against the host; whether acli's `auth status`
--- does is unobserved. Then each field the adapter names is taken from
--- setup{} or prompted for, the token page is put on screen and offered to
--- open, the token is prompted for, and the client is run. An empty answer,
--- or <C-c>, at a field's prompt or the token's stops the flow with nothing
--- changed.
---
--- A successful login clears the cached rows, every backend's: the cache key
--- carries the query and not the account, so rows the account that signed out
--- fetched cannot be told from the rest, and a `currentUser()` query's rows
--- would otherwise be painted under the account that replaced it.
---
--- A failed login reports the client's own message verbatim; a successful one
--- reports what the state check prints afterwards.
---@param name string the adapter's name
---@param opts { force: boolean|nil }|nil
---@return boolean ok
---@return string message what to report
function M.login(name, opts)
  opts = opts or {}
  local adapter, err = adapters.get(name)
  if not adapter then
    return false, err
  end

  local status = adapter.auth_status()
  if status.missing then
    return false, ("%s: the client is not installed\n%s"):format(name, status.detail)
  end
  if status.authenticated and not opts.force then
    return true,
      ("%s: already signed in; nothing changed. %s %s signs in anyway: for another account, or when the token has stopped working and this check still passes it\n%s"):format(
        name,
        M.RELOGIN_COMMAND,
        name,
        status.detail
      )
  end

  local fields = {}
  for _, field in ipairs(adapter.auth_fields()) do
    local value = field_value(name, field)
    if value == "" then
      return false, ("%s: no %s given; nothing changed"):format(name, field.name)
    end
    fields[field.name] = value
  end

  offer_token_page(adapter.token_url())

  local token = vim.fn.inputsecret(("%s token: "):format(name))
  if token == "" then
    return false, ("%s: no token given; nothing changed"):format(name)
  end

  -- Counted before the client runs and whatever it answers, as auth_login()
  -- drops what the adapter learnt: a login it refuses may have replaced its
  -- stored credentials as well.
  logins[name] = (logins[name] or 0) + 1
  local result = adapter.auth_login(token, fields)
  if not result.ok then
    return false, spawn.message(result)
  end

  cache.clear()

  status = adapter.auth_status()
  if not status.authenticated then
    return false, ("%s: the login ran and the client still reports no account\n%s"):format(name, status.detail)
  end
  return true, ("%s: signed in\n%s"):format(name, status.detail)
end

return M
