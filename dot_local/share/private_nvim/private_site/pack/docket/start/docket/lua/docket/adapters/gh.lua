-- GitHub, over gh: the row calls, and the handoff of an item to octo.nvim.
-- Imports env, flight, spawn and row. Everything past the rows -- the pull
-- request, its threads, its diff, approving, merging -- is octo.nvim, which is
-- installed and bound to `<leader>op`, and which authenticates through the
-- same gh credential store, so one login serves both. So this adapter declares
-- no capability: the buffer never opens a `docket://gh/` item, and item() is
-- where the handoff lives. project_of() reads `owner/repo` off a pull
-- request's address, which the dashboard holds against its clone's remotes
-- before `w` or `R` takes a row into it; for a dashboard row item() hands
-- octo.nvim the address itself.
--
-- `pr list --json <fields>` names the fields it prints, and `headRefName` in
-- that list is the branch the launcher takes, so nothing here reads a pull
-- request on its own; `gh api` has `--jq`, unlike glab's, so the identity is
-- one call with the field selected by the client.
--
-- Every callback here arrives in a fast-event context, as spawn.run's do,
-- except item()'s, which is scheduled onto the main loop because the
-- handoff runs an editor command there.
--
-- env is imported for editor_error alone, which is the one place the rule for
-- stripping neovim's internals off a raised editor command is written down.

local env = require("docket.env")
local flight = require("docket.flight")
local row = require("docket.row")
local spawn = require("docket.spawn")

local M = {}

M.capabilities = {}

-- Where an item opens: the contract's `handoff`, which commands reads to hand
-- a row to item() rather than to the item buffer, since there is no item to
-- render here.
M.handoff = "octo.nvim"

-- A pull request's identifier as the dashboard shows it, `#12`; the bare
-- number is what every gh verb and octo.nvim take.
M.PREFIX = "#"
M.NUMBER = "^#?(%d+)$"

-- What `pr list` is asked for: what a row renders -- the identifier, the
-- state and the title; the branch the launcher takes; `isCrossRepository`,
-- true for a pull request whose head repository is not its base's, one from
-- a fork, which becomes the row's `fork`; the page url() answers with; and
-- the people and the timestamp a row carries, which the dashboard's line
-- does not show. `gh pr list --json` with no value lists the fields the
-- installed gh takes, and gh 2.101.0's list has every one of these.
M.ROW_FIELDS = "number,title,state,isDraft,headRefName,isCrossRepository,url,updatedAt,author,assignees"

-- The page `pr list` returns without being asked: 30, which `--limit` raises.
-- 100 is asked for, and a section that stops at exactly 100 rows is the symptom
-- of the limit.
M.LIMIT = "100"

M.DEFAULT_HOST = "github.com"

-- The host, read off the first host `auth status` names or a row's `url`,
-- whichever comes first, or named by a login; token_url() and auth_fields()
-- default to it, and auth_status() checks it alone once it is known.
local host = nil

-- Each pull request's page on the web, by number, from every row read this
-- session, since the repository's path is not in the identifier.
local urls = {}

-- The account's login once whoami() has answered.
local identity = nil

-- Bumped by forget(). A list captures the value when it starts and drops what
-- it read when the two no longer agree, because the login flow pumps the event
-- loop and a list started before `:Docket login` can land inside it.
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

-- The directory a gh call runs in, for the reason adapters/glab.lua states at
-- its own: `pr list` resolves the repository from the working directory, and
-- the editor's own follows the current tab. rows() runs in the section's
-- `cwd` instead, as glab's does.
local root = nil

local function gh(args, opts, on_done)
  return spawn.run(vim.list_extend({ "gh" }, args), vim.tbl_extend("keep", opts or {}, { cwd = root }), on_done)
end

-- An argument list as a line to paste at a prompt, for the message that reports
-- a payload nobody expected: a section's query comes from configuration and
-- can carry a space.
local shell_line = spawn.shell_line

local function number_of(id)
  return tostring(id):match(M.NUMBER)
end

-- The state a row carries: `draft` for a draft, and gh's own `state`
-- lowercased otherwise -- `open`, `closed` or `merged`.
local function state_of(pr)
  if pr.isDraft == true then
    return "draft"
  end
  return type(pr.state) == "string" and pr.state:lower() or pr.state
