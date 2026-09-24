-- One request in flight per key, and the rule for joining it. Imports nothing
-- local. Each caller makes a join of its own with new(), so a search for
-- `flight.new` across the plugin lists them.
--
-- A second caller for a key joins the request already in flight rather than
-- spawning another, but only while the key is on the generation that request
-- started in. invalidate() moves the key on, and the request in flight is then
-- abandoned: a caller arriving afterwards starts a request of its own instead
-- of waiting out the old one only to be refused, and the old one's answer,
-- when it lands, is replaced by the site's refusal. This ordering is reached in
-- practice because spawn.wait and every prompt pump the event loop, so a
-- request started before a login or a write answers during one.
--
-- The rule, in full:
--
--   - a generation per key, moved on by invalidate();
--   - a join that compares the request's generation with the key's;
--   - a waiter list owned by each request rather than by the key, so a stale
--     request that settles late answers the callers that joined it and no one
--     else;
--   - a settle that runs once, and clears the key's slot only while the slot
--     still holds its own request, since a fresh one may be collecting waiters
--     there by then;
--   - a refusal in place of any answer that lands after its key moved on;
--   - a pcall around the request, so one that raises answers its waiters with
--     the error and frees the key, where otherwise every later caller would
--     join a request that never answers.
--
-- Each waiter is called under pcall as well: one that raises would otherwise
-- leave the waiters behind it with no answer. What it raised is reported with
-- vim.notify, scheduled, because a settle usually runs in the fast-event
-- context of a spawn callback, where vim.notify is refused.

local M = {}

local unpack = unpack or table.unpack

local Flight = {}
Flight.__index = Flight

-- Reports an error that has no caller left to hand it to.
local function report(raised)
  vim.schedule(function()
    vim.notify(tostring(raised), vim.log.levels.ERROR)
  end)
end

--- A join of its own, for one site.
---
--- `refusal` is what every waiter is given, as the second value after a nil,
--- in place of an answer that landed after its key was invalidated: a string,
--- or a function of the key that returns one. `accept`, when given, is called
--- with the key and the answer whenever an answer is kept, before any waiter
--- sees it; the cache writes the rows there and whoami() remembers the
--- identity. When `accept` raises, the waiters are given nil and what it
--- raised.
---@param opts { refusal: string|fun(key: string): string, accept: fun(key: string, ...)|nil }
---@return table flight with join, invalidate, invalidate_all and pending
function M.new(opts)
  return setmetatable({
    refusal = opts.refusal,
    accept = opts.accept,
    generation = {},
    slot = {},
  }, Flight)
end

--- Asks for a key's answer, starting at most one request per key.
---
--- A request in flight that started in the key's current generation collects
--- `on_done` and `request` is not called. Otherwise `request` is called, on the
--- caller's own context, with the function it hands its answer to, which takes
--- any number of values; every waiter on that request gets the same values.
---@param key string
---@param request fun(settle: fun(...))
---@param on_done fun(...)
---@return boolean started false when on_done joined a request already in flight
function Flight:join(key, request, on_done)
  local current = self.generation[key] or 0
  local flight = self.slot[key]
  if flight and flight.generation == current then
    flight.waiting[#flight.waiting + 1] = on_done
    return false
  end
  local mine = { generation = current, waiting = { on_done }, settled = false }
  self.slot[key] = mine
  local function settle(...)
    if mine.settled then
      return
    end
    mine.settled = true
    if self.slot[key] == mine then
      self.slot[key] = nil
    end
    local answer = { n = select("#", ...), ... }
    if (self.generation[key] or 0) ~= mine.generation then
      local refusal = self.refusal
      if type(refusal) == "function" then
        refusal = refusal(key)
      end
      answer = { n = 2, nil, refusal }
    elseif self.accept then
      local accepted, raised = pcall(self.accept, key, unpack(answer, 1, answer.n))
      if not accepted then
        answer = { n = 2, nil, tostring(raised) }
      end
    end
    for _, callback in ipairs(mine.waiting) do
      local delivered, raised = pcall(callback, unpack(answer, 1, answer.n))
      if not delivered then
        report(raised)
      end
    end
  end
  local ok, raised = pcall(request, settle)
  if not ok then
    -- A request that has already answered and then raises has nobody left to
    -- tell, so what it raised is reported rather than lost.
    if mine.settled then
      report(raised)
    else
      settle(nil, tostring(raised))
    end
  end
  return true
end

--- Moves a key on: the request in flight for it, if any, is no longer joined,
--- and its answer is refused when it lands.
---@param key string
function Flight:invalidate(key)
  self.generation[key] = (self.generation[key] or 0) + 1
end

--- Moves on every key that has a request in flight. A key with none has
--- nothing to refuse, so it is left where it is.
function Flight:invalidate_all()
  for key in pairs(self.slot) do
    self:invalidate(key)
  end
end

--- Whether a request that the key's next join would join is in flight. One
--- the key has since moved on from is not, since that join starts its own.
---@param key string
---@return boolean
function Flight:pending(key)
  local flight = self.slot[key]
  return flight ~= nil and flight.generation == (self.generation[key] or 0)
end

return M
