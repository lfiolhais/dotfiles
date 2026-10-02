-- GitLab, over glab. Imports adapters, config, flight, spawn, row and item;
-- adapters for ME and NOBODY alone, the two values assign() takes besides a
-- username. The argument lists are written out rather than assembled, so that
-- what runs can be read off this file; every flag is one glab's own `--help`
-- lists. The payload shapes the run against the real instance returned are a
-- discussion, its notes and `diff_refs`; the fields read off `mr list -F json`
-- and `mr view -F json` come from GitLab's REST reference for the merge request
-- object and are unverified here. The `note` verbs that write a body, `create`
-- and `update`, have been run with the body on standard input. The parts marked
-- unverified where they are used are the `note` verbs that take no body,
-- `resolve` and `delete`, which glab itself marks experimental; the identity
-- route, which the instance has not answered; the user search behind
-- completion, whose endpoint the instance has not printed either; assigning,
-- which has not been run; and the two project ids a row from a fork is
-- recognised by.
--
-- A body here is markdown, not a document tree, so the read-write asymmetry
-- that constrains the Jira buffer does not exist: a description or a note
-- round-trips as text, every region is editable, and nothing in this file
-- goes through adf. A write hands the region's text to glab on standard
-- input, which is how `mr note create` and `mr note update` document taking
-- a body, so the body never reaches an argument list.
--
-- `mr note list -F json` returns discussions, each `id`, `individual_note`
-- and `notes`. `id` is the whole discussion identifier, which `resolve` and
-- `--reply` take; the human rendering truncates it to eight characters, which
-- is why `-F json` is required rather than cosmetic. `individual_note` is what
-- separates a standalone comment from a thread, so it is read rather than
-- guessed from the note count. A note with `system` set is one GitLab wrote
-- itself -- a status change, a force-push, a label edit -- and is left out
-- everywhere, or every merge request opens with its own history in front of
-- the diff. `position` carries a diff note's file and line and is passed on
-- as it came; `resolvable` and `resolved` are read per note; `updated_at` is
-- what a conflict check compares.
--
-- `glab api` has no `--jq` -- that flag is on `mr list`, `mr view` and `mr
-- note list` -- so the passthrough's output is decoded here with
-- spawn.decode. `api` substitutes `:id` from the repository in the working
-- directory, and the dashboard runs at a clone's root, where the bare
-- layout's `.git` pointer file lets git, and so glab, find the remote.
--
-- The account's own identifier is held in this module for as long as the
-- editor runs -- one query per session, nothing on disk -- and dropped by
-- auth_login, since a different account may have signed in. Callers asking
-- while the query runs join it, under flight.lua's rule.
--
-- Every callback here arrives in a fast-event context, as spawn.run's do.

local adapters = require("docket.adapters")
local config = require("docket.config")
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
  "diff",
  "threads",
  "line_comment",
  "thread_resolve",
  "submit",
}

-- A merge request's identifier as the dashboard shows it, `!482`; the bare
-- number is what every glab verb takes.
M.PREFIX = "!"
M.IID = "^!?(%d+)$"

-- The page `mr list` returns without being asked: 30, with no flag that
-- walks every page. GitLab's API caps a page at 100, so that is asked for,
-- and a section that stops at exactly 100 rows is the symptom of the cap.
M.PER_PAGE = "100"

-- The state a row and an item carry: `draft` for a draft, and GitLab's own
-- `state` otherwise -- `opened`, `closed`, `merged` or `locked`.
local function state_of(mr)
  if mr.draft == true then
    return "draft"
  end
  return mr.state
end

-- The host, `gitlab.example.com`, read off whatever names it first: a
-- `web_url` on a row or an item, or the host lines of `auth status`.
-- token_url() and auth_fields() default to it.
local host = nil
M.DEFAULT_HOST = "gitlab.com"

-- Each merge request's page on the web, by iid, from every row and view
-- read this session. url() answers from it, since the project's path is not
-- in the identifier and only a read names it.
local urls = {}

-- The account's own identifier once whoami() has answered.
local identity = nil

-- Bumped by forget(). A list or an item captures the value when it starts and
-- drops what it read when the two no longer agree, because the login flow
-- pumps the event loop and a read started before `:Docket login` can land
-- inside it, carrying what the account that signed out could see.
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

-- Every row a list has returned this session, by identifier, which is what
-- complete() answers item references from.
local last_rows = {}

-- How long a failed user search stops complete() asking again, in seconds,
-- and the moment it may ask again. forget() clears the second, since a login
-- is what a search refused for want of one is waiting on.
M.USERS_BACKOFF = 60
local users_down_until = 0

-- The directory a glab call runs in when it is given a bare identifier. glab
-- resolves the project an iid belongs to from the working directory, and the
-- editor's own follows the current tab: `:tcd` moves it into a worktree, and a
-- person moves it into another repository, where the same iid names a
-- different merge request. It is taken in auth_status(), which every mode
-- asks at entry, on the main loop -- `vim.fn.getcwd` raises E5560 in the
-- fast-event context a spawn callback arrives in -- from the `cwd` the caller
-- passes, or from the editor's directory when it passes none. The current
-- tab's directory is what is read then rather than `getcwd(-1, -1)`, because
-- `:Docket <id>` resolves the clone from `vim.fn.getcwd()`, so this has to
-- name the project the mode named.
--
-- It names the clone of whichever mode was entered last, so a call about an
-- item, a review or a dashboard that was entered earlier cannot use it: a
-- state check from another clone's tab between the entry and the call would
-- send the call to a merge request of the same iid there, or list another
-- project's. Those calls are given their directory instead: a reference,
-- `{ id, cwd }`, which adapters/init.lua describes, where item() answers one
-- naming the directory it read in and the review mode passes one naming its
-- worktree; and a section's `cwd`, the clone the dashboard shows, which rows()
-- runs in, since the dashboard's state check answers while the editor goes on.
-- A call that chains several glab runs takes its directory once, when it
-- starts, and passes it to each.
local root = nil

