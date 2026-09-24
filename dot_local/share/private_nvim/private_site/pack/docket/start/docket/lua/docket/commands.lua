-- The user commands and the keymaps: what `:Docket` dispatches to, and what
-- the dashboard, the item buffer and a review's diff bind. Imports adapters,
-- auth, buffer, cache, config, env, list, repo, review and row; adapters for
-- can(), ME and NOBODY, and cache to drop the rows a transition or an
-- assignment makes stale. plugin/docket.lua declares the command, the
-- `<leader>dd` map and the autocommands and calls in here, so that nothing
-- below is loaded until the first use. The other `<leader>d` keys are set per
-- buffer, by attach() on an item buffer, attach_dash() on the dashboard and
-- attach_review() on each buffer that shows a side of a review's diff.
--
-- Every mode asks its adapter for the authentication state before it asks
-- for anything else -- through auth.ready(), or on the dashboard through
-- auth.check(), which leaves the editor free -- and reports `:Docket login
-- <backend>` rather than prompting: a prompt cannot run in the fast-event
-- context every client callback arrives in, and the login is a command of
-- its own for that reason. The keys of an item buffer belong to the mode its
-- open entered, which asked already, so they ask nothing before calling the
-- adapter; a call the client refuses reports the client's own words.
--
-- A key or a command that needs an optional call runs only when the adapter
-- declares it, through adapters.can(), and otherwise says which call the
-- adapter lacks in one line. The keys are set on every item buffer and the
-- check is made when one is pressed, because the adapter a buffer needs is
-- loaded by the read, after the keys are attached.
--
-- A new ticket is written in a buffer of its own kind, named DRAFT and the
-- backend: its header is `Name: value` lines down to the first blank line,
-- and the rest is the body. It is not an item buffer, whose regions compare
-- against a snapshot of an item that exists; `:w` there creates the item
-- through the adapter's item_create and puts the item buffer of the new key
-- where the draft was.
--
-- The review mode is review.lua. `:Docket review <id>` opens it, and
-- `:Docket review <verb>` runs one of its verbs on the review in the current
-- tab; the bang on `submit` is review.lua's `force`, which posts comments held
-- against a merge request that has moved since. `R` on a merge request row
-- builds the environment and hands the editor window `:Docket review <id>`,
-- which is how a row reaches the review. A pull request goes to octo.nvim, as
-- `:Docket #12` sends it, since the GitHub adapter names that handoff and
-- implements no review call.
--
-- The review's keys are set on each buffer that shows a side of its diff, and
-- taken off again when the review's tab closes: the new side is the
-- worktree's own files, which stay open and are edited after the review. The
-- autocommands that do both are made at the first review, so an editor that
-- never opens one never has them.
--
-- A pull request never opens in the item buffer: the GitHub adapter names a
-- `handoff`, and open_item() then calls its item(), which opens octo.nvim.
-- From the dash the row's address goes with the identifier, and octo.nvim is
-- handed the address, which names the repository and its host, as gh.item()
-- says, UNVERIFIED; `:Docket #12` typed by hand, and a `docket://gh/` name,
-- which the read command hands off the same way, carry no address, so the
-- number goes alone, and octo.nvim's README says the repository then comes
-- from `<cwd>/.git/config`; gh.item() says what settles it against the
-- release installed.
--
-- A dash row whose address names another project than the dash's clone -- a
-- section naming `glab` or `gh` as its adapter runs in every clone, and `-R
-- acme/payments` or `--repo acme/tools` in its query lists that project's
-- rows -- is refused by every key that takes the row into the clone, through
-- foreign(): its number is this clone's merge request of that number, and a
-- branch of its name here is another's code. The clone's projects are the
-- paths its remotes name, so a row of `upstream`'s listed in a fork's clone
-- is the clone's own; a clone whose origin spells its one project another
-- way than the rows' addresses do is refused all the same, and the refusal
-- ends with the `git remote set-url origin` that makes the two agree. `<CR>`
-- on a pull request is the exception, since octo.nvim is handed the address.

local adapters = require("docket.adapters")
local auth = require("docket.auth")
local buffer = require("docket.buffer")
local cache = require("docket.cache")
local config = require("docket.config")
local env = require("docket.env")
local list = require("docket.list")
local repo = require("docket.repo")
local review = require("docket.review")
local row = require("docket.row")

local M = {}

-- A Jira key, `PROJ-142`, a merge request, `!482`, and a pull request,
-- `#12`, which are the shapes `:Docket <id>` takes.
M.KEY = "^%u[%u%d]+%-%d+$"
M.MR = "^!(%d+)$"
M.PR = "^#(%d+)$"

-- What `:Docket review` takes in place of an identifier, each the review.lua
-- function of the same name, run on the review in the current tab.
-- review.VERBS holds the spellings its own messages print.
M.REVIEW_VERBS = { "comment", "reply", "resolve", "submit", "abandon" }

-- The words `:Docket review submit` takes, each a field of the verdict
-- review.submit() is given: `approve` approves once the held comments are
-- posted, and `summary` opens a buffer for a summary comment whose `:w`
-- submits.
M.SUBMIT_WORDS = { "approve", "summary" }

-- The keys of a review, set on each buffer that shows a side of its diff.
-- Abandoning discards every held comment, so it has no key: it is typed out.
M.REVIEW_KEYS = {
  { lhs = "<leader>dc", verb = "comment", desc = "Docket: hold a review comment on this line" },
  { lhs = "<leader>dr", verb = "reply", desc = "Docket: reply to the thread on this line" },
  { lhs = "<leader>dx", verb = "resolve", desc = "Docket: resolve the thread on this line" },
  { lhs = "<leader>ds", verb = "submit", desc = "Docket: submit the review" },
}

-- A Jira project key, which is what `:Docket create` takes: the prefix of a
-- key such as `PROJ-142`.
M.PROJECT = "^%u[%u%d]+$"

