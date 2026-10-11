-- Micron tag highlights inside triple-quoted strings of shebang Python pages.
local tags = require("micron.tags")

local M = {}

M.ns = vim.api.nvim_create_namespace("micron_python_strings")

local query

---@param buf integer
---@return {[1]:integer,[2]:integer,[3]:integer,[4]:integer}[]? ranges, nil when the python parser is unavailable
local function string_ranges(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "python")
  if not ok or not parser then
    return nil
  end
  if not query then
    query = vim.treesitter.query.parse("python", "(string) @s")
  end
  local tree = parser:parse()[1]
  local out = {}
  for _, node in query:iter_captures(tree:root(), buf, 0, -1) do
    local sr, sc, er, ec = node:range()
    local first = vim.api.nvim_buf_get_lines(buf, sr, sr + 1, false)[1] or ""
    local head = first:sub(sc + 1, sc + 6)
    if head:match('^%a*"""') or head:match("^%a*'''") then
      out[#out + 1] = { sr, sc, er, ec }
    end
  end
  return out
end

---@param buf integer
function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local ranges = string_ranges(buf) or { { 0, 0, #lines, 0 } }
  for _, r in ipairs(ranges) do
    local sr, sc, er, ec = r[1], r[2], r[3], r[4]
    for row = sr, math.min(er, #lines - 1) do
      local line = lines[row + 1]
      local lo = row == sr and sc or 0
      local hi = row == er and ec or #line
      for _, tok in ipairs(tags.scan(line)) do
        if tok.s >= lo and tok.e <= hi then
          vim.api.nvim_buf_set_extmark(buf, M.ns, row, tok.s, { end_col = tok.e, hl_group = tok.group, priority = 125 })
        end
      end
    end
  end
end

return M
