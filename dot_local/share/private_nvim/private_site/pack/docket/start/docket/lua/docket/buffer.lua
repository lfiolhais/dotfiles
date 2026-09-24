-- The item buffer: its read path, its region marks and its write path.
-- Imports render, diff, item, auth, highlight, cache, repo and the adapter
-- registry.
-- The buffer is a rendered document whose structure is invisible: nothing in
-- the text says where a region begins, and the marks below are what carry it.
-- Reading extmark ranges back out of the buffer is this module's job; deciding
-- what a save sends from them is diff's; sending it is write()'s, through the
-- adapter, which serialises the text into whatever its backend takes.
--
-- The buffer's name is `docket://<source>/<id>`, or
-- `docket://<source>/<project>/<id>` for a source in BY_PROJECT, whose
-- identifiers are numbered within a project: `!482` opened from clones of two
-- projects is two merge requests, and the project in the name keeps them in
-- two buffers. The name's project is read off `origin`, and the client picks
-- its own from the clone's remotes, so a read whose answer names another
-- project than the name is refused with nothing filled; read() says how. The
-- answer's path and the name's are compared through repo.same_project(),
-- without case. Under 'fileignorecase', the editor's default on macOS,
-- named() also matches names without case, as the editor does, so a clone
-- whose origin spells the path in another case opens the buffer that exists;
-- a second name would be refused with E95. With the option off the two
-- spellings are two buffers. A
-- source whose adapter names a `handoff` gets no item buffer
-- at all: read() hands the item to that plugin and the buffer `:e` made is
-- wiped once the plugin's own takes its window.
--
-- The buffer is `buftype=acwrite`,
-- which routes `:w` on a name that is not a file through the BufWriteCmd
-- autocommand; without it `:w` tries to create a file of that name. It is
-- `bufhidden=hide` and never `wipe`, because `wipe` overrides `hidden` and a
-- modified buffer then refuses every switch away with E37, trapping the editor
-- in it. It is unlisted, which keeps it out of the `badd` lines `:mksession`
-- writes and out of `:ls` and the buffer picker; a buffer shown in a window is
-- still recorded, as a `file docket://…` line. Restoring that session renames
-- an empty buffer to the item's name and fires no BufReadCmd, so no client
-- spawns at startup. What is left is an empty buffer that looks like a
-- ticket, with the item keymaps attached and no `docket` variable, where
-- `:w` reports that nothing is loaded and `:e` reads the item.
--
-- The region rules, stated because this is the part that gets built wrong:
--
--   * Each region is one extmark in REGIONS spanning its range, from column 0
--     of its first line to column 0 of the line after its last, with
--     `right_gravity=false` and `end_right_gravity=true`, so that text put
--     where either end sits goes inside. That covers a line opened or put
--     above the first line or below the last -- `O`, `o`, a linewise `P` or
--     `p`, `:put` -- and text typed on the blank line after a region, with or
--     without <CR>. A `:sort` over the region's lines replaces them in one
--     change, which collapses the range and inserts the sorted lines where it
--     collapsed; a `!` filter inserts its output below the last line and then
--     deletes the old lines; and lines put back after every line was deleted
--     go where the range collapsed. The same two gravities take the new lines
--     in whole each time. Deleting every line leaves an empty range, which
--     the save reports as emptied. A blank line joined at either end is
--     harmless, because diff trims leading and trailing blank lines.
--   * Each region also has an edge: a point extmark in EDGES where its range
--     ended at the read, with `right_gravity=false`, so text inserted where
--     it sits goes after it while the range's end takes that text in. The
--     two part only there, which is what tells text typed at the start of the
--     line after a region apart from the region's own.
--   * And each region has a head: a point extmark in HEADS at the end of the
--     nearest line above its first line that holds text -- its author line,
--     or the title above the body -- with `right_gravity=true`, so it stays
--     after anything typed at the end of that line. Text put at the start of
--     the region's first line is on another line and leaves it where it is.
--     The blank line between the title and the body is passed over: deleting
--     it does not refuse the save, and a head on it would fall to the start
--     of the body's first line and move with text typed there, so that a
--     later `J` of the title onto the body would read that text as the
--     title's.
--   * A region's text is what lies between the mark's ends, to the column:
--     the whole of a line only when an end sits at column 0. An end that
--     sits part-way along a line whose rest holds text shares that line with
--     the text outside the regions. A `J` of the region's last line onto an
--     author line leaves it so, and so does text typed at the start of an
--     author line once the blank line above it is deleted, because the end
--     takes that text in. So the region stops at its end's edge when the
--     edge is on that line, and at the start of the line when it is not,
--     which puts the space a `J` inserts and anything typed there outside,
--     where the save compares it.
--   * A start that sits part-way along a line is where the line above was
--     joined onto the region, as a `J`, a `gJ` or a `gq` over the author line
--     does, and the head is where that line's own text ends. So the region
--     starts at its head when the head lies after the start and no further
--     than the end. A `J` puts the space it inserts before the head, which
--     leaves that space outside, and text typed where the two lines meet --
--     at the end of the author line's words, or after that space -- goes
--     before the head as well, where the save refuses it as an edit to the
--     author line. When the head is not after the start, the join inserted
--     nothing there -- a `gJ` never does, nor does a `J` onto a first line
--     that is empty or opens with `)` -- and a `J` that did insert a space
--     put it before both, so every space from the start on is the region's
--     own and is kept. Only a region with no head, which populate() and
--     compose() never leave, drops a single space before the start's first
--     word, taking it for the one a `J` inserts.
--   * The mark is not set with `invalidate`. That option flags a range
--     invalid once every character of it is deleted, and the flag stays
--     through the lines a `:sort` or a `P` then inserts where the range
--     collapsed, which are the region's text.
--   * An edit the marks cannot follow refuses the save instead: a `:sort` or
--     a `:move` across a region's boundary leaves two ranges overlapping or
--     an end above its start, and a line moved or typed where no region
--     reaches is text a save would never send. So the text outside the
--     regions is kept as loaded, and the save compares it too; see diff.lua.
--   * A side table maps each mark, by its id, to the region's identifier, kind,
--     owner and the ids of its edge and its head. The snapshot the compare
--     needs -- each region's kind, owner, editable, reason, lines as loaded
--     and `crlf` where its body arrived with CRLF line ends, and the text
--     outside the regions -- sits beside it in the buffer variable
--     `docket`, in exactly the shape diff.plan() takes, and so does each
--     comment's `updated` as loaded, under `stamps`, for the write's conflict
--     check.
--   * A comment not yet posted is a region compose() opens at the end of the
--     buffer, under the identifier NEW. The write posts it, and the read that
--     follows is what names the comment it became. The author line compose()
--     writes above it joins the text outside the regions the snapshot keeps,
--     and the save expects it there only while the buffer holds its text:
--     gone, it was deleted, and deleting it is no change; still there, inside
--     a region after a `:sort`, it refuses the save as any line of the header
--     moved into a region does. compose() is an edit like any other, and `u`
--     takes its lines out again. The region's range then collapses where the
--     last region ends, and a save sends what it sent before compose() and
--     skips the comment as empty. Text a later put or undo puts where both
--     ranges end is the last region's, because the comment is withdrawn; see
--     read_marks(). A redo puts the lines back where both ends now sit, both
--     ranges take them in, and the save refuses the two as overlapping until
--     `u` again.
--   * An editable region's lines carry DocketEditable through one extmark per
--     line with `line_hl_group`, in DECOR rather than REGIONS, so that the
--     region mark stays a single range. Whether one ranged mark's
--     `line_hl_group` covers every row is undocumented, and per-line marks do
--     not depend on the answer.
--
-- The Docket* groups the decoration uses are named and defined in
-- highlight.lua.

local adapters = require("docket.adapters")
local auth = require("docket.auth")
local cache = require("docket.cache")
local diff = require("docket.diff")
local highlight = require("docket.highlight")
local item = require("docket.item")
local render = require("docket.render")
local repo = require("docket.repo")

local M = {}

