-- `:checkhealth docket`: each backend's state, with `:Docket login` named as
-- the fix, which is what `:checkhealth octo` does for its own client; then
-- the help tags and the configuration. Imports auth, config, row, the adapter
-- registry, and docket, which is init.lua, for the help file's lookup.
--
-- The checks are written against vim.health's own functions, so the suite
-- replaces those to read the report without running :checkhealth.

local adapters = require("docket.adapters")
local auth = require("docket.auth")
local config = require("docket.config")
local docket = require("docket")
local row = require("docket.row")

local M = {}

local function backend(name)
  local adapter, err = adapters.get(name)
  if not adapter then
    -- The registry names a backend with no module in this build; anything
    -- else it reports is a defect.
    if err:find("no adapter in this build", 1, true) then
      vim.health.info(err)
    else
      vim.health.error(err)
    end
    return
  end
  local status = adapter.auth_status()
  if status.missing then
    vim.health.error(("%s: the client is not installed"):format(name), { status.detail })
  elseif not status.authenticated then
    vim.health.error(("%s: not signed in"):format(name), { ("run %s %s"):format(auth.LOGIN_COMMAND, name), status.detail })
  else
    vim.health.ok(("%s: signed in\n%s"):format(name, status.detail))
  end
end

local function helptags()
  local files = docket.help_files()
  if not files.help then
    vim.health.error(("%s is not on the runtime path, so :help docket does not resolve"):format(docket.HELP))
    return
  end
  if files.tags then
    vim.health.ok(("help tags beside %s"):format(files.help))
  else
    vim.health.warn(("no tags beside %s, so :help docket does not resolve"):format(files.help), {
      "run :lua print(require('docket').helptags()) to write them; it prints false and the reason when they cannot be written",
    })
  end
end

local function configuration()
  local titles = {}
  for _, section in ipairs(config.options.sections) do
    titles[#titles + 1] = ("%s (%s)"):format(section.title, section.adapter)
  end
  vim.health.info("sections: " .. table.concat(titles, ", "))
  vim.health.info("cache directory: " .. config.options.cache_dir)
end

--- The report.
function M.check()
  vim.health.start("docket: backends")
  for _, name in ipairs(row.SOURCES) do
    backend(name)
  end
  vim.health.start("docket: help")
  helptags()
  vim.health.start("docket: configuration")
  configuration()
end

return M
