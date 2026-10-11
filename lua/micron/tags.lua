-- Shared Micron tag knowledge: completion items, hover hints and an inline tag scanner.
local M = {}

---@class micron.TagItem
---@field label string
---@field body string  LSP snippet body
---@field detail string

---@type micron.TagItem[]
M.items = {
  { label = "`F", body = "`F${1:0a0}${2:text}`f", detail = "Foreground color" },
  { label = "`B", body = "`B${1:444}${2:text}`b", detail = "Background color" },
  { label = "`!", body = "`!${1:text}`!", detail = "Bold" },
  { label = "`*", body = "`*${1:text}`*", detail = "Italic" },
  { label = "`_", body = "`_${1:text}`_", detail = "Underline" },
  { label = "``", body = "``", detail = "Reset all formatting" },
  { label = "`c", body = "`c${1:centered}", detail = "Center align" },
  { label = "`l", body = "`l", detail = "Left align" },
  { label = "`r", body = "`r${1:right}", detail = "Right align" },
  { label = "`a", body = "`a", detail = "Default align" },
  { label = "`f", body = "`f", detail = "Reset foreground" },
  { label = "`b", body = "`b", detail = "Reset background" },
  { label = "`[", body = "`[${1:label}`:${2:/page/index.mu}]", detail = "Page link" },
  { label = "`[file", body = "`[${1:name}`:${2:/file/name.zip}]", detail = "File link" },
  { label = "`<", body = "`B444`<${1:16}|${2:name}`${3}>`b", detail = "Text field" },
  { label = "`<?", body = "`B444`<?|${1:field}|${2:1}`>`b ${3:Label}", detail = "Checkbox" },
  { label = "`<^", body = "`B444`<^|${1:group}|${2:value}`>`b ${3:Label}", detail = "Radio" },
  { label = "`{", body = "`{:${1:/page/partial.mu}`${2:5}}", detail = "Partial / live fragment" },
  { label = "`=", body = "`=\n${1}\n`=", detail = "Literal block" },
  { label = "`t", body = "`t\n${1:A}|${2:B}\n-|-\n${3:1}|${4:2}\n`t", detail = "Table" },
  { label = ">", body = ">${1:Heading}\n${2}", detail = "Section heading" },
  { label = "#!c=", body = "#!c=${1:60}", detail = "Cache / refresh seconds" },
}

---@class micron.Hint
---@field pattern string  Lua pattern anchored at the tag start
---@field title string
---@field body string

---@type micron.Hint[]
M.hints = {
  {
    pattern = "^`FT%x%x%x%x%x%x",
    title = "Foreground color (24-bit)",
    body = "`FTrrggbb sets a 24-bit foreground. Close with `f.",
  },
  {
    pattern = "^`BT%x%x%x%x%x%x",
    title = "Background color (24-bit)",
    body = "`BTrrggbb sets a 24-bit background. Close with `b.",
  },
  {
    pattern = "^`F%x%x%x",
    title = "Foreground color",
    body = "`Fxxx starts a 3-nibble foreground color. Close with `f.",
  },
  {
    pattern = "^`B%x%x%x",
    title = "Background color",
    body = "`Bxxx starts a 3-nibble background color. Close with `b.",
  },
  {
    pattern = "^`%[",
    title = "Link",
    body = "`[label`:/page/path.mu] or `[label`:/page/path.mu`fields]. Same-node paths look like :/page/…; `* submits all fields, key=value adds request variables.",
  },
  {
    pattern = "^`<",
    title = "Input field",
    body = "`<name`default> or `<16|name`> or `<!|pass`secret>. Checkboxes `<?|name|value`label>, radios `<^|group|value`label>; append |* to pre-check.",
  },
  {
    pattern = "^`{",
    title = "Partial",
    body = "`{:/page/bit.mu`refresh`fields} embeds a fragment. refresh is seconds (>= 1); pid=… gives it a stable id.",
  },
  { pattern = "^`!", title = "Bold", body = "Toggle bold with `! … `!." },
  { pattern = "^`%*", title = "Italic", body = "Toggle italic with `* … `*." },
  { pattern = "^`_", title = "Underline", body = "Toggle underline with `_ … `_." },
  { pattern = "^``", title = "Reset", body = "`` clears all active formatting, colors and alignment." },
  {
    pattern = "^`[clra]",
    title = "Alignment",
    body = "`c center, `l left, `r right, `a default. Applies to the current line onward.",
  },
  {
    pattern = "^`=",
    title = "Literal block",
    body = "A line containing only `= toggles a literal block. Close with another `= line.",
  },
  {
    pattern = "^`t",
    title = "Table",
    body = "A line `t[l|c|r][maxwidth] opens a table; rows use | separators, the second row sets alignment (:-:, -:). Close with `t.",
  },
  { pattern = "^`:", title = "Anchor", body = "`:name defines an anchor; link to it with `[label`#name]." },
  {
    pattern = "^>",
    title = "Section",
    body = ">Heading starts a section. More > means deeper nesting; a line starting with < resets depth.",
  },
}

