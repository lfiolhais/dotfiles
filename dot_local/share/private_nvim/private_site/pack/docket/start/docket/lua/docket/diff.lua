-- The region compare: which calls a save makes, decided from the snapshot the
-- read command kept and the text each region holds now. Pure, and imports
-- nothing local: reading extmark ranges out of the buffer is buffer.lua's job,
-- and this takes what it read, so the part that decides what is sent is
-- tested without a buffer.
--
-- The snapshot is what the read command stored when it populated the buffer:
--
--   { regions = { [id] = { kind, owner, editable, reason, lines, crlf } }, frame }
--
-- `kind` is BODY, COMMENT or NEW. `owner` is the author's account identifier
-- as the backend reports it, absent on the body, and carried for the message
-- rather than for a decision. `id` is the backend's identifier for a comment
-- -- the numeric comment id on Jira, the note id on GitLab -- or NEW for a
-- comment appended in the buffer and not yet posted. `lines` are the region's
-- rendered lines as loaded. `crlf` is set on a region whose body arrived with
-- CRLF line ends, which `lines` no longer carry; the update a changed one
-- makes carries it, and the write puts those ends back into what it sends.
--
-- `editable` and `reason` are the read path's judgement, and this module makes
-- no judgement of its own. A region is unwritable when another account wrote
-- it, when its tree carries a node the serialiser does not emit, or when the
-- account's own identifier could not be established -- and the read path is the
-- only place that can see all of them, because it holds the tree and the
-- whoami() answer. So the compare has one rule: a changed region whose
-- `editable` is false is refused with its `reason`.
--
-- A NEW region is the exception: it is created whatever `editable` says,
-- because nothing about it was loaded from the backend. Its text was typed
-- here, so the serialiser can carry it, and no other account owns it.
--
-- The current state is one entry per region mark buffer.lua found:
--
--   { [id] = { lines = {...} } }        the text between the mark's ends now
--   { [id] = { overlaps = other } }     its range runs into region `other`'s
--   { [id] = { reversed = true } }      its end has moved above its start
--
-- A region in the snapshot with no entry at all is a mark the buffer no
-- longer has, and the whole write is refused: what the buffer holds can no
-- longer be matched to what was loaded. A mark the buffer has and the snapshot
-- does not is refused the same way and for the same reason, so a save is
-- attempted only when the two sets are the same. Overlapping and reversed
-- marks refuse it as well, because an edit moved lines across a region's
-- boundary in a way the marks cannot follow -- a `:sort` or a `:move` over
-- lines of two regions -- and which lines are whose is no longer known.
--
-- What lies outside every region -- the header, the title, the author lines,
-- the notices -- is never sent, so text there that was not there when the
-- item was read would be lost by a save that went ahead: a line moved out of
-- a region, or typed where no region reaches. The snapshot's `frame` is that
-- text as loaded, one string per non-blank line, and the third argument is
-- the same now, as `{ row, text }` with the 1-based line number. They are
-- compared word by word, so a join or a reflow that only moves line breaks
-- and spaces outside the regions is not a change, and any other difference
-- refuses the whole write.

local M = {}

M.BODY = "body"
M.COMMENT = "comment"
M.NEW = "new"

-- The calls, named after the adapter capabilities that carry them out.
M.BODY_UPDATE = "body_update"
M.COMMENT_UPDATE = "comment_update"
M.COMMENT_CREATE = "comment_create"

-- The identifier a refusal about the text outside the regions carries.
M.OUTSIDE = "outside the regions"

-- What a refused save says to do about a region whose mark no longer spans
-- its text. The buffer's text is the only copy of the edit, and `:e!`
-- discards it.
local RECOVER = "u undoes that edit; otherwise yank the text, then :e! reads the item again"

-- Leading and trailing blank lines are dropped before the compare, because a
-- line opened above a region joins it and that is not an edit.
local function trimmed(lines)
  local first, last = 1, #lines
  while first <= last and lines[first]:match("^%s*$") do
    first = first + 1
  end
  while last >= first and lines[last]:match("^%s*$") do
    last = last - 1
  end
  return table.concat(lines, "\n", first, last)
end

