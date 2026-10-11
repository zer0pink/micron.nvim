local M = {}

--- Fold sections: `>` lines open a fold at their depth, a line starting with `<` closes all.
---@param lnum integer
---@return string|integer
function M.expr(lnum)
  local line = vim.fn.getline(lnum)
  local depth = line:match("^(>+)")
  if depth and not line:find("`<", 1, true) then
    return ">" .. #depth
  end
  if line:sub(1, 1) == "<" then
    return 0
  end
  return "="
end

return M
