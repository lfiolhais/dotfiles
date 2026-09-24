-- The item: its header fields, its body, its comments, and the region
-- descriptors the buffer marks. Imports nothing local. new() normalises what
-- an adapter hands it into one shape, so nothing above it knows acli from
-- glab; regions() is the ownership half of the editability judgement, and
-- the tree half is adf's, which render combines with this one.
--
-- A body or a comment's body is the document tree the backend returned, held
-- as it came. The account's own identifier, `me`, is what the adapter's
-- whoami() answered, and nil when it could not answer: then every comment is
-- read-only, because none can be told from another account's.

local M = {}

-- The region kinds, and the body region's identifier. diff.lua names the same
-- strings and imports nothing, so the suite asserts the two agree.
M.BODY = "body"
M.COMMENT = "comment"
M.NEW = "new"
M.BODY_ID = "body"

local function nilled(value)
  if value == vim.NIL then
    return nil
  end
  return value
end

-- A person as the backend reports one: an identifier and a display name.
local function person(value)
  value = nilled(value)
  if type(value) ~= "table" then
    return nil
  end
  return { id = nilled(value.id), name = nilled(value.name) }
end

--- Builds an item, refusing one that lacks a field the buffer renders.
---
--- `comments` are in the order the backend gave them, each with `id`,
--- `author`, `created`, `updated` and `body`. `total` is how many comments
--- the backend says the thread holds, and nil when it does not say; when it
--- exceeds the comments given, `missing` is the difference and the renderer
--- says so in place of the comments it does not have. `start_at` is the
--- offset in the thread of the first comment given, 0 when the backend does
--- not say; that many of the missing lie before the page held and the rest
--- after it, which is how the renderer splits its notice between the two
--- ends. `me` is the account's own identifier, or nil when the client could
--- not supply it. `category` is a Jira status's `statusCategory.key` --
--- "new", "indeterminate" or "done" -- which is what colours the state; it is
--- kept only as a non-empty string, and is nil on every other backend.
--- `ref` is the reference the adapter's later calls about the item take in
--- place of `id`, which adapters/init.lua describes; nil when the adapter
--- takes the identifier alone. `project` is the project path the backend's
--- answer names, on a backend that numbers its items within a project and
--- whose answer says which; nil where it does not say, and the item buffer
--- then holds nothing against its name.
---
--- The refusals are raised at level 0, so the message carries no source
--- location: an adapter catches them with pcall and the buffer shows the text
--- after the item's name, where a path into this file is noise.
---@param fields { source: string, id: string, title: string, state: string|nil, category: string|nil, url: string|nil, assignee: table|nil, reporter: table|nil, updated: string|nil, body: table|nil, comments: table[]|nil, total: integer|nil, start_at: integer|nil, me: string|nil, ref: table|nil, project: string|nil }
---@return table item
function M.new(fields)
  for _, name in ipairs({ "source", "id", "title" }) do
    if type(fields[name]) ~= "string" or fields[name] == "" then
      error(("item: %s needs a non-empty string for %s"):format(tostring(fields.id), name), 0)
    end
  end
  local comments = {}
  for index, given in ipairs(nilled(fields.comments) or {}) do
    local id = nilled(given.id)
    if id == nil then
      error(("item: comment %d of %s has no id"):format(index, fields.id), 0)
    end
    comments[index] = {
      id = tostring(id),
      author = person(given.author),
      created = nilled(given.created),
      updated = nilled(given.updated),
      body = nilled(given.body),
    }
  end
  local total = tonumber(nilled(fields.total))
  return {
    source = fields.source,
    id = fields.id,
    title = fields.title,
    state = nilled(fields.state) or "",
    category = (type(fields.category) == "string" and fields.category ~= "") and fields.category or nil,
    url = nilled(fields.url),
    assignee = person(fields.assignee),
    reporter = person(fields.reporter),
    updated = nilled(fields.updated),
    body = nilled(fields.body),
    comments = comments,
    total = total,
    missing = (total and total > #comments) and total - #comments or 0,
    start_at = tonumber(nilled(fields.start_at)) or 0,
    me = nilled(fields.me),
    ref = type(fields.ref) == "table" and fields.ref or nil,
    project = (type(fields.project) == "string" and fields.project ~= "") and fields.project or nil,
  }
end

-- Days since 1970-01-01 for a civil date, by arithmetic rather than through
-- os.time, which reads the calendar in the machine's own zone.
local function days_from_civil(year, month, day)
  if month <= 2 then
    year = year - 1
  end
  local era = math.floor(year / 400)
  local year_of_era = year - era * 400
  local month_shifted = (month + 9) % 12
  local day_of_year = math.floor((153 * month_shifted + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year
  return era * 146097 + day_of_era - 719468
end

--- Seconds since the epoch for a timestamp as Jira and GitLab write one:
--- `2024-05-03T10:11:12.345+0100`, `2024-05-03T10:11:12Z`, or the same with
--- a colon in the offset. nil for anything else.
---@param stamp string|nil
---@return integer|nil seconds
function M.parse_time(stamp)
  if type(stamp) ~= "string" then
    return nil
  end
  local year, month, day, hour, minute, second, rest =
    stamp:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.?%d*(.*)$")
  if not year then
    return nil
  end
  -- The arithmetic below answers any pair of numbers, so an impossible date
  -- such as `2024-13-45` would come back as a moment in 2025 and read as a
  -- plausible `3 days ago`. Out of range is nil instead, and the stamp is
  -- then shown as given.
  local y, mo, d = tonumber(year), tonumber(month), tonumber(day)
  local days_in_month = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if mo == 2 and (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) then
    days_in_month[2] = 29
  end
  if mo < 1 or mo > 12 or d < 1 or d > days_in_month[mo] then
    return nil
  end
  if tonumber(hour) > 23 or tonumber(minute) > 59 or tonumber(second) > 60 then
    return nil
  end
  local offset = 0
  if rest ~= "" and rest ~= "Z" then
    local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
    if not sign then
      return nil
    end
    offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
  end
  return days_from_civil(y, mo, d) * 86400
    + tonumber(hour) * 3600
    + tonumber(minute) * 60
    + tonumber(second)
    - offset
end

--- How long ago a moment was, in the words the header and each author line
--- carry: `just now`, `5m ago`, `2h ago`, `yesterday`, `3 days ago`, and the
--- date itself past a month.
---@param seconds integer the moment
---@param now integer the present
---@return string
function M.ago(seconds, now)
  local elapsed = now - seconds
  if elapsed < 60 then
    return "just now"
  elseif elapsed < 3600 then
    return ("%dm ago"):format(math.floor(elapsed / 60))
  elseif elapsed < 86400 then
    return ("%dh ago"):format(math.floor(elapsed / 3600))
  elseif elapsed < 2 * 86400 then
    return "yesterday"
  elseif elapsed < 30 * 86400 then
    return ("%d days ago"):format(math.floor(elapsed / 86400))
  end
  return os.date("!%Y-%m-%d", seconds)
end

--- The regions an item has, in buffer order: the body, then one per comment.
---
--- Each is `{ id, kind, owner, editable, reason, body }`, with `body` the
--- tree. `editable` here is the ownership judgement alone: the body has no
--- owner and is editable; a comment is editable when its author is `me`, and
--- read-only naming the author otherwise -- or, when `me` is nil, naming the
--- missing identity. Whether the tree survives a write is adf's judgement,
--- which render() adds on top.
---@param item table
---@return table[] regions
function M.regions(item)
  local regions = {
    { id = M.BODY_ID, kind = M.BODY, owner = nil, editable = true, reason = nil, body = item.body },
  }
  for _, comment in ipairs(item.comments) do
    local author = comment.author or {}
    local editable, reason = true, nil
    if item.me == nil then
      editable = false
      reason = "the account's own identifier is unknown, so no comment can be told from another account's"
    elseif author.id ~= item.me then
      editable = false
      reason = ("written by %s"):format(author.name or author.id or "another account")
    end
    regions[#regions + 1] = {
      id = comment.id,
      kind = M.COMMENT,
      owner = author.id,
      editable = editable,
      reason = reason,
      body = comment.body,
    }
  end
  return regions
end

return M