-- Each word of the text outside the regions, with the line it is on: the
-- line's text, and its number where the line carries one, which the text
-- as it is now does and the text as loaded does not.
local function words(lines)
  local found = {}
  for _, line in ipairs(lines) do
    local text = type(line) == "table" and line.text or line
    for word in text:gmatch("%S+") do
      found[#found + 1] = { word = word, text = text, row = type(line) == "table" and line.row or nil }
    end
  end
  return found
end

-- Why the text outside the regions refuses a save, or nil when it is the text
-- loaded. The words both ends share are set aside, and what is left names
-- the first line holding a word that was not there, or else the first line
-- whose words are gone.
local function outside(loaded, now)
  local was, is = words(loaded), words(now)
  local first = 1
  while first <= #was and first <= #is and was[first].word == is[first].word do
    first = first + 1
  end
  local last_was, last_is = #was, #is
  while last_was >= first and last_is >= first and was[last_was].word == is[last_is].word do
    last_was, last_is = last_was - 1, last_is - 1
  end
  if last_is >= first then
    return ('line %d, "%s", is outside every region, where a save sends nothing; move it into a region, or u undoes the edit that put it there'):format(
      is[first].row,
      is[first].text
    )
  end
  if last_was >= first then
    return ('"%s" is no longer outside the regions, so an edit deleted it or moved it into one, and a save cannot tell which; u undoes that edit'):format(
      was[first].text
    )
  end
  return nil
end

local function sorted_ids(regions)
  local ids = {}
  for id in pairs(regions) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

--- Decides what a save sends.
---
--- Each call is `{ kind, id, text }`, with `kind` one of BODY_UPDATE,
--- COMMENT_UPDATE and COMMENT_CREATE, and `text` joined with LF. An update of
--- a region whose snapshot carries `crlf` carries `crlf = true` as well, and
--- no other call has the field. Each skipped or refused entry is
--- `{ id, reason }`. When anything is refused, `calls` is empty: an edit in a
--- region that cannot be written is refused before any call is made, so a
--- save never half-succeeds around it. A refusal about the text outside the
--- regions carries OUTSIDE as its `id`, and is made only when both the
--- snapshot's `frame` and `frame` are given.
---@param snapshot { regions: table<string, table>, frame: string[]|nil }
---@param current table<string, table>
---@param frame { row: integer, text: string }[]|nil the text outside the regions now
---@return { calls: table[], skipped: table[], refused: table[] }
function M.plan(snapshot, current, frame)
  local calls, skipped, refused = {}, {}, {}

  for _, id in ipairs(sorted_ids(snapshot.regions)) do
    local region = snapshot.regions[id]
    local now = current[id]
    if now == nil then
      refused[#refused + 1] = {
        id = id,
        reason = "its mark is gone; yank the text, then :e! reads the item again",
      }
    elseif now.overlaps then
      refused[#refused + 1] = {
        id = id,
        reason = ("its text runs into %s's, so which lines are whose is lost; %s"):format(now.overlaps, RECOVER),
      }
    elseif now.reversed then
      refused[#refused + 1] = {
        id = id,
        reason = ("an edit moved its first line below its last, so its mark no longer spans its text; %s"):format(RECOVER),
      }
    elseif trimmed(now.lines) == "" and (region.kind == M.NEW or trimmed(region.lines) ~= "") then
      -- An emptied region is never posted as an empty body. Deleting text is
      -- not how a comment is deleted; that is a command. A region loaded
      -- empty -- an item with no description -- and still empty was not
      -- emptied: it falls through to the compare and sends nothing. A NEW
      -- region is loaded empty by construction, so for it blank means skip.
      skipped[#skipped + 1] = { id = id, reason = "empty; nothing sent" }
    elseif region.kind == M.NEW then
      calls[#calls + 1] = { kind = M.COMMENT_CREATE, id = id, text = trimmed(now.lines) }
    else
      local text = trimmed(now.lines)
      if text ~= trimmed(region.lines) then
        if region.editable == false then
          refused[#refused + 1] = {
            id = id,
            reason = region.reason or "not editable here",
          }
        elseif region.kind == M.BODY then
          calls[#calls + 1] = { kind = M.BODY_UPDATE, id = id, text = text, crlf = region.crlf or nil }
        else
          calls[#calls + 1] = { kind = M.COMMENT_UPDATE, id = id, text = text, crlf = region.crlf or nil }
        end
      end
    end
  end

  for _, id in ipairs(sorted_ids(current)) do
    if snapshot.regions[id] == nil then
      refused[#refused + 1] = { id = id, reason = "not in the loaded snapshot" }
    end
  end

  if snapshot.frame and frame then
    local reason = outside(snapshot.frame, frame)
    if reason then
      refused[#refused + 1] = { id = M.OUTSIDE, reason = reason }
    end
  end

  if #refused > 0 then
    calls = {}
  end
  return { calls = calls, skipped = skipped, refused = refused }
end

return M
