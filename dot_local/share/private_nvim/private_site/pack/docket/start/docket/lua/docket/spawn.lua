-- The only process spawn in docket. Every client call, every git command and
-- every tmux command goes through run() or wait(), so the argument list, the
-- timeout, the closed standard input, the added environment and the exit-code
-- check are written once. Imports config.
--
-- A callback given to run() arrives in a fast-event context, where a prompt or
-- a buffer change is an error: a caller that needs the editor wraps its work
-- in vim.schedule(). wait() is for the callers that cannot yield -- the
-- omnifunc, and the launcher's sequence of commands that each need the
-- previous one's output -- and it holds the editor until the process exits or
-- the timeout kills it.

local config = require("docket.config")

local M = {}

-- Added to the editor's own environment, never replacing it: the launcher's
-- tmux needs $TMUX to find the session, git needs SSH_AUTH_SOCK for the
-- remote, and glab's keyring on Linux needs DBUS_SESSION_BUS_ADDRESS. NO_COLOR
-- and CLICOLOR keep escape sequences out of parsed output; the two GH_
-- variables keep gh from stopping to ask a question or printing an update
-- notice into the output being parsed.
M.ENV = {
  NO_COLOR = "1",
  CLICOLOR = "0",
  GH_NO_UPDATE_NOTIFIER = "1",
  GH_PROMPT_DISABLED = "1",
}

-- The exit code a shell uses for a command it cannot find, and the one
-- timeout(1) uses for a command it killed. run() and wait() report the second
-- one themselves, with the signal they sent first.
M.MISSING = 127
M.TIMED_OUT = 124

-- The milliseconds between the SIGTERM a timeout sends a command's process
-- group and the SIGKILL that follows it; kill_group() says why there are two.
M.GRACE = 1000

-- The signals kill_group() sends, by number, which is how a result reports
-- one.
local SIGTERM = vim.uv.constants.SIGTERM
local SIGKILL = vim.uv.constants.SIGKILL

-- The result every caller reads:
--   ok        the exit code was zero and no signal ended the process
--   code      the exit code, which is 0 for a process a signal ended
--   signal    the signal that ended the process, or absent
--   stdout    what the process wrote, as text
--   stderr    what it wrote to stderr, verbatim
--   timed_out the timeout killed it
--   timeout   the milliseconds it was allowed, for the message
--   argv      the command, for messages
--   unstarted no process ran, because its working directory does not exist;
--             absent otherwise
--
-- vim.system reports a process a signal ended with code 0 and the signal's
-- number, so the code alone would read a `glab auth status` the OOM killer
-- or a `pkill` ended as signed in.
local function finish(argv, out, timeout)
  local code = out.code
  local signal = out.signal or 0
  return {
    argv = argv,
    ok = code == 0 and signal == 0,
    code = code,
    signal = signal ~= 0 and signal or nil,
    stdout = out.stdout or "",
    stderr = out.stderr or "",
    timed_out = code == M.TIMED_OUT and signal ~= 0,
    timeout = timeout,
  }
end

-- vim.system raises before any process exists when the executable is not on
-- PATH, and when the working directory does not exist -- a tab still in a
-- worktree that has been removed, whose vim.fn.getcwd() answers "". Either is
-- turned into a result rather than an error, so that it is reported like any
-- other failure, without the source location the raised message starts with.
-- Only the first is a missing client, with code MISSING. The raised text names
-- which, as `(cmd)` or `(cwd)`, and the second is given code 1, `unstarted`,
-- and a message naming the directory.
local function unstarted(argv, err, cwd)
  local text = tostring(err):gsub("^.-:%d+: ", "")
  if text:find("(cwd)", 1, true) then
    return {
      argv = argv,
      ok = false,
      code = 1,
      stdout = "",
      stderr = (cwd or "") == "" and "the editor's working directory has been removed; :cd to one that exists"
        or ("the working directory %s does not exist; :cd to one that does"):format(cwd),
      timed_out = false,
      unstarted = true,
    }
  end
  return {
    argv = argv,
    ok = false,
    code = M.MISSING,
    stdout = "",
    stderr = text,
    timed_out = false,
  }
