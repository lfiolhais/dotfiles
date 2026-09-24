-- The development environment: the branch a ticket produces, the window name
-- a branch produces, the worktree through `git wt-add`, and the two tmux
-- windows -- or, away from tmux, a tab of the running editor at the worktree.
-- Imports config, spawn and repo. Working on a ticket and reviewing a merge
-- request share launch() and differ in two things: where the branch comes
-- from, and what the editor window opens on. teardown() is the counterpart:
-- both windows closed, then the worktree removed through `git wt-rm`.
--
-- Every step needs the previous one's output, so the process calls use
-- spawn's blocking form. `git wt-add` fetches when a ref is unknown and
-- `ls-remote` always asks the remote, so those two hold the editor for as
-- long as the network takes, bounded by the git timeout.

local config = require("docket.config")
local repo = require("docket.repo")
local spawn = require("docket.spawn")

local M = {}

-- The longest branch branch_for() generates.
M.BRANCH_MAX = 60
-- A branch that starts with a Jira key: an uppercase letter, then uppercase
-- letters or digits, a hyphen, digits. The frontier after the digits is what
-- stops `PROJ-142abc` from yielding `PROJ-142`.
M.KEY_PATTERN = "^(%u[%u%d]+%-%d+)%f[^%w]"

--- The ticket key a branch starts with, so that inside a worktree the
--- comment and transition commands need no selection step.
---@param branch string
---@return string|nil key
function M.key_of(branch)
  return branch:match(M.KEY_PATTERN)
end

