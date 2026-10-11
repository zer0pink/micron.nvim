-- Wrap selections in Micron tags, insert colour tags, convert colours, hover hints.
local colors = require("micron.colors")
local tags = require("micron.tags")

local M = {}

local api = vim.api

---@class micron.Selection
---@field srow integer 0-based
---@field scol integer 0-based byte
---@field erow integer 0-based
---@field ecol integer 0-based byte, exclusive

--- Last visual selection as a charwise range ('V' covers whole lines).
---@return micron.Selection
local function last_selection()
  local s = api.nvim_buf_get_mark(0, "<")
  local e = api.nvim_buf_get_mark(0, ">")
  local mode = vim.fn.visualmode()
  local srow, erow = s[1] - 1, e[1] - 1
  local scol, ecol
  if mode == "V" then
    scol = 0
    ecol = #(api.nvim_buf_get_lines(0, erow, erow + 1, true)[1] or "")
  else
    scol = s[2]
    local line = api.nvim_buf_get_lines(0, erow, erow + 1, true)[1] or ""
    -- '> marks the first byte of the last character; include the whole character
    local char = vim.fn.strpart(line, e[2], 1, true)
    ecol = math.min(#line, e[2] + math.max(1, #char))
  end
  return { srow = srow, scol = scol, erow = erow, ecol = ecol }
end

---@param sel micron.Selection
---@return string
local function selection_text(sel)
  return table.concat(api.nvim_buf_get_text(0, sel.srow, sel.scol, sel.erow, sel.ecol, {}), "\n")
end

---@param sel micron.Selection
---@param text string
local function replace(sel, text)
  api.nvim_buf_set_text(0, sel.srow, sel.scol, sel.erow, sel.ecol, vim.split(text, "\n", { plain = true }))
end

--- Wrap the last visual selection (when `range` is set) or insert an empty pair at the cursor.
---@param left string
---@param right string
---@param range boolean
function M.wrap(left, right, range)
  if range then
    local sel = last_selection()
    replace(sel, left .. selection_text(sel) .. right)
    return
  end
  local esc = function(s)
    return (s:gsub("[%$}\\]", "\\%0"))
  end
  vim.snippet.expand(esc(left) .. "${1:text}" .. esc(right))
end

---@param kind "F"|"B"
---@param color string? Micron or hex colour; prompts when nil
---@param range boolean
function M.color(kind, color, range)
  local function apply(input)
    if not input or input == "" then
      return
    end
    local micron = colors.hex_to_micron(input)
    if not micron then
      vim.notify("Micron: use a 3-digit Micron colour (0a0) or hex (#00aa00)", vim.log.levels.WARN)
      return
    end
    M.wrap("`" .. kind .. micron, kind == "F" and "`f" or "`b", range)
  end
  if color then
    apply(color)
  else
    vim.ui.input({
      prompt = ("Micron %s colour: "):format(kind == "F" and "foreground" or "background"),
      default = kind == "F" and "0a0" or "444",
    }, apply)
  end
end

--- Convert between hex and Micron colours. Replaces the selection when given a range,
--- otherwise converts the argument (or a prompted value); the result is yanked to + and ".
---@param mode "to_micron"|"to_hex"
---@param arg string?
---@param range boolean
function M.convert(mode, arg, range)
  local sel = range and last_selection() or nil
  local function apply(input)
    if not input or input == "" then
      return
    end
    local out = mode == "to_micron" and colors.hex_to_micron(input) or colors.micron_to_hex(input)
    if not out then
      vim.notify(
        ("Micron: not a %s colour: %s"):format(mode == "to_micron" and "hex" or "Micron", input),
        vim.log.levels.WARN
      )
      return
    end
    if sel then
      replace(sel, out)
    end
    vim.fn.setreg('"', out)
    pcall(vim.fn.setreg, "+", out)
    local other = mode == "to_micron" and colors.micron_to_hex(out) or colors.hex_to_micron(out)
    vim.notify(("Micron: %s (%s) copied"):format(out, other))
  end
  if sel then
    apply(vim.trim(selection_text(sel)))
  elseif arg and arg ~= "" then
    apply(arg)
  else
    vim.ui.input({ prompt = mode == "to_micron" and "Hex colour: " or "Micron colour: " }, apply)
  end
end

--- Show the syntax hint for the tag under the cursor.
function M.hover()
  local cur = api.nvim_win_get_cursor(0)
  local line = api.nvim_get_current_line()
  local hint = tags.hint_at(line, cur[2])
  if not hint then
    vim.notify("Micron: no tag under cursor (:help micron-syntax)")
    return
  end
  -- Plain text: Micron tags are full of backticks that markdown would turn into code spans.
  vim.lsp.util.open_floating_preview({ hint.body, "", ":help micron-syntax" }, "text", {
    border = "rounded",
    title = " " .. hint.title .. " ",
    focus_id = "micron_hover",
    wrap_at = 72,
  })
end

return M