-- The name of a new ticket's buffer is DRAFT and the backend,
-- `docket-new://jira`: one draft per backend. It is a scheme of its own so
-- that the read and write commands of `docket://` never see it.
M.DRAFT = "docket-new://"

-- The header of a new ticket, in the order the draft shows it, each the
-- field item_create() takes under the lower-case name. A blank line ends it.
M.HEADER = { "Project", "Type", "Summary", "Assignee" }

-- The type a new ticket's draft starts with.
M.TYPE = "Task"

-- What the report of a transition the client refused ends with: one whose
-- workflow needs fields filled in first fails naming them, and the web is
-- where they are filled.
M.WEB = "gx opens the item on the web"

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
end

--- The adapter an identifier belongs to.
---@param id string
---@return string|nil source
---@return string|nil err
function M.source_of(id)
  if id:match(M.KEY) then
    return "jira"
  end
  if id:match(M.MR) then
    return "glab"
  end
  if id:match(M.PR) then
    return "gh"
  end
  return nil,
    ("%s is none of a Jira key such as PROJ-142, a merge request such as !482 or a pull request such as #12"):format(id)
end

-- Opens an item after the state check: in the item buffer, or, for an
-- adapter that names a `handoff`, through buffer.hand_off() alone -- the
-- GitHub adapter opens a pull request in octo.nvim and has no item to
-- render, so no `docket://` buffer is made for it. The adapter goes down
-- with the open, so the read does not ask the client for the state a second
-- time. `cwd` is the clone the item is opened from, which the state check
-- runs in and buffer.open() names a merge request's buffer after and reads
-- it in: the dashboard passes the root it shows, so that `<CR>` opens a
-- merge request from the clone its row was fetched in, as `w` builds from
-- it, whatever the tab's directory is by then; `:Docket <id>` passes none,
-- and the editor's directory is read. `url` is the address a dash row
-- carries, and `:Docket <id>` passes none: a pull request is handed to
-- octo.nvim as `{ id, url }`, and gh.item() hands over the address, so that
-- octo.nvim is named the row's repository, as gh.item() says, UNVERIFIED;
-- with no address the number goes alone. `cwd` reaches a pull request's
-- state check and nothing after it.
local function open_item(source, id, cwd, url)
  local adapter, reason = auth.ready(source, cwd)
  if not adapter then
    notify(reason, vim.log.levels.ERROR)
    return nil
  end
  if adapter.handoff then
    buffer.hand_off(adapter, url and { id = id, url = url } or id, function(ok, err)
      if not ok then
        notify(err, vim.log.levels.ERROR)
      end
    end)
    return nil
  end
  return buffer.open(source, id, nil, adapter, cwd)
end

