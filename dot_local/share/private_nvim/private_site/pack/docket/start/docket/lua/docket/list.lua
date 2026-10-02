-- The dashboard: one buffer at the root of a clone, its sections, the rows
-- under each, and the row under the cursor. Imports auth, cache, config,
-- flight, highlight, item and repo. The sections come from repo.sections(),
-- which turns the clone's binding, the configured list and the remote's
-- review client into what is shown; this module checks each backend's state,
-- fetches each section's rows, shows the cached ones at once with their age,
-- and renders.
-- The keys are attached by commands, which owns every keymap and imports this
-- module for the row under the cursor.
--
-- The buffer is scratch and `nofile`, so a paint leaves it unmodified. It is
-- listed and `bufhidden=hide`, so `:bnext` away from it and `:bprevious` back
-- land on it with its rows and its cursor as they were. An answer that
-- arrives while it is hidden is painted into it, and the cursor then comes
-- back on line 1: render() holds the cursor only of a window showing the
-- buffer, and replacing every line moves the position a hidden buffer
-- remembers to the top. The next `:Docket` paints it afresh.
--
-- Each section is a fold, which `za` closes to its header line. open() sets
-- the fold options and `nowrap` on each window showing the buffer, and so
-- does a BufWinEnter autocommand on each window the buffer enters later;
-- render() keeps the sections a window had closed closed across a paint.
--
-- `:bdelete`, or vim-bufkill's `BD`, unloads it and unlists it without wiping
-- it, and drops its options and its keys. `:e`, `:e!` and `:bunload` unload it
-- too and keep both, so it stays the dash, blank until `r` or `:Docket` paints
-- it again. Inside BufUnload `:bdelete` and `:e` look the same, so the
-- BufUnload autocommand looks again from a scheduled callback, and drops the
-- state and forgets the buffer only when `buftype` is no longer `nofile`; the
-- BufWipeout one drops them at once. No answer paints into a buffer that is unloaded or
-- has lost its `nofile`, and buffer() wipes a dash `:bdelete` left unloaded
-- and makes it afresh, because showing it would load it with its options
-- reset. Entered with `<C-^>` or `:b` before that, it loads as an empty buffer
-- of that name with no `buftype`, which no read command fills; buffer() takes
-- that buffer over at the next `:Docket`.
--
-- A session saved while it is on screen records it, as `enew` followed by
-- `file docket-dash://`, and init.lua's before_session_save() keeps it off
-- the session's buffer list. Restoring that session leaves an empty buffer of
-- that name. No read command matches the name, so nothing spawns at startup,
-- and buffer() takes that buffer over, because naming a second one raises
-- E95. buffer.lua says what listing lets into neovim's ShaDa file, and the
-- `'shada'` entry that keeps it out.
--
-- A section's count is the number of rows fetched, because the search
-- endpoint returns no total. A section with a `reason` renders it under the
-- header -- with no query that is all it renders, which is how an unbound
-- repository, an ignored one and an unknown remote each report themselves.
-- A section carrying both a query and a reason shows its rows under the
-- reason: the unbound section, under the command that binds the repository,
-- and the section a complete query runs in when an epic is bound beside it,
-- under the line saying the epic narrows nothing.
--
-- Every client's state check reaches its host, so it is asked through
-- auth.check(), which leaves the editor free while the client runs: a section
-- shows that it is checking until its backend answers, and then its rows or
-- its login line.
--
-- Every client callback arrives in a fast-event context, so the buffer work
-- is scheduled, and a callback that lands after the dashboard was reopened
-- for another root, refreshed again, unloaded or wiped, paints nothing.

local auth = require("docket.auth")
local cache = require("docket.cache")
local config = require("docket.config")
local flight = require("docket.flight")
local highlight = require("docket.highlight")
local item = require("docket.item")
local repo = require("docket.repo")

local M = {}