--- The branch a ticket produces: the key, a hyphen, then the summary
--- lowercased with every run of characters outside `[a-z0-9]` collapsed to
--- one hyphen and the ends trimmed, the whole capped at BRANCH_MAX. The cap
--- shortens the slug and never the key, so key_of() reads the key back off
--- every generated branch.
---
--- The key comes first so the folder sorts and completes by key. No slash
--- appears, because gitwt flattens a slash into the folder name and
--- `feature/X` and `feature-X` would then contend for one folder. `%w` is
--- ASCII here, so a letter outside ASCII collapses like punctuation.
---@param key string
---@param summary string
---@return string branch
function M.branch_for(key, summary)
  local slug = summary:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if #key + 1 + #slug > M.BRANCH_MAX then
    slug = slug:sub(1, M.BRANCH_MAX - #key - 1):gsub("%-+$", "")
  end
  if slug == "" then
    return key
  end
  return key .. "-" .. slug
end

--- The tmux window name for a branch: everything outside `[A-Za-z0-9_-]`
--- collapses to one hyphen.
---
--- Applied to every branch, not only generated ones, because a review's
--- source branch is whatever its author typed and tmux reads `:` and `.` in
--- a target as separators. Nothing is truncated: a generated branch is
--- already capped, and truncating would let two long branches sharing a
--- prefix collide under `new-window -S`.
---@param branch string
---@return string window
function M.window_name(branch)
  return (branch:gsub("[^%w_%-]+", "-"))
end

--- Creates the worktree, or reuses the one already on that branch.
---
--- On failure the message is `git-wt-add`'s stderr verbatim. In a plain clone
--- that is its own refusal, naming `git-wt-clone` as the way to a layout with
--- worktrees; everything else in the dashboard works in a plain clone. A
--- process the git timeout killed is reported by spawn.message() instead,
--- which says so ahead of the stderr: what it had printed by then is progress,
--- `Preparing worktree ...`, and reads as the error on its own.
---@param root string
---@param branch string
---@return string|nil path
---@return string|nil err
function M.add_worktree(root, branch)
  local result = spawn.wait({ "git", "wt-add", branch }, {
    cwd = root,
    timeout = config.options.timeouts.git,
  })
  if not result.ok then
    if result.stderr ~= "" and not result.timed_out then
      return nil, vim.trim(result.stderr)
    end
    return nil, spawn.message(result)
  end
  return vim.trim(result.stdout)
end

--- Asks origin whether it has the branch.
---
--- A local ref lookup is the wrong test: a merge request whose branch has
--- never been fetched, which is every new one, has no local ref, and
--- `git-wt-add` would then create a branch of that name off the default --
--- silently, since its standard input is never a terminal from the editor.
---@param root string
---@param branch string
---@return boolean|nil present nil when the remote could not be asked
---@return string|nil err
function M.remote_has_branch(root, branch)
  local result = spawn.wait({ "git", "ls-remote", "--heads", "origin", branch }, {
    cwd = root,
    timeout = config.options.timeouts.git,
  })
  if not result.ok then
    return nil, spawn.message(result)
  end
  return vim.trim(result.stdout) ~= ""
end

--- Whether the editor runs inside tmux.
---
--- `$TMUX` is the test, not whether a server is running: with a server up
--- and `$TMUX` unset, `new-window` would land in the most recently used
--- session, which is some other repository's.
---@return boolean
function M.in_tmux()
  local tmux = vim.env.TMUX
  return tmux ~= nil and tmux ~= ""
end

--- The command the editor window runs: nvim on the worktree's files, or
--- nvim opening a review's diff.
---@param review string|nil the merge request's identifier, `!482`
---@return string[] argv
function M.editor_command(review)
  if review then
    return { "nvim", "-c", "Docket review " .. review }
  end
  return { "nvim" }
end

local function tmux(argv)
  return spawn.wait(vim.list_extend({ "tmux" }, argv), { timeout = config.options.timeouts.tmux })
end

--- Opens the two named windows in the current tmux session and selects the
--- editor's.
---
--- `-n` names the window, and a name given at creation is what holds against
--- tmux's own renaming. `-S` finds or creates, which is the whole of choosing
--- the same item twice. `-d` on the companion keeps focus from moving to it.
--- `allow-rename off` is a guard against a future tmux configuration letting a
--- program in the pane rename the window; its default is off.
---
--- Every target is written `=<name>`, which is an exact name match. A bare
--- `-t <name>` matches a prefix and then a glob pattern, so a target
--- naming a window that does not exist can land on a shorter-named one. The
--- `=` form also removes any need for a window identifier: `new-window -S -d`
--- prints nothing when the window is already there, so `-P` cannot supply one,
--- and the name is already what a listing would resolve from.
---
--- tmux runs a shell-command given as several arguments directly, without
--- `sh -c`, so the editor command is appended as arguments and nothing here
--- is quoted.
---
--- Creating the windows is what fails the call, and so is the focus move at the
--- end. Between them, both `allow-rename` steps are attempted rather than
--- stopping at the first failure: the option guards against a tmux
--- configuration this repository does not ship, while `select-window` is the
--- focus move the caller asked for, so a tmux that refuses the option must not
--- cost it.
---
--- `select-window` is also what separates a survivable failure from an
--- unsurvivable one, which is why its result decides the return rather than
--- being folded in with the others. It addresses `=<window>`, so succeeding
--- proves the editor's window is there -- the window the caller is sent to --
--- and leaves an earlier failure as a warning beside it. It proves nothing about
--- the companion: tmux closes a window when its command completes, so a
--- companion whose shell exits at once is gone before `allow-rename` reaches it,
--- and a warning naming `=<name>-sh` is the report on that window. Failing
--- leaves nothing established about the window, the session or the server, so it
--- is a failed launch -- and the cause to check first is the editor's own window
--- having closed the same way, which is what an `nvim` missing from tmux's PATH
--- looks like from here.
---@param path string
---@param window string
---@param command string[] the editor command
---@return { editor: string, shell: string|nil, warning: string|nil }|nil names
---        the editor's window, the companion while it is still there, and what
---        failed after both were made
---@return string|nil err
function M.tmux_windows(path, window, command)
  local shell = window .. "-sh"
  local created = {
    vim.list_extend({ "new-window", "-S", "-n", window, "-c", path }, command),
    { "new-window", "-S", "-d", "-n", shell, "-c", path },
  }
  for _, step in ipairs(created) do
    local result = tmux(step)
    if not result.ok then
      return nil, spawn.message(result)
    end
  end

  local names = { editor = window, shell = shell }
  for _, settled in ipairs({
    { window, { "set-option", "-w", "-t", "=" .. window, "allow-rename", "off" } },
    { shell, { "set-option", "-w", "-t", "=" .. shell, "allow-rename", "off" } },
  }) do
    local result = tmux(settled[2])
    if not result.ok then
      if settled[1] == shell then
        -- Each step names one window, so its failure is the report on that one:
        -- a companion that is gone must not come back as a name to switch to.
        names.shell = nil
      end
      names.warning = names.warning or spawn.message(result)
    end
  end

  local selected = tmux({ "select-window", "-t", "=" .. window })
  if not selected.ok then
    -- An earlier failure is the first symptom of whatever also stopped the focus
    -- move, and it names the step that met it first, so it goes out in front.
    if names.warning ~= nil then
      return nil, names.warning .. "\n" .. spawn.message(selected)
    end
    return nil, spawn.message(selected)
  end
  return names
end

-- Single quotes, because they read the same in every shell this is pasted into.
-- The close-escape-reopen form this produces for an apostrophe is read alike by
-- fish and by POSIX shells, and it is unreachable from the launcher in any
-- case: window_name() admits no apostrophe, and a worktree path under
-- `git wt-add` carries none.
local function quoted(text)
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

--- The shell lines that do what tmux_windows() does, for a machine where the
--- launcher cannot: away from tmux.
---
--- What this returns is printed for somebody to paste at a prompt, where the
--- shell is fish, which has neither `var=value` assignment nor `$(...)`
--- substitution. So no line holds either: the `=`-prefixed exact-match targets
--- are what remove the need for a window identifier and therefore for any
--- intermediate variable.
---@param path string
---@param window string
---@param command string[] the editor command
---@return string script
function M.tmux_script(path, window, command)
  local words = {}
  for _, word in ipairs(command) do
    words[#words + 1] = quoted(word)
  end
  local shell = window .. "-sh"
  return table.concat({
    ("tmux new-window -S -n %s -c %s %s"):format(quoted(window), quoted(path), table.concat(words, " ")),
    ("tmux new-window -S -d -n %s -c %s"):format(quoted(shell), quoted(path)),
    ("tmux set-option -w -t %s allow-rename off"):format(quoted("=" .. window)),
    ("tmux set-option -w -t %s allow-rename off"):format(quoted("=" .. shell)),
    ("tmux select-window -t %s"):format(quoted("=" .. window)),
  }, "\n")
end

--- The message an editor command failed with, without the neovim internals in
--- front of it and without a traceback behind it.
---
--- A raised `E492` arrives as `[string "vim/_core/editor"]:353: nvim_exec2(),
--- line 1: Vim:E492: ...`, and a command whose own body raises adds a
--- `stack traceback:` block after it. A launcher message carrying either reads
--- as a defect in the plugin. spawn.lua strips a source location off a raised
--- `vim.system` error for the same reason.
---@param err any what pcall returned
---@return string message
function M.editor_error(err)
  local text = tostring(err):gsub("\nstack traceback:.*$", "")
  text = text:gsub("^.-:%d+: ", "")
  text = text:gsub("^nvim_exec2%(%), line %d+: ", "")
  text = text:gsub("^Vim%b():", "")
  return (text:gsub("^Vim:", ""))
end

--- Opens the environment where the launcher can, and says what it did.
---
--- Inside tmux, both windows, and `how` is "tmux". Away from tmux there is no
--- terminal to open: macOS has no supported command-line route to a terminal
--- window at a directory, and Ghostty's own `+new-window --working-directory`
--- is supported on GTK alone. So the launcher opens a tab of the running editor
--- instead, `:tcd`s it into the worktree and returns `how = "tab"` with the
--- script for the two windows, which the caller prints beside the path so a
--- shell already open can reach the same place. There is no companion shell in
--- that state and no platform branch.
---
--- `:tcd` is tab-local, so the editor showing the dashboard keeps its global
--- working directory at the clone's root and auto-session goes on saving that
--- rather than a worktree's. A tab already at the worktree is switched to
--- rather than a second one opened, which is what `new-window -S` does for a
--- window inside tmux; the review command does not run again there, as it
--- does not in a window `-S` finds.
---
--- A review's editor command carries `-c <cmd>`; in a tab the command is run
--- directly, since the editor is already the thing being addressed. A command
--- that fails does not fail the launch: the tab is already open at the worktree,
--- which is most of what was asked for, so the failure comes back as `warning`
--- for the caller to print beside the path rather than as an error that hides
--- the worktree it already made.
---
--- `warning` comes from the `allow-rename` steps inside tmux, or from a review
--- command that failed in the tab -- never both, since only one arm runs. A
--- failed focus move is an error rather than a warning, so it never arrives
--- here.
---@param path string
---@param window string
---@param command string[] the editor command
---@return { how: string, editor: string|nil, shell: string|nil, script: string|nil, warning: string|nil }|nil opened
---@return string|nil err
function M.open_windows(path, window, command)
  if M.in_tmux() then
    local names, err = M.tmux_windows(path, window, command)
    if not names then
      return nil, err
    end
    return { how = "tmux", editor = names.editor, shell = names.shell, warning = names.warning }
  end

  local wanted = vim.uv.fs_realpath(path) or path
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local cwd = vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tab))
    if (vim.uv.fs_realpath(cwd) or cwd) == wanted then
      vim.api.nvim_set_current_tabpage(tab)
      return { how = "tab", script = M.tmux_script(path, window, command) }
    end
  end

  local ok, err = pcall(function()
    vim.cmd.tabnew()
    vim.cmd.tcd(vim.fn.fnameescape(path))
  end)
  if not ok then
    return nil, M.editor_error(err)
  end

  local opened = { how = "tab", script = M.tmux_script(path, window, command) }
  -- The editor command is { "nvim" } or { "nvim", "-c", <command> }; in a tab
  -- only the command matters, and a bare nvim leaves the tab on the worktree.
  for index, word in ipairs(command) do
    if word == "-c" and command[index + 1] then
      local ran, failed = pcall(vim.cmd, command[index + 1])
      if not ran then
        opened.warning = M.editor_error(failed)
      end
    end
  end
  return opened