end

-- vim.system's settings for a command, and the milliseconds it may run.
--
-- vim.system answers once the output pipes close, and its own timeout signals
-- only the process it started. A command that exits, or is killed, while a
-- process it forked holds the pipes open -- an update check, a telemetry
-- sender, the `git fetch` that `git wt-add` streams -- would hold the answer
-- for as long as that process lives. So the timeout is left out of the
-- settings and kept by run() and wait() instead, and `detach` starts the
-- command in a session of its own, which makes it the leader of a process
-- group that every process it forks joins unless it starts a session or
-- group of its own, as a daemon does; kill_group() ends every process still
-- in the group.
local function options(opts)
  opts = opts or {}
  local settings = {
    cwd = opts.cwd,
    env = M.ENV,
    -- A string is written to the child and then closed. false opens no pipe,
    -- so a child that reads its input gets end-of-file at once, and a client
    -- that stops to ask a question fails instead of hanging the editor.
    stdin = opts.stdin or false,
    text = true,
    detach = true,
  }
  return settings, opts.timeout or config.options.timeouts.client
end

-- Ends the process group a command leads. A negative pid names the group.
-- SIGTERM goes first, because a process that catches it cleans up on it and
-- SIGKILL gives it no chance to: git removes its `*.lock` files on SIGTERM,
-- and `git worktree add` removes the half-made worktree and its
-- `.bare/worktrees/<name>` entry, which a SIGKILL leaves locked
-- `initializing` for the next `w` or `git wt-rm` to trip over. SIGKILL
-- follows once GRACE has passed, for whatever ignored the first. `answered`
-- says whether vim.system has answered by then, which means every process
-- holding the output has gone; the group is then left alone, since its id
-- may belong to a new process by then. The leader may have exited already,
-- which is the case the group exists for; a group with no process left
-- answers ESRCH, which is no error here.
local function kill_group(handle, answered)
  pcall(vim.uv.kill, -handle.pid, SIGTERM)
  local timer = vim.uv.new_timer()
  timer:start(M.GRACE, 0, function()
    timer:close()
    if not answered() then
      pcall(vim.uv.kill, -handle.pid, SIGKILL)
    end
  end)
end

--- Runs a command and hands the result to on_done when it exits, or at the
--- timeout, whichever comes first.
---
--- At the timeout the command's whole process group is sent SIGTERM, and
--- SIGKILL once GRACE has passed, and on_done is answered with the timeout
--- result at once, so a client that exits while a process it forked holds
--- the output answers then rather than when that process ends. The answer
--- vim.system gives after that is dropped.
---
--- on_done runs once, in a fast-event context. A caller that touches a
--- buffer or prompts from it schedules that work with vim.schedule(). When the
--- executable or the working directory is absent, on_done runs before run
--- returns, on the caller's own context.
---@param argv string[] the command and its arguments; no shell is involved
---@param opts { cwd: string|nil, stdin: string|nil, timeout: integer|nil }|nil
---@param on_done fun(result: table)
---@return vim.SystemObj|nil handle nil when the executable was not found
function M.run(argv, opts, on_done)
  local settings, timeout = options(opts)
  local answered, exited, timer = false, false, nil
  local function answer(result)
    if answered then
      return
    end
    answered = true
    if timer and not timer:is_closing() then
      timer:close()
    end
    on_done(result)
  end
  local ok, handle = pcall(vim.system, argv, settings, function(out)
    exited = true
    answer(finish(argv, out, timeout))
  end)
  if not ok then
    on_done(unstarted(argv, handle, settings.cwd))
    return nil
  end
  timer = vim.uv.new_timer()
  timer:start(timeout, 0, function()
    if answered then
      return
    end
    kill_group(handle, function()
      return exited
    end)
    answer(finish(argv, { code = M.TIMED_OUT, signal = SIGTERM }, timeout))
  end)
  return handle
end

