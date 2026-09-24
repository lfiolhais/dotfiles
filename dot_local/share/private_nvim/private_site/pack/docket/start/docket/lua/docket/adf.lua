-- Atlassian Document Format, the node tree Jira returns a body as. render()
-- turns a tree into buffer lines, serialise() turns buffer text into the
-- minimal tree a write sends, and editable() says whether a tree survives that
-- round trip. Imports nothing local and touches no buffer.
--
-- The asymmetry the item buffer is built on: a body is read as a tree and
-- written back as one the serialiser builds from text, so the written tree
-- holds only `doc`, `paragraph`, `hardBreak` and `text` with no marks. A
-- region whose tree holds anything else -- a link, bold, a mention, a list, a
-- heading, a code block, a table -- would be replaced by its flattened form
-- on the write, which is what editable() refuses.
--
-- The rendering of nodes outside that subset is for reading. A mark, a list
-- or a heading renders in the shape Markdown gives it; a node this module
-- does not know is named in place as `[unsupported: <type>]` and whatever it
-- holds is rendered beneath the name, so no text is lost from the buffer.

local M = {}

-- The node types the serialiser emits, and the only ones editable() admits.
M.SUBSET = { doc = true, paragraph = true, hardBreak = true, text = true }

-- How each mark wraps the text it is on. `link` is handled apart, because it
-- carries the address in its attrs.
local WRAP = {
  strong = { "**", "**" },
  em = { "_", "_" },
  code = { "`", "`" },
  strike = { "~~", "~~" },
  underline = { "__", "__" },
}

-- The kinds that are inline content. The two places that meet a node in a
-- position its kind does not belong -- an inline node where a block was
-- expected, and the children of a node this module does not know -- ask this
-- which way to render it.
local INLINE = {
  text = true,
  hardBreak = true,
  mention = true,
  emoji = true,
  inlineCard = true,
  status = true,
  date = true,
  placeholder = true,
  inlineExtension = true,
  mediaInline = true,
  media = true,
}

local function children(node)
  local content = node.content
  if type(content) ~= "table" then
    return {}
  end
  return content
end

local function attrs(node)
  return type(node.attrs) == "table" and node.attrs or {}
end

-- A node whose kind this module has no rendering for. `[unsupported: x]` is
-- what the reader sees, in the position the node held.
local function unsupported(node)
  return ("[unsupported: %s]"):format(tostring(node.type))
end

local render_blocks