end

--- Builds the development environment for a ticket or a review.
---
--- A ticket gives `key` and `summary`; a registered worktree whose branch
--- begins `<KEY>-` is reused, and otherwise the branch is generated. A review
--- gives `branch`, the merge request's own source branch, and `review`, its
--- identifier for the editor command; the branch has to exist on origin,
--- because one that does not -- a merge request from a fork, typically --
--- would otherwise become a new branch off the default.
---
--- An unbound repository refuses a ticket: its rows come from every project
--- the account works on, so a worktree here could be for another
--- repository's ticket, which is the one destructive mistake this can make.
--- A repository bound to its projects refuses a key from any other project
--- for the same reason, since an item buffer opened with `:Docket <KEY>` or
--- from another clone's dashboard reaches the launcher here. A binding by a
--- complete query names no project list, so its keys are not checked.
---@param opts { root: string, binding: table, key: string|nil, summary: string|nil, branch: string|nil, review: string|nil }
---@return { path: string, branch: string, window: string, how: string, editor: string|nil, shell: string|nil, script: string|nil, warning: string|nil }|nil opened
---@return string|nil err
function M.launch(opts)
  local worktrees, err = repo.worktrees(opts.root)
  if not worktrees then
    return nil, err
  end

  local branch, path
  if opts.key then
    if opts.binding.kind == "unbound" then
      return nil, ("%s is bound to no Jira project, so its rows come from every project and a worktree here could be for another repository's ticket. Bind it first:\n  %s\n%s lists the keys."):format(
        opts.root,
        repo.BIND_COMMAND,
        repo.LIST_COMMAND
      )
    end
    local project = opts.key:match("^(.-)%-%d+$")
    if opts.binding.kind == "projects" and not vim.tbl_contains(opts.binding.projects, project) then
      return nil, ("%s is bound to %s, not %s, so no worktree is made for %s here. If %s's tickets belong in this repository:\n  %s"):format(
        opts.root,
        table.concat(opts.binding.projects, ", "),
        project,
        opts.key,
        project,
        (repo.BIND_COMMAND:gsub("<KEY>", function()
          return project
        end))
      )
    end
    local existing = repo.worktree_for_key(worktrees, opts.key)
    if existing then
      branch, path = existing.branch, existing.path
    else
      branch = M.branch_for(opts.key, opts.summary or "")
    end
  elseif opts.branch then
    branch = opts.branch
    local existing = repo.worktree_for_branch(worktrees, branch)
    if existing then
      path = existing.path
    else
      local present
      present, err = M.remote_has_branch(opts.root, branch)
      if present == nil then
        return nil, err
      end
      if not present then
        return nil, ("%s is not a branch on origin -- a merge request from a fork, typically -- so no worktree is made for it"):format(branch)
      end
    end
  else
    error("env.launch: needs a ticket key or a review branch")
  end

  if not path then
    path, err = M.add_worktree(opts.root, branch)
    if not path then
      return nil, err
    end
  end

  local window = M.window_name(branch)
  local opened
  opened, err = M.open_windows(path, window, M.editor_command(opts.review))
  if not opened then
    return nil, err
  end
  opened.path, opened.branch, opened.window = path, branch, window
  return opened
