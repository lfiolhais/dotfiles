-- setup(), and the help tags. Imports config and highlight alone, so setup(),
-- which runs at every start, loads no part of the read path. The command and
-- the maps are declared by plugin/docket.lua, so setup() takes the options,
-- defines the highlight groups and keeps them defined across a colour scheme
-- change, and writes the help tags.
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

--- Configures docket.
---
--- The options are config.defaults with `opts` merged over them, every one
--- described under `docket-setup` in `:help docket`. The Docket* highlight
--- groups are defined here and again from a ColorScheme autocommand, since
--- a colour scheme change clears them; a call after octo.nvim's own setup
--- is what lets them follow the Octo* groups.
---@param opts table|nil
---@return table options
function M.setup(opts)
  local options = config.configure(opts)
  highlight.define()
  local group = vim.api.nvim_create_augroup("docket/highlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = highlight.define,
  })
  M.helptags()
  return options
end

return M