local function glab(args, opts, on_done)
  return spawn.run(vim.list_extend({ "glab" }, args), vim.tbl_extend("keep", opts or {}, { cwd = root }), on_done)
end

-- An argument list as a line to paste at a prompt, for the messages that
-- report a payload nobody expected: a section's query comes from
-- configuration and can carry a space.
local shell_line = spawn.shell_line

-- The bare number a glab verb takes, or nil for an identifier that is not a
-- merge request's.
local function iid_of(id)
  return tostring(id):match(M.IID)
end

-- What a call is about: the bare number, or nil for an identifier that is not
-- a merge request's; the directory glab runs in, the reference's own or `root`
-- as it is now for a bare identifier; and the identifier as a message names
-- it.
local function subject(id)
  if type(id) == "table" then
    return iid_of(id.id), id.cwd or root, tostring(id.id)
  end
  return iid_of(id), root, tostring(id)
end

-- A person as item.new takes one, from the user object GitLab returns on an
-- author, an assignee or `api user`. The identifier is `username`, the field
-- the account's own user object carries, so it is the ownership test.
-- UNVERIFIED: the run against the instance printed a note's own field names
-- and not its `author` object's, so `username` on an author comes from
-- GitLab's REST reference rather than from a payload. `glab api
-- projects/:id/merge_requests/<iid>/notes | jq '.[0].author | keys'` settles
-- it, and until it does a comment whose author carries none is read-only.
local function person(user)
  if type(user) ~= "table" then
    return nil
  end
  return { id = user.username, name = user.name }
end

-- Whether a merge request comes from a fork: the row's `fork`, read off
-- `mr list`, and the `fork` M.item() stores, read off `mr view`. It is what
-- makes `w` and `R` on the dash, and `<leader>dw` and `<leader>dR` in the
-- merge request's buffer, refuse it in a clone of its target project: its
-- source branch lives in the fork, so origin's branch of the same name is
-- somebody else's code. commands.lua has the rule for a fork's clone. GitLab's
-- merge request object carries `source_project_id` and `target_project_id`,
-- and the two differ for a merge request from a fork. UNVERIFIED: neither
-- field has been printed from the instance, from either command, and both
-- come from GitLab's REST reference. Run in a clone of the project, the first
-- line prints them for the first page of its open merge requests, and the
-- second for one merge request, 482 here, the number after `!` in its
-- buffer's name; a merge request from a fork shows two different numbers:
--
--   glab mr list -F json |
--     jq '.[] | {iid, source_project_id, target_project_id}'
--   glab mr view 482 -F json |
--     jq '{source_project_id, target_project_id, source_branch}'
--
-- An object carrying one of the two or neither is not marked, and the
-- launcher's own question to origin is what stands for such a merge request.
local function forked(mr)
  local source, target = mr.source_project_id, mr.target_project_id
  if type(source) ~= "number" or type(target) ~= "number" then
    return nil
  end
  return source ~= target
end

local function remember(mr)
  if type(mr.web_url) == "string" then
    if host == nil then
      host = mr.web_url:match("^https?://([^/]+)")
    end
    if mr.iid then
      urls[tostring(mr.iid)] = mr.web_url
    end
  end
end

-- A write's outcome: glab exits non-zero and writes its complaint to stderr
-- when it fails. The third value is set when glab was killed at its timeout,
-- when whatever it sent may have reached GitLab.
local function outcome(result)
  if not result.ok then
    return false, spawn.message(result), result.timed_out == true
  end
  return true, nil
end

-- Runs a read that prints JSON and hands the decoded payload on, or the
-- reason there is none. `cwd` is the directory a chained call took when it
-- started; nil runs in `root` as it is now.
local function read(args, on_done, cwd)
  glab(args, { cwd = cwd }, function(result)
    if not result.ok then
      return on_done(nil, spawn.message(result))
    end
    local decoded, err = spawn.decode(result)
    if err then
      return on_done(nil, err)
    end
    on_done(decoded)
  end)
end

-- Runs a write whose body goes to glab on standard input, with the newline a
-- `<` redirection would carry. `mr note create` and `mr note update` read the
-- body from standard input when `-m` is absent, as their help documents and
-- as both do on the instance. `cwd` is as read() takes it.
local function write(args, text, on_done, cwd)
  glab(args, { stdin = text .. "\n", cwd = cwd }, function(result)
    on_done(outcome(result))
  end)
end

--- Whether glab has an account signed in for the host in context.
---
--- `auth status` verifies the token against the API for the host the current
--- context names -- a git remote, `GITLAB_HOST`, or the configuration -- and
--- `detail` is its output, read off both streams because glab writes the whole
--- report to standard error; its lines name what is wrong. UNVERIFIED: glab's
--- own help states no exit code, unlike `gh auth status`, and no failing run
--- has been seen from the instance, so the exit code standing for a host with
--- trouble is taken from glab's behaviour rather than from its documentation;
--- `glab auth status; echo $status` answers it. The host is read off the first
--- line that is a bare hostname, which is also unverified: with no such line,
--- auth_fields() and token_url() offer DEFAULT_HOST, which is gitlab.com and
--- wrong for a self-hosted instance until a row's `web_url` names the host.
---
--- This is also where the directory every later call runs in is taken, since
--- a mode asks it at entry, on the main loop: `cwd` when the caller passes
--- one -- the dashboard passes the root it shows, so that this check and its
--- rows run in one clone -- and the editor's directory otherwise. The check
--- itself runs there too, since the verdict follows the host that directory's
--- remote names.
---
--- Without on_done this blocks and returns the state; with it, glab runs
--- through spawn.run and the state goes to on_done in a fast-event context.
--- A host is read off the answer only while no login has run since the check
--- started, because the answer describes the account signed in before it.
---@param on_done fun(status: { authenticated: boolean, missing: boolean, detail: string })|nil
---@param cwd string|nil the clone the check is about; nil reads the editor's directory
---@return { authenticated: boolean, missing: boolean, detail: string }|nil status nil when on_done is given
function M.auth_status(on_done, cwd)
  root = cwd or vim.fn.getcwd()
  local argv = { "glab", "auth", "status" }
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
    { name = "hostname", prompt = "GitLab host, as gitlab.example.com", default = host or M.DEFAULT_HOST },
  }
end

--- Logs in with a personal access token.
---
--- The token goes to glab on standard input through `--stdin`, with the
--- newline `< token.txt` would carry, and never in the argument list. What
--- was learnt under the account signed in until now is dropped first.
---
--- glab stores the token in the operating system's keyring and falls back to
--- its configuration file when none is available, so nothing here asks for
--- one store over the other. `--insecure-storage` is the flag that would
--- force the file, and it is not passed: the login on the work server holds
--- as it stands, and the flag is the fallback if a fresh login there cannot
--- reach a keyring and refuses rather than falling back.
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
    { "glab", "auth", "login", "--stdin", "--hostname", fields.hostname },
    { stdin = token .. "\n", cwd = root }
  )
  host = result.ok and fields.hostname or previous
  return result
end

--- Drops what was learnt under the account signed in until now: the
--- remembered identity, so the next whoami() asks again; the last rows, so
--- complete() offers no reference from the previous account's lists; the
--- addresses read this session, since one iid names a different merge request
--- on another host; and the host in context, which the next status or row
--- answers again. A query in flight is told apart by the generation it started
--- in.
function M.forget()
  identity = nil
  last_rows = {}
  users_down_until = 0
  urls = {}
  host = nil
  generation = generation + 1
  identity_query:invalidate(WHOAMI)
end

--- The page where a personal access token is minted, on the host in context.
---@return string
function M.token_url()
  return ("https://%s/-/user_settings/personal_access_tokens"):format(host or M.DEFAULT_HOST)
end

--- The rows a section's query returns, normalised by row.new.
---
--- The query is the argument list the section carries -- `mr list
--- --reviewer=@me` or `mr list --assignee=@me` -- and `--per-page` with `-F
--- json` are added here. It runs in the section's `cwd`, or in the directory
--- the last state check took when the section has none. A row the client
--- returned that row.new refuses is left out and named in `warning`, while the
--- rest are given; only when no row survives is the whole section an error.
---@param section { query: string[], cwd: string|nil }
---@param on_done fun(rows: table[]|nil, err: string|nil, warning: string|nil)
function M.rows(section, on_done)
  local args = vim.list_extend(vim.deepcopy(section.query), { "--per-page", M.PER_PAGE, "-F", "json" })
  -- Rows outlive the account: the login flow pumps the event loop, so a list
  -- started under the account signing out lands after forget() has run, and
  -- without this its titles and addresses are remembered as the new one's.
  local started = generation
  read(args, function(found, err)
    if started ~= generation then
      return on_done(
        nil,
        "glab: a login ran while this section was in flight, so its rows are not shown; refresh to ask again"
      )
    end
    if not found then
      return on_done(nil, err)
    end
    if not vim.islist(found) then
      return on_done(
        nil,
        ("glab: mr list printed something other than a list of merge requests; run\n  glab %s\nby hand to see what it prints"):format(
          shell_line(args)
        )
      )
    end
    local rows, reasons = {}, {}
    for _, mr in ipairs(found) do
      remember(mr)
      local ok, built = pcall(row.new, {
        source = "glab",
        id = M.PREFIX .. tostring(mr.iid),
        state = state_of(mr),
        title = mr.title,
        branch = mr.source_branch,
        fork = forked(mr),
      })
      if ok then
        built.target = mr.target_branch
        built.author = person(mr.author)
        built.assignee = person(vim.islist(mr.assignees) and mr.assignees[1] or nil)
        built.updated = mr.updated_at
        built.url = mr.web_url
        rows[#rows + 1] = built
      else
        reasons[#reasons + 1] = tostring(built)
      end
    end
    if #rows == 0 and #reasons > 0 then
      return on_done(nil, table.concat(reasons, "\n"))
    end
    for _, built in ipairs(rows) do
      last_rows[built.id] = built
    end
    on_done(rows, nil, #reasons > 0 and table.concat(reasons, "\n") or nil)
  end, section.cwd)
end

--- The account's own identifier, asked once per session.
---
--- The route is `glab api user`, the passthrough to `GET /api/v4/user`, which
--- is the endpoint `auth status` checks a token against. The response is the
--- account's user object, and `username` is read off it. UNVERIFIED against
--- the instance: the run against it made no `api user` call, and the field name
--- comes from GitLab's REST reference for the endpoint. Callers during the
--- query join it. An answer that lands after forget() has run was asked before
--- a login, so it is replaced by a reason to open the item again.
---@param on_done fun(id: string|nil, err: string|nil)
function M.whoami(on_done)
  if identity then
    return on_done(identity)
  end
  identity_query:join(WHOAMI, function(settle)
    -- `api` takes the host from the working directory and falls back to
    -- gitlab.com outside a clone, so the host in context is named where it is
    -- known: an identity from another host would be cached for the session and
    -- would make every comment read-only.
    local args = { "api", "user" }
    if host then
      vim.list_extend(args, { "--hostname", host })
    end
    read(args, function(user, err)
      if not user then
        return settle(nil, err)
      end
      if type(user) ~= "table" or type(user.username) ~= "string" then
        return settle(nil, "glab: `api user` printed no `username`; run `glab api user` by hand to see what it prints")
      end
      settle(user.username)
    end)
  end, on_done)
end

-- The notes of a discussion that a person wrote, in order. A note with
-- `system` set is GitLab's own record of an event and is left out.
local function human_notes(discussion)
  local kept = {}
  for _, note in ipairs(vim.islist(discussion.notes) and discussion.notes or {}) do
    if note.system ~= true then
      kept[#kept + 1] = note
    end
  end
  return kept
end

-- Reads a merge request's discussions and hands the payload on. `cwd` is as
-- read() takes it.
local function discussions(iid, on_done, cwd)
  read({ "mr", "note", "list", iid, "-F", "json" }, function(found, err)
    if not found then
      return on_done(nil, err)
    end
    if not vim.islist(found) then
      return on_done(
        nil,
        ("glab: mr note list %s printed something other than a list of discussions; run\n  glab mr note list %s -F json\nby hand to see what it prints"):format(
          iid,
          iid
        )
      )
    end
    on_done(found)
  end, cwd)
end

--- One merge request with its comments, built by item.new.
---
--- The merge request comes from `mr view -F json` and the comments from `mr
--- note list -F json`, every note of every discussion in order with the
--- system notes left out. The description and each body are markdown and are
--- held as the text they are. `me` is whoami()'s answer, nil when it could
--- not answer, with `me_err` the reason for the buffer to show.
---
--- No `total` is given: `mr note list` reports no count and exposes no page
--- flag, so the count the renderer would compare against does not exist here
--- and a short thread cannot be told from a whole one. `glab api
--- projects/:id/merge_requests/<iid>/discussions` against a merge request with
--- more than a hundred discussions is what settles whether the verb walks every
--- page.
---
--- The item carries `ref`, the reference naming the directory it was read in,
--- which the item buffer hands to every later call about it; `root` says why.
--- It carries `project` as well, the path its `web_url` names through
--- project_of(), which the item buffer holds against the project in its name,
--- and `branch` and `fork`, the source branch and whether it lives in a fork,
--- as rows() reads them, which the item buffer's `<leader>dw` and
--- `<leader>dR` build the environment from.
---@param id string|table `!482`, the bare number, or a reference
---@param on_done fun(item: table|nil, err: string|nil, me_err: string|nil)
function M.item(id, on_done)
  local iid, cwd, shown = subject(id)
  if not iid then
    return on_done(nil, ("%s is not a merge request identifier such as !482"):format(shown))
  end
  -- The reads below outlive the identity: whoami() answers, and a login during
  -- `mr view` or `mr note list` may sign a different account in. So the
  -- generation is captured here and the identity is dropped when it moved,
  -- which leaves every comment read-only with the reason beside it.
  local started = generation
  M.whoami(function(me, me_err)
    read({ "mr", "view", iid, "-F", "json" }, function(mr, err)
      if not mr then
        return on_done(nil, err)
      end
      if type(mr) ~= "table" or mr.iid == nil then
        return on_done(
          nil,
          ("glab: mr view %s printed no merge request; run\n  glab mr view %s -F json\nby hand to see what it prints"):format(
            iid,
            iid
          )
        )
      end
      remember(mr)
      discussions(iid, function(found, notes_err)
        if not found then
          return on_done(nil, notes_err)
        end
        local comments = {}
        for _, discussion in ipairs(found) do
          for _, note in ipairs(human_notes(discussion)) do
            comments[#comments + 1] = {
              id = note.id,
              author = person(note.author),
              created = note.created_at,
              updated = note.updated_at,
              body = note.body,
            }
          end
        end
        if started ~= generation then
          me, me_err = nil, "a login ran while the item was read; open it again"
        end
        local ok, built = pcall(item.new, {
          source = "glab",
          id = M.PREFIX .. tostring(mr.iid),
          title = mr.title,
          state = state_of(mr),
          url = mr.web_url,
          assignee = person(vim.islist(mr.assignees) and mr.assignees[1] or nil),
          reporter = person(mr.author),
          updated = mr.updated_at,
          body = mr.description,
          comments = comments,
          me = me,
          ref = { id = M.PREFIX .. tostring(mr.iid), cwd = cwd },
          project = M.project_of(mr.web_url),
          branch = mr.source_branch,
          fork = forked(mr),
        })
        if not ok then
          return on_done(nil, tostring(built))
        end
        on_done(built, nil, me_err)
      end, cwd)
    end, cwd)
  end)
end

--- The project path a merge request's `web_url` names: `acme/sub/payments`
--- for `https://gitlab.example.test/acme/sub/payments/-/merge_requests/482`,
--- the group and its subgroups included, since the path runs up to the `/-/`
--- that separates it from the rest. item() puts it on the item, and the item
--- buffer holds it against the project in its name, because glab picks the
--- project from the clone's remotes while the name is read off `origin`;
--- buffer.lua says what a mismatch means. The path alone is compared there:
--- the host an ssh origin names need not be the one the instance's web
--- addresses carry, so a project of the same path on another host -- a
--- mirror kept as another remote -- fills the buffer. The dashboard reads a
--- row's project off its `web_url` the same way and holds it against the
--- paths its clone's remotes name, so that a row listed by `-R <project>` in
--- the dash of another project's clone is refused, where `<CR>` would read
--- the clone's own merge request of that number.
---
--- nil for an address of any other shape, an empty path included, and the
--- buffer then compares nothing and the read goes ahead: such an address is
--- more likely an instance that writes its addresses differently than
--- another project, and refusing it would refuse every correct read there.
--- UNVERIFIED: no merge request payload has been printed here, so the shape
--- rests on the addresses GitLab's web interface shows; `glab mr view <iid>
--- -F json | jq -r .web_url` in a clone prints the shape the instance
--- writes.
---@param web_url any what the payload carries under `web_url`
---@return string|nil project
function M.project_of(web_url)
  if type(web_url) ~= "string" then
    return nil
  end
  return web_url:match("^https?://[^/]+/([^/].-)/%-/merge_requests/%d+")
end

--- The branch a row already has: its source branch, which `mr list` carries
--- as `source_branch` and rows() keeps.
---@param r { branch: string|nil }
---@return string|nil
function M.branch(r)
  return r.branch
end

--- Where a row is on the web: the `web_url` a list or a view returned for it.
---@param r { id: string, url: string|nil }
---@return string|nil url
---@return string|nil err
function M.url(r)
  if r.url then
    return r.url
  end
  local iid = iid_of(r.id)
  if iid and urls[iid] then
    return urls[iid]
  end
  return nil, ("%s has not been read this session, so its address is unknown"):format(tostring(r.id))
end

-- Posts a note that cannot be resolved. `mr note create` otherwise starts a
-- discussion thread, which its help says, and on a project that requires every
-- thread resolved each comment and each review summary would block the merge
-- until someone resolved it on the web. `--unique` posts nothing when a note
-- with the same body is there already, so posting again after a timeout, when
-- whether the first post landed is unknown, cannot make a second note. Both
-- flags are from the help of glab 1.119.0, which lets them be combined and
-- refuses either with `--reply` or `--file`, so line_comment() uses neither.
--
-- A note already holding the text makes glab print that note's address and
-- exit 0, so the save reports `new: posted` and reads the merge request
-- again. The loaded snapshot already holds that note, so identify() in
-- buffer.lua finds no new comment, conclude() fills the buffer from the read,
-- and the comment just typed leaves the buffer, its text shown as the note's
-- that was there. It is held read-only under buffer.POSTED instead only when
-- that read fails, another call of the same save fails, or text was typed
-- while the save ran.
local function create_note(iid, text, on_done, cwd)
  write({ "mr", "note", "create", iid, "--resolvable=false", "--unique" }, text, on_done, cwd)
end

--- Adds a comment, as a note nobody has to resolve.
---@param id string|table the identifier, or the item's reference
---@param text string the region's text, markdown
---@param on_done fun(ok: boolean, err: string|nil)
function M.comment_create(id, text, on_done)
  local iid, cwd, shown = subject(id)
  if not iid then
    return on_done(false, ("%s is not a merge request identifier"):format(shown))
  end
  create_note(iid, text, on_done, cwd)
end

--- Replaces a note's body.
---
--- The merge request comes before the note, which is the order every example
--- in `mr note update --help` shows and the order the `Use` string in the
--- binary carries, `update [<id> | <branch>] <note-id>`. The USAGE line the
--- help prints is assembled rather than quoted: it appends `[--flags]` and
--- moves the optional merge request behind the required note, which is what
--- leaves the double space in the parent command's own table.
---@param id string|table the identifier, or the item's reference
---@param comment_id string the note's `id`
---@param text string the region's text, markdown
---@param on_done fun(ok: boolean, err: string|nil)
function M.comment_update(id, comment_id, text, on_done)
  local iid, cwd, shown = subject(id)
  if not iid then
    return on_done(false, ("%s is not a merge request identifier"):format(shown))
  end
  write({ "mr", "note", "update", iid, tostring(comment_id) }, text, on_done, cwd)
end

--- Deletes a note. `--yes` skips the confirmation, which behind a pipe is a
--- hang; the delete happens on this call and any confirmation belongs to
--- whatever binds it.
---
--- The merge request comes before the note, for the reason comment_update
--- states. UNVERIFIED: the verb has not been run.
---@param id string|table the identifier, or the item's reference
---@param comment_id string the note's `id`
---@param on_done fun(ok: boolean, err: string|nil)
function M.comment_delete(id, comment_id, on_done)
  local iid, cwd, shown = subject(id)
  if not iid then
    return on_done(false, ("%s is not a merge request identifier"):format(shown))
  end
  glab({ "mr", "note", "delete", iid, tostring(comment_id), "--yes" }, { cwd = cwd }, function(result)
    on_done(outcome(result))
  end)
end

--- Replaces the description, read from standard input through
--- `--description-file -`, which `mr update --help` documents.
---@param id string|table the identifier, or the item's reference
---@param text string the region's text, markdown
---@param on_done fun(ok: boolean, err: string|nil)
function M.body_update(id, text, on_done)
  local iid, cwd, shown = subject(id)
  if not iid then
    return on_done(false, ("%s is not a merge request identifier"):format(shown))
  end
  write({ "mr", "update", iid, "--description-file", "-" }, text, on_done, cwd)
end

--- Completion candidates.
---
--- Item references come from every row a list has returned this session,
--- matched by the digits typed after `!`, in the dashboard's own order.
--- Users come from `glab api projects/:id/users?search=<query>`, the
--- passthrough decoded here, and are `{ id = username, title = name }`.
--- UNVERIFIED: no `projects/:id/users` call has been made against the instance,
--- so the field names come from GitLab's REST reference; `glab api
--- 'projects/:id/users?search=<name>'` prints what it answers with, and
--- completion offering no user is the symptom of a different shape. The call
--- blocks for the omnifunc, under the short timeout config gives it. A query
--- carrying anything outside `[%w._-]` is not sent, because it would have to be
--- encoded into the URL: a name with a space or a letter outside ASCII offers no
--- candidate until the query is encoded.
---
--- A search that fails is not asked again for USERS_BACKOFF seconds. The
--- omnifunc runs after every pause in typing, and each query is a new one, so
--- with GitLab unreachable every character typed after `@` would otherwise hold
--- the editor for the whole timeout again.
---@param kind string "item" or "user"
---@param query string what has been typed since the trigger
---@return { id: string, title: string }[]
function M.complete(kind, query)
  local found = {}
  if kind == "item" then
    local rows = {}
    for _, r in pairs(last_rows) do
      rows[#rows + 1] = r
    end
    for _, r in ipairs(row.sort(rows)) do
      if r.id:sub(2, 1 + #query) == query then
        found[#found + 1] = { id = r.id, title = r.title }
      end
    end
    return found
  end
  if kind ~= "user" or not query:match("^[%w._-]*$") then
    return found
  end
  if os.time() < users_down_until then
    return found
  end
  local result = spawn.wait(
    { "glab", "api", "projects/:id/users?search=" .. query },
    { cwd = root, timeout = config.options.timeouts.complete }
  )
  if not result.ok then
    users_down_until = os.time() + M.USERS_BACKOFF
    return found
  end
  local users = spawn.decode(result)
  for _, user in ipairs(vim.islist(users) and users or {}) do
    if type(user.username) == "string" then
      found[#found + 1] = { id = user.username, title = user.name or user.username }
    end
  end
  return found
end

--- The actions a merge request offers, each `{ label, target }`, from its
--- state: an open or locked one can be approved, merged or closed; a closed
--- one reopened; a merged one offers nothing.
---@param id string|table the identifier, or the item's reference
---@param on_done fun(states: { label: string, target: string }[]|nil, err: string|nil)
function M.states(id, on_done)
  local iid, cwd, shown = subject(id)
  if not iid then
    return on_done(nil, ("%s is not a merge request identifier"):format(shown))
  end
  read({ "mr", "view", iid, "-F", "json" }, function(mr, err)
    if err then
      return on_done(nil, err)
    end
    -- JSON `null` decodes to nil with no error, and a scalar would raise at
    -- `mr.state` inside the callback, which leaves the picker with no answer.
    if type(mr) ~= "table" or mr.iid == nil then
      return on_done(
        nil,
        ("glab: mr view %s printed no merge request; run\n  glab mr view %s -F json\nby hand to see what it prints"):format(
          iid,
          iid
        )
      )
    end
    remember(mr)
    if mr.state == "opened" or mr.state == "locked" then
      return on_done({
        { label = "Approve", target = "approve" },
        { label = "Merge", target = "merge" },
        { label = "Close", target = "close" },
      })
    end
    if mr.state == "closed" then
      return on_done({ { label = "Reopen", target = "reopen" } })
    end
    on_done({})
  end, cwd)
end

-- The verb each action runs. `merge` carries `--yes`, because it prompts
-- without it and a prompt behind a pipe is a hang. It does not carry
-- `--auto-merge=false`: glab defaults that flag to true and, with a pipeline
-- running, sets the merge request to merge when the pipeline passes rather than
-- merging it now. The merge request stays `opened` until it does, which is what
-- a row still open after a Merge that reported success means.
local ACTIONS = {
  approve = { "mr", "approve" },
  merge = { "mr", "merge" },
  close = { "mr", "close" },
  reopen = { "mr", "reopen" },
}

-- Runs an action on a merge request. `cwd` is as read() takes it.
local function act(iid, target, on_done, cwd)
  local verb = ACTIONS[target]
  if not verb then
    return on_done(false, ("%s is not an action a merge request offers; the actions are approve, merge, close, reopen"):format(tostring(target)))
  end
  local args = vim.list_extend(vim.deepcopy(verb), { iid })
  if target == "merge" then
    args[#args + 1] = "--yes"
  end
  glab(args, { cwd = cwd }, function(result)
    on_done(outcome(result))
  end)
end

--- Applies an action states() offered.
---@param id string|table the identifier, or the item's reference
---@param target string one of approve, merge, close, reopen
---@param on_done fun(ok: boolean, err: string|nil)
function M.state_set(id, target, on_done)
  local iid, cwd, shown = subject(id)
  if not iid then
    return on_done(false, ("%s is not a merge request identifier"):format(shown))
  end
  act(iid, target, on_done, cwd)
end

-- A GitLab username as `mr update --assignee` can be given one: its help
-- reads a leading `!` or `-` as removing that user and `+` as adding, and a
-- comma as separating several, so none of them reaches the flag.
local USERNAME = "^[%w._][%w._-]*$"

--- Leaves a merge request with one assignee, or none.
---
--- `mr update --assignee <username>` replaces the assignees with that one
--- user, and `--unassign` removes them all, both from `mr update --help`.
--- ME is resolved through whoami(), the identity that already decides which
--- notes are the account's own, rather than handed to glab as `@me`, which its
--- help does not document for this flag. `--yes` because the same help lists a
--- confirmation prompt it skips without saying which updates ask; a closed
--- standard input would otherwise fail such an update rather than hold the
--- editor. The directory is taken when the call starts, for the reason `root`
--- states, since the whoami() before the update can take a turn of the loop.
--- UNVERIFIED: no `mr
--- update` carrying either flag has been run; `glab mr update <iid>
--- --assignee <username> --yes` inside the clone, read back with `glab mr view
--- <iid> -F json`, settles it, and the merge request endpoint through `glab
--- api --method PUT`, which takes a numeric `assignee_id`, is the fallback.
---@param id string|table the identifier, or the item's reference
---@param who string ME, NOBODY, or a username as a person's `id` carries it
---@param on_done fun(ok: boolean, err: string|nil)
function M.assign(id, who, on_done)
  local iid, cwd, shown = subject(id)
  if not iid then
    return on_done(false, ("%s is not a merge request identifier"):format(shown))
  end
  local function update(flags)
    glab(vim.list_extend({ "mr", "update", iid }, flags), { cwd = cwd }, function(result)
      on_done(outcome(result))
    end)
  end
  if who == adapters.NOBODY then
    return update({ "--unassign", "--yes" })
  end
  if who == adapters.ME then
    return M.whoami(function(me, err)
      if not me then
        return on_done(false, err)
      end
      update({ "--assignee", me, "--yes" })
    end)
  end
  if type(who) ~= "string" or not who:match(USERNAME) then
    return on_done(false, ("%s is not a GitLab username"):format(vim.inspect(who)))
  end
  update({ "--assignee", who, "--yes" })
end

--- What the review mode diffs: the source and target branches from `mr view
--- -F json`, and `diff_refs` -- `base_sha`, `start_sha` and `head_sha` --
--- from `api projects/:id/merge_requests/<iid>`, decoded here since `api`
--- has no `--jq`. The review's diff is `origin/<target>...HEAD`; the shas are
--- what a fallback through `glab api` needs to place a line comment.
---@param id string|table the identifier, or the review's reference
---@param on_done fun(diff: { source: string, target: string, refs: table }|nil, err: string|nil)
function M.diff(id, on_done)
  local iid, cwd, shown = subject(id)
  if not iid then
    return on_done(nil, ("%s is not a merge request identifier"):format(shown))
  end
  read({ "mr", "view", iid, "-F", "json" }, function(mr, err)
    if not mr then
      return on_done(nil, err)
    end
    remember(mr)
    read({ "api", "projects/:id/merge_requests/" .. iid }, function(full, api_err)
      if not full then
        return on_done(nil, api_err)
      end
      if type(full) ~= "table" or type(full.diff_refs) ~= "table" then
        return on_done(
          nil,
          ("glab: the merge request %s payload carries no `diff_refs`; run\n  glab api projects/:id/merge_requests/%s\nby hand to see what it prints"):format(
            iid,
            iid
          )
        )
      end
      on_done({ source = mr.source_branch, target = mr.target_branch, refs = full.diff_refs })
    end, cwd)
  end, cwd)
end

--- The discussions, with the system notes left out and a discussion that
--- held nothing else dropped.
---
--- Each is `{ id, individual, resolvable, resolved, position, notes }`:
--- `id` the whole discussion identifier `resolve` and `--reply` take;
--- `individual` from `individual_note`, true for a standalone comment nobody
--- can reply into and false for a thread; `resolvable` and `resolved` from
--- the first note, since GitLab resolves a discussion whole; `position` the
--- first note's, as GitLab sent it, so a diff note renders at its file and
--- line without assembling one. Each note is `{ id, author, body, created,
--- updated, type, resolvable, resolved, position }`, `type` being `DiffNote`
--- or `DiscussionNote` and nil for a plain note.
---@param id string|table the identifier, or the review's reference
---@param on_done fun(threads: table[]|nil, err: string|nil)
function M.threads(id, on_done)
  local iid, cwd, shown = subject(id)
  if not iid then
    return on_done(nil, ("%s is not a merge request identifier"):format(shown))
  end
  discussions(iid, function(found, err)
    if not found then
      return on_done(nil, err)
    end
    local threads = {}
    for _, discussion in ipairs(found) do
      local kept = human_notes(discussion)
      if #kept > 0 then
        local notes = {}
        for index, note in ipairs(kept) do
          notes[index] = {
            id = tostring(note.id),
            author = person(note.author),
            body = note.body,
            created = note.created_at,
            updated = note.updated_at,
            type = note.type,
            resolvable = note.resolvable == true,
            resolved = note.resolved == true,
            position = note.position,
          }
        end
        threads[#threads + 1] = {
          id = discussion.id,
          individual = discussion.individual_note == true,
          resolvable = notes[1].resolvable,
          resolved = notes[1].resolved,
          position = notes[1].position,
          notes = notes,
        }
      end
    end
    on_done(threads)
  end, cwd)
end

--- Posts a comment at a place in the review: on a line of the diff, on a
--- file, or into an existing discussion.
---
--- `position` is one of `{ file, line }` for the new side, `{ file,
--- old_line }` for the old side, `{ file }` for a file-level note, or
--- `{ thread }` for a reply into the discussion of that identifier. glab
--- places the diff comment itself from `--file` with `--line` or
--- `--old-line`, so no position is assembled from the shas here; `--reply`
--- takes the whole discussion identifier. `--file` places the note against the
--- latest diff version on the server rather than against the diff in the
--- worktree, so a held line is only right while the branch has not moved; the
--- shas diff() returns are what pins a version, through the `discussions`
--- endpoint. `create` with `--file` and `--line`, and with `--reply`, takes
--- the body on standard input as a plain `create` does.
---@param id string|table the identifier, or the review's reference
---@param position { file: string|nil, line: integer|string|nil, old_line: integer|string|nil, thread: string|nil }
---@param text string the comment, markdown
---@param on_done fun(ok: boolean, err: string|nil)
function M.line_comment(id, position, text, on_done)
  local iid, cwd, shown = subject(id)
  if not iid then
    return on_done(false, ("%s is not a merge request identifier"):format(shown))
  end
  local args = { "mr", "note", "create", iid }
  if position.thread then
    vim.list_extend(args, { "--reply", tostring(position.thread) })
  elseif position.file then
    vim.list_extend(args, { "--file", position.file })
    if position.line then
      vim.list_extend(args, { "--line", tostring(position.line) })
    elseif position.old_line then
      vim.list_extend(args, { "--old-line", tostring(position.old_line) })
    end
  else
    return on_done(false, "a line comment needs a file, or a thread to reply into")
  end
  write(args, text, on_done, cwd)
end

--- Resolves a discussion.
---
--- The merge request comes before the discussion, for the reason
--- comment_update states; the binary's own long help reads `glab mr note
--- resolve <iid> <discussion-id>`, and the verb takes a numeric note
--- identifier there as well, finding the discussion that holds it. UNVERIFIED:
--- the verb has not been run; the `discussions` endpoint through `glab api` is
--- the fallback.
---@param id string|table the identifier, or the review's reference
---@param thread string the whole discussion identifier
---@param on_done fun(ok: boolean, err: string|nil)
function M.thread_resolve(id, thread, on_done)
  local iid, cwd, shown = subject(id)
  if not iid then
    return on_done(false, ("%s is not a merge request identifier"):format(shown))
  end
  glab({ "mr", "note", "resolve", iid, tostring(thread) }, { cwd = cwd }, function(result)
    on_done(outcome(result))
  end)
end

--- Applies a review's verdict, after its held comments have been posted: a
--- summary note when `verdict.summary` holds text, then `mr approve` when
--- `verdict.approve` is set. With an empty summary and no approval nothing is
--- posted and the submit succeeds.
---
--- `verdict.head` is the head the reviewer saw. It goes to `mr approve` as
--- `--sha`, which glab 1.119.0's help documents as having to match the merge
--- request's head, so a push after the diff was read makes GitLab refuse the
--- approval rather than approve commits nobody reviewed. `mr approve --sha
--- <head>` approves on the instance.
---
--- An approval that fails once the note is out is reported as that rather than
--- as a plain failure, so that the retry is the approval alone. Both run in the
--- reference's directory, for the reason `root` states.
---@param id string|table the identifier, or the review's reference
---@param verdict { approve: boolean|nil, summary: string|nil, head: string|nil }
---@param on_done fun(ok: boolean, err: string|nil)
function M.submit(id, verdict, on_done)
  local iid, cwd, shown = subject(id)
  if not iid then
    return on_done(false, ("%s is not a merge request identifier"):format(shown))
  end
  local function approve(posted)
    if not verdict.approve then
      return on_done(true, nil)
    end
    local args = { "mr", "approve", iid }
    if type(verdict.head) == "string" and verdict.head ~= "" then
      vim.list_extend(args, { "--sha", verdict.head })
    end
    glab(args, { cwd = cwd }, function(result)
      local ok, err = outcome(result)
      if not ok and posted then
        return on_done(
          false,
          ("the summary note is posted and the approval is not; approve alone rather than submitting again\n%s"):format(
            err
          )
        )
      end
      on_done(ok, err)
    end)
  end
  if verdict.summary and verdict.summary ~= "" then
    return create_note(iid, verdict.summary, function(ok, err)
      if not ok then
        return on_done(false, err)
      end
      approve(true)
    end, cwd)
  end
  approve(false)
end

return M
