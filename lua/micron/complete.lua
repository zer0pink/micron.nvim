-- Tag completion: an omnifunc (snippet expanded on accept) and a blink.cmp source.
local tags = require("micron.tags")

local M = {}

--- Items matching the text typed since the last backtick (or a heading at line start).
---@param before string line text before the cursor
---@return integer? start 0-based byte column the completion replaces from
---@return micron.TagItem[]
function M.candidates(before)
  local tick = before:match(".*()`")
  if not tick then
    if before:match("^%s*$") then
      for _, item in ipairs(tags.items) do
        if item.label == ">" then
          return #before, { item }
        end
      end
    end
    return nil, {}
  end
  local typed = before:sub(tick):lower()
  local out = {}
  for _, item in ipairs(tags.items) do
    local label = item.label:lower()
    if item.label:sub(1, 1) == "`" and (typed == "`" or label:sub(1, #typed) == typed) then
      out[#out + 1] = item
    end
  end
  return tick - 1, out
end

--- 'omnifunc' implementation. Accepting an item expands its snippet body.
---@param findstart integer
---@param base string
---@return integer|table
function M.omnifunc(findstart, base)
  if findstart == 1 then
    local col = vim.fn.col(".") - 1
    return (M.candidates(vim.api.nvim_get_current_line():sub(1, col))) or -3
  end
  -- Vim removes `base` from the line before this second call, so match on it directly.
  local _, items = M.candidates(base)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = { word = item.label, menu = item.detail, kind = "s", user_data = { micron = item.body } }
  end
  return out
end

--- Expand the snippet of an accepted omnifunc item (CompleteDone handler).
function M.on_complete_done()
  local item = vim.v.completed_item
  local body = type(item) == "table" and type(item.user_data) == "table" and item.user_data.micron
  if not body then
    return
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local start = col - #item.word
  vim.api.nvim_buf_set_text(0, row - 1, start, row - 1, col, { "" })
  vim.api.nvim_win_set_cursor(0, { row, start })
  vim.snippet.expand(body)
end

-- ---------------------------------------------------------------------------
-- blink.cmp source:  sources.providers.micron = { name = "Micron", module = "micron.blink" }
-- ---------------------------------------------------------------------------

local blink = {}
blink.__index = blink

function blink.new()
  return setmetatable({}, blink)
end

function blink:enabled()
  return vim.bo.filetype == "micron" or vim.b.micron_page == true
end

function blink:get_trigger_characters()
  return { "`" }
end

function blink:get_completions(ctx, callback)
  local row, col = ctx.cursor[1], ctx.cursor[2]
  local start, items = M.candidates(ctx.line:sub(1, col))
  local out = {}
  if start then
    for _, item in ipairs(items) do
      out[#out + 1] = {
        label = item.label,
        filterText = item.label:gsub("^`", ""),
        detail = item.detail,
        kind = 15, -- Snippet
        insertTextFormat = 2, -- Snippet
        textEdit = {
          newText = item.body,
          range = { start = { line = row - 1, character = start }, ["end"] = { line = row - 1, character = col } },
        },
      }
    end
  end
  callback({ items = out, is_incomplete_forward = false, is_incomplete_backward = false })
end

M.blink = blink

return M
