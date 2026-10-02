-- The Docket* highlight groups: their names, what each links to, a group for
-- each Jira status setup{} gives a colour of its own, and the one a state
-- renders in. Imports nothing local, which is what lets setup() define the
-- groups without loading the read path; the configured statuses arrive as
-- define()'s argument. The item buffer and the dashboard read the names from
-- here.
--
-- define() runs at setup and again whenever the colours change, from the
-- autocommands setup() makes: ColorScheme; OptionSet for 'background', which
-- changes neovim's own colours and, only when a colour scheme is loaded,
-- fires ColorScheme; and VimEnter, because OptionSet does not fire during
-- startup. Each fixed group links to a
-- built-in group as a default, so a colour scheme or the configuration that
-- defines one keeps its own definition. DocketEditable takes a background
-- from the colour scheme, chosen again at every define() unless the group
-- holds something define() did not set. Each configured status is set after
-- them, as given. A colour scheme's `:hi clear` puts each default link back
-- by itself and empties DocketEditable and every configured status, which the
-- ColorScheme autocommand then sets again.

local M = {}

M.EDITABLE = "DocketEditable"
M.USER = "DocketUser"
M.LABEL = "DocketLabel"
M.OPEN = "DocketStateOpen"
M.CLOSED = "DocketStateClosed"
M.MERGED = "DocketStateMerged"
M.PENDING = "DocketStatePending"

-- Each Docket* group but DocketEditable, and the built-in group it links to.
-- Each built-in group has a colour of its own under neovim's default colour
-- scheme, except Label, which is Normal's foreground in bold.
M.GROUPS = {
  { M.USER, "Identifier" },
  { M.LABEL, "Label" },
  { M.OPEN, "DiagnosticOk" },
  { M.CLOSED, "DiagnosticError" },
  { M.MERGED, "Special" },
  { M.PENDING, "DiagnosticWarn" },
}

-- The groups whose background DocketEditable takes, the first that has one
-- other than Normal's, and the group it links to when none has. Which
-- built-in group has a background of its own depends on the colour scheme,
-- so DocketEditable is chosen again at each define() rather than linked once.
M.EDITABLE_FROM = { "NormalFloat", "CursorLine", "ColorColumn" }
M.EDITABLE_FALLBACK = "CursorLine"

-- A Jira status category, as `statusCategory.key` names it, and its group.
-- A status name is a workflow's own word, and matching words inside it
-- misreads names such as `Renewal`, so a Jira status is read by its category.
M.CATEGORIES = { new = M.OPEN, indeterminate = M.PENDING, done = M.CLOSED }

-- A merge request's or a pull request's state, as the adapters report it,
-- and its group. These are fixed words rather than a workflow's: GitLab's
-- `opened`, `closed`, `locked` and `merged`, GitHub's `open`, `closed` and
-- `merged` lower-cased, and the `draft` both adapters put in place of an open
-- draft. `draft` and `locked` are left to DocketLabel.
-- UNVERIFIED: the words are GitLab's REST reference and GitHub's
-- PullRequestState; no state was recorded from either instance, and
-- `glab mr list --all -F json | jq '[.[].state] | unique'` prints GitLab's.
M.STATES = { opened = M.OPEN, open = M.OPEN, closed = M.CLOSED, merged = M.MERGED }

-- What a configured status's group name starts with.
M.STATUS_PREFIX = "DocketStatus"

-- The configured statuses that define() last set, keyed by the name
-- lower-cased, each `{ name, group, value, link }` with the name as
-- configured and `link` the group it links to, if any. Kept here so that
-- define() with no argument, which is what setup()'s autocommands run, sets
-- them again.
local statuses = {}
-- What the last define() given a table could not set, one line per status.
local problems = {}
-- What define() last set DocketEditable to, as nvim_get_hl() reads it back;
-- nil until it has set it. A group holding this is replaced at the next
-- define(), and one holding anything else is left as a colour scheme or the
-- configuration set it. `default` cannot make that distinction: it refuses a
-- group that holds any value, and DocketEditable still holds the background
-- chosen before when the colours change without `:hi clear` emptying it --
-- a 'background' change under neovim's own colours, or a colour scheme that
-- loads without `:hi clear`.
local chosen = nil

--- The group a configured status renders in: STATUS_PREFIX, then the name
--- with each run of characters other than ASCII letters and digits made one
--- `_`, so `In Review` is `DocketStatusIn_Review`. neovim refuses a space,
--- and a letter outside ASCII, in a group name.
---@param name string the status as Jira prints it
---@return string group
function M.status_group(name)
  return M.STATUS_PREFIX .. name:gsub("[^A-Za-z0-9]+", "_")
end

-- The characters neovim accepts in a group's name.
local GROUP_NAME = "^[A-Za-z0-9_.@-]+$"

-- What nvim_set_hl() takes for a configured value: a string starting `#` as
-- the foreground colour, another string as a group to link to, a table as it
-- is. A `#` string is never passed as a link, because nvim_set_hl() given one
-- prints E5248 without raising and defines nothing; a group's name, as a
-- string or as a table's `link`, is held to GROUP_NAME for the same reason. A
-- `link` that is a number is refused too, because nvim_set_hl() takes it as a
-- group's id, which depends on the order the session created its groups in.
local function definition(value)
  if type(value) == "string" then
    if value:sub(1, 1) == "#" then
      return { fg = value }
    end
    if value:match(GROUP_NAME) then
      return { link = value }
    end
    return nil, "its value is neither a #rrggbb colour nor a highlight group's name"
  end
  if type(value) == "table" then
    local link = value.link
    if link ~= nil and not (type(link) == "string" and link:match(GROUP_NAME)) then
      return nil, "its link is not a highlight group's name"
    end
    return value
  end
  return nil, ("its value is a %s, where a colour, a group's name or a table goes"):format(type(value))