end

--- Closes the two windows a branch's environment holds, where they are still
--- open, and names the ones it closed.
---
--- The session's windows are listed first and only a name on the list is
--- killed, so a window already gone is not a failure: the point of closing is
--- that no window sits in the worktree when it is removed, and an absent one
--- sits nowhere. A `kill-window` that fails is an error rather than a warning,
--- because that window may still sit in the directory, which is what the
--- order exists to prevent. The listing is what settles presence rather than
--- the text of tmux's refusal, so nothing here depends on the wording of
--- `can't find window`.
---
--- The window the editor itself runs in is refused: killing it kills the
--- editor running this, and the worktree would then never be removed. The name
--- compared is what `display-message -p` answers with no target, which is the
--- window of the pane this editor was started in, since tmux resolves an
--- unqualified target from the `TMUX_PANE` that pane passed to its child.
--- UNVERIFIED: tmux(1) documents `TMUX_PANE` being passed to the child and not
--- that resolution rule, so a client looking at another window when the teardown
--- runs is untried; from a second window, `tmux display-message -p
--- '#{window_name}'` prints which window it means.
---
--- This blocks on each tmux command, so it runs on the main loop; from a spawn
--- callback spawn.wait raises `E5560: vim.wait must not be called in a fast
--- event context`.
---@param window string the editor window's name; the companion is `<window>-sh`
---@return string[]|nil closed the names closed, in order
---@return string|nil err
function M.close_windows(window)
  local shell = window .. "-sh"
  local current = tmux({ "display-message", "-p", "#{window_name}" })
  if not current.ok then
    return nil, spawn.message(current)
  end
  local here = vim.trim(current.stdout)
  if here == window or here == shell then
    return nil, ("this editor runs in tmux window %s, which the teardown closes; run it from another window"):format(here)
  end
  local listed = tmux({ "list-windows", "-F", "#{window_name}" })
  if not listed.ok then
    return nil, spawn.message(listed)
  end
  local present = {}
  for _, name in ipairs(vim.split(listed.stdout, "\n", { trimempty = true })) do
    present[name] = true
  end
  local closed = {}
  for _, name in ipairs({ window, shell }) do
    if present[name] then
      local result = tmux({ "kill-window", "-t", "=" .. name })
      if not result.ok then
        return nil, spawn.message(result)
      end
      closed[#closed + 1] = name
    end
  end
  return closed
end

-- What a failed `git wt-rm` is reported with: its stderr verbatim, which names
-- the refusal and its override, or spawn.message() for a process that printed
-- nothing or that the git timeout killed, since only that says it was killed.
local function failure(result)
  local stderr = vim.trim(result.stderr)
  if stderr ~= "" and not result.timed_out then
    return stderr
  end
  return spawn.message(result)
end

--- Removes a branch's development environment: both tmux windows, then the
--- worktree, in that order, because `git wt-rm` on a worktree a window sits
--- in leaves that window in a directory that no longer exists. Away from
--- tmux there are no windows to close, so the teardown is the worktree alone.
---
--- That order makes every refusal cost both windows, so what `git wt-rm` needs
--- is established before either is killed: the branch has a worktree here, and
--- without `force` that worktree is clean. `kill-window` sends SIGHUP to the
--- program in the pane, and an unsaved buffer in the editor it kills survives
--- only as a swap file, in a folder that is about to go. What cannot be
--- established first is that `git-wt-rm` is on the editor's PATH, so a refusal
--- after the windows are closed names them and says the worktree is still there.
---
--- `git wt-rm` takes the ref and finds the folder by the same flattening that
--- named it. Without `force` it refuses a folder holding uncommitted work,
--- and the refusal is its stderr verbatim; `force` discards that work along
--- with the folder. After removing the folder it deletes the branch with
--- `git branch -d`, and an unmerged branch is refused and left in place with
--- exit code 1 -- that is the late failure: the worktree is gone, which is
--- what was asked for, so the refusal comes back as `warning` beside the
--- result rather than hiding it. The two outcomes are told apart by the
--- script's own `removed <folder>/` line on stdout, which it prints whenever
--- the folder is gone, whatever became of the branch.
---
--- This blocks -- git first, then tmux -- so it runs on the main loop, from a
--- user command or a keymap, never from a spawn callback, where the first git
--- call raises `E5560: vim.wait must not be called in a fast event context` and
--- nothing is closed or removed.
---@param opts { root: string, branch: string, force: boolean|nil }
---@return { branch: string, window: string, closed: string[], warning: string|nil }|nil removed
---@return string|nil err
function M.teardown(opts)
  local window = M.window_name(opts.branch)
  local worktrees, err = repo.worktrees(opts.root)
  if not worktrees then
    return nil, err
  end
  local existing = repo.worktree_for_branch(worktrees, opts.branch)
  if not existing then
    return nil, ("%s has no worktree in %s, so there is nothing to remove"):format(opts.branch, opts.root)
  end
  if not opts.force then
    local dirty =
      spawn.wait({ "git", "status", "--porcelain" }, { cwd = existing.path, timeout = config.options.timeouts.git })
    if not dirty.ok then
      return nil, spawn.message(dirty)
    end
    if vim.trim(dirty.stdout) ~= "" then
      return nil,
        ("%s holds modified or untracked files, which `git wt-rm` refuses; commit them, or pass force = true to discard them along with the folder"):format(
          existing.path
        )
    end
  end
  local closed = {}
  if M.in_tmux() then
    closed, err = M.close_windows(window)
    if not closed then
      return nil, err
    end
  end
  local args = { "git", "wt-rm", opts.branch }
  if opts.force then
    args[#args + 1] = "--force"
  end
  local result = spawn.wait(args, { cwd = opts.root, timeout = config.options.timeouts.git })
  local removed = result.stdout:match("^removed .+/") ~= nil or result.stdout:match("\nremoved .+/") ~= nil
  if not result.ok and not removed then
    local reason = failure(result)
    if #closed > 0 then
      local windows = #closed == 1 and ("tmux window %s is"):format(closed[1])
        or ("tmux windows %s are"):format(table.concat(closed, " and "))
      return nil, ("%s\nthe %s closed; the worktree is still there"):format(reason, windows)
    end
    return nil, reason
  end
  local done = { branch = opts.branch, window = window, closed = closed }
  if not result.ok then
    done.warning = failure(result)
  end
  return done
end

return M
