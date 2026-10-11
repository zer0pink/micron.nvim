-- Micron markup -> terminal lines + highlight/link/widget metadata.
-- State machine follows micron-parser.js (itself a port of NomadNet's MicronParser.py).
local hl = require("micron.preview.hl")

local M = {}

local DEFAULT_FG_DARK = "ddd"
local DEFAULT_FG_LIGHT = "222"

local HEADINGS = {
  dark = {
    { fg = "222", bg = "bbb" },
    { fg = "111", bg = "999" },
    { fg = "000", bg = "777" },
  },
  light = {
    { fg = "000", bg = "777" },
    { fg = "111", bg = "aaa" },
    { fg = "222", bg = "ccc" },
  },
}

---@class micron.Style
---@field fg string
---@field bg string
---@field bold boolean
---@field underline boolean
---@field italic boolean

---@class micron.Link
---@field row integer 0-based
---@field col integer byte start
---@field end_col integer byte end (exclusive)
---@field url string destination without nomadnetwork:// / lxmf://
---@field fields string[] raw field specs ("*", "name", "key=value")

---@class micron.Widget
---@field row integer
---@field col integer
---@field end_col integer
---@field type "field"|"checkbox"|"radio"
---@field name string
---@field value string current value (fields) or option value (checkbox/radio)
---@field checked? boolean
---@field masked? boolean
---@field label? string

---@class micron.Partial
---@field row integer
---@field key string descriptor, stable across renders
---@field url string
---@field refresh? number seconds
---@field fields string[]
---@field id? string

---@class micron.Mark
---@field row integer
---@field col? integer
---@field end_col? integer
---@field hl string
---@field line? boolean whole-line background
---@field priority integer

---@class micron.Doc
---@field lines string[]
---@field marks micron.Mark[]
---@field links micron.Link[]
---@field widgets micron.Widget[]
---@field partials micron.Partial[]
---@field anchors table<string, integer> name -> row
---@field heading_rows integer[]
---@field page_bg? string "#rrggbb" from #!bg=

---@class micron.RenderOpts
---@field dark boolean
---@field width integer
---@field form? table<string,string> current form values by field name
---@field partials? table<string, {doc?: micron.Doc, error?: string, loading?: boolean}>

---@param url string
---@return string
local function strip_scheme(url)
  return (url:gsub("^nomadnetwork://", ""):gsub("^lxmf://", ""))
end

---@param style micron.Style
---@return micron.Style
local function copy(style)
  return { fg = style.fg, bg = style.bg, bold = style.bold, underline = style.underline, italic = style.italic }
end

---@param state table
---@return micron.Style
local function state_style(state)
  return { fg = state.fg, bg = state.bg, bold = state.bold, underline = state.underline, italic = state.italic }
end

---@param style table
---@param state table
local function apply_style(style, state)
  for _, k in ipairs({ "fg", "bg", "bold", "underline", "italic" }) do
    if style[k] ~= nil then
      state[k] = style[k]
    end
  end
end

---@param state table
local function reset_formatting(state)
  state.bold, state.underline, state.italic = false, false, false
  state.fg, state.bg = state.default_fg, state.default_bg
  state.align = state.default_align
end

local STRIP = {
  function(s, i)
    return s:match("^`[FB]T%x%x%x%x%x%x", i)
  end,
  function(s, i)
    return s:match("^`[FB]%x%x%x", i)
  end,
  function(s, i)
    return s:match("^`:[%w_%-]*", i)
  end,
  function(s, i)
    return s:match("^`[!*_=fbacrl`<>{]", i)
  end,
}

--- Header anchor slug (same rules as micron-parser.js slugifyMicron).
---@param text string
---@return string
function M.slugify(text)
  local out, i = {}, 1
  while i <= #text do
    local m
    if text:sub(i, i) == "`" then
      for _, f in ipairs(STRIP) do
        m = f(text, i)
        if m then
          break
        end
      end
    end
    if m then
      i = i + #m
    else
      out[#out + 1] = text:sub(i, i)
      i = i + 1
    end
  end
  return (table.concat(out):gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", ""):lower())
end

--- Page-level colours from leading #!fg= / #!bg= header lines.
---@param lines string[]
---@return string?, string?
local function header_colors(lines)
  local fg, bg
  for _, line in ipairs(lines) do
    local t = vim.trim(line)
    if t ~= "" then
      if t:sub(1, 2) ~= "#!" then
        break
      end
      local c = t:match("^#!fg=(.*)$")
      if c then
        c = vim.trim(c)
        if #c == 3 or #c == 6 then
          fg = c
        end
      end
      c = t:match("^#!bg=(.*)$")
      if c then
        c = vim.trim(c)
        if #c == 3 or #c == 6 then
          bg = c
        end
      end
    end
  end
  return fg, bg
end

---@param line string
---@param i integer 1-based index of the char after "<"
---@param state table
---@return table? part
---@return integer? close index of the closing ">"
local function parse_field(line, i, state)
  local tick = line:find("`", i, true)
  if not tick then
    return nil
  end
  local content = line:sub(i, tick - 1)
  local kind, name, value, masked, prechecked, width = "field", content, "", false, false, 24
  if content:find("|", 1, true) then
    local comps = vim.split(content, "|", { plain = true })
    local flags = comps[1]
    name = comps[2]
    if flags:find("^", 1, true) then
      kind, flags = "radio", flags:gsub("%^", "", 1)
    elseif flags:find("?", 1, true) then
      kind, flags = "checkbox", flags:gsub("%?", "", 1)
    elseif flags:find("!", 1, true) then
      masked, flags = true, flags:gsub("!", "", 1)
    end
    local w = tonumber(flags:match("^%d+"))
    if w then
      width = math.min(w, 256)
    end
    value = comps[3] or ""
    prechecked = comps[4] == "*"
  end
  local close = line:find(">", tick, true)
  if not close then
    return nil
  end
  local data = line:sub(tick + 1, close - 1)
  local style = state_style(state)
  if kind == "field" then
    return { t = "field", name = name, width = width, masked = masked, data = data, style = style }, close
  end
  return {
    t = kind,
    name = name,
    value = value ~= "" and value or data,
    label = data,
    prechecked = prechecked,
    style = style,
  },
    close
end

---@param line string
---@param i integer 1-based index of "["
---@param state table
---@return table? part
---@return integer? close index of the closing "]"
local function parse_link(line, i, state)
  local close = line:find("]", i, true)
  if not close then
    return nil
  end
  local data = line:sub(i + 1, close - 1)
  local comps = vim.split(data, "`", { plain = true })
  local label, url, fields = "", "", ""
  if #comps == 1 then
    url = data
  elseif #comps == 2 then
    label, url = comps[1], comps[2]
  elseif #comps == 3 then
    label, url, fields = comps[1], comps[2], comps[3]
  end
  if url == "" then
    return nil
  end
  if label == "" then
    label = url
  end
  return {
    t = "link",
    url = strip_scheme(url),
    label = label,
    fields = fields ~= "" and vim.split(fields, "|", { plain = true }) or {},
    style = state_style(state),
  },
    close
end

--- Port of makeOutput: one source line -> styled parts. Mutates state.
---@param state table
---@param line string
---@param pre_escape? boolean
---@return table[]
local function make_output(state, line, pre_escape)
  if state.literal then
    if line == "\\`=" then
      line = "`="
    end
    return { { t = "text", style = state_style(state), text = line } }
  end

  local out, part = {}, {}
  local mode = "text"
  local escape = pre_escape or false
  local skip = 0
  local function flush()
    if #part > 0 then
      out[#out + 1] = { t = "text", style = state_style(state), text = table.concat(part) }
      part = {}
    end
  end
  local function at(k)
    return line:sub(k, k)
  end

  local i, n = 1, #line
  while i <= n do
    local c = at(i)
    if skip > 0 then
      skip = skip - 1
      i = i + 1
    elseif mode == "formatting" then
      local advance = true
      if c == "_" then
        state.underline = not state.underline
      elseif c == "!" then
        state.bold = not state.bold
      elseif c == "*" then
        state.italic = not state.italic
      elseif c == "F" or c == "B" then
        local key = c == "F" and "fg" or "bg"
        local color
        if at(i + 1) == "T" and n >= i + 7 then
          color, skip = line:sub(i + 2, i + 7), 7
        elseif at(i + 4) == "`" and at(i + 5) == c and n >= i + 8 then
          color = at(i + 6) .. at(i + 1) .. at(i + 7) .. at(i + 2) .. at(i + 8) .. at(i + 3)
          skip = 8
        elseif n >= i + 3 then
          color, skip = line:sub(i + 1, i + 3), 3
        end
        if color then
          state[key] = color
          if c == "B" then
            flush()
          end
        end
      elseif c == "f" then
        state.fg = state.default_fg
      elseif c == "b" then
        state.bg = state.default_bg
        flush()
      elseif c == "`" then
        reset_formatting(state)
      elseif c == "c" then
        state.align = "center"
      elseif c == "l" then
        state.align = "left"
      elseif c == "r" then
        state.align = "right"
      elseif c == "a" then
        state.align = state.default_align
      elseif c == "<" then
        flush()
        local field, close = parse_field(line, i + 1, state)
        if field then
          out[#out + 1] = field
          i = close --[[@as integer]]
          advance = false
        end
      elseif c == "[" then
        flush()
        local link, close = parse_link(line, i, state)
        if link then
          out[#out + 1] = link
          i = close --[[@as integer]]
          advance = false
        end
      elseif c == ":" then
        local name = line:match("^[%w_%-]*", i + 1)
        if name ~= "" then
          flush()
          out[#out + 1] = { t = "anchor", name = name }
        end
        mode = "text"
        i = i + 1 + #name
        advance = false
      end
      if advance then
        mode = "text"
        i = i + 1
      end
    else
      if escape then
        part[#part + 1] = c
        escape = false
      elseif c == "\\" then
        escape = true
      elseif c == "`" then
        flush()
        if at(i + 1) == "`" then
          reset_formatting(state)
          i = i + 1
        else
          mode = "formatting"
        end
      else
        part[#part + 1] = c
      end
      i = i + 1
    end
  end
  flush()
  return out
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

---@class micron.Renderer
---@field doc micron.Doc
---@field opts micron.RenderOpts
---@field state table
local R = {}
R.__index = R

---@param style micron.Style
---@param default_bg string
---@return string?
local function style_group(style, default_bg)
  return hl.group({
    fg = hl.to_hex(style.fg),
    bg = style.bg ~= default_bg and hl.to_hex(style.bg) or nil,
    bold = style.bold,
    underline = style.underline,
    italic = style.italic,
  })
end

---@param s string
---@return integer
local function width(s)
  return vim.api.nvim_strwidth(s)
end

--- Truncate to at most `max` display cells.
---@param s string
---@param max integer
---@return string
local function truncate(s, max)
  if width(s) <= max then
    return s
  end
  local chars = vim.fn.split(s, "\\zs")
  local out, w = {}, 0
  for _, ch in ipairs(chars) do
    local cw = width(ch)
    if w + cw > max - 1 then
      break
    end
    out[#out + 1] = ch
    w = w + cw
  end
  return table.concat(out) .. (max > 0 and "…" or "")
end

--- Convert parts into display chunks: {text, group?, link?, widget?, anchor?}.
---@param parts table[]
---@return table[]
function R:chunks(parts)
  local default_bg = self.state.default_bg
  local form = self.opts.form or {}
  local out = {}
  for _, p in ipairs(parts) do
    if p.t == "text" then
      out[#out + 1] = { text = p.text:gsub("\t", "    "), group = style_group(p.style, default_bg) }
    elseif p.t == "anchor" then
      out[#out + 1] = { text = "", anchor = p.name, header = p.header }
    elseif p.t == "link" then
      out[#out + 1] = {
        text = p.label,
        group = style_group(p.style, default_bg),
        extra = "MicronPreviewLink",
        link = { url = p.url, fields = p.fields },
      }
    elseif p.t == "field" then
      local value = form[p.name] or p.data
      local shown = p.masked and string.rep("*", vim.fn.strchars(value)) or value
      local pad = math.max(0, p.width - width(shown))
      out[#out + 1] = {
        text = shown .. string.rep(" ", pad),
        group = style_group(p.style, default_bg),
        extra = "MicronPreviewField",
        widget = { type = "field", name = p.name, value = value, masked = p.masked },
      }
    else -- checkbox / radio
      local checked = p.prechecked
      local current = form[p.name]
      if current ~= nil then
        if p.t == "checkbox" then
          checked = vim.tbl_contains(vim.split(current, ",", { plain = true, trimempty = true }), p.value)
        else
          checked = current == p.value
        end
      end
      local box = p.t == "checkbox" and (checked and "[X]" or "[ ]") or (checked and "(X)" or "( )")
      out[#out + 1] = {
        text = box .. " " .. p.label,
        group = style_group(p.style, default_bg),
        widget = { type = p.t, name = p.name, value = p.value, checked = checked, label = p.label },
      }
    end
  end
  return out
end

---@param chunks table[]
---@return integer
local function chunks_width(chunks)
  local w = 0
  for _, c in ipairs(chunks) do
    w = w + width(c.text)
  end
  return w
end

--- Emit one buffer row.
---@param chunks table[]
---@param o {indent?: integer, align?: string, line_bg?: string, line_hl?: string}
function R:emit(chunks, o)
  local doc = self.doc
  local row = #doc.lines
  local indent = math.max(0, o.indent or 0)
  local avail = self.opts.width - indent
  local w = chunks_width(chunks)
  local pad = 0
  if o.align == "center" and w < avail then
    pad = math.floor((avail - w) / 2)
  elseif o.align == "right" and w < avail then
    pad = avail - w
  end
  local buf = { string.rep(" ", indent + pad) }
  local col = indent + pad
  for _, c in ipairs(chunks) do
    local s, e = col, col + #c.text
    if c.group and e > s then
      doc.marks[#doc.marks + 1] = { row = row, col = s, end_col = e, hl = c.group, priority = 110 }
    end
    if c.extra and e > s then
      doc.marks[#doc.marks + 1] = { row = row, col = s, end_col = e, hl = c.extra, priority = 105 }
    end
    if c.link then
      doc.links[#doc.links + 1] = { row = row, col = s, end_col = e, url = c.link.url, fields = c.link.fields }
    end
    if c.widget then
      local wd = c.widget
      wd.row, wd.col, wd.end_col = row, s, e
      doc.widgets[#doc.widgets + 1] = wd
    end
    if c.anchor then
      doc.anchors[c.anchor] = doc.anchors[c.anchor] or row
      if c.header then
        doc.heading_rows[#doc.heading_rows + 1] = row
      end
    end
    buf[#buf + 1] = c.text
    col = e
  end
  local line_hl = o.line_hl or (o.line_bg and hl.group({ bg = o.line_bg }))
  if line_hl then
    doc.marks[#doc.marks + 1] = { row = row, hl = line_hl, line = true, priority = 100 }
  end
  doc.lines[#doc.lines + 1] = table.concat(buf)
end

---@return integer
function R:indent()
  return math.max(0, (self.state.depth - 1) * 2)
end

---@return string? "#rrggbb" when the current background differs from the page default
function R:line_bg()
  local s = self.state
  if s.bg ~= s.default_bg and s.bg ~= "default" then
    return hl.to_hex(s.bg)
  end
end

---@param text string
---@return string[]
local function table_row(text)
  text = vim.trim(text)
  text = text:gsub("^|", ""):gsub("|$", "")
  local cells, cur, escaped = {}, {}, false
  for ch in text:gmatch(".") do
    if escaped then
      cur[#cur + 1] = ch
      escaped = false
    elseif ch == "\\" then
      escaped = true
    elseif ch == "|" then
      cells[#cells + 1] = vim.trim(table.concat(cur))
      cur = {}
    else
      cur[#cur + 1] = ch
    end
  end
  cells[#cells + 1] = vim.trim(table.concat(cur))
  return cells
end

---@param chunks table[]
---@param max integer
---@return table[]
local function clip_chunks(chunks, max)
  local out, used = {}, 0
  for _, c in ipairs(chunks) do
    local w = width(c.text)
    if used + w <= max then
      out[#out + 1] = c
      used = used + w
    else
      local copy_c = vim.tbl_extend("force", {}, c)
      copy_c.text = truncate(c.text, max - used)
      out[#out + 1] = copy_c
      break
    end
  end
  return out
end

function R:render_table()
  local s = self.state
  local rows = s.table_buffer
  if #rows < 2 then
    return
  end
  local header = table_row(rows[1])
  local ncols = #header
  local aligns = {}
  for idx, cell in ipairs(table_row(rows[2])) do
    if cell:sub(1, 1) == ":" and cell:sub(-1) == ":" then
      aligns[idx] = "center"
    elseif cell:sub(-1) == ":" then
      aligns[idx] = "right"
    else
      aligns[idx] = "left"
    end
  end

  -- Cells are rendered with the surrounding state, which is restored after each cell.
  local grid = {}
  local function cell_chunks(text)
    local snap = { fg = s.fg, bg = s.bg, align = s.align, bold = s.bold, underline = s.underline, italic = s.italic }
    local chunks = self:chunks(make_output(s, text))
    for k, v in pairs(snap) do
      s[k] = v
    end
    return chunks
  end
  grid[1] = {}
  for c = 1, ncols do
    grid[1][c] = cell_chunks(header[c])
  end
  for r = 3, #rows do
    local cells = table_row(rows[r])
    local row = {}
    for c = 1, ncols do
      row[c] = cell_chunks(cells[c] or "")
    end
    grid[#grid + 1] = row
  end

  local widths = {}
  for c = 1, ncols do
    widths[c] = 1
    for _, row in ipairs(grid) do
      widths[c] = math.max(widths[c], chunks_width(row[c]))
    end
  end
  -- Shrink the widest columns until the table fits its max width (borders: 3 per col + 1).
  local maxw = s.table_maxwidth
  if maxw then
    local function total()
      local t = 1
      for c = 1, ncols do
        t = t + widths[c] + 3
      end
      return t
    end
    while total() > maxw do
      local widest = 1
      for c = 2, ncols do
        if widths[c] > widths[widest] then
          widest = c
        end
      end
      if widths[widest] <= 1 then
        break
      end
      widths[widest] = widths[widest] - 1
    end
  end

  local border =
    style_group({ fg = s.fg, bg = s.default_bg, bold = false, underline = false, italic = false }, s.default_bg)
  local function rule(l, m, r)
    local segs = {}
    for c = 1, ncols do
      segs[c] = string.rep("─", widths[c] + 2)
    end
    return { { text = l .. table.concat(segs, m) .. r, group = border } }
  end
  local function data_row(row)
    local out = { { text = "│", group = border } }
    for c = 1, ncols do
      local chunks = clip_chunks(row[c], widths[c])
      local free = widths[c] - chunks_width(chunks)
      local left = aligns[c] == "right" and free or aligns[c] == "center" and math.floor(free / 2) or 0
      out[#out + 1] = { text = " " .. string.rep(" ", left) }
      vim.list_extend(out, chunks)
      out[#out + 1] = { text = string.rep(" ", free - left) .. " " }
      out[#out + 1] = { text = "│", group = border }
    end
    return out
  end

  local align = ({ l = "left", c = "center", r = "right" })[s.table_align or ""] or "left"
  local o = { indent = self:indent(), align = align }
  self:emit(rule("┌", "┬", "┐"), o)
  self:emit(data_row(grid[1]), o)
  self:emit(rule("├", "┼", "┤"), o)
  for r = 2, #grid do
    self:emit(data_row(grid[r]), o)
  end
  self:emit(rule("└", "┴", "┘"), o)
end

---@param data string partial descriptor (between "`{" and "}")
function R:partial(data)
  local comps = vim.split(data, "`", { plain = true })
  local url = comps[1] or ""
  if url == "" or #comps > 3 then
    return
  end
  local refresh = comps[2] and tonumber(comps[2]) or nil
  if refresh and refresh < 1 then
    refresh = nil
  end
  local fields = (comps[3] and comps[3] ~= "") and vim.split(comps[3], "|", { plain = true }) or {}
  local id
  for _, f in ipairs(fields) do
    if f:sub(1, 4) == "pid=" then
      id = f:sub(5)
    end
  end
  local doc = self.doc
  doc.partials[#doc.partials + 1] = {
    row = #doc.lines,
    key = data,
    url = strip_scheme(url),
    refresh = refresh,
    fields = fields,
    id = id,
  }
  local cached = (self.opts.partials or {})[data]
  if cached and cached.doc then
    self:splice(cached.doc)
  elseif cached and cached.error then
    self:emit({ { text = "⧖ " .. url .. ": " .. cached.error:gsub("\n", " "), group = "MicronPreviewError" } }, {})
  else
    self:emit({ { text = "⧖ " .. url, group = "MicronPreviewPartial" } }, { indent = self:indent() })
  end
end

--- Append a rendered sub-document (partial content), shifting its rows.
---@param sub micron.Doc
function R:splice(sub)
  local doc = self.doc
  local off = #doc.lines
  vim.list_extend(doc.lines, sub.lines)
  for _, m in ipairs(sub.marks) do
    doc.marks[#doc.marks + 1] = vim.tbl_extend("force", {}, m, { row = m.row + off })
  end
  for _, l in ipairs(sub.links) do
    doc.links[#doc.links + 1] = vim.tbl_extend("force", {}, l, { row = l.row + off })
  end
  for _, w in ipairs(sub.widgets) do
    doc.widgets[#doc.widgets + 1] = vim.tbl_extend("force", {}, w, { row = w.row + off })
  end
  for name, row in pairs(sub.anchors) do
    doc.anchors[name] = doc.anchors[name] or row + off
  end
end

---@param line string
function R:line(line)
  local s = self.state
  if line == "" then
    self:emit({}, { indent = self:indent(), line_bg = self:line_bg() })
    return
  end

  if line == "`=" then
    s.literal = not s.literal
    return
  end

  if not s.literal and line:sub(1, 2) == "`t" then
    if s.table_mode then
      self:render_table()
      s.table_mode, s.table_buffer, s.table_align, s.table_maxwidth = false, {}, nil, nil
    else
      local rest = line:sub(3)
      local align = rest:match("^[lcr]")
      if align then
        rest = rest:sub(2)
      end
      s.table_mode, s.table_buffer, s.table_align = true, {}, align
      s.table_maxwidth = tonumber(rest:match("^%d+"))
    end
    return
  end
  if s.table_mode then
    s.table_buffer[#s.table_buffer + 1] = line
    return
  end

  local pre_escape = false
  if not s.literal then
    if line:sub(1, 1) == ">" and line:find("`<", 1, true) then
      line = line:gsub("^>+", "")
    end
    local c = line:sub(1, 1)
    if c == "\\" then
      line = line:sub(2)
      pre_escape = true
    elseif c == "#" then
      return
    elseif line:sub(1, 2) == "`{" then
      local close = line:find("}", 3, true)
      if close then
        self:partial(line:sub(3, close - 1))
      end
      return
    elseif c == "<" then
      s.depth = 0
      if #line > 1 then
        self:line(line:sub(2))
      end
      return
    elseif c == ">" then
      local depth = #line:match("^>+")
      s.depth = depth
      local text = line:sub(depth + 1)
      if text == "" then
        return
      end
      local style = { fg = s.default_fg, bg = "default", bold = false, underline = false, italic = false }
      local headings = HEADINGS[self.opts.dark and "dark" or "light"]
      style = headings[math.min(depth, #headings)] or style
      style = vim.tbl_extend("force", { bold = false, underline = false, italic = false }, style)
      local latched = state_style(s)
      apply_style(style, s)
      local parts = make_output(s, text)
      apply_style(latched, s)
      local slug = M.slugify(text)
      if slug ~= "" then
        table.insert(parts, 1, { t = "anchor", name = slug, header = true })
      end
      self:emit(self:chunks(parts), {
        indent = self:indent(),
        align = s.align,
        line_hl = style_group(copy(style --[[@as micron.Style]]), "none"),
      })
      return
    elseif c == "-" then
      local chars = vim.fn.split(line, "\\zs")
      local ch = "─"
      if #chars == 2 and (chars[2]:byte() or 0) >= 32 then
        ch = chars[2]
      end
      local avail = math.max(1, self.opts.width - self:indent())
      local text = string.rep(ch, math.floor(avail / math.max(1, width(ch))))
      local group = style_group({ fg = s.fg, bg = s.bg, bold = false, underline = false, italic = false }, s.default_bg)
      self:emit({ { text = text, group = group } }, { indent = self:indent(), line_bg = self:line_bg() })
      return
    end
  end

  local parts = make_output(s, line, pre_escape)
  if #parts == 0 then
    return
  end
  self:emit(self:chunks(parts), { indent = self:indent(), align = s.align, line_bg = self:line_bg() })
end

--- Render Micron markup.
---@param markup string
---@param opts micron.RenderOpts
---@return micron.Doc
function M.render(markup, opts)
  local lines = vim.split((markup:gsub("\r\n", "\n")), "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  local page_fg, page_bg = header_colors(lines)
  local default_fg = page_fg or (opts.dark and DEFAULT_FG_DARK or DEFAULT_FG_LIGHT)
  local default_bg = page_bg or "default"
  local self = setmetatable({
    opts = opts,
    doc = {
      lines = {},
      marks = {},
      links = {},
      widgets = {},
      partials = {},
      anchors = {},
      heading_rows = {},
      page_bg = hl.to_hex(page_bg),
    },
    state = {
      literal = false,
      depth = 0,
      fg = default_fg,
      bg = default_bg,
      bold = false,
      underline = false,
      italic = false,
      align = "left",
      default_align = "left",
      default_fg = default_fg,
      default_bg = default_bg,
      table_mode = false,
      table_buffer = {},
    },
  }, R)
  for _, line in ipairs(lines) do
    self:line(line)
  end
  if self.state.table_mode then
    -- Unterminated table: render what we have rather than dropping content.
    self:render_table()
  end
  return self.doc
end

M._make_output = make_output

return M
