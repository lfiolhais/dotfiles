-- An item to buffer lines, and the region ranges that go with them. Imports
-- item and adf. Pure: it writes no extmark and touches no buffer, which is
-- buffer.lua's job, so what the buffer holds is tested without one.
--
-- Nothing in the text says where a region begins. The header line, the title
-- and each author line sit outside every region; the body's lines and each
-- comment's lines are one region each, and the ranges returned beside the
-- lines are what buffer.lua marks. Each region carries exactly what diff's
-- snapshot needs -- `kind`, `owner`, `editable`, `reason`, `lines`, and
-- `crlf` where it is set -- plus `id`, `first_line` and `last_line`.

local adf = require("docket.adf")
local item = require("docket.item")

local M = {}

-- Between the runs of the header and of an author line.
M.SEPARATOR = "   "
-- What every read-only reason ends with, because the web is where such a
-- region is edited.
M.WEB_HINT = "gx opens it on the web"

-- Who a person is, as the header and the author lines say it: `me` for the
-- account itself, the display name otherwise, the identifier failing that.
local function who(person, me)
  if person == nil then
    return nil
  end
  if me ~= nil and person.id == me then
    return "me"
  end
  return person.name or person.id
end

-- `2h ago` when the timestamp parses, and the string as given when it does
-- not, so an unfamiliar format is shown rather than lost.
local function when(stamp, now)
  local seconds = item.parse_time(stamp)
  if seconds then
    return item.ago(seconds, now)
  end
  return stamp
end

local function header(it, now)
  local parts = { it.id }
  if it.state ~= "" then
    parts[#parts + 1] = it.state
  end
  parts[#parts + 1] = who(it.assignee, it.me) or "unassigned"
  if it.updated then
    parts[#parts + 1] = "updated " .. when(it.updated, now)
  end
  return table.concat(parts, M.SEPARATOR)
end

-- A body is one of two things. Jira returns a document tree, which renders
-- through adf and is editable only over the subset the serialiser emits.
-- GitLab returns markdown as a string, which is its own lines and is
-- editable as it stands: text written back is the same markdown, so none
-- of the tree's read-only rule applies to it.

-- The region's lines: the string split at its newlines or the tree rendered,
-- and one empty line for an empty body, so the region has a line to type
-- into and a range to mark. A line ending in a carriage return loses it, so
-- a body written with CRLF line ends shows no `^M`.
local function region_lines(body)
  local lines
  if type(body) == "string" then
    lines = vim.split(body, "\n", { plain = true })
    for index, line in ipairs(lines) do
      lines[index] = (line:gsub("\r$", ""))
    end
  else
    lines = adf.render(body)
  end
  if #lines == 0 then
    return { "" }
  end
  return lines
end

--- Whether the line breaks between a body's lines are all CRLF. region_lines()
--- drops the carriage returns, so the buffer and the compare hold LF text, and
--- a save puts CRLF back into what it sends for a region whose body this
--- answers true for. False for a tree, for a string with no line break or
--- whose only one is a final LF, and for one mixing the two endings, which a
--- save writes with LF.
---
--- A line break that ends the body is not counted when others lie between
--- its lines: a save sends the region's text with its trailing blank lines
--- trimmed, and the adapter ends it as its client needs -- glab's write
--- appends LF -- so a CRLF body read back after one save can end in LF, and
--- counted, that would make every later save LF. As the body's only line
--- break it is the only evidence of the ending, so a body whose only break is
--- a final CRLF answers true, and a line added under it is sent with CRLF.
--- UNVERIFIED: whether GitLab returns a body ending in CRLF, and that CRLF is
--- then the ending to send it, are both reasoned from the ending the body
--- arrived with; `glab api projects/:id/merge_requests/<iid>` on a
--- description typed in the web interface shows what it returns.
---@param body table|string|nil
---@return boolean
function M.crlf(body)
  if type(body) ~= "string" then
    return false
  end
  local inner = body:gsub("\r?\n$", "")
  if not inner:find("\n", 1, true) then
    return body:sub(-2) == "\r\n"
  end
  return not inner:find("^\n") and not inner:find("[^\r]\n")
end

-- Whether a write reproduces what the region shows: always for a string,
-- adf's judgement for a tree.
local function body_editable(body)
  if type(body) == "string" then
    return true, nil
  end
  return adf.editable(body)
end

--- Renders an item to lines, with the range of each region.
---
--- Lines are 1-based and inclusive: a region's text is
--- `nvim_buf_get_lines(buf, first_line - 1, last_line, false)`, and its mark
--- runs from column 0 of `first_line` to column 0 of the line after
--- `last_line`. `editable` and `reason` combine item's ownership judgement
--- with the body's: adf's judgement on a tree, and always editable for a
--- markdown string. Ownership is judged first, and every reason ends with
--- WEB_HINT. `crlf` is set, to true, on a region whose body M.crlf() answers
--- true for, and absent otherwise.
---
--- When the backend reports more comments than it gave, a line at each end
--- of the thread says how many are not shown there: `start_at` comments lie
--- before the page held, the rest of `missing` after it, and an end with
--- none is silent. With no comment given at all, both counts are one notice
--- after the body.
---@param it table the item
---@param opts { now: integer|nil }|nil `now` in seconds since the epoch, for the relative times
---@return string[] lines
---@return table[] regions each `{ id, kind, owner, editable, reason, first_line, last_line, lines, crlf }`
function M.render(it, opts)
  local now = (opts and opts.now) or os.time()
  local lines = { header(it, now), "# " .. it.title, "" }
  local regions = {}

  local by_id = {}
  for _, comment in ipairs(it.comments) do
    by_id[comment.id] = comment
  end

  -- The page held starts `start_at` comments into the thread, so that many of
  -- the missing lie before it and the rest after; a page in the middle of a
  -- long thread has some at each end. The count is capped at the gap because a
  -- comment deleted between the page and the total leaves `start_at` past the
  -- end of what is left, and that is a race rather than a fault.
  local before = math.min(it.start_at, it.missing)
  local after = it.missing - before
  local function notice(count)
    lines[#lines + 1] = ""
    lines[#lines + 1] =
      ("%d of %d comment%s not shown; %s"):format(count, it.total, it.total == 1 and "" or "s", M.WEB_HINT)
  end

  for _, region in ipairs(item.regions(it)) do
    if region.kind == item.COMMENT then
      local comment = by_id[region.id]
      if before > 0 then
        notice(before)
        before = 0
      end
      -- `view --fields comment` returns `created` and `updated` on a comment,
      -- and a backend that returns neither gets the author line alone.
      local parts = { who(comment.author, it.me) or "someone" }
      local stamp = comment.created or comment.updated
      if stamp then
        parts[#parts + 1] = when(stamp, now)
      end
      lines[#lines + 1] = ""
      lines[#lines + 1] = table.concat(parts, M.SEPARATOR)
    end
    local editable, reason = region.editable, region.reason
    if editable then
      editable, reason = body_editable(region.body)
    end
    if reason then
      reason = reason .. "; " .. M.WEB_HINT
    end
    local body = region_lines(region.body)
    local first = #lines + 1
    vim.list_extend(lines, body)
    regions[#regions + 1] = {
      id = region.id,
      kind = region.kind,
      owner = region.owner,
      editable = editable,
      reason = reason,
      first_line = first,
      last_line = #lines,
      lines = body,
      crlf = M.crlf(region.body) or nil,
    }
  end

  -- The comments missing after the page follow the last one. With no comment
  -- given, `before` was never spent, so both counts are one notice after the
  -- body.
  if before + after > 0 then
    notice(before + after)
  end

  return lines, regions
end

return M
