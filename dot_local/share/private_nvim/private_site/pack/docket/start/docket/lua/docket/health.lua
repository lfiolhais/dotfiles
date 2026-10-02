-- `:checkhealth docket`: the state of each backend a configured section needs
-- in the working directory, with `:Docket login` named as the fix, which is
-- what `:checkhealth octo` does for its own client; then the help tags and the
-- configuration. Imports auth, config, highlight, row, repo, the adapter
-- registry, and docket, which is init.lua, for the help file's lookup.
--
-- The checks are written against vim.health's own functions, so the suite
-- replaces those to read the report without running :checkhealth.

local adapters = require("docket.adapters")
local auth = require("docket.auth")
local config = require("docket.config")
local docket = require("docket")
local highlight = require("docket.highlight")
local repo = require("docket.repo")
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
  -- The statuses as highlight.define() set them, each with the group to
  -- inspect with :hi, and a warning for each it could not set and for each
  -- that links to a group with nothing set.
  local set, problems = highlight.configured()
  local named = {}
  for _, status in ipairs(set) do
    named[#named + 1] = ("%s (%s)"):format(status.name, status.group)
  end
  vim.health.info("statuses with a colour of their own: " .. (#named > 0 and table.concat(named, ", ") or "none"))
  for _, problem in ipairs(problems) do
    vim.health.warn(problem)
  end
  -- A link to a group nothing sets is accepted when setup{} runs, since a
  -- colour scheme loaded after it may set that group, so it is caught here,
  -- against the groups as they stand. hlexists() cannot tell, because the
  -- link itself creates the group it names; `link = false` follows the
  -- target's own links to the group that sets something.
  for _, status in ipairs(set) do
    if status.link and next(vim.api.nvim_get_hl(0, { name = status.link, link = false })) == nil then
      vim.health.warn(
        ("the status %s renders uncoloured: it links to %s, which sets nothing here"):format(status.name, status.link),
        { "correct the name in setup{}'s statuses; :highlight lists the groups there are" }
      )
    end
  end
end

--- The backends the configured sections need in the working directory: each
--- one a section names as its adapter, and for a `review` section the client
--- `origin` selects, found the way the dash finds it -- repo.root(), then
--- repo.remote_url(), then repo.adapter_for(). The working directory is that
--- of the window `:checkhealth` ran from, which the window it opens for the
--- report keeps.
---@return table<string, boolean> needed keyed by backend name
---@return string|nil reason why the review sections select no client here, when they select none
local function needed()
  local names, review = {}, false
  for _, section in ipairs(config.options.sections) do
    if section.adapter == "review" then
      review = true
    elseif section.adapter ~= nil then
      names[section.adapter] = true
    end
  end
  if not review then
    return names, nil
  end
  local found, err = repo.root(vim.fn.getcwd())
  if not found then
    return names, err
  end
  local url
  url, err = repo.remote_url(found.root)
  if not url then
    return names, err
  end
  local client
  client, err = repo.adapter_for(url)
  if client then
    names[client] = true
  end
  return names, err
end

--- The report.
---
--- A backend no section needs here is named and not checked, so the report
--- does not wait on a host this directory does not use.
function M.check()
  vim.health.start("docket: backends")
  local names, reason = needed()
  if reason then
    vim.health.info("the review sections select no client here: " .. reason)
  end
  for _, name in ipairs(row.SOURCES) do
    if names[name] then
      backend(name)
      names[name] = nil
    else
      vim.health.info(("%s: no configured section needs it here; not checked"):format(name))
    end
  end
  -- What is left is an adapter name outside row.SOURCES, which the registry
  -- refuses with the list of names, the message the dash shows under that
  -- section.
  local rest = vim.tbl_keys(names)
  table.sort(rest)
  for _, name in ipairs(rest) do
    backend(name)
  end
  vim.health.start("docket: help")
  helptags()
  vim.health.start("docket: configuration")
  configuration()
end

return M
