-- The user commands and the keymaps: what `:Docket` dispatches to, and what
-- the dashboard and the item buffer bind. Imports auth, buffer, config, env,
-- list, repo and row. plugin/docket.lua declares the command, the `<leader>d`
-- maps and the autocommands and calls in here, so that nothing below is
-- loaded until the first use.
--
-- Every mode asks its adapter for the authentication state before it asks
-- for anything else -- through auth.ready(), or on the dashboard through
-- auth.check(), which leaves the editor free -- and reports `:Docket login
-- <backend>` rather than prompting: a prompt cannot run in the fast-event
-- context every client callback arrives in, and the login is a command of
-- its own for that reason.
--
-- The review mode is not part of this build. Its command reports that rather
-- than doing something else; `R` on a merge request row builds the
-- environment and hands the editor window that command, which is how a row
-- reaches the report.
--
-- A pull request never opens in the item buffer: the GitHub adapter names a
-- `handoff`, and open_item() then calls its item(), which opens octo.nvim.
-- A `docket://gh/` name typed by hand is handed off the same way, by the
-- read command.

local auth = require("docket.auth")
local buffer = require("docket.buffer")
local config = require("docket.config")
local env = require("docket.env")
local list = require("docket.list")
local repo = require("docket.repo")
local row = require("docket.row")

local M = {}

-- A Jira key, `PROJ-142`, a merge request, `!482`, and a pull request,
-- `#12`, which are the shapes `:Docket <id>` takes.
M.KEY = "^%u[%u%d]+%-%d+$"
M.MR = "^!(%d+)$"
M.PR = "^#(%d+)$"

M.NOT_BUILT = {
  review = "the review mode is not part of this build",
}

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

--- The buffer-local keymaps of an item buffer, set from the FileType
--- autocommand.
---@param buf integer
function M.attach(buf)
  local opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set("n", "gx", function()
    M.browse(buf)
  end, vim.tbl_extend("force", opts, { desc = "Docket: open the item on the web" }))
  vim.keymap.set("n", "<leader>dw", function()
    M.work(buf)
  end, vim.tbl_extend("force", opts, { desc = "Docket: build the development environment" }))
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
-- refuses it.
local function from_fork(r)
  return ("%s comes from a fork, so origin's %s is not its branch and no worktree is made for it"):format(r.id, r.branch)
end

--- Opens the item on the dashboard's cursor line, after the state check.
---@param buf integer
function M.open_row(buf)
  local r = row_under_cursor(buf)
  if not r then
    return
  end
  open_item(r.source, r.id)
end

--- Builds the development environment for the row on the dashboard's cursor
--- line: from the key for a ticket, from the branch a merge request carries.
---@param buf integer
function M.work_row(buf)
  local r = row_under_cursor(buf)
  if not r then
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
  if r.fork then
    return notify(from_fork(r), vim.log.levels.ERROR)
  end
  M.launch({ root = clone.root, binding = clone.binding, branch = r.branch })
end

--- Starts a review on the merge request on the dashboard's cursor line: the
--- same environment as work_row(), with the editor window opening the review.
---@param buf integer
function M.review_row(buf)
  local r = row_under_cursor(buf)
  if not r then
    return
  end
  if r.source == "jira" then
    return notify(("%s is a ticket; R starts a review on a merge request"):format(r.id), vim.log.levels.ERROR)
  end
  if not r.branch then
    return notify(("%s carries no branch, so no worktree is made for it"):format(r.id), vim.log.levels.ERROR)
  end
  if r.fork then
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
--- `review <id>`, or one identifier.
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
    return notify(M.NOT_BUILT.review, vim.log.levels.WARN)
  end
  if #args > 1 then
    return notify(("Docket takes one identifier; got %s"):format(table.concat(args, " ")), vim.log.levels.ERROR)
  end
  M.item(args[1])
end

--- Command-line completion for `:Docket`: the subcommands, then the backend
--- names after `login`.
---@param lead string what has been typed of the current word
---@param line string the whole command line
---@return string[]
function M.complete(lead, line)
  local candidates
  if line:match("^%s*Docket!?%s+login%s") then
    candidates = row.SOURCES
  else
    candidates = { "login", "review" }
  end
  return vim.tbl_filter(function(word)
    return word:sub(1, #lead) == lead
  end, candidates)
end

return M