-- The buffer's name, kept verbatim by the editor because it carries `://`. A
-- name without one is resolved against the working directory, and a buffer
-- already holding that path -- a file of that name, opened -- makes
-- nvim_buf_set_name raise E95 and the dashboard does not open. Not under
-- `docket://`, whose BufReadCmd reads an item.
M.NAME = "docket-dash://"
-- The filetype, which is not the item buffer's, so the item keymaps never
-- attach here.
M.FILETYPE = "docket-dash"
-- The highlights, which are decoration only.
M.NS = vim.api.nvim_create_namespace("docket/dash")
-- What a row and a note under a header are indented by, and what separates a
-- row's columns.
M.INDENT = "  "
M.GAP = "   "
-- What separates a header's title from how the section stands.
M.SEPARATOR = " · "
-- The last line, naming the keys commands attaches, `za`, neovim's own,
-- which folds the section under the cursor, and `g?`, which lists every key
-- with what it does. The suite holds it to commands.DASH_KEYS.
M.KEYS = "<CR> open   w build environment   r refresh   R review   za fold   g? keys"

-- The one dashboard buffer, while it is valid and keeps the `nofile` that
-- `:bdelete` clears. A wiped buffer is invalid, and the autocommands buffer()
-- sets forget one `:bdelete` left; the next open() makes a new one.
local dash = nil

-- The group of the autocommands buffer() sets on the dashboard buffer, so
-- that taking a buffer over clears the ones an earlier take-over set on it:
-- `:bdelete` leaves a buffer's own autocommands in place.
local AUGROUP = vim.api.nvim_create_augroup("docket/dash", { clear = true })

-- What each buffer shows, by buffer:
--   root, bare        the clone, as repo.root() found it
--   binding           the clone's Jira binding, nil when it could not be read
--   binding_err       why, when it could not
--   sections          one per section shown: `def` as repo.sections() built
--                     it, `key` for a section that fetches, `rows` and the
--                     moment they were `written`, `status` "checking" while
--                     its backend's state check runs and "fetching" while
--                     its request runs, `error` from the state check or the
--                     client, `warning` from the adapter
--   at                the section and row on each line, by line number
--   round             how many refreshes have started on this state
--
-- Every open() files a state of its own here, and every refresh() moves its
-- round on. A client callback compares both with what it was started for: the
-- table is no longer the buffer's once the dashboard has been reopened, and
-- the round has moved once it has been refreshed again.
local states = {}

-- What the last paint of each buffer put on screen, by buffer:
--   folds   each line's fold level, as M.lines() answers it
--   heads   each section's header line, in order: `{ lnum, key }`, where the
--           key is the section's title and how many sections above it carry
--           the same title
--
-- Kept beside the state rather than in it, because it describes the lines
-- on screen, which are the last paint's until the next one. A second open()
-- files a state with new section tables and nothing painted, and sets the
-- fold options again, which re-evaluates every line: read from that state,
-- every line would be at level 0, and each closed section would open before
-- the first paint could record it.
local painted = {}

-- The state check in flight for each backend, keyed by adapter name. The
-- sections of one backend join one check, since each check spawns the
-- client. Every refresh moves every key on, so it starts checks of its own
-- rather than joining one an earlier refresh started: `r` asks for the state
-- as it is now. The refusal an earlier refresh's sections are given is never
-- painted, because their round has moved on as well.
local checks = flight.new({
  refusal = "the dashboard was refreshed while this state check was in flight, so its answer is not shown",
})

--- The state behind a dashboard buffer.
---@param buf integer
---@return table|nil state nil for a buffer that is not the dashboard
function M.state(buf)
  return states[buf]
end

--- The row on a line, and the section it is in.
---@param buf integer
---@param lnum integer 1-based
---@return table|nil row
---@return table|nil section the section's state
function M.row_at(buf, lnum)
  local state = states[buf]
  local found = state and state.at[lnum]
  if not found then
    return nil, nil
  end
  return found.row, found.section
end