end

-- A person from the user object gh returns: `login` is the identifier. An
-- account with no display name arrives with `name` as an empty string rather
-- than absent, and an empty string is truthy here, so the login stands in for
-- it.
local function person(user)
  if type(user) ~= "table" then
    return nil
  end
  return { id = user.login, name = user.name ~= "" and user.name or user.login }
end

local function remember(pr)
  if type(pr.url) == "string" then
    if host == nil then
      host = pr.url:match("^https?://([^/]+)")
    end
    if pr.number then
      urls[tostring(pr.number)] = pr.url
    end
  end
end

--- Whether gh has an account signed in.
---
--- `auth status` tests each account it reports against its host and exits 1
--- when one has trouble, which its own help states, so the exit code is the
--- test. `detail` is its output, read off both streams: the same help says a
--- host with trouble reports on standard error, and which stream the passing
--- report lands on has not been seen here. octo.nvim reads the same command for
--- the token's scopes.
---
--- Unscoped, an expired token on any account on any host fails the check, and
--- a login here cannot clear a failure that belongs to another host. So
--- `--active` asks about the account gh uses on each host rather than every
--- stored one, and `--hostname` names the host in context once one is known:
--- the help states that `--hostname` limits the exit code to that host. Both
--- flags are read from gh 2.101.0's help; a release without `--active` fails
--- this check on the unknown flag, and `gh auth status --help` shows whether
--- the installed one has it. Before any host is known the check covers every
--- host, and on a machine signed in to several the first one it names is the
--- one checked afterwards, until a login names another: a row's `url` names
--- the host only while none is known. UNVERIFIED: whether `--active` also
--- keeps an inactive account's trouble out of the exit code; `gh auth status
--- --active; echo $status`, with a second account on the host holding a
--- revoked token, answers it.
---
--- The host lines, which are bare hostnames at the start of a line, name the
--- default for a login, as they do for glab. This is also where the directory
--- every later call runs in is taken, since a mode asks it at entry, on the
--- main loop: `cwd` when the caller passes one -- the dashboard passes the
--- root it shows -- and the editor's directory otherwise. The check itself
--- runs there too.
---
--- Without on_done this blocks and returns the state; with it, gh runs
--- through spawn.run and the state goes to on_done in a fast-event context.
--- A host is read off the answer only while no login has run since the check
--- started, because the answer describes the account signed in before it.
---@param on_done fun(status: { authenticated: boolean, missing: boolean, detail: string })|nil
---@param cwd string|nil the clone the check is about; nil reads the editor's directory
---@return { authenticated: boolean, missing: boolean, detail: string }|nil status nil when on_done is given
function M.auth_status(on_done, cwd)
  root = cwd or vim.fn.getcwd()
  local argv = { "gh", "auth", "status", "--active" }
  if host then
    vim.list_extend(argv, { "--hostname", host })
  end
  local started = generation
  local function status_of(result)
    if host == nil and started == generation then
      for line in (result.stdout .. "\n" .. result.stderr):gmatch("[^\n]+") do
        if line:match("^[%w][%w.-]*%.[%a]+$") then
          host = line
          break
        end
      end
    end
    return {
      authenticated = result.ok,
      missing = result.code == spawn.MISSING,
      detail = result.ok and vim.trim(result.stdout .. "\n" .. result.stderr) or spawn.message(result),
    }
  end
  if on_done == nil then
    return status_of(spawn.wait(argv, { cwd = root }))
  end
  spawn.run(argv, { cwd = root }, function(result)
    on_done(status_of(result))
  end)
  return nil
end

--- What a first login needs besides the token: the host.
---@return { name: string, prompt: string, default: string|nil }[]
function M.auth_fields()
  return {
    { name = "hostname", prompt = "GitHub host", default = host or M.DEFAULT_HOST },
  }
end

--- Logs in with a personal access token, on standard input through
--- `--with-token`, with the newline `< token.txt` would carry, and never in
--- the argument list. What was learnt under the account signed in until now
--- is dropped first.
---
--- The host in context goes with the rest and is then named by the login: the
--- one signed in to on success, and on a failure the one signed in to until now,
--- which is still where a token is minted and still the default to offer.
---@param token string
---@param fields { hostname: string }
---@return table result the spawn result
function M.auth_login(token, fields)
  local previous = host
  M.forget()
  local result = spawn.wait(
    { "gh", "auth", "login", "--with-token", "--hostname", fields.hostname },
    { stdin = token .. "\n", cwd = root }
  )
  host = result.ok and fields.hostname or previous
  return result
end

--- Drops what was learnt under the account signed in until now: the remembered
--- identity, so the next whoami() asks again; the addresses read this session,
--- since one number names a different pull request in another repository; and
--- the host in context, which the next status or row answers again. Rows are not
--- kept, since this adapter offers no completion. A query in flight is told
--- apart by the generation it started in.
function M.forget()
  identity = nil
  urls = {}
  host = nil
  generation = generation + 1
  identity_query:invalidate(WHOAMI)
end

--- The page where a personal access token is minted.
---@return string
function M.token_url()
  return ("https://%s/settings/tokens"):format(host or M.DEFAULT_HOST)
end

--- The rows a section's query returns, normalised by row.new.
---
--- The query is the argument list the section carries -- `pr list
--- --assignee @me` or `pr list --search review-requested:@me` -- and the
--- field list and the limit are added here. It runs in the section's `cwd`,
--- or in the directory the last state check took when the section has none.
---@param section { query: string[], cwd: string|nil }
---@param on_done fun(rows: table[]|nil, err: string|nil, warning: string|nil)
function M.rows(section, on_done)
  local args = vim.list_extend(vim.deepcopy(section.query), { "--limit", M.LIMIT, "--json", M.ROW_FIELDS })
  -- A login during the list drops the addresses and the host the list would
  -- otherwise fill back in as the new account's.
  local started = generation
  gh(args, { cwd = section.cwd }, function(result)
    if started ~= generation then
      return on_done(nil, "gh: a login ran while this section was in flight, so its rows are not shown; refresh to ask again")
    end
    if not result.ok then
      return on_done(nil, spawn.message(result))
    end
    local found, err = spawn.decode(result)
    if err then
      return on_done(nil, err)
    end
    if not vim.islist(found) then
      return on_done(
        nil,
        ("gh: pr list printed something other than a list of pull requests; run\n  gh %s\nby hand to see what it prints"):format(
          shell_line(args)
        )
      )
    end
    local rows, reasons = {}, {}
    for _, pr in ipairs(found) do
      remember(pr)
      local ok, built = pcall(row.new, {
        source = "gh",
        id = M.PREFIX .. tostring(pr.number),
        state = state_of(pr),
        title = pr.title,
        branch = pr.headRefName,
        -- Kept only when gh printed true: a list that left the field out
        -- marks nothing, and the launcher's own question to origin stands for
        -- such a row.
        fork = pr.isCrossRepository == true,
      })
      if ok then
        built.author = person(pr.author)
        built.assignee = person(vim.islist(pr.assignees) and pr.assignees[1] or nil)
        built.updated = pr.updatedAt
        built.url = pr.url
        rows[#rows + 1] = built
      else
        reasons[#reasons + 1] = tostring(built)
      end
    end
    if #rows == 0 and #reasons > 0 then
      return on_done(nil, table.concat(reasons, "\n"))
    end
    on_done(rows, nil, #reasons > 0 and table.concat(reasons, "\n") or nil)
  end)
end

--- The account's own login, asked once per session, through `gh api user
--- --jq .login`. Callers during the query join it, and an answer landing
--- after forget() has run is not remembered, as adapters/jira.lua's whoami()
--- states.
---@param on_done fun(id: string|nil, err: string|nil)
function M.whoami(on_done)
  if identity then
    return on_done(identity)
  end
  identity_query:join(WHOAMI, function(settle)
    gh({ "api", "user", "--jq", ".login" }, nil, function(result)
      if not result.ok then
        return settle(nil, spawn.message(result))
      end
      local login = vim.trim(result.stdout)
      if login == "" then
        return settle(
          nil,
          "gh: `api user --jq .login` printed nothing; run `gh api user --jq .login` by hand to see what it prints"
        )
      end
      settle(login)
    end)
  end, on_done)
end

-- The host and the repository a pull request's address names: `github.com`
-- and `acme/payments` for `https://github.com/acme/payments/pull/12`, the
-- two path parts before `/pull/` and its number. nil for an address of any
-- other shape, and for none.
local function repository_of(url)
  if type(url) ~= "string" then
    return nil
  end
  return url:match("^https?://[^/]+/([^/]+/[^/]+)/pull/%d+")