--- The backends the current repository uses: Jira, and the review client the
--- remote names when the working directory is inside a clone.
---@param cwd string
---@return string[] names
function M.backends(cwd)
  local names = { "jira" }
  local found = repo.root(cwd)
  if found then
    local url = repo.remote_url(found.root)
    local review = url and repo.adapter_for(url)
    if review then
      names[#names + 1] = review
    end
  end
  return names
end

--- Logs backends in, each reported on its own.
---@param name string|nil one backend, or every one the repository uses
---@param force boolean a re-login for a backend already signed in
function M.login(name, force)
  local names = name and { name } or M.backends(vim.fn.getcwd())
  for _, backend in ipairs(names) do
    local ok, message = auth.login(backend, { force = force })
    notify(message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end
end

--- Opens one item, after the state check.
---@param id string
---@return integer|nil buf
function M.item(id)
  local source, err = M.source_of(id)
  if not source then
    notify(err, vim.log.levels.ERROR)
    return nil
  end
  return open_item(source, id)
end

--- What the launcher did, as one message: the worktree path, then the
--- windows or the tab, then the pasteable script away from tmux, and the
--- warning when there is one.
---
--- The warning is printed beside the path rather than dropped, because a
--- launch that returns one has already made a usable environment: inside
--- tmux both windows exist before `allow-rename` is set, and away from tmux
--- the tab is open before a review command runs in it. The warning is the
--- only sign that the option or the command did not take, so a caller that
--- prints the path alone reports a review buffer that never opened as a
--- success.
---@param opened table what env.launch() returned
---@return string message
---@return integer level
function M.describe(opened)
  local lines = { ("worktree %s on %s"):format(opened.path, opened.branch) }
  if opened.how == "tmux" then
    if opened.shell then
      lines[#lines + 1] = ("tmux windows %s and %s"):format(opened.editor, opened.shell)
    else
      lines[#lines + 1] = ("tmux window %s; the companion window closed before it was settled"):format(opened.editor)
    end
  else
    lines[#lines + 1] = "a tab of this editor is at the worktree; the windows that tmux would hold:"
    lines[#lines + 1] = opened.script
  end
  local level = vim.log.levels.INFO
  if opened.warning then
    lines[#lines + 1] = "warning: " .. opened.warning
    level = vim.log.levels.WARN
  end
  return table.concat(lines, "\n"), level
end

--- Runs the launcher and reports what it did, or why it refused.
---
--- The refusal is reported verbatim: in an unbound repository env.launch()
--- refuses a ticket with the binding command, and that reason is what the
--- dashboard has to show, since its rows there come from every project the
--- account works on.
---
--- The launcher blocks on git, and `git wt-add` and `git ls-remote` can wait
--- on origin up to the git timeout, so a line naming what is being prepared
--- is drawn first, and a held editor has it on screen to say why.
---@param opts table what env.launch() takes
function M.launch(opts)
  vim.api.nvim_echo({
    {
      ("docket: preparing the worktree for %s; when git has to ask origin, the editor waits up to %d s"):format(
        opts.key or opts.branch,
        math.floor(config.options.timeouts.git / 1000)
      ),
    },
  }, false, {})
  vim.cmd.redraw()
  local opened, err = env.launch(opts)
  if not opened then
    return notify(err, vim.log.levels.ERROR)
  end
  notify(M.describe(opened))
end

--- Builds the development environment for the ticket an item buffer holds.
---
--- A ticket alone: the item buffer keeps no branch, and a merge request's
--- comes from its dashboard row, where `w` reads it.
---@param buf integer
function M.work(buf)
  local state = vim.b[buf].docket
  if not state then
    return notify("nothing loaded in this buffer; :e reads the item", vim.log.levels.ERROR)
  end
  if state.source ~= "jira" then
    return notify(("%s is not a ticket; the launcher takes a ticket here"):format(state.id), vim.log.levels.ERROR)
  end
  local found, err = repo.root(vim.fn.getcwd())
  if not found then
    return notify(err, vim.log.levels.ERROR)
  end
  local binding
  binding, err = repo.binding(found.root)
  if not binding then
    return notify(err, vim.log.levels.ERROR)
  end
  M.launch({ root = found.root, binding = binding, key = state.id, summary = state.title })
end

--- Opens the item an item buffer holds in the browser.
---@param buf integer
function M.browse(buf)
  local adapter, id, err = buffer.adapter_of(buf)
  if not adapter then
    return notify(err, vim.log.levels.ERROR)
  end
  -- The address the buffer's last read answered comes first: glab keeps one
  -- address per number, and `!482` of two projects is two buffers. A buffer
  -- nothing has read yet carries none, and the adapter answers for it.
  local state = vim.b[buf].docket
  local url
  url, err = adapter.url({ id = id, url = type(state) == "table" and state.url or nil })
  if not url then
    return notify(err, vim.log.levels.ERROR)
  end
  -- vim.ui.open reports a missing opener as its second value rather than
  -- raising, and auth's token page checks it the same way.
  local _, open_err = vim.ui.open(url)
  if open_err then
    notify(open_err, vim.log.levels.WARN)
  end
end

-- The adapter of an item buffer and what its read stored, when the adapter
-- declares every call named; otherwise nil, after one line saying what is
-- missing. The line names the buffer and the call, in the words
-- buffer.compose() uses for a comment on a backend with no comment_create.
local function capable(buf, ...)
  local state = vim.b[buf].docket
  if not state then
    notify("nothing loaded in this buffer; :e reads the item", vim.log.levels.WARN)
    return nil
  end
  local name = buffer.name(state.source, state.id, state.project)
  local adapter, err = adapters.get(state.source)
  if not adapter then
    notify(("%s: %s"):format(name, err), vim.log.levels.ERROR)
    return nil
  end
  for _, capability in ipairs({ ... }) do
    if not adapters.can(adapter, capability) then
      notify(("%s: the %s adapter has no %s"):format(name, state.source, capability), vim.log.levels.WARN)
      return nil
    end
  end
  return adapter, state
end

-- The end of a transition or an assignment the client applied. The rows
-- cached for the item are dropped, because a row carries its state and its
-- assignee. The buffer is read again so its first line shows what the
-- backend holds now, unless it holds unsaved edits or a write is in flight:
-- a read refuses the first, and a read under a write leaves that write
-- unable to bring the buffer up to date after its calls.
local function applied(buf, state, adapter, message)
  cache.drop_item(state.source, state.id)
  if not vim.api.nvim_buf_is_valid(buf) then
    return notify(message)
  end
  if vim.bo[buf].modified or buffer.writing(buf) then
    return notify(
      ("%s; the buffer holds unsaved edits, so its first line shows the item as it was read until :w or :e! settles them"):format(
        message
      )
    )
  end
  notify(message)
  buffer.read(buf, nil, adapter)
end

--- Opens a comment at the end of an item buffer, through buffer.compose(),
--- which refuses in one line on a backend with no comment_create.
---@param buf integer
---@return integer|nil row the 1-based line the comment is typed on
function M.comment(buf)
  return (buffer.compose(buf))
end

--- Moves the item an item buffer holds to another state: the adapter's
--- states() in a picker, then state_set() with the one chosen.
---
--- On Jira the states are the statuses seen across the project, because acli
--- cannot list the transitions a work item offers, so a status the workflow
--- refuses is reported in acli's own words; so is one behind fields that
--- have to be filled in first, with the web named as where that is done.
---@param buf integer
function M.transition(buf)
  local adapter, state = capable(buf, "states", "state_set")
  if not adapter then
    return
  end
  local id = state.id
  adapter.states(buffer.target(state), function(states, err)
    vim.schedule(function()
      if not states then
        return notify(("%s: %s"):format(id, tostring(err or "the client offered no state")), vim.log.levels.ERROR)
      end
      if #states == 0 then
        return notify(("%s: there is no state to move it to"):format(id))
      end
      vim.ui.select(states, {
        prompt = ("Move %s to"):format(id),
        format_item = function(choice)
          return choice.label
        end,
      }, function(choice)
        if not choice then
          return
        end
        adapter.state_set(buffer.target(state), choice.target, function(ok, set_err)
          vim.schedule(function()
            if not ok then
              return notify(
                ("%s: %s: %s\n%s"):format(id, choice.label, tostring(set_err or "the client reported no success"), M.WEB),
                vim.log.levels.ERROR
              )
            end
            applied(buf, state, adapter, ("%s: %s"):format(id, choice.label))
          end)
        end)
      end)
    end)
  end)
end

-- Who an item can be assigned to: the account signed in, nobody, and each
-- person the item names -- its assignee, its reporter and each comment's
-- author -- once, by identifier. The assignee's label says so. These are the
-- people a picker can offer by name: acli has no user command, and on Jira
-- an identifier is an opaque account id nobody types.
local function assignees(it)
  local current = it.assignee and it.assignee.id
  local function label(text, id)
    return id ~= nil and id == current and (text .. " (assigned)") or text
  end
  local choices = {
    { label = label("me", it.me), who = adapters.ME },
    { label = "nobody", who = adapters.NOBODY },
  }
  local seen = {}
  if it.me ~= nil then
    seen[it.me] = true
  end
  local function offer(person)
    if person and person.id ~= nil and not seen[person.id] then
      seen[person.id] = true
      choices[#choices + 1] = { label = label(person.name or person.id, person.id), who = person.id }
    end
  end
  offer(it.assignee)
  offer(it.reporter)
  for _, comment in ipairs(it.comments or {}) do
    offer(comment.author)
  end
  return choices
end

--- Assigns the item an item buffer holds: the item is read for the people
--- it names, a picker offers them beside the account signed in and nobody,
--- and the adapter's assign() applies the choice.
---@param buf integer
function M.assign(buf)
  local adapter, state = capable(buf, "assign")
  if not adapter then
    return
  end
  local id = state.id
  adapter.item(buffer.target(state), function(it, err)
    vim.schedule(function()
      if not it then
        return notify(("%s: %s"):format(id, tostring(err or "the client returned no item")), vim.log.levels.ERROR)
      end
      vim.ui.select(assignees(it), {
        prompt = ("Assign %s to"):format(id),
        format_item = function(choice)
          return choice.label
        end,
      }, function(choice)
        if not choice then
          return
        end
        adapter.assign(buffer.target(state), choice.who, function(ok, assign_err)
          vim.schedule(function()
            if not ok then
              return notify(
                ("%s: %s"):format(id, tostring(assign_err or "the client reported no success")),
                vim.log.levels.ERROR
              )
            end
            local done = choice.who == adapters.NOBODY and ("%s: unassigned"):format(id)
              or ("%s: assigned to %s"):format(id, (choice.label:gsub(" %(assigned%)$", "")))
            applied(buf, state, adapter, done)
          end)
        end)
      end)
    end)
  end)
end

-- Whether a buffer is a new ticket's draft.
local function is_draft(buf)
  return vim.api.nvim_buf_get_name(buf):sub(1, #M.DRAFT) == M.DRAFT
end

--- The buffer-local keymaps of an item buffer, set from the FileType
--- autocommand. A new ticket's draft carries the same filetype and gets
--- none: each of them acts on an item that exists.
---@param buf integer
function M.attach(buf)
  if is_draft(buf) then
    return
  end
  local opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "gx", function()
    M.browse(buf)
  end, vim.tbl_extend("force", opts, { desc = "Docket: open the item on the web" }))
  vim.keymap.set("n", "<leader>dw", function()
    M.work(buf)
  end, vim.tbl_extend("force", opts, { desc = "Docket: build the development environment" }))
  vim.keymap.set("n", "<leader>dc", function()
    M.comment(buf)
  end, vim.tbl_extend("force", opts, { desc = "Docket: open a new comment" }))
  vim.keymap.set("n", "<leader>dt", function()
    M.transition(buf)
  end, vim.tbl_extend("force", opts, { desc = "Docket: move the item to another state" }))
  vim.keymap.set("n", "<leader>da", function()
    M.assign(buf)
  end, vim.tbl_extend("force", opts, { desc = "Docket: assign the item" }))
end

--- The header and the body a draft holds, in the shape item_create() takes.
---
--- The header is `Name: value` lines down to the first blank line, each name
--- one of HEADER in any case; the body is every line after that, with blank
--- lines at either end dropped, which is the trim the region compare makes.
--- An empty value is an absent field, which item_create() refuses naming it
--- where it is required. The assignee is `me`, `nobody`, or the identifier
--- items carry for a person -- an account id on Jira; empty leaves it to the
--- backend.
---@param lines string[]
---@return table|nil fields `{ project, type, summary, assignee }`
---@return string body, or why the lines are not a draft
function M.parse_draft(lines)
  local known = {}
  for _, name in ipairs(M.HEADER) do
    known[name:lower()] = true
  end
  local fields, index = {}, 1
  while index <= #lines and not lines[index]:match("^%s*$") do
    local name, value = lines[index]:match("^%s*(%a+)%s*:%s*(.-)%s*$")
    if not name then
      return nil,
        ("line %d is not a header line such as `Summary: text`; a blank line ends the header"):format(index)
    end
    if not known[name:lower()] then
      return nil, ("%s is not a field of a new ticket; the fields are %s"):format(name, table.concat(M.HEADER, ", "))
    end
    fields[name:lower()] = value ~= "" and value or nil
    index = index + 1
  end
  local first, last = index, #lines
  while first <= last and lines[first]:match("^%s*$") do
    first = first + 1
  end
  while last >= first and lines[last]:match("^%s*$") do
    last = last - 1
  end
  if fields.assignee == "me" then
    fields.assignee = adapters.ME
  elseif fields.assignee == "nobody" then
    fields.assignee = adapters.NOBODY
  end
  return fields, table.concat(lines, "\n", first, last)
end

-- The project a new ticket starts in when `:Docket create` names none: the
-- project of the Jira ticket in the current buffer, or the one project the
-- clone is bound to. nil otherwise, and the draft's Project line is left for
-- the reader to fill.
local function project_here()
  local state = vim.b.docket
  if type(state) == "table" and state.source == "jira" and type(state.id) == "string" then
    local project = state.id:match("^(%u[%u%d]+)%-%d+$")
    if project then
      return project
    end
  end
  local found = repo.root(vim.fn.getcwd())
  if not found then
    return nil
  end
  local binding = repo.binding(found.root)
  if binding and binding.kind == "projects" and #binding.projects == 1 then
    return binding.projects[1]
  end
  return nil
end

-- The creates in flight, by draft buffer, each holding the lines that were
-- sent: from :w until item_create() answers. The draft is not modifiable
-- meanwhile, so the text that answer replaces is the text that was sent.
local creating = {}

--- Fills a draft with the header and one empty body line, and clears
--- `modified`, since a blank draft is not an edit. BufReadCmd runs this on
--- `:e` in a draft, so `:e!` starts one afresh. The backend comes from the
--- buffer's name, and the project from the last `:Docket create`.
---
--- A draft whose create is in flight gets back the lines that were sent:
--- `:e!` has emptied it before BufReadCmd runs, 'modifiable' off or not, and
--- a create the client then refuses would leave nothing to correct and save
--- again.
---@param buf integer
function M.draft(buf)
  local pending = creating[buf]
  if pending then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, pending.lines)
    vim.bo[buf].modifiable = false
    return notify(
      ("%s: a create is in flight; the new ticket opens here when it reports"):format(vim.api.nvim_buf_get_name(buf)),
      vim.log.levels.WARN
    )
  end
  local state = vim.b[buf].docket_draft
  if type(state) ~= "table" then
    state = { source = vim.api.nvim_buf_get_name(buf):sub(#M.DRAFT + 1), project = project_here() }
  end
  buffer.prepare(buf)
  local values = { Project = state.project or "", Type = M.TYPE, Summary = "", Assignee = "" }
  local lines = {}
  for _, name in ipairs(M.HEADER) do
    lines[#lines + 1] = ("%s: %s"):format(name, values[name])
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ""
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = undolevels
  vim.b[buf].docket_draft = state
  vim.bo[buf].modified = false
end

--- `:Docket create [<project>]`: the state check, then a draft for a new
--- Jira ticket in the current window, its Project line filled from the
--- argument or from where the editor is. A draft already holding text is
--- switched to rather than replaced, and so is one whose create is in flight.
---@param project string|nil
---@return integer|nil buf
function M.create(project)
  if project ~= nil and not project:match(M.PROJECT) then
    notify(("create takes a project key such as PROJ; got %s"):format(project), vim.log.levels.ERROR)
    return nil
  end
  local source = "jira"
  local adapter, reason = auth.ready(source)
  if not adapter then
    notify(reason, vim.log.levels.ERROR)
    return nil
  end
  local name = M.DRAFT .. source
  if not adapters.can(adapter, "item_create") then
    notify(("%s: the %s adapter has no item_create"):format(name, source), vim.log.levels.WARN)
    return nil
  end
  local buf = buffer.named(name)
  if buf and (creating[buf] or vim.bo[buf].modified) then
    vim.api.nvim_set_current_buf(buf)
    notify(
      creating[buf] and ("%s: a create is in flight; the new ticket opens here when it reports"):format(name)
        or ("%s holds a ticket not yet created; :w creates it, and :e! starts it afresh"):format(name),
      vim.log.levels.WARN
    )
    return buf
  end
  project = project or project_here()
  if not buf then
    buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.b[buf].docket_draft = { source = source, project = project }
  M.draft(buf)
  vim.api.nvim_set_current_buf(buf)
  -- The summary is what every draft still needs, so the cursor starts at the
  -- end of its line.
  for index, field in ipairs(M.HEADER) do
    if field == "Summary" then
      vim.api.nvim_win_set_cursor(0, { index, #field + 1 })
    end
  end
  return buf
end

-- Puts the item buffer of a created key where the draft was: in every window
-- showing the draft, which is then deleted, and read through the adapter the
-- create went through. A draft shown nowhere leaves the item buffer hidden,
-- and the message names the command that shows it.
local function reopen(draft, source, key, adapter)
  local name = buffer.name(source, key)
  local buf = buffer.named(name)
  if not buf then
    buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, name)
    buffer.prepare(buf)
  end
  local shown = false
  if vim.api.nvim_buf_is_valid(draft) then
    for _, win in ipairs(vim.fn.win_findbuf(draft)) do
      vim.api.nvim_win_set_buf(win, buf)
      shown = true
    end
    vim.api.nvim_buf_delete(draft, { force = true })
  end
  buffer.read(buf, nil, adapter)
  return shown
end

--- The write command of a draft, which BufWriteCmd runs for `:w`: the draft
--- parsed, then the adapter's item_create(), then the new item's buffer in
--- the draft's place.
---
--- A second :w while the create is in flight is refused, and the draft is
--- not modifiable until it answers, so one draft makes one item. A create
--- the client refuses leaves the draft as it was, modified, with the
--- client's own words. A create that may have made the item all the same --
--- reported done with no key that can be read, or killed at the timeout --
--- leaves the text on screen and stops being a draft: `:w` then answers that
--- there is nothing to create, rather than making a second ticket.
---@param buf integer
---@param on_done fun(ok: boolean, message: string)|nil called once, when the create has answered or been refused
---@return boolean started true when item_create was called
---@return string|nil message why it was not, when it was not
function M.save_draft(buf, on_done)
  local name = vim.api.nvim_buf_get_name(buf)
  local function finish(ok, message, level)
    notify(message, level)
    if on_done then
      on_done(ok, message)
    end
    return false, message
  end
  local state = vim.b[buf].docket_draft
  if type(state) ~= "table" then
    return finish(false, "nothing to create in this buffer; :Docket create starts a ticket", vim.log.levels.WARN)
  end
  if creating[buf] then
    return finish(false, ("%s: a create is in flight; :w again once it reports"):format(name), vim.log.levels.WARN)
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local fields, body = M.parse_draft(lines)
  if not fields then
    return finish(false, ("%s: %s"):format(name, body), vim.log.levels.WARN)
  end
  local adapter, err = adapters.get(state.source)
  if not adapter then
    return finish(false, ("%s: %s"):format(name, err), vim.log.levels.ERROR)
  end
  if not adapters.can(adapter, "item_create") then
    return finish(false, ("%s: the %s adapter has no item_create"):format(name, state.source), vim.log.levels.WARN)
  end
  creating[buf] = { lines = lines }
  vim.bo[buf].modifiable = false
  local function answered(key, create_err, made)
    creating[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = true
      if not key and made then
        -- The ticket may exist, so the buffer is no longer a draft of one.
        vim.b[buf].docket_draft = nil
        vim.bo[buf].modified = false
      elseif not key then
        -- The draft holds a ticket that does not exist. `:e!` during the
        -- create clears `modified` after the read command has put the text
        -- back, so it is set here, where :e and :Docket create read it before
        -- replacing it.
        vim.bo[buf].modified = true
      end
    end
    if not key then
      finish(false, ("%s: %s"):format(name, tostring(create_err or "the client returned no key")), vim.log.levels.ERROR)
      return
    end
    local shown = reopen(buf, state.source, key, adapter)
    finish(true, shown and ("created %s"):format(key) or ("created %s; :Docket %s opens it"):format(key, key), vim.log.levels.INFO)
  end
  local called, raised = pcall(adapter.item_create, fields, body, function(key, create_err, made)
    vim.schedule(function()
      answered(key, create_err, made == true)
    end)
  end)
  if not called then
    answered(nil, tostring(raised))
  end
  return true, nil
end

-- The row under the cursor in the dashboard, reported when there is none.
local function row_under_cursor(buf)
  local r, section = list.row_at(buf, vim.api.nvim_win_get_cursor(0)[1])
  if not r then
    notify("no item on this line", vim.log.levels.WARN)
  end
  return r, section
end

-- The clone the dashboard shows, for the launcher. A binding that could not
-- be read stops the launch with the reason, because env.launch() decides the
-- unbound refusal from it.
local function dash_clone(buf)
  local state = list.state(buf)
  if not state then
    notify("this buffer is not the dashboard", vim.log.levels.ERROR)
    return nil
  end
  if not state.binding then
    notify(state.binding_err, vim.log.levels.ERROR)
    return nil
  end
  return state
end

-- The refusal for a merge request or a pull request from a fork. Its branch
-- lives in the fork, and a branch of the same name on origin, or a worktree
-- already on one, is somebody else's code under that name: `main` and
-- `patch-1` are the usual cases. The launcher's own check asks origin whether
-- the name exists, which such a branch passes, so the row's `fork` is what
-- refuses it, where refused_fork() says it does.
local function from_fork(r)
  return ("%s comes from a fork, so origin's %s is not its branch and no worktree is made for it"):format(r.id, r.branch)
end

-- Whether a row marked `fork` is refused in this clone. `fork` says the row's
-- source project is not its target's, and its branch lives in the source. In
-- a clone of the target -- the row's address names origin's project -- the
-- branch is in some fork and never on origin, so the row is refused. In a
-- fork's clone, where the client lists upstream's rows, foreign() has passed
-- the row because its address names a remote, and origin is itself a fork:
-- it holds the branch of every merge request made from it, so the row is
-- not refused, and the launcher's question to origin decides. The row of
-- another fork on a branch origin also has is what that does not catch. A
-- row whose address names no project, and one in a clone whose origin names
-- none, are refused: nothing says the clone is a fork.
local function refused_fork(r, root)
  if not r.fork then
    return false
  end
  local adapter = adapters.get(r.source)
  local theirs = adapter and adapter.project_of(r.url) or nil
  local ours = theirs and repo.project(root) or nil
  return not (theirs and ours) or repo.same_project(theirs, ours)
end

-- Whether a row is another project's than the dash's clone, in which case it
-- is refused at ERROR level and not taken into the clone. A section naming
-- `glab` or `gh` as its adapter runs its query in every clone, and `-R
-- acme/payments` or `--repo acme/tools` in it lists that project's rows in a
-- dash of this one, where `!482` is this project's merge request of that
-- number and a branch of the row's name is another's code. The row's project
-- is read off its address through the adapter's project_of(), and compared,
-- through repo.same_project() and without case, with origin's, from
-- repo.project(root), and then with the path every other remote names, from
-- repo.remotes(root), which says why: the client that listed the rows picks
-- its project from the remotes on its own, and a row of `upstream`'s in a
-- fork's clone is this clone's work. The remotes are read only once origin's
-- path is another, so a row of origin's project costs no second git call. A
-- row whose adapter cannot say what its address names -- a ticket, or an
-- address of another shape -- is not refused, nor is one in a clone whose
-- origin names no project; what the key does next reports its own reason
-- there. The refusal names the row's project and origin's, then what the key
-- says to do in its place -- `instead` is given the row's project and
-- answers that -- and ends, as the item buffer's refusal of an answer naming
-- another project does, with repo.set_url_remedy(): the compare cannot tell
-- a clone of another project from one whose origin spells this project
-- another way than the row's address does, so both remedies are given.
local function foreign(r, root, instead)
  local adapter = adapters.get(r.source)
  local theirs = adapter and adapter.project_of(r.url) or nil
  if not theirs then
    return false
  end
  local ours = repo.project(root)
  if not ours or repo.same_project(theirs, ours) then
    return false
  end
  for _, remote in ipairs(repo.remotes(root) or {}) do
    local path = repo.project_of(remote.url)
    if path and repo.same_project(theirs, path) then
      return false
    end
  end
  notify(
    ("%s is %s's, and the dash's clone is of %s, %s%s"):format(
      r.id,
      theirs,
      ours,
      instead(theirs),
      repo.set_url_remedy(r.url, theirs) or ""
    ),
    vim.log.levels.ERROR
  )
  return true
end

--- Opens the item on the dashboard's cursor line, after the state check,
--- from the clone the dashboard shows, where the row was fetched. A pull
--- request is handed to octo.nvim with its address, so that octo.nvim is
--- named the row's repository, as gh.item() says, UNVERIFIED; a merge
--- request is read in the clone, so a row of another project is refused,
--- through foreign().
---@param buf integer
function M.open_row(buf)
  local r = row_under_cursor(buf)
  if not r then
    return
  end
  -- The root from the state itself rather than through dash_clone(), whose
  -- refusal of a binding that could not be read is the launcher's: an open
  -- reads no binding.
  local root = list.state(buf).root
  local adapter = adapters.get(r.source)
  if
    not (adapter and adapter.handoff)
    and foreign(r, root, function(theirs)
      return ("whose %s is another; :Docket %s from a clone of %s opens it"):format(r.id, r.id, theirs)
    end)
  then
    return
  end
  open_item(r.source, r.id, root, r.url)
end

--- Builds the development environment for the row on the dashboard's cursor
--- line: from the key for a ticket, from the branch a merge request carries.
--- A row of another project than the dash's clone is refused through
--- foreign() before the launcher runs: its branch is on the other origin. A
--- row from a fork is refused through refused_fork(), which says where.
---@param buf integer
function M.work_row(buf)
  local r = row_under_cursor(buf)
  if not r then
    return
  end
  if
    foreign(r, list.state(buf).root, function(theirs)
      return ("where a branch of its name is another's code; w in the dash of a clone of %s builds it"):format(theirs)
    end)
  then
    return
  end
  local clone = dash_clone(buf)
  if not clone then
    return
  end
  if r.source == "jira" then
    return M.launch({ root = clone.root, binding = clone.binding, key = r.id, summary = r.title })
  end
  if not r.branch then
    return notify(("%s carries no branch, so no worktree is made for it"):format(r.id), vim.log.levels.ERROR)
  end
  if refused_fork(r, clone.root) then
    return notify(from_fork(r), vim.log.levels.ERROR)
  end
  M.launch({ root = clone.root, binding = clone.binding, branch = r.branch })
end

--- Starts a review on the merge request on the dashboard's cursor line: the
--- same environment as work_row(), with the editor window opening the review.
--- A row of another project than the dash's clone is refused as work_row()
--- refuses it, and first: the review it would open is this clone's merge
--- request of that number.
---@param buf integer
function M.review_row(buf)
  local r = row_under_cursor(buf)
  if not r then
    return
  end
  if
    foreign(r, list.state(buf).root, function(theirs)
      return ("where a branch of its name is another's code; R in the dash of a clone of %s reviews it"):format(theirs)
    end)
  then
    return
  end
  if r.source == "jira" then
    return notify(("%s is a ticket; R starts a review on a merge request"):format(r.id), vim.log.levels.ERROR)
  end
  if not r.branch then
    return notify(("%s carries no branch, so no worktree is made for it"):format(r.id), vim.log.levels.ERROR)
  end
  if refused_fork(r, list.state(buf).root) then
    return notify(from_fork(r), vim.log.levels.ERROR)
  end
  local clone = dash_clone(buf)
  if not clone then
    return
  end
  M.launch({ root = clone.root, binding = clone.binding, branch = r.branch, review = r.id })
end

--- The buffer-local keymaps of the dashboard.
---@param buf integer
function M.attach_dash(buf)
  local opts = { buffer = buf, noremap = true, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", function()
    M.open_row(buf)
  end, vim.tbl_extend("force", opts, { desc = "Docket: open the item" }))
  vim.keymap.set("n", "w", function()
    M.work_row(buf)
  end, vim.tbl_extend("force", opts, { desc = "Docket: build the development environment" }))
  vim.keymap.set("n", "r", function()
    list.refresh(buf)
  end, vim.tbl_extend("force", opts, { desc = "Docket: refresh" }))
  vim.keymap.set("n", "R", function()
    M.review_row(buf)
  end, vim.tbl_extend("force", opts, { desc = "Docket: review the merge request" }))
end

--- Runs one of the review's verbs on the review in the current tab.
---
--- review.lua reports a tab with no review, or a cursor on no side of its
--- diff, itself. `submit` takes the words of SUBMIT_WORDS, and `force` is
--- the bang; every other verb takes nothing more.
---@param verb string one of REVIEW_VERBS
---@param words string[] what followed the verb
---@param force boolean
function M.review_verb(verb, words, force)
  if verb ~= "submit" and #words > 0 then
    return notify(("review %s takes nothing more; got %s"):format(verb, table.concat(words, " ")), vim.log.levels.ERROR)
  end
  if verb == "comment" then
    return review.comment()
  end
  if verb == "reply" then
    return review.reply()
  end
  if verb == "resolve" then
    return review.resolve()
  end
  if verb == "abandon" then
    review.abandon()
    -- A diff that `:DiffviewClose` left open keeps its tab, and the review
    -- is gone all the same, so its keys come off here as well as on
    -- TabClosed.
    return M.unkey_reviews()
  end
  local verdict = { force = force == true }
  for _, word in ipairs(words) do
    if not vim.tbl_contains(M.SUBMIT_WORDS, word) then
      return notify(
        ("review submit takes %s; got %s"):format(table.concat(M.SUBMIT_WORDS, " and "), word),
        vim.log.levels.ERROR
      )
    end
    verdict[word] = true
  end
  review.submit(verdict)
end

--- Sets the review's keys on a buffer.
---@param buf integer
function M.attach_review(buf)
  local opts = { buffer = buf, noremap = true, silent = true }
  for _, key in ipairs(M.REVIEW_KEYS) do
    vim.keymap.set("n", key.lhs, function()
      M.review_verb(key.verb, {}, false)
    end, vim.tbl_extend("force", opts, { desc = key.desc }))
  end
end

--- Takes the review's keys off a buffer, and no other map: one is known as
--- the review's by its description.
---@param buf integer
function M.detach_review(buf)
  local ours = {}
  for _, key in ipairs(M.REVIEW_KEYS) do
    ours[key.desc] = true
  end
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if ours[map.desc] then
      vim.api.nvim_buf_del_keymap(buf, "n", map.lhs)
    end
  end
end

-- The buffers carrying the review's keys, each with the review whose tab it
-- was keyed in.
local keyed = {}

--- Keys every buffer of the current tab that shows a side of the diff of the
--- review in it, which review.locate() answers. Nothing when the tab holds
--- no review.
function M.key_review_tab()
  local current = review.current()
  if not current then
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if review.locate(current, buf) then
      M.attach_review(buf)
      keyed[buf] = current
    end
  end
end

--- Takes the keys off every buffer whose review no longer has its tab.
function M.unkey_reviews()
  for buf, owner in pairs(keyed) do
    if not (owner.tab and vim.api.nvim_tabpage_is_valid(owner.tab)) then
      keyed[buf] = nil
      if vim.api.nvim_buf_is_valid(buf) then
        M.detach_review(buf)
      end
    end
  end
end

local review_group = nil

-- The autocommands that key a review's buffers and unkey them, made once a
-- review exists. review.open() returns before its diff opens, since the
-- diff waits on the merge request's read, so they are in place when it
-- does. A buffer is keyed after the event rather than in it, because
-- diffview fills its tab's windows before review.lua records the tab as the
-- review's, and until then nothing answers review.current(). BufWinEnter
-- covers every file diffview puts in a window, and TabEnter every return to
-- the tab.
local function review_autocommands()
  if review_group ~= nil then
    return
  end
  review_group = vim.api.nvim_create_augroup("docket/review-keys", { clear = true })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "TabEnter" }, {
    group = review_group,
    callback = function()
      vim.schedule(M.key_review_tab)
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = review_group,
    callback = function()
      M.unkey_reviews()
    end,
  })
end

--- Opens the review of a merge request, through review.open().
---
--- The adapter is checked for every call a review makes before anything
--- runs, so a Jira key is refused without asking acli for its state, which
--- reaches the network. review.open() makes the state check itself, after
--- it has checked that diffview.nvim is there.
---@param id string
---@return table|nil review
function M.review_open(id)
  local source, err = M.source_of(id)
  if not source then
    notify(err, vim.log.levels.ERROR)
    return nil
  end
  local adapter
  adapter, err = adapters.get(source)
  if not adapter then
    notify(("%s: %s"):format(id, err), vim.log.levels.ERROR)
    return nil
  end
  if adapter.handoff then
    open_item(source, id)
    return nil
  end
  for _, capability in ipairs(review.NEEDS) do
    if not adapters.can(adapter, capability) then
      notify(("%s: %s has no review mode; it does not implement %s"):format(id, source, capability), vim.log.levels.ERROR)
      return nil
    end
  end
  local opened = review.open(source, id)
  if opened then
    review_autocommands()
  end
  return opened
end

--- `:Docket review <id>`, or `:Docket review <verb>`.
---@param args string[] the words after `review`
---@param force boolean the bang
---@return table|nil review
function M.review(args, force)
  local first = args[1]
  if first == nil then
    notify(
      ("review takes a merge request such as !482, or one of %s"):format(table.concat(M.REVIEW_VERBS, ", ")),
      vim.log.levels.ERROR
    )
    return nil
  end
  if vim.tbl_contains(M.REVIEW_VERBS, first) then
    M.review_verb(first, vim.list_slice(args, 2), force)
    return nil
  end
  if #args > 1 then
    notify(("review takes one merge request; got %s"):format(table.concat(args, " ")), vim.log.levels.ERROR)
    return nil
  end
  return M.review_open(first)
end

--- Opens the dashboard for the clone the working directory is in.
---@return integer|nil buf
function M.dash()
  local found, err = repo.root(vim.fn.getcwd())
  if not found then
    notify(("the dashboard opens inside a clone; %s"):format(err), vim.log.levels.ERROR)
    return nil
  end
  local buf = list.open(found)
  M.attach_dash(buf)
  return buf
end

--- The `:Docket` command: no argument for the dashboard, `login [<backend>]`,
--- `review <id>`, `review <verb>`, `create [<project>]`, or one identifier.
---@param command { fargs: string[], bang: boolean }
function M.run(command)
  local args = command.fargs
  if #args == 0 then
    return M.dash()
  end
  if args[1] == "login" then
    return M.login(args[2], command.bang)
  end
  if args[1] == "review" then
    return M.review(vim.list_slice(args, 2), command.bang)
  end
  if args[1] == "create" then
    if #args > 2 then
      return notify(("create takes one project key; got %s"):format(table.concat(args, " ", 2)), vim.log.levels.ERROR)
    end
    return M.create(args[2])
  end
  if #args > 1 then
    return notify(("Docket takes one identifier; got %s"):format(table.concat(args, " ")), vim.log.levels.ERROR)
  end
  M.item(args[1])
end

--- Command-line completion for `:Docket`: the subcommands, then the backend
--- names after `login`, the verbs after `review`, and the verdict's words
--- after `review submit`. A merge request's identifier is not offered, and
--- nothing follows one.
---@param lead string what has been typed of the current word
---@param line string the whole command line
---@return string[]
function M.complete(lead, line)
  local candidates
  if line:match("^%s*Docket!?%s+login%s") then
    candidates = row.SOURCES
  elseif line:match("^%s*Docket!?%s+review%s+submit%s") then
    candidates = M.SUBMIT_WORDS
  elseif line:match("^%s*Docket!?%s+review%s+%S*$") then
    candidates = M.REVIEW_VERBS
  elseif line:match("^%s*Docket!?%s+review%s") then
    candidates = {}
  else
    candidates = { "create", "login", "review" }
  end
  return vim.tbl_filter(function(word)
    return word:sub(1, #lead) == lead
  end, candidates)
end

return M