-- Inline content, as one string. A hardBreak is a newline in it; the caller
-- splits.
local function render_inline(nodes)
  local parts = {}
  for _, node in ipairs(nodes) do
    local kind = node.type
    if kind == "text" then
      local text = node.text or ""
      for _, mark in ipairs(type(node.marks) == "table" and node.marks or {}) do
        local wrap = WRAP[mark.type]
        if wrap then
          text = wrap[1] .. text .. wrap[2]
        elseif mark.type == "link" then
          text = ("[%s](%s)"):format(text, attrs(mark).href or "")
        end
        -- subsup, textColor, backgroundColor and any later mark change how the
        -- text looks and nothing about what it says, so they render as plain text.
      end
      parts[#parts + 1] = text
    elseif kind == "hardBreak" then
      parts[#parts + 1] = "\n"
    elseif kind == "mention" then
      -- Jira fills attrs.text with the display name already prefixed by `@`.
      -- A node carrying neither is named rather than rendered as `@nil`.
      local a = attrs(node)
      parts[#parts + 1] = a.text or (a.id and "@" .. tostring(a.id)) or unsupported(node)
    elseif kind == "emoji" then
      local a = attrs(node)
      parts[#parts + 1] = a.text or a.shortName or unsupported(node)
    elseif kind == "inlineCard" then
      parts[#parts + 1] = attrs(node).url or unsupported(node)
    elseif kind == "status" then
      parts[#parts + 1] = ("[%s]"):format(attrs(node).text or "status")
    elseif kind == "date" then
      local stamp = tonumber(attrs(node).timestamp)
      parts[#parts + 1] = stamp and os.date("!%Y-%m-%d", math.floor(stamp / 1000)) or unsupported(node)
    elseif kind == "placeholder" then
      parts[#parts + 1] = attrs(node).text or unsupported(node)
    elseif kind == "mediaInline" or kind == "media" then
      -- Inside a paragraph is where ADF puts an image, as a mediaInline
      -- carrying the file's own attrs or holding the media node that does.
      local a = attrs(node)
      if a.alt == nil and a.id == nil then
        a = attrs(children(node)[1] or node)
      end
      parts[#parts + 1] = ("[media: %s]"):format(a.alt or a.id or "media")
    else
      -- Named, then whatever it holds, so the text inside an unknown inline
      -- node is still read.
      local inner = render_inline(children(node))
      parts[#parts + 1] = unsupported(node) .. (inner ~= "" and " " .. inner or "")
    end
  end
  return table.concat(parts)
end

-- Lines from inline content: the joined string split at every newline. Code
-- block text carries its own newlines, so this covers those too.
local function inline_lines(nodes)
  return vim.split(render_inline(nodes), "\n", { plain = true })
end

local function prefixed(lines, first, rest)
  local out = {}
  for index, line in ipairs(lines) do
    local prefix = index == 1 and first or rest
    -- A blank line inside a quote or a list item takes the prefix trimmed, so
    -- no line ends in a space.
    out[index] = line == "" and (prefix:gsub("%s+$", "")) or prefix .. line
  end
  return out
end

local render_block

-- Lists: one item per child, rendered and indented under its marker. A
-- listItem holds blocks; a taskItem or decisionItem holds inline content
-- behind its own prefix, so those render as the block they are. Items follow
-- each other without a blank line between.
local function render_list(node, marker_for)
  local lines = {}
  for index, item in ipairs(children(node)) do
    local marker = marker_for(index)
    local body
    if item.type == "listItem" then
      body = render_blocks(children(item), false)
    else
      body = render_block(item)
    end
    if #body == 0 then
      body = { "" }
    end
    vim.list_extend(lines, prefixed(body, marker, (" "):rep(#marker)))
  end
  return lines
end

-- A table's cells are flattened to one line each; the row is `| a | b |`
-- and a header row is followed by the `| --- |` separator Markdown uses.
local function render_table(node)
  local lines = {}
  for _, row in ipairs(children(node)) do
    local cells, header = {}, false
    for _, cell in ipairs(children(row)) do
      if cell.type == "tableHeader" then
        header = true
      end
      -- A cell is one line, so a blank line inside it -- the one an unknown
      -- node's blocks follow -- would read as a double space; only the lines
      -- with text are joined.
      local kept = {}
      for _, line in ipairs(render_blocks(children(cell), false)) do
        if line ~= "" then
          kept[#kept + 1] = line
        end
      end
      cells[#cells + 1] = table.concat(kept, " ")
    end
    lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |"
    if header then
      local rule = {}
      for index = 1, #cells do
        rule[index] = "---"
      end
      lines[#lines + 1] = "| " .. table.concat(rule, " | ") .. " |"
    end
  end
  return lines
end

-- One block node to its lines.
function render_block(node)
  local kind = node.type
  if kind == "paragraph" then
    local nodes = children(node)
    if #nodes == 0 then
      return {}
    end
    return inline_lines(nodes)
  elseif kind == "heading" then
    local level = tonumber(attrs(node).level) or 1
    return { ("#"):rep(level) .. " " .. render_inline(children(node)):gsub("\n", " ") }
  elseif kind == "bulletList" then
    return render_list(node, function()
      return "- "
    end)
  elseif kind == "orderedList" then
    local start = tonumber(attrs(node).order) or 1
    return render_list(node, function(index)
      return ("%d. "):format(start + index - 1)
    end)
  elseif kind == "taskList" then
    return render_list(node, function()
      return "- "
    end)
  elseif kind == "taskItem" then
    -- Reached from render_list, which puts the list marker before the box.
    local box = attrs(node).state == "DONE" and "[x] " or "[ ] "
    return prefixed(inline_lines(children(node)), box, "    ")
  elseif kind == "decisionList" then
    return render_list(node, function()
      return "- "
    end)
  elseif kind == "decisionItem" then
    return prefixed(inline_lines(children(node)), "(decision) ", "           ")
  elseif kind == "codeBlock" then
    local language = attrs(node).language or ""
    local lines = { "```" .. language }
    vim.list_extend(lines, inline_lines(children(node)))
    lines[#lines + 1] = "```"
    return lines
  elseif kind == "blockquote" then
    return prefixed(render_blocks(children(node), true), "> ", "> ")
  elseif kind == "panel" then
    local lines = { ("> [%s]"):format(attrs(node).panelType or "panel") }
    vim.list_extend(lines, prefixed(render_blocks(children(node), true), "> ", "> "))
    return lines
  elseif kind == "expand" or kind == "nestedExpand" then
    local lines = { ("> [%s]"):format(attrs(node).title or "expand") }
    vim.list_extend(lines, prefixed(render_blocks(children(node), true), "> ", "> "))
    return lines
  elseif kind == "rule" then
    return { "---" }
  elseif kind == "table" then
    return render_table(node)
  elseif kind == "mediaSingle" or kind == "mediaGroup" then
    -- The block wrappers. A bare media node, and a mediaInline, are in INLINE
    -- and reach the same line through inline_lines instead.
    local lines = {}
    for _, media in ipairs(children(node)) do
      local a = attrs(media)
      lines[#lines + 1] = ("[media: %s]"):format(a.alt or a.id or tostring(media.type))
    end
    if #lines == 0 then
      lines[1] = ("[media: %s]"):format(attrs(node).alt or kind)
    end
    return lines
  elseif kind == "listItem" then
    return render_blocks(children(node), false)
  elseif kind == "layoutSection" or kind == "layoutColumn" then
    -- Jira's column layout: a section holds columns, a column holds blocks,
    -- and the blocks read as if they were at top level.
    return render_blocks(children(node), true)
  elseif kind == "blockCard" or kind == "embedCard" then
    -- A pasted link on a line of its own, rendered as inlineCard renders
    -- one, so a link reads the same however Jira placed it.
    return { attrs(node).url or unsupported(node) }
  elseif INLINE[kind] then
    -- Inline content where a block was expected: rendered as one paragraph
    -- rather than refused, since Jira's own output is what decides.
    return inline_lines({ node })
  end
  -- Named, then whatever it holds: inline content on the lines below the
  -- name, blocks beneath it after a blank line, so a bodiedExtension's
  -- paragraphs are still read under a line saying what wrapped them.
  local lines = { unsupported(node) }
  local inner = children(node)
  local inline = #inner > 0
  for _, child in ipairs(inner) do
    if not INLINE[child.type] then
      inline = false
    end
  end
  if inline then
    vim.list_extend(lines, inline_lines(inner))
  elseif #inner > 0 then
    lines[#lines + 1] = ""
    vim.list_extend(lines, render_blocks(inner, true))
  end
  return lines
end

-- A sequence of blocks to lines. `spaced` puts one blank line between
-- consecutive blocks, which is the document's own separator; inside a list
-- item the blocks follow each other directly.
function render_blocks(nodes, spaced)
  local lines = {}
  for index, node in ipairs(nodes) do
    if spaced and index > 1 then
      lines[#lines + 1] = ""
    end
    vim.list_extend(lines, render_block(node))
  end
  return lines
end

--- Renders a document tree to buffer lines.
---
--- Blocks are separated by one blank line, and an empty paragraph renders to
--- no line of its own, so two blank lines between paragraphs is one empty
--- paragraph between them -- which is how serialise() reads it back. An
--- absent body renders to no lines.
---@param node table|nil the `doc` node, or any node
---@return string[] lines
function M.render(node)
  if node == nil or node == vim.NIL then
    return {}
  end
  if node.type == "doc" then
    return render_blocks(children(node), true)
  end
  return render_block(node)
end

local function paragraph(lines)
  local content = {}
  for index, line in ipairs(lines) do
    if index > 1 then
      content[#content + 1] = { type = "hardBreak" }
    end
    content[#content + 1] = { type = "text", text = line }
  end
  return { type = "paragraph", content = content }
end

local function empty_paragraph()
  return { type = "paragraph", content = {} }
end

--- Serialises buffer text to the minimal document a write sends.
---
--- A run of non-blank lines is one `paragraph`, with a `hardBreak` between
--- each pair of lines and a `text` node per line. A blank line ends the
--- paragraph; every further blank line before the next paragraph, and every
--- blank line before the first or after the last, is one empty `paragraph`,
--- so render() of the result gives the text back. Only an empty line is
--- blank: a line of spaces is text, because a text node holds spaces as
--- readily as letters and the round trip keeps it. Empty text is an empty
--- document.
---@param text string
---@return table doc
function M.serialise(text)
  local content = {}
  if text == "" then
    return { version = 1, type = "doc", content = content }
  end
  local run, blanks, seen = {}, 0, false
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if line == "" then
      if #run > 0 then
        content[#content + 1] = paragraph(run)
        run, seen = {}, true
      end
      blanks = blanks + 1
    else
      -- Leading blanks each stand for an empty paragraph; between two
      -- paragraphs the first blank is the separator and the rest are empty
      -- paragraphs.
      local empties = seen and blanks - 1 or blanks
      for _ = 1, empties do
        content[#content + 1] = empty_paragraph()
      end
      blanks = 0
      run[#run + 1] = line
    end
  end
  if #run > 0 then
    content[#content + 1] = paragraph(run)
  else
    -- Every trailing blank is an empty paragraph, since the separator before
    -- the first of them is what render() emits for it. With no paragraph at
    -- all, n blank lines are the n - 1 separators of n + 1 empty paragraphs.
    local empties = seen and blanks or blanks + 1
    for _ = 1, empties do
      content[#content + 1] = empty_paragraph()
    end
  end
  return { version = 1, type = "doc", content = content }
end

-- `an em mark`, `a strong mark`, `an emoji node`, `a mention node`.
local function article(noun)
  return noun:match("^[aeiouAEIOU]") and "an" or "a"
end

-- The first node outside the subset, named for the reason.
local function offending(node)
  if node == nil or node == vim.NIL then
    return nil
  end
  local kind = tostring(node.type)
  if not M.SUBSET[kind] then
    return ("carries %s %s node, which a write would replace by its flattened text"):format(article(kind), kind)
  end
  if kind == "text" and type(node.marks) == "table" and node.marks[1] then
    local mark = tostring(node.marks[1].type)
    return ("carries a text node with %s %s mark, which a write would replace by its flattened text"):format(
      article(mark),
      mark
    )
  end
  for _, child in ipairs(children(node)) do
    local found = offending(child)
    if found then
      return found
    end
  end
  return nil
end

--- Whether a tree survives the round trip a write makes.
---
--- True when every node is `doc`, `paragraph`, `hardBreak` or `text` with no
--- marks. Over those nodes render() and serialise() are inverses, which the
--- suite asserts, so the node types are the whole judgement. Otherwise false,
--- with a reason naming the first node that made it so -- the type, or the
--- first mark on a text node. An absent body is editable, and so is one that
--- holds nothing but empty paragraphs.
---@param node table|nil
---@return boolean editable
---@return string|nil reason
function M.editable(node)
  local found = offending(node)
  if found then
    return false, found
  end
  return true, nil
end

return M