end

-- A group's definition as the colour scheme resolves it, following links.
local function resolved(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

-- What DocketEditable is defined as, in the shape nvim_set_hl() takes: the
-- background of the first group in EDITABLE_FROM whose background is set and
-- differs from Normal's, so that an editable line stands out from the text
-- around it, and a link to EDITABLE_FALLBACK when none differs. The
-- terminal's background, `ctermbg`, is copied with the GUI's, because it is
-- the one neovim draws with when 'termguicolors' is off.
local function editable()
  local normal = resolved("Normal").bg
  for _, name in ipairs(M.EDITABLE_FROM) do
    local spec = resolved(name)
    if spec.bg ~= nil and spec.bg ~= normal then
      return { bg = spec.bg, ctermbg = spec.ctermbg }
    end
  end
  return { link = M.EDITABLE_FALLBACK }
end

--- Defines the Docket* highlight groups, then one group per configured
--- status.
---
--- The fixed groups are set with `default`, which leaves a group that
--- already holds a definition as it is: one a colour scheme or the
--- configuration made keeps it. DocketEditable's background is chosen from
--- the colour scheme's at each call, and set when the group is empty or
--- holds what the last call set; a group holding anything else keeps it.
--- A colour scheme's `:hi clear` empties DocketEditable and the configured
--- statuses, which is why the ColorScheme autocommand calls this again.
---
--- `configured` is setup{}'s `statuses`: each key a status name as Jira
--- prints it, each value a `#rrggbb` colour, a group to link to, or the
--- table nvim_set_hl() takes. It replaces the statuses the last call kept;
--- nil keeps them and sets them again. They are set without `default`,
--- because each is the user's own setting and a second setup() replaces the
--- first, which `default` refuses once a group holds a value. A status whose
--- value cannot be set is dropped, so it renders in its category's group,
--- and is named in what configured() returns. So is one whose group a name
--- before it, in byte order, already took: status_group() makes `To Do` and
--- `To-Do` one group, and neovim matches a group's name in any case, so
--- `Done` and `DONE` are one as well. The order is sorted so that the same
--- name takes the group at every setup.
---@param configured table<string, string|table>|nil
---@return string[] problems one line for each status that could not be set
function M.define(configured)
  for _, group in ipairs(M.GROUPS) do
    vim.api.nvim_set_hl(0, group[1], { link = group[2], default = true })
  end
  local held = vim.api.nvim_get_hl(0, { name = M.EDITABLE, link = true })
  if next(held) == nil or vim.deep_equal(held, chosen) then
    vim.api.nvim_set_hl(0, M.EDITABLE, editable())
    chosen = vim.api.nvim_get_hl(0, { name = M.EDITABLE, link = true })
  end
  if configured == nil then
    for _, status in pairs(statuses) do
      vim.api.nvim_set_hl(0, status.group, definition(status.value))
    end
    return {}
  end
  statuses, problems = {}, {}
  local function refuse(name, err)
    problems[#problems + 1] = ("the status %s keeps its category's colour, because %s"):format(name, err)
  end
  local names = {}
  for name in pairs(configured) do
    if type(name) == "string" then
      names[#names + 1] = name
    else
      -- A list, `{ "In Review" }`, names no colour; its keys are numbers.
      refuse(vim.inspect(name), "its key is no status name; each key is the status as Jira prints it")
    end
  end
  table.sort(names)
  -- Each group a status has taken, lower-cased, and that status.
  local taken = {}
  for _, name in ipairs(names) do
    local value, group = configured[name], M.status_group(name)
    local spec, err = definition(value)
    local holder = taken[group:lower()]
    if spec and holder then
      spec, err = nil, ("%s already renders in %s"):format(holder.name, holder.group)
    end
    if spec then
      local ok, raised = pcall(vim.api.nvim_set_hl, 0, group, spec)
      err = not ok and ("nvim_set_hl() refused it: %s"):format(tostring(raised)) or nil
    end
    if err then
      refuse(name, err)
    else
      local status = { name = name, group = group, value = value, link = spec.link }
      statuses[name:lower()], taken[group:lower()] = status, status
    end
  end
  table.sort(problems)
  return problems
end

--- The configured statuses the last define() set, each with its group and
--- the group it links to, if any, sorted by name, and what it could not set.
---@return { name: string, group: string, link: string|nil }[] set
---@return string[] problems
function M.configured()
  local set = {}
  for _, status in pairs(statuses) do
    set[#set + 1] = { name = status.name, group = status.group, link = status.link }
  end
  table.sort(set, function(a, b)
    return a.name < b.name
  end)
  return set, vim.deepcopy(problems)
end

--- The group a state renders in.
---
--- A Jira status that setup{} gives a colour of its own, matched by name in
--- any case, renders in that status's group, whatever its category and
--- whether or not it carries one. Otherwise a Jira status carries its
--- category, which decides. With no category, which is every GitLab and
--- GitHub state, the state itself is looked up in STATES. Anything else is
--- DocketLabel.
---@param state string
---@param category string|nil a Jira `statusCategory.key`: "new", "indeterminate" or "done"
---@param source string|nil the row's or the item's source; a configured status applies to "jira" alone
---@return string group
function M.state_group(state, category, source)
  if source == "jira" then
    local status = statuses[state:lower()]
    if status then
      return status.group
    end
  end
  if category ~= nil then
    return M.CATEGORIES[category] or M.LABEL
  end
  return M.STATES[state:lower()] or M.LABEL
end

return M
