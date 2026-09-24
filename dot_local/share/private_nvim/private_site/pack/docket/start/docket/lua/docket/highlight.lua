-- The Docket* highlight groups: their names, what each links to, and the one
-- a state renders in. Imports nothing local, which is what lets setup()
-- define the groups without loading the read path; the item buffer and the
-- dashboard read the names from here.
--
-- define() runs at setup and again from a ColorScheme autocommand, since a
-- colour scheme change clears the groups. Each links to its Octo* equivalent
-- when octo.nvim has been set up at that moment, and to a built-in group
-- otherwise.

local M = {}

M.EDITABLE = "DocketEditable"
M.USER = "DocketUser"
M.LABEL = "DocketLabel"
M.OPEN = "DocketStateOpen"
M.CLOSED = "DocketStateClosed"
M.MERGED = "DocketStateMerged"
M.PENDING = "DocketStatePending"

-- Each Docket* group, the Octo* group it follows when octo.nvim is set up,
-- and the built-in group otherwise.
M.GROUPS = {
  { M.EDITABLE, "OctoEditable", "NormalFloat" },
  { M.USER, "OctoUser", "Identifier" },
  { M.LABEL, "OctoBubble", "Label" },
  { M.OPEN, "OctoStateOpen", "DiagnosticOk" },
  { M.CLOSED, "OctoStateClosed", "DiagnosticError" },
  { M.MERGED, "OctoStateMerged", "Special" },
  { M.PENDING, "OctoStatePending", "DiagnosticWarn" },
}

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

--- Defines the Docket* highlight groups.
---
--- octo.nvim defines its groups inside its own setup, with no `default` and
--- no re-application, so `package.loaded['octo']` says whether they can be
--- followed; a group it has not defined is not linked to, so a name this
--- table gets wrong falls back rather than linking to nothing.
function M.define()
  local octo = package.loaded["octo"] ~= nil
  for _, group in ipairs(M.GROUPS) do
    local target = group[3]
    if octo and vim.fn.hlexists(group[2]) == 1 then
      target = group[2]
    end
    vim.api.nvim_set_hl(0, group[1], { link = target })
  end
end

--- The group a state renders in.
---
--- A Jira status carries its category, which decides alone. With no
--- category, which is every GitLab and GitHub state, the state itself is
--- looked up in STATES. Anything else is DocketLabel.
---@param state string
---@param category string|nil a Jira `statusCategory.key`: "new", "indeterminate" or "done"
---@return string group
function M.state_group(state, category)
  if category ~= nil then
    return M.CATEGORIES[category] or M.LABEL
  end
  return M.STATES[state:lower()] or M.LABEL
end

return M
