-- On-demand highlight groups for Micron colours/attributes in the preview.
local M = {}

---@type table<string, true>
local defined = {}

--- Micron colour ("0a0", "00aa00", "g50") to "#rrggbb", or nil for default/invalid.
---@param c string?
---@return string?
function M.to_hex(c)
  if not c or c == "default" then
    return nil
  end
  if c:match("^%x%x%x$") then
    local r, g, b = c:sub(1, 1), c:sub(2, 2), c:sub(3, 3)
    return ("#%s%s%s%s%s%s"):format(r, r, g, g, b, b):lower()
  end
  if c:match("^%x%x%x%x%x%x$") then
    return "#" .. c:lower()
  end
  if c:match("^g") and #c == 3 then
    local val = tonumber(c:sub(2)) or 50
    return ("#%02x%02x%02x"):format(math.floor(val * 2.55), math.floor(val * 2.55), math.floor(val * 2.55))
  end
  return nil
end

---@param hex string "#rrggbb"
---@return integer xterm-256 colour
local function cterm(hex)
  local r, g, b = tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
  local function q(v)
    return math.floor(v / 255 * 5 + 0.5)
  end
  return 16 + 36 * q(r) + 6 * q(g) + q(b)
end

---@param hex string
---@return boolean
function M.is_light(hex)
  local r, g, b = tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
  return (0.299 * r + 0.587 * g + 0.114 * b) > 140
end

---@param spec {fg?:string, bg?:string, bold?:boolean, underline?:boolean, italic?:boolean}
---@return string? group name, nil when the spec has no attributes
function M.group(spec)
  local flags = (spec.bold and "b" or "") .. (spec.underline and "u" or "") .. (spec.italic and "i" or "")
  if not spec.fg and not spec.bg and flags == "" then
    return nil
  end
  local name = ("MicronP_%s_%s_%s"):format((spec.fg or "x"):gsub("#", ""), (spec.bg or "x"):gsub("#", ""), flags)
  if not defined[name] then
    vim.api.nvim_set_hl(0, name, {
      fg = spec.fg,
      bg = spec.bg,
      ctermfg = spec.fg and cterm(spec.fg) or nil,
      ctermbg = spec.bg and cterm(spec.bg) or nil,
      bold = spec.bold or nil,
      underline = spec.underline or nil,
      italic = spec.italic or nil,
    })
    defined[name] = true
  end
  return name
end

--- Colorschemes run :hi clear, so dynamic groups must be recreated afterwards.
function M.reset()
  defined = {}
end

function M.define_static()
  local set = function(name, val)
    val.default = true
    vim.api.nvim_set_hl(0, name, val)
  end
  set("MicronPreviewLink", {})
  set("MicronPreviewField", { underline = true })
  set("MicronPreviewPartial", { link = "Comment" })
  set("MicronPreviewError", { link = "DiagnosticError" })
  set("MicronPreviewInfo", { link = "Comment" })
  set("MicronPreviewTitle", { link = "Title" })
  -- Same defaults as syntax/micron.vim; also used for tags inside Python page strings.
  set("micronTag", { link = "Keyword" })
  set("micronAnchor", { link = "Label" })
  set("micronColor", { link = "Constant" })
  set("micronField", { link = "Identifier" })
  set("micronPartial", { link = "PreProc" })
  set("micronLink", { link = "Underlined" })
end

return M
