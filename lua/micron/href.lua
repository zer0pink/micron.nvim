-- Link parsing, local node path resolution, and form-field / environment merging.
-- Mirrors rns-micron-vsix src/scriptRunner.ts + src/previewConfig.ts.
local M = {}

local uv = vim.uv or vim.loop

---@class micron.Href
---@field kind "page"|"file"|"http"|"hash"|"unknown"
---@field path string
---@field raw string
---@field node? string destination hash when the link targets another node
---@field request_vars table<string,string>

---@param s string
---@param prefix string
local function starts(s, prefix)
  return s:sub(1, #prefix) == prefix
end

---@param suffix string
---@return table<string,string>
local function parse_request_vars(suffix)
  local out = {}
  for part in (suffix .. "|"):gmatch("([^|]*)|") do
    local eq = part:find("=", 1, true)
    if eq and eq > 1 then
      out[part:sub(1, eq - 1)] = part:sub(eq + 1)
    end
  end
  return out
end

---@param href string?
---@return micron.Href
function M.parse(href)
  local target = vim.trim(href or "")
  local raw = target
  local lower = target:lower()
  if starts(lower, "nomadnetwork://") then
    target = target:sub(#"nomadnetwork://" + 1)
  elseif starts(lower, "lxmf://") then
    target = target:sub(#"lxmf://" + 1)
  end

  if target == "" or target == "#" then
    return { kind = "hash", path = "", raw = raw, request_vars = {} }
  end
  if starts(target, "#") then
    return { kind = "hash", path = target, raw = raw, request_vars = {} }
  end
  if target:lower():match("^https?://") then
    return { kind = "http", path = target, raw = raw, request_vars = {} }
  end

  local node
  local hash, rest = target:match("^(%x+):(.*)$")
  if hash and #hash >= 16 then
    node = hash:lower()
    target = rest
  elseif starts(target, ":") then
    target = target:sub(2)
  end

  local request_vars = {}
  local tick = target:find("`", 1, true)
  if tick then
    request_vars = parse_request_vars(target:sub(tick + 1))
    target = target:sub(1, tick - 1)
  end

  local function result(kind, path)
    return { kind = kind, path = path, raw = raw, node = node, request_vars = request_vars }
  end
  for _, p in ipairs({ { "/page/", "page" }, { "page/", "page" }, { "/file/", "file" }, { "file/", "file" } }) do
    if starts(target, p[1]) then
      return result(p[2], target:sub(#p[1] + 1))
    end
  end
  if target:sub(-3) == ".mu" then
    return result("page", (target:gsub("^/", "")))
  end
  return result("unknown", (target:gsub("^/", "")))
end

---@param path string
---@return boolean
local function is_file(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "file"
end

---@param path string
---@return boolean
local function is_dir(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

---@param p string
---@return boolean
local function has_dotdot(p)
  return p:find("..", 1, true) ~= nil
end

--- Walk up (at most 6 levels) to the node `pages` directory.
---@param start_dir string
---@return string?
function M.pages_root(start_dir)
  local cur = vim.fs.normalize(start_dir)
  for _ = 1, 6 do
    if vim.fs.basename(cur) == "pages" then
      return cur
    end
    local parent = vim.fs.dirname(cur)
    if parent == cur then
      break
    end
    cur = parent
  end
  return nil
end

--- Node root: parent of pages/, else parent of the page directory.
---@param page_path string
---@return string
function M.node_root(page_path)
  local dir = vim.fs.dirname(vim.fs.normalize(page_path))
  local pages = M.pages_root(dir)
  return vim.fs.dirname(pages or dir)
end

---@param page_path string
---@return string? existing files/ directory of the node
function M.files_dir(page_path)
  local dir = vim.fs.joinpath(M.node_root(page_path), "files")
  return is_dir(dir) and dir or nil
end

---@param from_path string absolute path of the current page
---@param href string
---@return string?
function M.resolve_page(from_path, href)
  local parsed = M.parse(href)
  if parsed.kind ~= "page" or parsed.path == "" or has_dotdot(parsed.path) then
    return nil
  end
  local from_dir = vim.fs.dirname(vim.fs.normalize(from_path))
  local direct = vim.fs.normalize(vim.fs.joinpath(from_dir, parsed.path))
  if is_file(direct) then
    return direct
  end
  local pages = M.pages_root(from_dir)
  if pages then
    local under = vim.fs.normalize(vim.fs.joinpath(pages, parsed.path))
    if is_file(under) then
      return under
    end
  end
  return nil
end

---@param from_path string
---@param href string
---@return string?
function M.resolve_file(from_path, href)
  local parsed = M.parse(href)
  if parsed.kind ~= "file" or parsed.path == "" or has_dotdot(parsed.path) then
    return nil
  end
  local base = vim.fs.basename(parsed.path)
  local from_dir = vim.fs.dirname(vim.fs.normalize(from_path))
  local root = M.node_root(from_path)
  local candidates = {
    vim.fs.joinpath(root, "files", base),
    vim.fs.joinpath(root, "files", parsed.path),
    vim.fs.joinpath(vim.fs.dirname(from_dir), "files", base),
    vim.fs.joinpath(from_dir, base),
  }
  for _, c in ipairs(candidates) do
    c = vim.fs.normalize(c)
    if is_file(c) then
      return c
    end
  end
  return nil
end

--- Merge sticky preview fields with a navigation payload.
--- Empty values clear keys; `clear` is one-shot and never sticky.
---@param sticky table<string,string>
---@param incoming table<string,string>
---@param request_vars? table<string,string>
---@return table<string,string>
function M.merge_fields(sticky, incoming, request_vars)
  local overlay = vim.tbl_extend("force", {}, incoming or {}, request_vars or {})
  local next_fields = vim.tbl_extend("force", {}, sticky or {}, overlay)
  for k, v in pairs(overlay) do
    if v == "" then
      next_fields[k] = nil
    end
  end
  next_fields.clear = nil
  return next_fields
end

--- Script environment: base env + extra env + fields. Each field is also exported as
--- field_<name> (unless already prefixed), and field_<name> fills a missing bare <name>.
--- Explicitly supplied keys always beat derived ones.
---@param fields table<string,string>
---@param extra_env table<string,string>
---@param base_env? table<string,string> defaults to the current process environment
---@return table<string,string>
function M.build_env(fields, extra_env, base_env)
  fields = fields or {}
  local env = vim.tbl_extend("force", {}, base_env or uv.os_environ(), extra_env or {}, fields)
  for key, value in pairs(fields) do
    if not starts(key, "field_") and not starts(key, "var_") and fields["field_" .. key] == nil then
      env["field_" .. key] = value
    end
  end
  for key, value in pairs(fields) do
    local bare = starts(key, "field_") and key:sub(#"field_" + 1) or ""
    if bare ~= "" and env[bare] == nil then
      env[bare] = value
    end
  end
  return env
end

--- Sidecars written by page scripts must not retrigger the preview.
---@param path string
---@return boolean
function M.ignore_watch(path)
  local low = vim.fs.basename(path):lower()
  return low:match("%.lock$") ~= nil
    or low:match("%.tmp$") ~= nil
    or low:match("%.visits%.json$") ~= nil
    or low:match("%.thanks%.json$") ~= nil
end

return M
