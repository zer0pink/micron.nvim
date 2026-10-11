-- Script execution trust, keyed by node root (parent of pages/).
-- Neovim has no workspace trust, so scripted pages only run once the user trusts the node.
local M = {}

local uv = vim.uv or vim.loop

local function store_path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "micron", "trusted.json")
end

---@type table<string, true>?
local cache

---@return table<string, true>
local function load()
  if cache then
    return cache
  end
  cache = {}
  local fd = io.open(store_path(), "r")
  if fd then
    local ok, data = pcall(vim.json.decode, fd:read("*a"))
    fd:close()
    if ok and type(data) == "table" then
      for _, root in ipairs(data) do
        cache[root] = true
      end
    end
  end
  return cache
end

local function save()
  local list = vim.tbl_keys(load())
  table.sort(list)
  vim.fn.mkdir(vim.fs.dirname(store_path()), "p")
  local fd = assert(io.open(store_path(), "w"))
  fd:write(vim.json.encode(list))
  fd:close()
end

---@param root string
---@return string
local function canonical(root)
  return vim.fs.normalize(uv.fs_realpath(root) or root)
end

---@param root string
---@return boolean
function M.is_trusted(root)
  local key = canonical(root)
  for trusted in pairs(load()) do
    if key == trusted or key:sub(1, #trusted + 1) == trusted .. "/" then
      return true
    end
  end
  return false
end

---@param root string
function M.trust(root)
  load()[canonical(root)] = true
  save()
end

---@param root string
---@return boolean removed
function M.untrust(root)
  local key = canonical(root)
  if not load()[key] then
    return false
  end
  load()[key] = nil
  save()
  return true
end

---@return string[]
function M.list()
  local list = vim.tbl_keys(load())
  table.sort(list)
  return list
end

return M
