-- The one row shape every adapter normalises to, and its ordering. Imports
-- nothing local. The dashboard renders and sorts rows without knowing which
-- client produced them, which is what makes adding an adapter a table entry.

local M = {}

-- The sources, in the order the dashboard shows their sections, which is also
-- the order a list holding more than one source sorts by.
M.SOURCES = { "jira", "glab", "gh" }

local rank = {}
for position, source in ipairs(M.SOURCES) do
  rank[source] = position
end

--- Builds a row, refusing one that lacks a field the dashboard renders.
---
--- `branch` is optional: a merge request carries its source branch, a ticket
--- has none until the launcher generates one. `category` is a Jira status's
--- `statusCategory.key` -- "new", "indeterminate" or "done" -- which is what
--- colours the state; it is kept only as a non-empty string, and is nil on
--- every other backend. `fork` is true for a merge request or a pull request
--- whose branch lives in a fork rather than on origin, and nil otherwise; the
--- launcher refuses such a row.
---@param fields { source: string, id: string, state: string, title: string, branch: string|nil, category: string|nil, fork: boolean|nil }
---@return table row
function M.new(fields)
  -- Level 0 on both, so the message carries no source location: an adapter
  -- catches these with pcall and the dashboard shows the text to whoever is
  -- looking at the section, where `row.lua:<line>:` in front of it is noise.
  if not rank[fields.source] then
    error(("row: source %q is none of %s"):format(tostring(fields.source), table.concat(M.SOURCES, ", ")), 0)
  end
  for _, name in ipairs({ "id", "state", "title" }) do
    if type(fields[name]) ~= "string" or fields[name] == "" then
      error(("row: %s needs a non-empty string for %s"):format(tostring(fields.id), name), 0)
    end
  end
  return {
    source = fields.source,
    id = fields.id,
    state = fields.state,
    title = fields.title,
    branch = fields.branch,
    category = (type(fields.category) == "string" and fields.category ~= "") and fields.category or nil,
    fork = fields.fork == true or nil,
  }
end

--- Splits an identifier into its prefix and its trailing number.
---
--- `PAY-1201` gives `PAY-` and 1201, `!482` gives `!` and 482. Compared as
--- text `!10` sorts before `!9`, so the number is compared as a number.
---@param id string
---@return string prefix
---@return integer|nil number nil when the identifier ends in no digits
function M.split_id(id)
  local prefix, digits = id:match("^(.-)(%d+)$")
  if not prefix then
    return id, nil
  end
  return prefix, tonumber(digits)
end

--- The ordering: by source in SOURCES order, then by identifier prefix, then
--- by the identifier's number.
---@param a table
---@param b table
---@return boolean
function M.compare(a, b)
  if a.source ~= b.source then
    return rank[a.source] < rank[b.source]
  end
  local prefix_a, number_a = M.split_id(a.id)
  local prefix_b, number_b = M.split_id(b.id)
  if prefix_a ~= prefix_b then
    return prefix_a < prefix_b
  end
  if number_a and number_b and number_a ~= number_b then
    return number_a < number_b
  end
  return a.id < b.id
end

--- Sorts rows in place by compare() and returns the same table.
---@param rows table[]
---@return table[] rows
function M.sort(rows)
  table.sort(rows, M.compare)
  return rows
end

return M