M.SCHEME = "docket://"
-- The filetype an item buffer carries, which is what the buffer-local
-- keymaps attach to.
M.FILETYPE = "docket"
-- The region marks, one ranged extmark per region.
M.REGIONS = vim.api.nvim_create_namespace("docket/regions")
-- Each region's edge, one point extmark per region; see the region rules.
M.EDGES = vim.api.nvim_create_namespace("docket/edges")
-- Each region's head, one point extmark per region; see the region rules.
M.HEADS = vim.api.nvim_create_namespace("docket/heads")
-- The line highlights and the highlighted runs, which are decoration only.
M.DECOR = vim.api.nvim_create_namespace("docket/decor")
-- The omnifunc an item buffer names, and the module that holds it. prepare()
-- sets the option only when that module loads: mini.completion runs its
-- fallback after its delay whenever no language server answers, which is
-- every keystroke in an item buffer, so an omnifunc naming an absent module
-- would print a `module not found` dump repeatedly while a comment is typed.
M.COMPLETE = "docket.complete"
M.OMNIFUNC = "v:lua.require'" .. M.COMPLETE .. "'.omnifunc"
-- The reason a posted comment's region carries until a read names the
-- comment it became. comment_create answers with no identifier -- acli's
-- `--json` is a bulk summary -- so the identifier comes from the read that
-- follows the post, and when that read fails the region is held read-only
-- under this reason rather than left NEW, which the next :w would post again.
-- `:e` refuses a buffer holding unsaved edits, and `:e!` discards them, so the
-- reason says which to use.
M.POSTED =
  "posted; the comment it became is known once the item is read again: :e reads it when nothing is unsaved, and otherwise yank what to keep before :e!"

-- Each populate()'s number, kept in the buffer variable, so a write that
-- outlives a read can tell the buffer was read again under it.
local loads = 0

-- The buffers with a write in flight: from the plan until the read that
-- follows the calls has landed, since that read is what names a posted
-- comment and a second :w before it would post the comment twice.
local writing = {}

-- The read command behind M.read() and open(), assigned after M.read(),
-- which calls it.
local read

-- The sources whose identifiers are numbered within a project, so that one
-- identifier names a different item in each: GitLab's `!482`. An item buffer
-- of one of these carries the project in its name, the path repo.project()
-- reads off the origin of the clone it was opened from, and a read holds the
-- project the answer names against it. A Jira key names its project already,
-- and a GitHub pull request never opens in an item buffer.
M.BY_PROJECT = { glab = true }

--- The buffer name for an item: `docket://<source>/<id>`, or
--- `docket://<source>/<project>/<id>` when a project is given.
---@param source string the adapter's name
---@param id string the item's identifier
---@param project string|nil the project path, for a source in BY_PROJECT
---@return string name
function M.name(source, id, project)
  if project then
    return M.SCHEME .. source .. "/" .. project .. "/" .. id
  end
  return M.SCHEME .. source .. "/" .. id
end

