-- The omnifunc an item buffer names: the trigger rule, and the candidates the
-- buffer's adapter answers, cached by query. Imports the adapter registry. It
-- holds nothing about the buffer: buffer.lua sets `omnifunc` and
-- mini.completion's fallback when it prepares one, and the adapter is named
-- by the `docket` variable the read left there.
--
-- mini.completion runs its fallback after a short delay on every keystroke in
-- a buffer no language server answers, which is every item buffer, so the
-- first call answers NONE unless the text before the cursor ends in a
-- trigger, and ordinary typing asks nothing:
--
--   @ana      a user: the characters after `@` are the query, and the
--             completion replaces them and keeps the `@`
--   !48       a merge request: the digits are the query, and the completion
--             replaces the `!` as well, because the candidate carries it
--   PROJ-1    an item key: an uppercase run of two or more, a hyphen, and any
--             digits; the whole run is the query and is replaced
--
-- A trigger counts at the start of the line or after a character that cannot
-- be part of a word, so an address such as `ana@example.com` and a sentence
-- ending `done!` ask nothing.
--
-- What each backend answers is its adapter's complete(). Jira answers keys,
-- from the rows its dashboard sections returned, and no users: a mention in a
-- Jira body is a node carrying an account identifier, the serialiser emits
-- none, and a completed `@name` would post as those characters. GitLab answers
-- both, users through `glab api` under the short timeouts.complete, which
-- holds the editor for as long as glab takes. An answer with no candidate
-- cancels silently, so `@` in a Jira buffer shows nothing at all.

local adapters = require("docket.adapters")

local M = {}

-- What the first call answers when there is nothing to complete: -3 cancels
-- silently and leaves completion mode (`:help complete-functions`). -1 does
-- not cancel: completion then starts at the cursor and the function is called
-- a second time with an empty base, which under mini.completion is a second
-- call and an empty menu after every keystroke.
M.NONE = -3

-- How long an answer is reused, in seconds. mini.completion asks after every
-- pause in typing and a user search holds the editor while glab runs, so a
-- query asked again -- a character typed and erased, the menu reopened -- is
-- answered from here; past a minute the rows a dashboard refresh brought in
-- are offered.
M.TTL = 60

-- Answers by adapter, kind and query: `{ at, items }`.
local answers = {}

-- The first call's answer, for the second call: the text it replaces and the
-- items it found. Vim calls the two back to back with that text as `base`.
local pending = nil

-- Errors an adapter's complete() raised, reported once each rather than at
-- every keystroke.
local reported = {}

-- Whether the character before a trigger at `start` (1-based) leaves the
-- trigger standing: none at all, or one that cannot be part of a word.
local function standalone(before, start)
  return start == 1 or not before:sub(start - 1, start - 1):match("[%w_]")
end

--- The trigger the text before the cursor ends in, if any.
---
--- `start` is the 0-based byte column the completion replaces from, which is
--- what the first omnifunc call answers.
---@param before string the line up to the cursor
---@return string|nil kind "user" or "item"
---@return string|nil query what the adapter is asked for
---@return integer|nil start
function M.trigger(before)
  local at, name = before:match("()@([%w._-]*)$")
  if at and standalone(before, at) then
    return "user", name, at
  end
  local bang, digits = before:match("()!(%d*)$")
  if bang and standalone(before, bang) then
    return "item", digits, bang - 1
  end
  local first, key = before:match("()(%u[%u%d]+%-%d*)$")
  if first and standalone(before, first) then
    return "item", key, first - 1
  end
  return nil, nil, nil
end

--- Drops every cached answer.
function M.clear()
  answers = {}
  pending = nil
end

--- The candidates an adapter offers for a query, as complete-items, cached
--- for TTL seconds.
---
--- An item candidate is kept only when its identifier begins with `replaced`,
--- the text the completion replaces: the identifier is what is inserted, and
--- one that does not continue what was typed -- a Jira key offered for `!` --
--- is not a completion of it. A user candidate is kept whatever its name,
--- because the search matches display names as well as the username that is
--- inserted.
---@param source string the adapter's name
---@param kind string "user" or "item"
---@param query string
---@param replaced string
---@return table[] items `{ word, menu }` each
function M.items(source, kind, query, replaced)
  local key = table.concat({ source, kind, query, replaced }, "\n")
  local cached = answers[key]
  if cached and os.time() - cached.at < M.TTL then
    return cached.items
  end
  local adapter = adapters.get(source)
  if not adapter or not adapters.can(adapter, "complete") then
    return {}
  end
  local ok, found = pcall(adapter.complete, kind, query)
  if not ok then
    local message = ("docket: completion from %s: %s"):format(source, tostring(found))
    if not reported[message] then
      reported[message] = true
      vim.notify(message, vim.log.levels.WARN)
    end
    return {}
  end
  local items = {}
  for _, candidate in ipairs(type(found) == "table" and found or {}) do
    local word = type(candidate) == "table" and candidate.id
    if type(word) == "string" and (kind == "user" or word:sub(1, #replaced) == replaced) then
      items[#items + 1] = { word = word, menu = type(candidate.title) == "string" and candidate.title or nil }
    end
  end
  answers[key] = { at = os.time(), items = items }
  return items
end

--- The omnifunc, named by buffer.OMNIFUNC.
---
--- The first call answers the column the trigger's completion starts at, or
--- NONE when the text before the cursor ends in no trigger, the buffer holds
--- no item, or the adapter offers nothing, so an empty menu never opens. The
--- adapter is asked on the first call rather than the second because that
--- is how the empty answer is known in time to cancel; the second call hands
--- back what the first found.
---@param findstart integer 1 on the first call, 0 on the second
---@param base string the text the completion replaces, on the second call
---@return integer|table[] start on the first call, the complete-items on the second
function M.omnifunc(findstart, base)
  if findstart ~= 1 then
    local found = pending
    pending = nil
    if found and found.replaced == base then
      return found.items
    end
    return {}
  end
  pending = nil
  local state = vim.b.docket
  if type(state) ~= "table" or type(state.source) ~= "string" then
    return M.NONE
  end
  local before = vim.api.nvim_get_current_line():sub(1, vim.api.nvim_win_get_cursor(0)[2])
  local kind, query, start = M.trigger(before)
  if not kind then
    return M.NONE
  end
  local replaced = before:sub(start + 1)
  local items = M.items(state.source, kind, query, replaced)
  if #items == 0 then
    return M.NONE
  end
  pending = { replaced = replaced, items = items }
  return start
end

return M
