-- setup(), the help tags, and before_session_save(), which the configuration
-- runs from auto-session's `pre_save_cmds` hook. Imports config and highlight
-- alone, so setup(), which runs at every start, and the hook, which runs at
-- every session save, load no part of the read path. The command and the
-- maps are declared by plugin/docket.lua, so setup() takes the options,
-- defines the highlight groups and keeps them defined as the colours change,
-- and writes the help tags.
--
-- The tags are written here rather than by a bootstrap script because a
-- script would have to run nvim on a fresh machine -- on the rootless profile
-- a mise tool a bash `run_` script has no shims for, and with the real
-- configuration one that clones every plugin inside the bootstrap. Doing it
-- in setup() works on every profile.

local config = require("docket.config")
local highlight = require("docket.highlight")

local M = {}

-- The help file, relative to a runtime path entry.
M.HELP = "doc/docket.txt"

-- Whether a failure to write the tags has been reported, so that a repeated
-- setup() reports it once rather than at every call.
local reported = false

-- The names of every docket buffer that is ever listed start with one of
-- these: an item buffer's, buffer.SCHEME; a new ticket's draft,
-- commands.DRAFT; and the dashboard, list.NAME, which is the whole name. A
-- review's compose buffers, review.SCHEME, are never listed, and so never
-- reach a session's buffer list. Spelled here rather than read from those
-- modules, because requiring them loads the read path.
M.NAMES = { "docket://", "docket-new://", "docket-dash://" }

--- The help file and the tags file beside it: the one lookup both
--- helptags() and `:checkhealth docket` read.
---
--- The help file is found on the runtime path, because a package's `doc/` is
--- not under the configuration directory and `stdpath('config')` does not
--- reach it.
---@param help string|nil the help file's path; the runtime lookup when nil
---@return { help: string|nil, tags: string|nil } files `help` nil when the file is not found, `tags` nil when no tags file is beside it
function M.help_files(help)
  help = help or vim.api.nvim_get_runtime_file(M.HELP, false)[1]
  if not help then
    return { help = nil, tags = nil }
  end
  local tags = vim.fs.dirname(help) .. "/tags"
  return { help = help, tags = vim.uv.fs_stat(tags) and tags or nil }
end

--- Writes the help tags beside the help file when they are older than it.
---
--- `helptags` raises rather than warns -- E150 for an absent directory, E151
--- for one with no help file, E152 for one that cannot be written -- and
--- setup() runs at every start, so the call is guarded: a failure is
--- reported once with vim.notify and never raised.
---@param help string|nil the help file's path; the runtime lookup when nil
---@return boolean ok false when the tags could not be written
---@return string outcome "written", "current", "missing", or the error
function M.helptags(help)
  local files = M.help_files(help)
  if not files.help then
    return false, "missing"
  end
  local doc = vim.uv.fs_stat(files.help)
  local tags = files.tags and vim.uv.fs_stat(files.tags)
  if doc and tags and tags.mtime.sec >= doc.mtime.sec then
    return true, "current"
  end
  local ok, err = pcall(vim.cmd.helptags, vim.fn.fnameescape(vim.fs.dirname(files.help)))
  if ok then
    return true, "written"
  end
  local message = ("docket: the help tags could not be written, so :help docket does not resolve: %s"):format(
    tostring(err):gsub("^.-:%d+: ", "")
  )
  if not reported then
    reported = true
    vim.notify(message, vim.log.levels.WARN)
  end
  return false, message
end

--- Keeps every docket buffer out of the session about to be saved: each
--- listed one is taken off the buffer list, which is what keeps it from the
--- `badd` lines `:mksession` writes, and listed again from a scheduled
--- callback.
---
--- The configuration calls this from auto-session's `pre_save_cmds`. On
--- auto-session's main branch those hooks and the `:mksession` that writes
--- the file run in one synchronous call, so the callback runs after the file
--- is written, and runs whether or not the save went through. The installed
--- release is not known to be that revision; `:help docket-setup-sessions`
--- gives the `grep` that shows it is.
---
--- A buffer that was not listed is left so: `:bdelete` or `BD` took it off
--- the list, or it is the buffer a GitHub handoff unlists, and listed again,
--- `:bnext` would reach it and read the item. A buffer wiped before the
--- callback runs is passed over.
---@return integer[] bufs the buffers taken off the list
function M.before_session_save()
  local unlisted = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted then
      local name = vim.api.nvim_buf_get_name(buf)
      for _, prefix in ipairs(M.NAMES) do
        if vim.startswith(name, prefix) then
          vim.bo[buf].buflisted = false
          unlisted[#unlisted + 1] = buf
          break
        end
      end
    end
  end
  vim.schedule(function()
    for _, buf in ipairs(unlisted) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].buflisted = true
      end
    end
  end)
  return unlisted
end

--- Configures docket.
---
--- The options are config.defaults with `opts` merged over them, every one
--- described under `docket-setup` in `:help docket`: `sections`, `timeouts`,
--- `jira`, `glab`, `gh`, `cache_dir` and `statuses`. The Docket* highlight
--- groups, and one per status in `statuses`, are defined here and again
--- whenever the colours change: from a ColorScheme autocommand, since a
--- colour scheme's `:hi clear` empties DocketEditable and the statuses'
--- groups; from an OptionSet autocommand for 'background', since neovim's
--- own colours change with it and fire no ColorScheme event when no colour
--- scheme is loaded; and from a VimEnter autocommand, since OptionSet does
--- not fire during startup. A status whose colour cannot be set is reported
--- with vim.notify, and renders in its category's colour.
---@param opts table|nil
---@return table options
function M.setup(opts)
  local options = config.configure(opts)
  local problems = highlight.define(options.statuses)
  if #problems > 0 then
    vim.notify("docket: " .. table.concat(problems, "\ndocket: "), vim.log.levels.WARN)
  end
  local group = vim.api.nvim_create_augroup("docket/highlights", { clear = true })
  -- A function of its own, because a callback named directly receives the
  -- event's table, which define() would take for the statuses. It returns
  -- nothing, because a callback that returns anything but nil or false
  -- deletes its autocommand, and define() returns a table.
  local function again()
    highlight.define()
  end
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = again })
  vim.api.nvim_create_autocmd("OptionSet", { group = group, pattern = "background", callback = again })
  -- OptionSet does not fire during startup, so a 'background' set after this
  -- by the rest of the configuration's init.lua, or by neovim once the
  -- terminal reports its colour, is caught when startup ends.
  vim.api.nvim_create_autocmd("VimEnter", { group = group, callback = again })
  M.helptags()
  return options
end

return M