--- The source, identifier and project a buffer name carries, or nil for a
--- name that is not an item's. The identifier is the last `/`-separated part,
--- since none of the backends' identifiers holds a `/`, and the project is
--- whatever lies between the source and it, nil when nothing does.
---@param name string
---@return string|nil source
---@return string|nil id
---@return string|nil project
function M.parse(name)
  if name:sub(1, #M.SCHEME) ~= M.SCHEME then
    return nil, nil, nil
  end
  local source, rest = name:sub(#M.SCHEME + 1):match("^([^/]+)/(.+)$")
  if not source then
    return nil, nil, nil
  end
  local project, id = rest:match("^(.+)/([^/]+)$")
  if not project then
    return source, rest, nil
  end
  return source, id, project
end

--- Sets the options every item buffer carries. Idempotent, because the read
--- command runs on a buffer `:e docket://…` made as well as on one open()
--- made, and both need them.
---@param buf integer
function M.prepare(buf)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  if pcall(require, M.COMPLETE) then
    vim.bo[buf].omnifunc = M.OMNIFUNC
    -- mini.completion's fallback is keyword completion; this buffer-local
    -- override, which that module documents, makes it the omnifunc instead.
    vim.b[buf].minicompletion_config = { fallback_action = "<C-x><C-o>" }
  end
  if vim.bo[buf].filetype ~= M.FILETYPE then
    vim.bo[buf].filetype = M.FILETYPE
  end
end

-- One highlighted run, as an extmark in DECOR.
local function run(buf, row, col, length, group)
  if length > 0 then
    vim.api.nvim_buf_set_extmark(buf, M.DECOR, row, col, { end_col = col + length, hl_group = group })
  end
end

-- The runs the header and each author line carry, placed from render's line
-- shape: the header is the identifier, the state when there is one, the
-- assignee and the update time, joined by render.SEPARATOR; each comment's
-- author line sits one line above its region and starts with the name.
local function decorate(buf, it, lines, regions)
  local sep = #render.SEPARATOR
  local col = #it.id + sep
  if it.state ~= "" then
    run(buf, 0, col, #it.state, highlight.state_group(it.state, it.category))
    col = col + #it.state + sep
  end
  local assignee = lines[1]:sub(col + 1):match("^(.-)" .. render.SEPARATOR) or lines[1]:sub(col + 1)
  run(buf, 0, col, #assignee, highlight.USER)
  for _, region in ipairs(regions) do
    if region.kind == item.COMMENT then
      local row = region.first_line - 2
      local author = lines[row + 1]:match("^(.-)" .. render.SEPARATOR) or lines[row + 1]
      run(buf, row, 0, #author, highlight.USER)
    end
    if region.editable then
      for row = region.first_line - 1, region.last_line - 1 do
        vim.api.nvim_buf_set_extmark(buf, M.DECOR, row, 0, { line_hl_group = highlight.EDITABLE })
      end
    end
  end
end

-- Sets a region mark from `from` to `to`, each a `{ row, col }` pair,
-- 0-based as extmarks take them, or moves the mark `id` names there. The
-- region rules above say why these gravities and no `invalidate`.
local function set_region(buf, from, to, id)
  return vim.api.nvim_buf_set_extmark(buf, M.REGIONS, from[1], from[2], {
    id = id,
    end_row = to[1],
    end_col = to[2],
    right_gravity = false,
    end_right_gravity = true,
  })
end

-- Sets a region's edge at `at`, a `{ row, col }` pair, and returns its id.
local function set_edge(buf, at)
  return vim.api.nvim_buf_set_extmark(buf, M.EDGES, at[1], at[2], { right_gravity = false })
end

-- Sets a region's head at the end of the nearest line from `row` upwards
-- that holds text, `row` being the line above its first line, and returns
-- its id; the region rules say why a blank line is passed over.
local function set_head(buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  while row > 0 and line:match("^%s*$") do
    row = row - 1
    line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  end
  return vim.api.nvim_buf_set_extmark(buf, M.HEADS, row, #line, { right_gravity = true })
end

-- Whether position `a` comes before position `b`.
local function before(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
end

-- Line `row` of the buffer, or "" past its end.
local function line_at(buf, row)
  return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

-- The text from `from` up to `to` as lines: the first from from's column, the
-- last up to to's, and none at all for a range that is empty.
local function between(buf, from, to)
  if not before(from, to) then
    return {}
  end
  local lines = vim.api.nvim_buf_get_lines(buf, from[1], to[2] > 0 and to[1] + 1 or to[1], false)
  if #lines == 0 then
    return {}
  end
  if to[2] > 0 then
    lines[#lines] = lines[#lines]:sub(1, to[2])
  end
  lines[1] = lines[1]:sub(from[2] + 1)
  return lines
end

-- Where a region's text begins and ends, from its mark's ends `from` and `to`,
-- its `edge` and its `head`, each nil when the region has none. The region
-- rules above say why a line shared with the text outside the regions is read
-- this way. Whatever this leaves out of the region lies outside every region,
-- where the frame reads it, so nothing on the line goes unread.
local function bounds(buf, from, to, edge, head)
  local s, e = from, to
  if s[2] > 0 then
    if head and before(s, head) and not before(to, head) then
      s = head
    elseif not head and line_at(buf, s[1]):sub(s[2] + 1):match("^ %S") then
      s = { s[1], s[2] + 1 }
    end
  end
  if e[2] > 0 and line_at(buf, e[1]):sub(e[2] + 1):match("%S") then
    e = (edge and edge[1] == e[1]) and edge or { e[1], 0 }
  end
  -- Both ends moved in on one line can cross. The region is then empty,
  -- and the frame reads the line once, from the end.
  if before(e, s) then
    s = e
  end
  return s, e
end

-- Where the point mark `id` in namespace `ns` is now, or nil for no id.
local function point_at(buf, ns, id)
  if id then
    local at = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
    if at[1] then
      return { at[1], at[2] }
    end
  end
  return nil
end

-- The author line compose() writes above a comment it opens.
local AUTHOR = "me" .. render.SEPARATOR .. "not posted"

-- `frame`, the text outside the regions as the snapshot keeps it, less each
-- AUTHOR entry compose() added to it that the buffer no longer holds. An
-- author line compose() wrote is decoration, and one whose text is nowhere in
-- the buffer was deleted, by hand or by a `u` of compose(), which is no
-- change. One whose text is still there, inside a region after a `:sort`,
-- stays expected outside them, so the save refuses it rather than send it.
local function held(buf, frame)
  local drop = 0
  for _, text in ipairs(frame) do
    if text == AUTHOR then
      drop = drop + 1
    end
  end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local at = line:find(AUTHOR, 1, true)
    while at do
      drop = drop - 1
      at = line:find(AUTHOR, at + #AUTHOR, true)
    end
  end
  local kept = {}
  for index = #frame, 1, -1 do
    if frame[index] == AUTHOR and drop > 0 then
      drop = drop - 1
    else
      table.insert(kept, 1, frame[index])
    end
  end
  return kept
end

-- Whether the region mark `known` is a comment compose() opened whose author
-- line the buffer no longer holds, per held(). read_marks() takes it as
-- withdrawn when its range also runs into another's. `state` is the buffer
-- variable `docket`, or at the read a table of the marks alone.
local function withdrawn(buf, state, known)
  local frame = state.snapshot and state.snapshot.frame
  return known.id == diff.NEW and frame ~= nil and #held(buf, frame) < #frame
end

-- Every region mark `state.marks` knows, read out of the buffer: `current`
-- and `frame` in the shapes diff.plan() takes. The marks are walked in the
-- order they start in, and one that starts before the one furthest along has
-- ended overlaps it, so both are reported so rather than read. An empty
-- range holds no text, so it overlaps nothing, wherever it sits -- which also
-- makes the order of two marks that start together immaterial. The text
-- between one region and the next is the frame.
--
-- A mark whose end is above its start is reported as reversed rather than
-- read: its range is empty, and read as one it would be skipped as emptied.
-- A `:move` of lines holding a region's first line to below its last does
-- it.
--
-- A comment compose() opened whose lines are all gone, by a `u` of compose()
-- or by hand, has its range collapsed where the last region's ends. Text an
-- undo or a put puts back there goes into both, and the two then overlap.
-- When the author line compose() wrote is gone as well -- see withdrawn() --
-- the comment is read as empty and left out of the walk, so the text is the
-- last region's. Its own text cannot be in the other range: a range's end
-- moves past only what is inserted where it sits. With its lines back, as a
-- redo of compose() puts them, the author line is back too, and the two
-- overlap as any two do.
local function read_marks(buf, state)
  local found, current, frame = {}, {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, M.REGIONS, 0, -1, { details = true })) do
    local known = state.marks[tostring(mark[1])]
    if known then
      local from, to = { mark[2], mark[3] }, { mark[4].end_row, mark[4].end_col }
      if before(to, from) then
        current[known.id] = { reversed = true }
      else
        found[#found + 1] = {
          id = known.id,
          from = from,
          to = to,
          edge = point_at(buf, M.EDGES, known.edge),
          head = point_at(buf, M.HEADS, known.head),
          withdrawn = withdrawn(buf, state, known),
        }
      end
    end
  end
  for index = #found, 1, -1 do
    local region = found[index]
    if region.withdrawn and before(region.from, region.to) then
      for _, other in ipairs(found) do
        if other ~= region and before(other.from, other.to) and before(other.from, region.to) and before(region.from, other.to) then
          table.remove(found, index)
          current[region.id] = { lines = {} }
          break
        end
      end
    end
  end
  table.sort(found, function(a, b)
    return before(a.from, b.from)
  end)
  local function outside(from, to)
    for index, line in ipairs(between(buf, from, to)) do
      if not line:match("^%s*$") then
        frame[#frame + 1] = { row = from[1] + index, text = vim.trim(line) }
      end
    end
  end
  -- `at` is where the frame is read from next: the end of the last region
  -- read, which a line shared with the text outside puts before its mark's.
  local at, furthest = { 0, 0 }, nil
  for _, region in ipairs(found) do
    if furthest and before(region.from, region.to) and before(region.from, furthest.to) then
      current[region.id] = { overlaps = furthest.id }
      current[furthest.id] = { overlaps = region.id }
      if before(at, region.to) then
        at = region.to
      end
    else
      local s, e = bounds(buf, region.from, region.to, region.edge, region.head)
      outside(at, s)
      current[region.id] = { lines = between(buf, s, e) }
      if before(at, e) then
        at = e
      end
    end
    if not furthest or before(furthest.to, region.to) then
      furthest = region
    end
  end
  outside(at, { vim.api.nvim_buf_line_count(buf), 0 })
  return current, frame
end

-- The frame as the snapshot keeps it: the text of each line alone.
local function texts(frame)
  return vim.tbl_map(function(line)
    return line.text
  end, frame)
end

--- Fills a buffer with an item: the lines, one region mark per region, the
--- decoration, and the snapshot in the buffer variable `docket`, beside each
--- comment's `updated` as loaded under `stamps`, which the write path's
--- conflict check compares, the account's own identifier under `me`, the
--- item's `ref`, which every later call about the item is given -- see
--- M.target() -- and the `project` the buffer's name carries, nil when it
--- carries none.
---
--- The lines are set with undo off, so that an undo after the read does not
--- empty the buffer; `modified` is cleared after, because the read is not an
--- edit.
---@param buf integer
---@param it table the item, as item.new builds it
---@param opts { now: integer|nil }|nil passed to render
function M.populate(buf, it, opts)
  local lines, regions = render.render(it, opts)
  M.prepare(buf)
  vim.api.nvim_buf_clear_namespace(buf, M.REGIONS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, M.EDGES, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, M.HEADS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, M.DECOR, 0, -1)
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = undolevels

  local snapshot, marks = { regions = {} }, {}
  for _, region in ipairs(regions) do
    local mark = set_region(buf, { region.first_line - 1, 0 }, { region.last_line, 0 })
    -- Keyed by the id as a string: a buffer variable turns integer keys into
    -- a list.
    marks[tostring(mark)] = {
      id = region.id,
      kind = region.kind,
      owner = region.owner,
      edge = set_edge(buf, { region.last_line, 0 }),
      head = set_head(buf, region.first_line - 2),
    }
    snapshot.regions[region.id] = {
      kind = region.kind,
      owner = region.owner,
      editable = region.editable,
      reason = region.reason,
      lines = region.lines,
      crlf = region.crlf,
    }
  end
  snapshot.frame = texts(select(2, read_marks(buf, { marks = marks })))
  decorate(buf, it, lines, regions)
  local stamps = {}
  for _, comment in ipairs(it.comments) do
    stamps[comment.id] = comment.updated
  end
  loads = loads + 1
  vim.b[buf].docket = {
    source = it.source,
    id = it.id,
    title = it.title,
    url = it.url,
    me = it.me,
    ref = it.ref,
    project = select(3, M.parse(vim.api.nvim_buf_get_name(buf))),
    load = loads,
    snapshot = snapshot,
    marks = marks,
    stamps = stamps,
  }
  vim.bo[buf].modified = false
end

--- What the buffer holds now, read through the region marks, in the shapes
--- diff.plan() takes. `current` has one entry per region: `{ lines }`, its
--- text as the region rules at the top of this file read it, empty once
--- every line of it is deleted, and for a comment compose() opened that
--- read_marks() finds withdrawn; `{ overlaps = id }` for a region whose range
--- runs into another's; or `{ reversed = true }` for one whose end is above
--- its start. `frame` is each non-blank line outside the regions, trimmed,
--- with its 1-based number, as `{ row, text }`.
---@param buf integer
---@return table<string, table> current
---@return { row: integer, text: string }[] frame
function M.current(buf)
  local state = vim.b[buf].docket or { marks = {} }
  local current, frame = read_marks(buf, state)
  return current, frame
end

--- What an adapter call about the buffer's item is given in place of its
--- identifier: the reference the item was read with, when its adapter answered
--- one, and the identifier otherwise. adapters/init.lua says why a reference
--- exists: on GitLab it names the clone the buffer's text came from, so a save,
--- a state change and the reads around them go to that clone's merge request
--- whichever mode was entered since.
---@param state table the buffer variable `docket`
---@return string|table id
function M.target(state)
  return state.ref or state.id
end

--- The snapshot the read command stored, in the shape diff.plan() takes.
---@param buf integer
---@return { regions: table<string, table> }|nil snapshot nil before a read
function M.snapshot(buf)
  local state = vim.b[buf].docket
  return state and state.snapshot or nil
end

--- What a save would send, from the snapshot and the marks as they stand.
--- The text outside the regions is compared with the snapshot's less each
--- author line compose() wrote that the buffer no longer holds; see held().
---@param buf integer
---@return { calls: table[], skipped: table[], refused: table[] }|nil plan nil before a read
function M.plan(buf)
  local snapshot = M.snapshot(buf)
  if not snapshot then
    return nil
  end
  local current, frame = M.current(buf)
  if snapshot.frame then
    snapshot.frame = held(buf, snapshot.frame)
  end
  return diff.plan(snapshot, current, frame)
end

--- The read command: the state check, then the item from its adapter, then
--- populate(). Runs on `:Docket <id>` and on `:e` in the buffer.
---
--- The state check comes first and reports the login command rather than
--- prompting, as every mode does. It blocks, so a mode asks it once at
--- entry: a caller that has already asked passes the adapter it got, and the
--- check runs here only when none is passed, which is the `:e` path, where
--- there is no caller to have asked. It runs where the read is about to: in
--- the clone the buffer's reference names, when it holds one, and in the
--- editor's directory otherwise, because a client's verdict follows the host
--- its working directory names, and `:e` has emptied the buffer by the time
--- the check runs, so a verdict from another clone would refuse a read that
--- succeeds. The adapter's callback arrives in a fast-event context, so the
--- buffer work is scheduled; a buffer closed while the client ran is left
--- alone.
---
--- A buffer holding unsaved edits is not read into, whether it held them
--- when the read was asked for or they were typed while the client ran,
--- because populate() replaces every line with undo off and nothing brings
--- the edits back. The read is refused with a warning naming `:e!`. Only
--- open() reaches a modified buffer at the start, since `:e` refuses one
--- and `:e!` clears `modified` before the read command runs.
---
--- A buffer already holding the item is read again through M.target(), the
--- reference its last read answered, so `:e`, `:e!` and the read after a state
--- change stay with the clone the buffer's text came from. `:e` has emptied
--- the buffer before its read command runs, and that command clears the
--- buffer variable, so it hands over the variable as it stood, as `held`.
--- open() reads by the identifier alone, in the clone its caller's state
--- check ran in -- the `cwd` open() was given, or the editor's directory --
--- and names the buffer after that clone's project.
---
--- A read with no reference to go by, of a name that carries a project, reads
--- by the identifier in the clone the editor is in, so it is refused unless
--- that clone's project is the name's: otherwise the buffer would hold the
--- same number from another project under this one's name. That is a name
--- typed by hand, a buffer a session restored, or one whose last read
--- failed. A source in BY_PROJECT whose name carries no project is refused
--- too, naming `:Docket <id>`, which builds the name.
---
--- An answer that names its project is held against the name's, and one
--- naming another is refused with nothing filled. The path alone is
--- compared: the host an ssh origin names need not be the one the instance's
--- web addresses carry, so a project of the same path on another host -- a
--- mirror kept as another remote -- fills the buffer. The name's project is
--- what `origin` names, and the client picks its own from the clone's
--- remotes: glab reads one of them, and which it prefers in a clone with
--- `upstream` beside `origin`, the usual fork, is unobserved. Were it
--- `upstream`, the buffer would hold that project's item under the fork's
--- name, and `gx` would open an address the name contradicts. The refusal
--- names both projects, the clone to open the item from, and, for a clone
--- whose origin spells the one project another way, the `git remote
--- set-url` that makes the two agree. An answer that names no project --
--- glab.project_of() says when -- is compared with nothing and fills the
--- buffer.
---
--- On a source whose adapter names a `handoff`, the item is handed to that
--- plugin with M.hand_off() rather than read, and the buffer is made
--- `bufhidden=wipe`, so it is gone once the plugin's own buffer takes its
--- window. It is left, empty and not modifiable, when the handoff fails,
--- which is reported.
---@param buf integer
---@param on_done fun(ok: boolean, message: string|nil)|nil
---@param adapter table|nil the adapter auth.ready() handed the caller
---@param held table|nil the buffer variable `docket` as it stood before `:e` emptied the buffer; nil reads the variable itself
function M.read(buf, on_done, adapter, held)
  return read(buf, on_done, adapter, false, held)
end

-- Hands the buffer's item to the plugin its adapter names, for read(). On `:e`
-- this runs inside the buffer's own read command, and the handoff shows the
-- plugin's buffer in the current window, so it is scheduled to run once `:e`
-- has finished with this one. UNVERIFIED: that `Octo pr edit`, and `Octo
-- <address>` for a dashboard row, show the pull request in the current
-- window, which is what wipes this buffer, was run only against a stand-in
-- command. `:e docket://gh/\#<n>` with octo.nvim installed settles it: `:ls!`
-- then lists no `docket://gh/` buffer.
local function read_handed_off(buf, source, id, adapter, finish)
  vim.bo[buf].buflisted = false
  vim.bo[buf].bufhidden = "wipe"
  -- `wipe` refuses every switch away from a modified buffer with E37, and
  -- this one holds nothing to save, so nothing can be typed into it.
  vim.bo[buf].modifiable = false
  if not adapter then
    local err
    adapter, err = auth.ready(source)
    if not adapter then
      return finish(false, err)
    end
  end
  vim.schedule(function()
    M.hand_off(adapter, id, finish)
  end)
end

-- Why a read with no reference to go by is refused, or nil when the clone
-- the editor is in is the project the name carries, compared as
-- repo.same_project() compares, so that a clone whose origin spells the path
-- in another case reads it; see M.read().
local function elsewhere(name, id, project)
  local here, err = repo.project(vim.fn.getcwd())
  if here and repo.same_project(here, project) then
    return nil
  end
  if not here then
    -- `err` is spawn.message() output, several lines ending in a newline, so
    -- it goes last, trimmed, under the line that says what to do.
    return ("%s: :e reads it only from a clone of %s, and the editor's directory names no project; :tcd into a clone of %s and :e again\n%s"):format(
      name,
      project,
      project,
      vim.trim(err)
    )
  end
  return ("%s: the editor is in a clone of %s, whose %s is another; :e reads this one from a clone of %s"):format(
    name,
    here,
    id,
    project
  )
end

-- Why a read whose answer names another project than the name is refused;
-- see M.read(). `source` is one in BY_PROJECT, and `url` is the address the
-- answer carries, from which repo.set_url_remedy() makes the second remedy,
-- for a clone whose origin spells this one project another way than the
-- instance writes it: the first remedy, a clone whose origin is the answered
-- path, names no clone such an origin can be. Both are given, since the
-- refusal cannot tell a fork's clone from one of these.
local function misnamed(name, source, id, project, answered, url)
  return ("%s: %s answered %s of %s, and the name, read off origin, says %s, so nothing is filled; :Docket %s from a clone whose origin is %s opens that one under its own name%s"):format(
    name,
    source,
    id,
    answered,
    project,
    id,
    answered,
    repo.set_url_remedy(url, answered) or ""
  )
end

-- The read command, with `fresh` set for open(), which reads by the name's
-- identifier whatever reference the buffer holds, `held` as M.read() takes
-- it, and `cwd` as open() takes it: the clone the state check runs in when
-- none was made yet, so that the read follows the name.
read = function(buf, on_done, adapter, fresh, held, cwd)
  local function finish(ok, message, level)
    if message then
      vim.notify(message, level or (ok and vim.log.levels.WARN or vim.log.levels.ERROR))
    end
    if on_done then
      on_done(ok, message)
    end
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local source, id, project = M.parse(name)
  if not source then
    return finish(false, ("%s is not an item buffer; the name is %s<source>/<id>"):format(name, M.SCHEME))
  end
  local function edited()
    return finish(
      false,
      ("%s holds unsaved edits, so the item is not read into it; :e! discards them and reads it"):format(name),
      vim.log.levels.WARN
    )
  end
  if vim.bo[buf].modified then
    return edited()
  end
  local module = adapters.get(source)
  if module and module.handoff then
    return read_handed_off(buf, source, id, adapter, finish)
  end
  if M.BY_PROJECT[source] and not project then
    return finish(
      false,
      ("%s names no project, and %s numbers its items within one; :Docket %s opens it from a clone of its project"):format(
        name,
        source,
        id
      )
    )
  end
  M.prepare(buf)
  if held == nil then
    held = vim.b[buf].docket
  end
  local asked = id
  if not fresh and type(held) == "table" and held.source == source and held.id == id and held.project == project then
    asked = M.target(held)
  end
  if not adapter then
    -- Where the read runs: the reference's clone, or open()'s. The adapter
    -- takes the directory of its later calls from this check, so a bare
    -- identifier is read there too.
    local err
    adapter, err = auth.ready(source, cwd or (type(asked) == "table" and asked.cwd or nil))
    if not adapter then
      return finish(false, err)
    end
  end
  if project and not fresh and asked == id then
    local refused = elsewhere(name, id, project)
    if refused then
      return finish(false, refused)
    end
  end
  adapter.item(asked, function(it, item_err, me_err)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if not it then
        return finish(false, ("%s: %s"):format(name, item_err))
      end
      if project and it.project and not repo.same_project(it.project, project) then
        return finish(false, misnamed(name, source, id, project, it.project, it.url))
      end
      if vim.bo[buf].modified then
        return edited()
      end
      M.populate(buf, it)
      finish(true, me_err)
    end)
  end)
end

--- The buffer with this name, or nil.
---
--- Compared for equality over every buffer, because `bufnr(name)` matches its
--- argument as a pattern: with `docket://jira/PROJ-142` open it answers that
--- buffer for `docket://jira/PROJ-1` too, and `:Docket PROJ-1` would then
--- switch to another ticket and re-read it. Under 'fileignorecase', the
--- editor's default on macOS, the compare drops case, because the editor's
--- own does: nvim_buf_set_name refuses a name another buffer carries in
--- another case with E95, so `docket://glab/Acme/Payments/!482` is the buffer
--- `:Docket !482` from a clone whose origin spells the path `acme/payments`
--- gets, and it is read again from that clone. With the option off the two
--- are two buffers, as the editor has them.
---@param name string
---@return integer|nil buf
function M.named(name)
  local fold = vim.o.fileignorecase
  if fold then
    name = name:lower()
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local have = vim.api.nvim_buf_get_name(buf)
    if fold then
      have = have:lower()
    end
    if have == name then
      return buf
    end
  end
  return nil
end

--- Hands an item to the plugin its adapter names in `handoff`, through the
--- adapter's item(), which opens it there and answers no item. `on_done` is
--- called once, on the main loop, with whether it opened and, when it did
--- not, the adapter's reason; an item() that raises has not opened it. `id`
--- goes to item() as given: the identifier alone, or the reference `{ id,
--- url }` adapters/init.lua describes, which the dashboard passes for a row
--- so that the plugin is told the repository the row's address names.
---@param adapter table an adapter whose `handoff` is set
---@param id string|table the identifier, or `{ id, url }`
---@param on_done fun(ok: boolean, message: string|nil)
function M.hand_off(adapter, id, on_done)
  local asked, raised = pcall(adapter.item, id, function(_, err)
    vim.schedule(function()
      on_done(err == nil, err)
    end)
  end)
  if not asked then
    on_done(false, tostring(raised))
  end
end

--- Opens an item in the current window: the buffer of that name, made when
--- there is none, then read. The buffer is found through named(), so under
--- 'fileignorecase' a name that differs from an open buffer's in case alone
--- opens that buffer, read afresh from this clone, rather than a second the
--- editor would refuse. On a source in BY_PROJECT the name carries the
--- project of the clone the item is opened from, from repo.project(): `cwd`
--- when the caller passes one -- the dashboard passes the root it shows, so
--- that `<CR>` on a row names the buffer from the clone the row was fetched
--- in, whatever the tab's directory is by then -- and the editor's directory
--- otherwise, which is `:Docket <id>`. The read runs in that clone as well:
--- a caller that made the state check there passes the adapter it got, and
--- one that passes none has the check made here, in `cwd`. Where
--- repo.project() names no project -- outside a clone, or in one whose
--- origin is missing or names none -- nothing opens and the reason is
--- reported, naming the directory it read when that is `cwd`, since a `:tcd`
--- changes nothing for a caller that passes one.
---@param source string the adapter's name
---@param id string
---@param on_done fun(ok: boolean, message: string|nil)|nil
---@param adapter table|nil the adapter auth.ready() handed the caller, for read()
---@param cwd string|nil the clone the item is opened from; nil reads the editor's directory
---@return integer|nil buf nil when nothing opened
function M.open(source, id, on_done, adapter, cwd)
  local project
  if M.BY_PROJECT[source] then
    local err
    project, err = repo.project(cwd or vim.fn.getcwd())
    if not project then
      -- `err` is spawn.message() output, several lines ending in a newline,
      -- so it goes last, trimmed, under the line that says what to do.
      local message
      if cwd then
        message = ("%s: %s numbers its items within a project, and %s, the clone it is opened from, names none; :Docket %s from a clone of the project opens it\n%s"):format(
          id,
          source,
          cwd,
          id,
          vim.trim(err)
        )
      else
        message = ("%s: %s numbers its items within a project, and the editor's directory names none; :tcd into a clone of the project and run :Docket %s again\n%s"):format(
          id,
          source,
          id,
          vim.trim(err)
        )
      end
      vim.notify(message, vim.log.levels.ERROR)
      if on_done then
        on_done(false, message)
      end
      return nil
    end
  end
  local name = M.name(source, id, project)
  local buf = M.named(name)
  if not buf then
    buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, name)
    M.prepare(buf)
  end
  vim.api.nvim_set_current_buf(buf)
  read(buf, on_done, adapter, true, nil, cwd)
  return buf
end

-- A region's text as the compare sees it: leading and trailing blank lines
-- dropped and the rest joined, which is diff's own trim. A body read back can
-- differ from the one loaded by a trailing newline -- glab sends a body with
-- the newline a `<` redirection carries, and whether GitLab keeps it is
-- unobserved -- and that is not a change.
local function text_of(lines)
  local first, last = 1, #lines
  while first <= last and lines[first]:match("^%s*$") do
    first = first + 1
  end
  while last >= first and lines[last]:match("^%s*$") do
    last = last - 1
  end
  return table.concat(lines, "\n", first, last)
end

-- The key of the region mark carrying an identifier, or nil.
local function mark_of(state, id)
  for key, known in pairs(state.marks) do
    if known.id == id then
      return key
    end
  end
  return nil
end

-- Runs fn, which replaces the buffer's lines, and puts each window's cursor
-- on the buffer back where it was, or on the last line when the buffer is now
-- shorter: replacing every line otherwise moves it.
local function keep_cursor(buf, fn)
  local saved = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    saved[win] = vim.api.nvim_win_get_cursor(win)
  end
  fn()
  local count = vim.api.nvim_buf_line_count(buf)
  for win, cursor in pairs(saved) do
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(cursor[1], count), cursor[2] })
  end
end

-- What the next step says when a check finds the field changed. The buffer's
-- text is the only copy of the edit, and `:e!` replaces it.
local YANK = "Yank each region named to keep its text; :e! then reads the item again, discarding every edit in this buffer."

-- Whether a call's text may be on the backend: it succeeded, or it is a post
-- whose client was killed at its timeout, after it may have sent it. A post
-- like that is treated as one that landed until the read after it says which
-- comment it became -- posting it again could post it twice.
local function landed(result)
  return result.ok or (result.unsure == true and result.call.kind == diff.COMMENT_CREATE)
end

-- Ends a write that dispatched: frees the buffer for the next one, reports,
-- and answers on_done.
local function finish(job, ok, message, level)
  writing[job.buf] = nil
  vim.notify(message, level)
  if job.on_done then
    job.on_done(ok, message)
  end
end

-- Whether the buffer still holds the read the write was planned from. `:e!`
-- while the write runs reads the item again, and a snapshot from that read
-- is not the one the plan compared against.
local function same_load(job)
  if not vim.api.nvim_buf_is_valid(job.buf) then
    return false
  end
  local state = vim.b[job.buf].docket
  return state ~= nil and state.load == job.state.load
end

-- Each field the plan replaces, compared with what was loaded: the body by
-- its text, through render.region_lines as the load did, and a comment by
-- its own `updated` -- or by its text where the load or this read carries
-- none. Never the item's own timestamp, which Jira moves whenever anyone
-- comments, so comparing it would refuse every edit made after a
-- colleague's comment. A NEW region replaces nothing and is not compared.
--
-- The body carries no stamp, and its text as rendered hides what the
-- serialiser cannot write back: a colour or a subscript added on the web to
-- words already there, a link turned into a card, all render as the same
-- words. So the body is judged again as the load judged it, and one that is
-- no longer editable is refused with the reason, whatever its text.
local function conflicts(job, fresh)
  local comments = {}
  for _, comment in ipairs(fresh.comments) do
    comments[comment.id] = comment
  end
  local judged = {}
  for _, region in ipairs(select(2, render.render(fresh))) do
    judged[region.id] = region
  end
  local stamps = job.state.stamps or {}
  local found = {}
  for _, call in ipairs(job.plan.calls) do
    local loaded = job.state.snapshot.regions[call.id]
    if call.kind == diff.BODY_UPDATE then
      local now = judged[call.id]
      if now and not now.editable then
        found[#found + 1] = ("%s: now %s"):format(call.id, tostring(now.reason))
      elseif text_of(render.region_lines(fresh.body)) ~= text_of(loaded.lines) then
        found[#found + 1] = ("%s: changed since it was loaded"):format(call.id)
      end
    elseif call.kind == diff.COMMENT_UPDATE then
      local comment = comments[call.id]
      if not comment then
        found[#found + 1] =
          ("%s: not among the comments the client returned now, so it may have been deleted"):format(call.id)
      elseif stamps[call.id] ~= nil and comment.updated ~= nil then
        if comment.updated ~= stamps[call.id] then
          found[#found + 1] = ("%s: edited since it was loaded"):format(call.id)
        end
      elseif text_of(render.region_lines(comment.body)) ~= text_of(loaded.lines) then
        found[#found + 1] = ("%s: changed since it was loaded"):format(call.id)
      end
    end
  end
  return found
end

-- The comment a post became, found in the read that follows it: one the
-- loaded snapshot does not hold, written by the account, and holding the
-- text that was sent -- the last such when there are several. With none
-- holding the text and exactly one comment of the account's that is new,
-- that one, with a note: a body the backend kept as something other than
-- what was sent shows up here. nil when the read cannot say which it is.
local function identify(job, fresh, text)
  local loaded = job.state.snapshot.regions
  local candidates, matching = {}, {}
  for _, comment in ipairs(fresh.comments) do
    local author = comment.author and comment.author.id
    if loaded[comment.id] == nil and (fresh.me == nil or author == fresh.me) then
      candidates[#candidates + 1] = comment
      if text_of(render.region_lines(comment.body)) == text then
        matching[#matching + 1] = comment
      end
    end
  end
  if #matching > 0 then
    return matching[#matching], nil
  end
  if #candidates == 1 then
    return candidates[1], "it reads back differently from what was sent; gx shows it on the web"
  end
  return nil, nil
end

-- Moves the snapshot on past what was written, for a write whose buffer is
-- not populated afresh: a call failed, the read after the calls failed, or
-- text was typed while they ran. Each written region takes what the backend
-- now holds -- this read's text and stamp where it answered, and the text
-- sent otherwise, with the stamp dropped so the next check compares text --
-- so the next :w sends only what is left and checks against the right thing.
-- A posted comment's mark and snapshot take the identifier identify() found,
-- or stay under NEW as a read-only comment carrying POSTED. Each region this
-- read answered for is judged as a load judges it, by owner and by what its
-- tree holds, so a comment that came back holding a node the serialiser
-- cannot write -- a URL the backend turned into a card -- is read-only here
-- as it would be after `:e`, and no later edit flattens it. It takes `crlf`
-- from that read too, as a load does.
local function settle_in_place(buf, state, results, fresh, created)
  local comments, judged = {}, {}
  if fresh then
    for _, comment in ipairs(fresh.comments) do
      comments[comment.id] = comment
    end
    for _, region in ipairs(select(2, render.render(fresh))) do
      judged[region.id] = region
    end
  end
  state.stamps = state.stamps or {}
  for _, result in ipairs(results) do
    local call = result.call
    if landed(result) then
      local sent = vim.split(call.text, "\n", { plain = true })
      if call.kind == diff.COMMENT_CREATE then
        local key = mark_of(state, diff.NEW)
        if created then
          local region = judged[created.id]
          state.snapshot.regions[diff.NEW] = nil
          state.snapshot.regions[created.id] = {
            kind = item.COMMENT,
            owner = region.owner,
            editable = region.editable,
            reason = region.reason,
            lines = render.region_lines(created.body),
            crlf = region.crlf,
          }
          state.stamps[created.id] = created.updated
          if key then
            -- The entry keeps its edge and its head.
            local known = state.marks[key]
            known.id, known.kind, known.owner = created.id, item.COMMENT, region.owner
          end
        else
          state.snapshot.regions[diff.NEW] =
            { kind = item.COMMENT, owner = state.me, editable = false, reason = M.POSTED, lines = sent }
          if key then
            state.marks[key].kind = item.COMMENT
          end
        end
      else
        local region = state.snapshot.regions[call.id]
        if call.kind == diff.BODY_UPDATE then
          region.lines = fresh and render.region_lines(fresh.body) or sent
        else
          local comment = comments[call.id]
          region.lines = comment and render.region_lines(comment.body) or sent
          state.stamps[call.id] = comment and comment.updated or nil
        end
        if judged[call.id] then
          region.editable, region.reason = judged[call.id].editable, judged[call.id].reason
          region.crlf = judged[call.id].crlf
        end
      end
    end
  end
  vim.b[buf].docket = state
end

-- The end of a write whose calls have all answered: the report, then the
-- buffer brought up to what the backend holds. `fresh` is the read after the
-- calls, nil when none succeeded or the read failed, with `read_err` saying
-- why in the second case.
--
-- A post whose client was killed at its timeout is looked for in that read
-- like any post. Found, it is posted; not found, whether it was is unknown,
-- and it is held read-only under POSTED, `unknown`, so no :w posts it again.
local function conclude(job, results, fresh, read_err, me_err)
  local buf = job.buf
  local report, failed, unknown, created = {}, false, false, nil
  for _, result in ipairs(results) do
    local call = result.call
    if call.kind == diff.COMMENT_CREATE and landed(result) then
      local note
      if fresh then
        created, note = identify(job, fresh, call.text)
      end
      if result.ok then
        report[#report + 1] = created and ("%s: posted as %s"):format(call.id, created.id) or ("%s: posted"):format(call.id)
      elseif created then
        report[#report + 1] = ("%s: posted as %s; the client was killed at its timeout after sending it"):format(call.id, created.id)
      else
        unknown = true
        report[#report + 1] = ("%s: %s\nwhether the comment was posted is unknown, so it is held read-only rather than posted again"):format(
          call.id,
          tostring(result.err)
        )
      end
      if note then
        report[#report + 1] = ("%s: %s"):format(created.id, note)
      end
    elseif not result.ok then
      failed = true
      report[#report + 1] = ("%s: %s"):format(call.id, tostring(result.err or "the client reported no success"))
    else
      report[#report + 1] = ("%s: written"):format(call.id)
    end
  end
  vim.list_extend(report, job.skipped)
  if read_err then
    report[#report + 1] = ("the item could not be read after the write, so the buffer keeps what was sent: %s"):format(read_err)
  end
  local level = failed and vim.log.levels.ERROR or ((read_err or unknown) and vim.log.levels.WARN or vim.log.levels.INFO)
  local ok = not failed and not unknown

  if not same_load(job) then
    report[#report + 1] = "the buffer was closed or read again while the write ran, so it was left as it is"
    return finish(job, ok, table.concat(report, "\n"), level)
  end
  local typed = vim.api.nvim_buf_get_changedtick(buf) ~= job.tick
  if ok and fresh and not typed then
    keep_cursor(buf, function()
      M.populate(buf, fresh)
    end)
    if me_err then
      report[#report + 1] = me_err
      level = vim.log.levels.WARN
    end
    return finish(job, true, table.concat(report, "\n"), level)
  end
  settle_in_place(buf, vim.b[buf].docket, results, fresh, created)
  if typed then
    -- A posted comment held under POSTED refuses the whole save once it holds
    -- text of its own, and `:e!` is then the way on, which discards it.
    local held = false
    for _, entry in ipairs(M.plan(buf).refused) do
      held = held or entry.id == diff.NEW
    end
    report[#report + 1] = held
        and "the buffer changed while the write ran; the posted comment is read-only until the item is read again, so yank what was typed into it before :e!"
      or "the buffer changed while the write ran; :w sends those edits"
  elseif not failed then
    vim.bo[buf].modified = false
  end
  if failed then
    report[#report + 1] = "the buffer keeps its edits, and :w sends what is left"
  end
  finish(job, ok, table.concat(report, "\n"), level)
end

-- After the calls: when any succeeded, the rows cached for the item are
-- dropped, so the dashboard does not show its old state, and the item is read
-- again for conclude(). That read is part of the write -- it is what names a
-- posted comment -- so the buffer stays in `writing` until it lands.
local function after_calls(job, results)
  local any = false
  for _, result in ipairs(results) do
    any = any or landed(result)
  end
  if not any then
    return conclude(job, results, nil, nil, nil)
  end
  cache.drop_item(job.state.source, job.state.id)
  local asked, raised = pcall(job.adapter.item, M.target(job.state), function(fresh, err, me_err)
    vim.schedule(function()
      conclude(job, results, fresh, not fresh and tostring(err or "the client returned no item") or nil, me_err)
    end)
  end)
  if not asked then
    conclude(job, results, nil, tostring(raised), nil)
  end
end

-- Sends the plan's calls one at a time, in its order, each through the
-- adapter capability diff names it after, and hands every answer to
-- after_calls(). A failed call does not stop the ones after it: each region
-- is its own call, and the retry sends only what is left. The answers arrive
-- in a fast-event context, so each is scheduled; an adapter that answers
-- twice is heard once, and one that raises is a failed call.
--
-- A call carrying `crlf` is an update of a region whose body arrived with
-- CRLF line ends, which the buffer holds as LF, so its text goes to the
-- adapter with them put back. Every other call's text goes as the plan
-- holds it. The plan's own text stays LF, because settle_in_place() keeps it
-- as the region's lines, which are LF like every line the buffer holds.
local function dispatch(job)
  local results = {}
  local function step(index)
    local call = job.plan.calls[index]
    if not call then
      return after_calls(job, results)
    end
    local answered = false
    local function answer(ok, err, unsure)
      if answered then
        return
      end
      answered = true
      vim.schedule(function()
        results[index] = { call = call, ok = ok == true, err = err, unsure = ok ~= true and unsure == true }
        step(index + 1)
      end)
    end
    local send = job.adapter[call.kind]
    local text = call.text
    if call.crlf then
      text = (text:gsub("\n", "\r\n"))
    end
    local sent, raised
    if call.kind == diff.COMMENT_UPDATE then
      sent, raised = pcall(send, M.target(job.state), call.id, text, answer)
    else
      sent, raised = pcall(send, M.target(job.state), text, answer)
    end
    if not sent then
      answer(false, tostring(raised))
    end
  end
  step(1)
end

-- The check before any call, when the plan replaces something: the item is
-- read again and each field about to be replaced compared with what was
-- loaded. A mismatch, or a read that fails, writes nothing.
local function check(job)
  local asked, raised = pcall(job.adapter.item, M.target(job.state), function(fresh, err)
    vim.schedule(function()
      if not same_load(job) then
        return finish(
          job,
          false,
          ("%s: nothing written, because the buffer was closed or read again while the item was checked"):format(job.name),
          vim.log.levels.WARN
        )
      end
      if not fresh then
        return finish(
          job,
          false,
          ("%s: nothing written, because the item could not be read to check it for changes:\n%s"):format(
            job.name,
            tostring(err or "the client returned no item")
          ),
          vim.log.levels.ERROR
        )
      end
      local found = conflicts(job, fresh)
      if #found > 0 then
        return finish(
          job,
          false,
          table.concat({
            ("%s: nothing written, because what these regions would replace has changed since the buffer was loaded:"):format(job.name),
            table.concat(found, "\n"),
            YANK,
          }, "\n"),
          vim.log.levels.WARN
        )
      end
      dispatch(job)
    end)
  end)
  if not asked then
    finish(job, false, ("%s: nothing written: %s"):format(job.name, tostring(raised)), vim.log.levels.ERROR)
  end
end

--- The write command, which BufWriteCmd runs for `:w`.
---
--- The save is planned with diff.plan(), and nothing is sent when a region is
--- refused, when no region changed, or while a write to this buffer is still
--- in flight. With no region changed `modified` is cleared, since every
--- region already holds what the backend has. Text outside every region --
--- the header, the title, an author line -- is never sent, so an edit there
--- refuses the save, and so does a region's line moved out to there; see
--- diff.lua. A region skipped as empty keeps the
--- buffer modified when nothing else is sent; when another region is sent,
--- the read that follows puts the emptied region's text back, and when that
--- read fails the region is left empty with `modified` cleared; `:e` puts the
--- text back.
---
--- When the plan replaces the body or a comment, the item is read again first
--- and each field about to be replaced is compared with what was loaded: the
--- body by its text, a comment by its own `updated`. On a mismatch nothing is
--- sent, the buffer stays modified, and the message names each region, the
--- yank that keeps its text and `:e!`, which reads the item again.
---
--- The calls then go out one at a time, and after them, when any succeeded,
--- the rows cached for the item are dropped and the item is read again. That
--- read is part of the write, because it is what names a posted comment. When
--- every call succeeded, the read answered and nothing was typed meanwhile,
--- the buffer is populated from it, which clears `modified`. Otherwise the
--- snapshot moves on past what was written -- see settle_in_place() -- and
--- `modified` clears only when every call succeeded and nothing was typed.
---
--- Every outcome is reported with vim.notify, because BufWriteCmd discards
--- the return value, and handed to `on_done` when there is one.
---@param buf integer
---@param on_done fun(ok: boolean, message: string)|nil called once, when the write has finished or stopped
---@return boolean started true when calls went out, whose outcome arrives through `on_done`
---@return string|nil message why nothing went out, when nothing did
function M.write(buf, on_done)
  local function stop(ok, message, level)
    vim.notify(message, level)
    if on_done then
      on_done(ok, message)
    end
    return false, message
  end
  local state = vim.b[buf].docket
  local plan = M.plan(buf)
  if not plan then
    return stop(false, "nothing loaded in this buffer; :e reads the item", vim.log.levels.WARN)
  end
  local name = M.name(state.source, state.id, state.project)
  if writing[buf] then
    return stop(false, ("%s: a write is still in flight; :w again once it reports"):format(name), vim.log.levels.WARN)
  end
  local parts = {}
  for _, entry in ipairs(plan.refused) do
    parts[#parts + 1] = ("%s: refused: %s"):format(entry.id, entry.reason)
  end
  for _, entry in ipairs(plan.skipped) do
    parts[#parts + 1] = ("%s: %s"):format(entry.id, entry.reason)
  end
  if #plan.refused > 0 then
    return stop(false, table.concat(parts, "\n"), vim.log.levels.WARN)
  end
  if #plan.calls == 0 then
    if #parts > 0 then
      return stop(false, table.concat(parts, "\n"), vim.log.levels.WARN)
    end
    vim.bo[buf].modified = false
    return stop(true, "nothing changed", vim.log.levels.INFO)
  end
  local adapter, err = adapters.get(state.source)
  if not adapter then
    return stop(false, ("%s: %s"):format(name, err), vim.log.levels.ERROR)
  end
  for _, call in ipairs(plan.calls) do
    if not adapters.can(adapter, call.kind) then
      return stop(
        false,
        ("%s: %s: the %s adapter has no %s, so nothing was sent"):format(name, call.id, state.source, call.kind),
        vim.log.levels.ERROR
      )
    end
  end
  writing[buf] = true
  local job = {
    buf = buf,
    name = name,
    state = state,
    plan = plan,
    adapter = adapter,
    skipped = parts,
    tick = vim.api.nvim_buf_get_changedtick(buf),
    on_done = on_done,
  }
  local replaces = false
  for _, call in ipairs(plan.calls) do
    replaces = replaces or call.kind ~= diff.COMMENT_CREATE
  end
  if replaces then
    check(job)
  else
    dispatch(job)
  end
  return true, nil
end

--- Whether a write to the buffer is in flight: from :w until the read that
--- follows the calls has landed.
---@param buf integer
---@return boolean
function M.writing(buf)
  return writing[buf] == true
end

--- Opens a comment at the end of an item buffer: an author line, and one
--- empty line under a region mark whose identifier is NEW, which the next :w
--- posts. The cursor goes to that line when the buffer is the current one.
---
--- One unposted comment at a time, because the snapshot is keyed by
--- identifier: with one already open the cursor goes there instead, and one
--- whose every line was deleted, or that `u` took out again, is replaced.
--- An author line the one replaced left in the buffer stays there, above the
--- new one and outside every region. `modified` is left as it was,
--- because an empty comment is not an edit -- :w skips it. Refused while a
--- write is in flight, since the read that ends it may move the marks, and on
--- a backend whose adapter has no comment_create.
---@param buf integer
---@return integer|nil row the 1-based line the comment is typed on
---@return string|nil err
function M.compose(buf)
  local function refuse(message)
    vim.notify(message, vim.log.levels.WARN)
    return nil, message
  end
  local state = vim.b[buf].docket
  if not state then
    return refuse("nothing loaded in this buffer; :e reads the item")
  end
  local name = M.name(state.source, state.id, state.project)
  if writing[buf] then
    return refuse(("%s: a write is still in flight; a comment opens once it reports"):format(name))
  end
  local adapter, err = adapters.get(state.source)
  if not adapter then
    return refuse(("%s: %s"):format(name, err))
  end
  if not adapters.can(adapter, diff.COMMENT_CREATE) then
    return refuse(("%s: the %s adapter has no %s"):format(name, state.source, diff.COMMENT_CREATE))
  end
  local function place(row)
    if vim.api.nvim_get_current_buf() == buf then
      vim.api.nvim_win_set_cursor(0, { row, 0 })
    end
    return row
  end
  local key = mark_of(state, diff.NEW)
  if key and state.snapshot.regions[diff.NEW].kind ~= diff.NEW then
    -- A comment posted without a read naming it holds NEW until one does.
    return refuse(("%s: the last comment is %s"):format(name, M.POSTED))
  end
  if key then
    -- Open while the read finds text in its range, blank lines included, or a
    -- range that runs into another's; replaced when that range is empty or
    -- reversed, or the comment is withdrawn.
    local now = read_marks(buf, state)[diff.NEW]
    if now and (now.overlaps or (now.lines and #now.lines > 0)) then
      return place(vim.api.nvim_buf_get_extmark_by_id(buf, M.REGIONS, tonumber(key), {})[1] + 1)
    end
    vim.api.nvim_buf_del_extmark(buf, M.REGIONS, tonumber(key))
    if state.marks[key].edge then
      vim.api.nvim_buf_del_extmark(buf, M.EDGES, state.marks[key].edge)
    end
    if state.marks[key].head then
      vim.api.nvim_buf_del_extmark(buf, M.HEADS, state.marks[key].head)
    end
    state.marks[key] = nil
  end
  local modified = vim.bo[buf].modified
  local count = vim.api.nvim_buf_line_count(buf)
  -- The region that ends the buffer has its end past the last line, where the
  -- lines below are appended, and its end's right gravity would take them in.
  -- It is set again where it was once they are there.
  local ending = {}
  for _, found in ipairs(vim.api.nvim_buf_get_extmarks(buf, M.REGIONS, { count, 0 }, { count, 0 }, { details = true, overlap = true })) do
    if found[4].end_row == count and found[4].end_col == 0 then
      ending[#ending + 1] = found
    end
  end
  vim.api.nvim_buf_set_lines(buf, count, count, false, { "", AUTHOR, "" })
  for _, found in ipairs(ending) do
    set_region(buf, { found[2], found[3] }, { count, 0 }, found[1])
  end
  -- The same marks populate() sets, on the one empty line. The author line
  -- above it is outside every region, so the frame the save compares gains
  -- it; M.plan() stops expecting it once the buffer no longer holds it.
  local row = count + 2
  local mark = set_region(buf, { row, 0 }, { row + 1, 0 })
  run(buf, row - 1, 0, #"me", highlight.USER)
  vim.api.nvim_buf_set_extmark(buf, M.DECOR, row, 0, { line_hl_group = highlight.EDITABLE })
  state.marks[tostring(mark)] = {
    id = diff.NEW,
    kind = diff.NEW,
    owner = state.me,
    edge = set_edge(buf, { row + 1, 0 }),
    head = set_head(buf, row - 1),
  }
  state.snapshot.regions[diff.NEW] = { kind = diff.NEW, owner = state.me, editable = true, lines = { "" } }
  if state.snapshot.frame then
    state.snapshot.frame[#state.snapshot.frame + 1] = AUTHOR
  end
  vim.b[buf].docket = state
  vim.bo[buf].modified = modified
  return place(row + 1)
end

--- The adapter of an item buffer, and the identifier it holds.
---@param buf integer
---@return table|nil adapter
---@return string|nil id
---@return string|nil err
function M.adapter_of(buf)
  local source, id = M.parse(vim.api.nvim_buf_get_name(buf))
  if not source then
    return nil, nil, "not an item buffer"
  end
  local adapter, err = adapters.get(source)
  if not adapter then
    return nil, nil, err
  end
  return adapter, id, nil
end

return M