--- Runs a command and waits for it, holding the editor until it exits or the
--- timeout, whichever comes first.
---
--- The command runs as run() runs it, as the leader of a process group of
--- its own, and at the timeout the whole group is sent SIGTERM, and SIGKILL
--- once GRACE has passed, and the timeout result is returned at once, so the
--- editor is held for the timeout and no longer. What the command wrote
--- before the kill is lost with it.
---
--- Every git and tmux command runs here, in a session of its own, which has
--- no controlling terminal: ssh asking for a passphrase, or about a host key
--- it has not seen, cannot open /dev/tty to ask. UNVERIFIED: no command has
--- run this way against a live tmux or over ssh, and no run here had a
--- terminal to compare with. `w` on a dashboard row inside tmux, for a branch
--- not fetched yet, exercises both.
---
--- vim.wait here processes fast events only, as vim.system's own wait does
--- and as every caller was written against: a spawn.run callback can land
--- during it, and a scheduled callback, which may change a buffer, runs once
--- the caller has finished.
---@param argv string[] the command and its arguments; no shell is involved
---@param opts { cwd: string|nil, stdin: string|nil, timeout: integer|nil }|nil
---@return table result
function M.wait(argv, opts)
  local settings, timeout = options(opts)
  local out = nil
  local ok, handle = pcall(vim.system, argv, settings, function(result)
    out = result
  end)
  if not ok then
    return unstarted(argv, handle, settings.cwd)
  end
  if
    vim.wait(timeout, function()
      return out ~= nil
    end, nil, true)
  then
    return finish(argv, out, timeout)
  end
  kill_group(handle, function()
    return out ~= nil
  end)
  return finish(argv, { code = M.TIMED_OUT, signal = SIGTERM }, timeout)
end

--- An argument list as a line to paste at a prompt, for a message that names
--- a command to run by hand.
---
--- A word outside the characters every shell passes through unchanged is
--- single-quoted. Inside single quotes fish reads `\\` and `\'` as escapes
--- where POSIX shells read both literally, so neither character is left
--- there. An apostrophe is written `'\''`, closing the quote, escaping it and
--- reopening; a backslash is written `'"\\"'`, the same with the backslash in
--- double quotes, where both read `\\` as one backslash.
---@param argv string[]
---@return string
function M.shell_line(argv)
  local words = {}
  for index, word in ipairs(argv) do
    if word:match("^[%w_@%%+=:,./-]+$") then
      words[index] = word
    else
      words[index] = "'" .. word:gsub("[\\']", { ["\\"] = [['"\\"']], ["'"] = [['\'']] }) .. "'"
    end
  end
  return table.concat(words, " ")
end

--- The message a failed result is reported with: the command, how it ended,
--- and its stderr verbatim, because the client's own words are what name the
--- fix.
---@param result table
---@return string
function M.message(result)
  local name = result.argv[1]
  local head
  if result.code == M.MISSING then
    head = ("%s: not found"):format(name)
  elseif result.unstarted then
    head = ("%s: not started"):format(name)
  elseif result.timed_out then
    head = ("%s: killed after %d ms without exiting"):format(name, result.timeout)
  elseif result.signal then
    head = ("%s: killed by signal %d"):format(name, result.signal)
  else
    head = ("%s exited %d"):format(name, result.code)
  end
  if result.stderr == "" then
    return head
  end
  return head .. "\n" .. result.stderr
end

--- Parses the JSON a client wrote to stdout.
---
--- Only for a result whose exit code was checked first: a client that failed
--- writes its complaint to stderr and nothing parseable to stdout, and the
--- complaint is the message to show.
---@param result table
---@return any|nil value
---@return string|nil err
function M.decode(result)
  local ok, value = pcall(vim.json.decode, result.stdout, {
    -- JSON null becomes nil rather than vim.NIL, so a missing field reads as
    -- absent everywhere an adapter looks at it.
    luanil = { object = true, array = true },
  })
  if not ok then
    return nil, ("%s: output is not JSON: %s"):format(result.argv[1], value)
  end
  return value
end

return M