end

--- The repository a pull request's address names, `acme/payments` for
--- `https://github.com/acme/payments/pull/12`, whatever the host. The
--- dashboard holds it against the paths its clone's remotes name, which
--- repo.project_of() reads off their URLs in the same `owner/repo` shape, and
--- item() hands an address that names one to octo.nvim as it is. nil for an
--- address of any other shape, and for none.
---@param url any what a row carries under `url`
---@return string|nil repository
function M.project_of(url)
  return repository_of(url)
end

--- Hands a pull request to octo.nvim. A reference carrying an address that
--- names a pull request -- a dashboard row's -- runs `Octo <address>`, which
--- octo.nvim's README documents for "GitHub.com URLs" and for "GitHub
--- Enterprise URLs (hostname is automatically detected)", so that the row
--- opens as its own repository's on its own host, whatever directory the
--- editor is in and whatever `github_hostname` octo.nvim is configured with;
--- the identifier alone runs `Octo pr edit <number>`, which the README
--- documents as `edit <number> [repo]` with `[repo]` "derived from
--- `<cwd>/.git/config`" when it is not given. The address rather than the
--- command with `[repo]`, because the README states the command's argument
--- order twice -- the table has the repository after the number, and its
--- example, `Octo issue edit pwntester/octo.nvim 1`, before it -- and rather
--- than an `octo://` buffer name, because the README's names carry a host for
--- "a specific GitHub Enterprise instance" alone and open one without a host
--- "from the default GitHub instance (github.com or configured
--- github_hostname)", so a github.com row would open on a configured
--- Enterprise host; the address carries its own. UNVERIFIED against the
--- octo.nvim installed, whose source is not in this repository: the shapes
--- are its README's, and `:Octo https://github.com/<owner>/<repo>/pull/<n>`
--- in the editor shows whether the release installed takes an address, with
--- `:help octo-commands` there as that release's own documentation. There is
--- no item to hand back, so on success the callback gets neither an item nor
--- an error, and commands reads `handoff` to call this in place of opening
--- an item buffer. The command runs on the main loop, so the callback
--- arrives there.
---@param id string|table `#12`, the bare number, or `{ id, url }` with the row's address
---@param on_done fun(item: nil, err: string|nil)
function M.item(id, on_done)
  local shown, url = id, nil
  if type(id) == "table" then
    shown, url = id.id, id.url
  end
  local number = number_of(shown)
  if not number then
    return on_done(nil, ("%s is not a pull request identifier such as #12"):format(tostring(shown)))
  end
  local address = repository_of(url) and url or nil
  vim.schedule(function()
    if vim.fn.exists(":Octo") ~= 2 then
      local at = url or M.url({ id = shown })
      return on_done(
        nil,
        at and ("octo.nvim is not installed, and a pull request opens there; %s is at %s"):format(shown, at)
          or ("octo.nvim is not installed, and a pull request opens there; %s has no address until a list names it"):format(
            shown
          )
      )
    end
    local command = ("Octo pr edit %s"):format(number)
    if address then
      command = "Octo " .. address
    end
    local ok, err = pcall(vim.cmd, command)
    if not ok then
      return on_done(nil, env.editor_error(err))
    end
    on_done(nil, nil)
  end)
end

--- The branch a row already has: its head branch, which `pr list` carries
--- as `headRefName` and rows() keeps.
---@param r { branch: string|nil }
---@return string|nil
function M.branch(r)
  return r.branch
end

--- Where a row is on the web: the `url` a list returned for it.
---@param r { id: string, url: string|nil }
---@return string|nil url
---@return string|nil err
function M.url(r)
  if r.url then
    return r.url
  end
  local number = number_of(r.id)
  if number and urls[number] then
    return urls[number]
  end
  return nil, ("%s has not been listed this session, so its address is unknown"):format(tostring(r.id))
end

return M