--- The sections to show for a clone, and its binding.
---
--- The review client comes from origin's URL; with no origin, or one on a
--- host that is neither GitLab nor GitHub, the review sections are replaced by
--- one that says so. A binding that cannot be read -- git config failing --
--- leaves no Jira section to assemble, so one section carries the reason and
--- the review sections stand.
---@param found { root: string, bare: boolean } what repo.root() returned
---@return table[] sections
---@return table|nil binding
---@return string|nil binding_err
function M.assemble(found)
  local review = {}
  local url, err = repo.remote_url(found.root)
  if url then
    review.adapter, review.reason = repo.adapter_for(url)
  else
    review.reason = err
  end
  local binding, binding_err = repo.binding(found.root)
  if not binding then
    local shown = repo.sections({ kind = "ignored" }, config.options.sections, review)
    table.insert(shown, 1, {
      title = "Tickets",
      adapter = "jira",
      reason = ("the repository's Jira binding could not be read: %s"):format(binding_err),
    })
    return shown, nil, binding_err
  end
  return repo.sections(binding, config.options.sections, review), binding, nil
end

local function pad(text, width)
  return text .. string.rep(" ", width - vim.api.nvim_strwidth(text))
end

-- Appends one line and the highlight covering the whole of it.
local function put(lines, marks, text, group)
  lines[#lines + 1] = text
  if group then
    marks[#marks + 1] = { #lines - 1, 0, #text, group }
  end
end

-- Appends a note under a header: each line of `text`, indented, the first
-- carrying `prefix`.
local function note(lines, marks, text, prefix, group)
  for index, part in ipairs(vim.split(text, "\n", { plain = true })) do
    put(lines, marks, M.INDENT .. (index == 1 and prefix or "") .. part, group)
  end
end

-- The header: the title, the count when the rows are known, and after ` · `
-- how the section stands -- the rows' age, carrying `, refresh failed`,
-- `, checking sign-in` or `, refreshing` where a request has failed, the
-- state check is running, or a request is running behind them; `error`,
-- `checking sign-in` or `fetching` where there are no rows to age; or the age
-- alone.
--
-- A failed refresh leaves the rows it could not replace on screen, so the age
-- stays with them: it is the only thing that says they are old. It is computed
-- at each paint and nothing repaints on a timer, so a dashboard left open
-- shows the age it was last painted with.
local function header(st, now)
  local title = st.def.title
  if st.rows then
    title = ("%s (%d)"):format(title, #st.rows)
  end
  local meta
  if st.error then
    meta = st.written and (item.ago(st.written, now) .. ", refresh failed") or "error"
  elseif st.status == "checking" then
    meta = st.written and (item.ago(st.written, now) .. ", checking sign-in") or "checking sign-in"
  elseif st.status == "fetching" then
    meta = st.written and (item.ago(st.written, now) .. ", refreshing") or "fetching"
  elseif st.written then
    meta = item.ago(st.written, now)
  end
  return title, meta
end

--- The buffer's lines from a state, with the row on each line, the header
--- line of each section, the highlights and each line's fold level. Reads
--- nothing but the state and the statuses setup{} gave a colour, which is
--- what lets the suite render one it built by hand. It measures each column
--- with nvim_strwidth, so it runs on the main loop and not in a fast event. A
--- row's state is coloured by highlight.state_group(), which is where those
--- statuses are kept.
---
--- The first line names the clone, and the epic after it when the binding
--- is by project and carries one, so the narrowing is on screen. Under a
--- complete query the epic narrows nothing, and the line names none; the
--- section's reason says why.
---
--- Each section is one fold, from its header to the blank line that ends
--- it, so `za` on any of its lines closes it to the header. The fold levels
--- are strings in the form 'foldexpr' answers: `>1` on a header, `1` on
--- every line after it to that blank line, and `0` on the title lines and
--- the footer, which belong to no section.
---@param state table
---@param now integer the present, for each section's age
---@return string[] lines
---@return table<integer, { section: table, row: table }> at by 1-based line number
---@return { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] marks 0-based row, col, end_col, group
---@return table<table, integer> heads each section's header line, 1-based, keyed by the section's state
---@return string[] folds each line's fold level, by 1-based line number
function M.lines(state, now)
  local lines, at, marks, heads, folds = {}, {}, {}, {}, {}
  local top = "Docket" .. M.SEPARATOR .. state.root
  local binding = state.binding
  if binding and binding.kind == "projects" and binding.epic then
    top = top .. M.SEPARATOR .. binding.epic
  end
  put(lines, marks, top, "Title")
  put(lines, marks, "")
  folds[1], folds[2] = "0", "0"
  for _, st in ipairs(state.sections) do
    local title, meta = header(st, now)
    lines[#lines + 1] = meta and (title .. M.SEPARATOR .. meta) or title
    heads[st] = #lines
    marks[#marks + 1] = { #lines - 1, 0, #title, "Title" }
    if meta then
      marks[#marks + 1] = { #lines - 1, #title + #M.SEPARATOR, #lines[#lines], "Comment" }
    end
    if st.def.reason then
      note(lines, marks, st.def.reason, "", "Comment")
    end
    if st.error then
      note(lines, marks, st.error, "", "ErrorMsg")
    end
    if st.rows then
      local id_width, state_width = 0, 0
      for _, r in ipairs(st.rows) do
        id_width = math.max(id_width, vim.api.nvim_strwidth(r.id))
        state_width = math.max(state_width, vim.api.nvim_strwidth(r.state))
      end
      for _, r in ipairs(st.rows) do
        local id_cell = pad(r.id, id_width)
        local text = M.INDENT .. id_cell .. M.GAP .. pad(r.state, state_width) .. M.GAP .. r.title:gsub("\n", " ")
        lines[#lines + 1] = text
        marks[#marks + 1] = { #lines - 1, #M.INDENT, #M.INDENT + #r.id, "Identifier" }
        local state_col = #M.INDENT + #id_cell + #M.GAP
        marks[#marks + 1] = { #lines - 1, state_col, state_col + #r.state, highlight.state_group(r.state, r.category, r.source) }
        at[#lines] = { section = st, row = r }
      end
    end
    if st.warning then
      note(lines, marks, st.warning, "warning: ", "WarningMsg")
    end
    put(lines, marks, "")
    folds[heads[st]] = ">1"
    for lnum = heads[st] + 1, #lines do
      folds[lnum] = "1"
    end
  end
  put(lines, marks, M.KEYS, "Comment")
  folds[#lines] = "0"
  return lines, at, marks, heads, folds
end

--- The fold level of a line of the dashboard, from the last paint: what
--- 'foldexpr' evaluates in every window showing it; see open(). `0` before
--- any paint and past the last line.
---@param buf integer
---@param lnum integer 1-based
---@return string level
function M.fold(buf, lnum)
  local last = painted[buf]
  return last and last.folds[lnum] or "0"
end

-- The 'foldexpr' of the dashboard's windows, naming the buffer it folds.
local function foldexpr(buf)
  return ("v:lua.require'docket.list'.fold(%d, v:lnum)"):format(buf)
end

-- Sets the dashboard's window options on a window showing it, as
-- `:setlocal` sets them, so that another buffer shown in that window keeps
-- its own: `nowrap`, because a row is one line and `<CR>`, `w` and `R` act
-- on the row under the cursor, and a title wrapped onto a second screen line
-- would read as a row with no identifier; and a fold per section, through
-- fold(), with `foldtext` empty so that a closed section shows its header
-- line as painted. `foldlevel` is set to 99, which opens every section under
-- the editor's default of 0, only in a window whose 'foldexpr' is not yet
-- this buffer's, so a second `:Docket` leaves closed sections closed.
local function dress(win, buf)
  local expr = foldexpr(buf)
  local wo = vim.wo[win][0]
  if vim.wo[win].foldexpr ~= expr then
    wo.foldlevel = 99
  end
  wo.wrap = false
  wo.foldmethod = "expr"
  wo.foldexpr = expr
  wo.foldtext = ""
end

--- The dashboard buffer: the one already made, while it keeps its `nofile`;
--- a loaded buffer of that name -- a restored session's, or one `:b` loaded
--- after `:bdelete` -- taken over; or a new one. One of that name that is
--- not loaded is wiped first, since `:bdelete` left it so and showing it
--- would load it with the options set here reset.
---@return integer buf
function M.buffer()
  if dash and vim.api.nvim_buf_is_valid(dash) and vim.bo[dash].buftype == "nofile" then
    return dash
  end
  local buf
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(candidate) == M.NAME then
      buf = candidate
      break
    end
  end
  if buf and not vim.api.nvim_buf_is_loaded(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
    buf = nil
  end
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, M.NAME)
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = true
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = M.FILETYPE
  vim.api.nvim_clear_autocmds({ group = AUGROUP, buffer = buf })
  local function drop()
    states[buf] = nil
    painted[buf] = nil
    if dash == buf then
      dash = nil
    end
  end
  vim.api.nvim_create_autocmd("BufWipeout", { group = AUGROUP, buffer = buf, callback = drop })
  -- A window that showed this buffer before it was taken over -- a restored
  -- session's, or one `:b` loaded it in after `:bdelete` -- gets back the
  -- values it had then when the buffer returns to it, and open() dresses
  -- only the windows showing the buffer when it runs. So each window the
  -- buffer enters is dressed; BufWinEnter runs with that window current.
  -- It dresses only while the buffer keeps its `nofile`, because `:bdelete`
  -- leaves this autocommand in place and clears `buftype`, and what `:b`
  -- loads after it is not the dash.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = AUGROUP,
    buffer = buf,
    callback = function()
      if vim.bo[buf].buftype == "nofile" then
        dress(vim.api.nvim_get_current_win(), buf)
      end
    end,
  })
  -- `:e` and `:bdelete` both fire BufUnload while the buffer is still listed
  -- and `nofile`. Afterwards `:bdelete` has cleared `buftype` and `:e` has
  -- kept it, so the look waits until the command is done.
  vim.api.nvim_create_autocmd("BufUnload", {
    group = AUGROUP,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype ~= "nofile" then
          drop()
        end
      end)
    end,
  })
  dash = buf
  return buf
end

-- The sections closed in a window, by the key `painted` gives each, read off
-- the header lines of the last paint, which are what the window shows.
local function closed_in(win, last)
  return vim.api.nvim_win_call(win, function()
    local shut = {}
    for _, head in ipairs(last.heads) do
      if vim.fn.foldclosed(head.lnum) == head.lnum then
        shut[head.key] = true
      end
    end
    return shut
  end)
end

-- Opens every section in a window and closes the ones `shut` names. Both
-- commands raise E490 where they find no fold, which is every line of a
-- window whose 'foldmethod' was changed by hand to one that finds no fold in
-- the dash, such as marker, so each is guarded.
local function refold(win, heads, shut)
  vim.api.nvim_win_call(win, function()
    pcall(vim.cmd, "%foldopen!")
    for _, head in ipairs(heads) do
      if shut[head.key] then
        pcall(vim.cmd, head.lnum .. "foldclose")
      end
    end
  end)
end

--- Paints the buffer from its state, keeping each window's cursor on the row
--- it was on: an answer that adds or drops rows above it moves the row, and a
--- cursor left on the line number would be on another row, where `w` builds
--- that row's worktree. A row the answer dropped leaves the cursor on its
--- section's header. A cursor on a header stays on that section's header,
--- and so does one anywhere in a closed section, which shows only its
--- header: `j` and `k` onto a closed section stop on its first line, and a
--- cursor left on the line number would be in another section, where the
--- next `za` folds that one.
---
--- Each window showing the dash with its fold options keeps the sections it
--- had closed. A fold moves with the lines when a paint changes their count,
--- so with the first section closed, a row added to the second leaves the
--- second closed and the first open. The sections closed before the paint
--- are therefore recorded, by title and, where two sections share a title,
--- by their order, from the last paint's header lines, and after it every
--- section in that window is opened and the recorded ones closed. The fold
--- levels are stored before the lines are replaced, because replacing them
--- evaluates 'foldexpr' again, and levels stored afterwards would leave the
--- new lines at the old levels until `zx`.
---@param buf integer
function M.render(buf)
  local state = states[buf]
  if not state or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local held, closed = {}, {}
  local expr, last = foldexpr(buf), painted[buf]
  -- The section whose header the last paint put on each line.
  local head_on = {}
  for _, head in ipairs(last and last.heads or {}) do
    head_on[head.lnum] = head.key
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    held[win] = state.at[lnum]
    if not held[win] then
      -- A cursor that `zc` left on a section's note or its closing blank
      -- line sits inside the fold, whose first line is the header.
      local start = vim.api.nvim_win_call(win, function()
        return vim.fn.foldclosed(lnum)
      end)
      local key = head_on[start ~= -1 and start or lnum]
      held[win] = key and { key = key }
    end
    if last and vim.wo[win].foldexpr == expr then
      closed[win] = closed_in(win, last)
    end
  end
  local lines, at, marks, heads, folds = M.lines(state, os.time())
  state.at = at
  -- A title is the key, counted where two sections carry the same one, so
  -- that closing the first of them leaves the second open.
  local record, seen = { folds = folds, heads = {} }, {}
  for _, st in ipairs(state.sections) do
    local title = st.def.title
    seen[title] = (seen[title] or 0) + 1
    record.heads[#record.heads + 1] = { lnum = heads[st], key = ("%s\n%d"):format(title, seen[title]) }
  end
  painted[buf] = record
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, M.NS, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, M.NS, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
  for win, shut in pairs(closed) do
    refold(win, record.heads, shut)
  end
  local head_of = {}
  for _, head in ipairs(record.heads) do
    head_of[head.key] = head.lnum
  end
  for win, was in pairs(held) do
    local target
    if was.key then
      target = head_of[was.key]
    else
      target = heads[was.section]
      for lnum, found in pairs(at) do
        if found.section == was.section and found.row.id == was.row.id then
          target = lnum
          break
        end
      end
    end
    if target then
      vim.api.nvim_win_set_cursor(win, { target, 0 })
    end
  end
end

-- Whether an answer to a request that `round` of `state` started may paint:
-- the buffer is still the dashboard, loaded, `nofile` and holding that
-- state, and no refresh has started since. A request in flight is joined by
-- the section that replaced this one when the dashboard was reopened or
-- refreshed, so one answer can reach several waiters, and only the latest
-- may paint. nvim_buf_set_lines on an unloaded buffer loads it, so the paint
-- would undo a `:bunload`. A buffer `:bdelete` left keeps its state until
-- the BufUnload autocommand's scheduled look, and one entered with `:b`
-- before then is loaded with no `buftype`, where a paint leaves it modified
-- and `:qall` refuses with E37.
local function current(buf, state, round)
  return vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == "nofile"
    and states[buf] == state
    and state.round == round
end

-- Asks the adapter for one section's rows through the cache, so that a
-- refresh while an earlier one's request runs joins it, and paints the
-- answer. The query runs in the clone the dashboard shows, which the section
-- carries to the adapter as `cwd`.
local function fetch(buf, state, round, st, adapter)
  cache.fetch(st.key, function(deliver)
    adapter.rows(vim.tbl_extend("force", st.def, { cwd = state.root }), deliver)
  end, function(rows, err, warning)
    vim.schedule(function()
      if not current(buf, state, round) then
        return
      end
      st.status = nil
      if rows then
        -- The client's own order, because every default Jira query ends
        -- `ORDER BY updated DESC` and a section holds one adapter, so
        -- re-ordering by identifier here would discard what the query asked
        -- for and put the oldest ticket at the top.
        st.rows, st.written, st.error = rows, os.time(), nil
      else
        st.error = err
      end
      st.warning = warning
      M.render(buf)
    end)
  end)
end

-- Asks whether a section's backend is signed in, joining the check this
-- refresh already started for it, and then fetches the section's rows, or
-- puts the login command under it and asks nothing more of the backend. The
-- check runs in the clone the dashboard shows, as the rows do, so that `r`
-- after a `:cd` in the dashboard's tab reports the state of that clone's
-- host and not of the directory the tab moved to.
--
-- The answer is settled from a scheduled callback, on the main loop after
-- refresh() has returned, so every section of the backend has joined the
-- check by then and the waiters run where they can paint. auth.check()
-- answers before it returns when no process starts -- an adapter that does
-- not load, a client that is not installed -- and a settle made there would
-- free the key before the next section joined, which would then ask again:
-- for a module whose load raised, a second require answers "loop or previous
-- error" in place of the module's own message. A check that raises is
-- caught here for the same reason: flight settles a request that raises
-- where it raised, which is before the next section joins, so what it raised
-- is scheduled like an answer instead.
local function check(buf, state, round, st)
  local name = st.def.adapter
  checks:join(name, function(settle)
    local function later(adapter, err)
      vim.schedule(function()
        settle(adapter, err)
      end)
    end
    local ok, raised = pcall(auth.check, name, later, state.root)
    if not ok then
      later(nil, tostring(raised))
    end
  end, function(adapter, err)
    if not current(buf, state, round) then
      return
    end
    if adapter then
      st.status = "fetching"
      fetch(buf, state, round, st, adapter)
    else
      st.error, st.status = err, nil
    end
    M.render(buf)
  end)
end

--- Checks each backend's state and then fetches every section that has a
--- query, painting each section as it goes and holding the editor for
--- neither.
---
--- The state check runs once per backend rather than once per section, since
--- it spawns the client and the Jira sections share one answer; the sections
--- join it through `checks`, and it runs in the clone the dashboard shows. A
--- backend not signed in puts the login command under each of its sections
--- and asks nothing more of it. An answer from an earlier refresh, or from
--- before the dashboard was reopened, unloaded or wiped, paints nothing.
---
--- Called on the main loop, where every paint happens.
---@param buf integer
function M.refresh(buf)
  local state = states[buf]
  if not state then
    return
  end
  state.round = (state.round or 0) + 1
  local round = state.round
  checks:invalidate_all()
  local asking = {}
  for _, st in ipairs(state.sections) do
    if st.key then
      st.error, st.status = nil, "checking"
      asking[#asking + 1] = st
    end
  end
  M.render(buf)
  for _, st in ipairs(asking) do
    check(buf, state, round, st)
  end
end

--- Opens the dashboard for a clone in the current window: the sections, the
--- cached rows at once with their age, and a refresh behind them, which
--- paints each section as checking until its backend answers.
---
--- Every window showing the dashboard gets its window options, which
--- dress() lists. neovim keeps these values with the buffer, so they follow
--- it into a window that has not shown it, as an item buffer's wrap options
--- do; a window that showed it before is dressed by the BufWinEnter
--- autocommand buffer() sets when the buffer returns to it.
---@param found { root: string, bare: boolean } what repo.root() returned
---@return integer buf
function M.open(found)
  local sections, binding, binding_err = M.assemble(found)
  local buf = M.buffer()
  local state = {
    root = found.root,
    bare = found.bare,
    binding = binding,
    binding_err = binding_err,
    sections = {},
    at = {},
  }
  for index, def in ipairs(sections) do
    local st = { def = def }
    if def.query and def.adapter then
      -- A review client reads its project from the working directory, so the
      -- clone is part of what its rows answer; a JQL query names its own
      -- projects and its rows are the same in every clone.
      local scope = def.adapter ~= "jira" and found.root or nil
      st.key = cache.key(def.adapter, def.query, scope)
      local cached = cache.read(st.key)
      if cached then
        st.rows, st.written = cached.rows, cached.written
      end
    end
    state.sections[index] = st
  end
  states[buf] = state
  vim.api.nvim_set_current_buf(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    dress(win, buf)
  end
  M.refresh(buf)
  return buf
end

return M
