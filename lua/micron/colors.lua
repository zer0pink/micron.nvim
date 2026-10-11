-- Colour swatches on `Fxxx / `Bxxx and hex <-> Micron conversion.
local config = require("micron.config")
local hl = require("micron.preview.hl")
local tags = require("micron.tags")

local M = {}

M.ns = vim.api.nvim_create_namespace("micron_colors")

--- "#00aa00" / "00aa00" / "#0a0" / "0a0" -> "0a0"
---@param input string
---@return string?
function M.hex_to_micron(input)
  local raw = vim.trim(input or "")
  local h6 = raw:match("^#?(%x%x%x%x%x%x)$")
  if h6 then
    local out = {}
    for i = 1, 5, 2 do
      out[#out + 1] = ("%x"):format(math.floor(tonumber(h6:sub(i, i + 1), 16) / 17 + 0.5))
    end
    return table.concat(out)
  end
  local h3 = raw:match("^#?(%x%x%x)$")
  return h3 and h3:lower() or nil
end

--- "0a0" / "`F0a0" / "`B0a0`b" -> "#00aa00"
---@param input string
---@return string?
function M.micron_to_hex(input)
  local cleaned = vim.trim(input or ""):gsub("^`[FBf]?", ""):gsub("`[fb]?$", "")
  if not cleaned:match("^%x%x%x$") then
    return nil
  end
  return hl.to_hex(cleaned)
end

---@param buf integer
function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  if not config.get().editor.color_swatches then
    return
  end
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    for _, tok in ipairs(tags.scan(line)) do
      local hex = tok.color and hl.to_hex(tok.color)
      if hex then
        local group = hl.group({ fg = hl.is_light(hex) and "#000000" or "#ffffff", bg = hex })
        local start = tok.s + (#tok.color == 6 and 3 or 2)
        vim.api.nvim_buf_set_extmark(buf, M.ns, lnum - 1, start, { end_col = tok.e, hl_group = group, priority = 150 })
      end
    end
  end
end

return M