---@class micron.Token
---@field s integer 0-based byte start
---@field e integer 0-based byte end (exclusive)
---@field group string
---@field color? string 3- or 6-digit hex for colour tokens
---@field kind? "F"|"B"

local SIMPLE = {
  f = true,
  b = true,
  c = true,
  l = true,
  r = true,
  a = true,
  t = true,
  ["!"] = true,
  ["="] = true,
  ["*"] = true,
  ["_"] = true,
}
local CLOSERS = { ["["] = { "]", "micronLink" }, ["{"] = { "}", "micronPartial" }, ["<"] = { ">", "micronField" } }

--- Scan one line for inline Micron tags (same rules as syntax/micron.vim).
---@param line string
---@return micron.Token[]
function M.scan(line)
  local out = {}
  local i = 1
  local n = #line
  while i <= n do
    local tick = line:find("`", i, true)
    if not tick then
      break
    end
    local c = line:sub(tick + 1, tick + 1)
    local closer = CLOSERS[c]
    local stop
    if closer then
      local close = line:find(closer[1], tick + 2, true)
      if close then
        out[#out + 1] = { s = tick - 1, e = close, group = closer[2] }
        stop = close
      end
    elseif c == "F" or c == "B" then
      local hex6 = line:match("^T(%x%x%x%x%x%x)", tick + 2)
      local hex3 = not hex6 and line:match("^(%x%x%x)", tick + 2)
      local gray = not hex6 and not hex3 and line:match("^(g%d%d)", tick + 2)
      local value = hex6 or hex3 or gray
      if value then
        local len = hex6 and 8 or 4
        out[#out + 1] = { s = tick - 1, e = tick - 1 + len, group = "micronColor", color = value, kind = c }
        stop = tick + len - 1
      end
    elseif c == "`" or SIMPLE[c] then
      out[#out + 1] = { s = tick - 1, e = tick + 1, group = "micronTag" }
      stop = tick + 1
    elseif c == ":" then
      local name = line:match("^[%w_%-]*", tick + 2)
      out[#out + 1] = { s = tick - 1, e = tick + 1 + #name, group = "micronAnchor" }
      stop = tick + 1 + #name
    end
    i = (stop or tick) + 1
  end
  return out
end

--- Find the hint for the tag under (or nearest before) a 0-based byte column.
---@param line string
---@param col integer
---@return micron.Hint?
function M.hint_at(line, col)
  for _, tok in ipairs(M.scan(line)) do
    if col >= tok.s and col < tok.e then
      local slice = line:sub(tok.s + 1)
      for _, hint in ipairs(M.hints) do
        if slice:match(hint.pattern) then
          return hint
        end
      end
    end
  end
  if line:match("^>") then
    return M.hints[#M.hints]
  end
  if line == "`=" then
    for _, hint in ipairs(M.hints) do
      if hint.title == "Literal block" then
        return hint
      end
    end
  end
  return nil
end

return M
