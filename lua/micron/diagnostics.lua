-- Unclosed tags, missing local /page and /file targets, unterminated literal blocks.
local config = require("micron.config")
local href = require("micron.href")

local M = {}

M.ns = vim.api.nvim_create_namespace("micron_diagnostics")

local S = vim.diagnostic.severity

---@param dir string
---@return string[]
local function list_pages(dir)
  local pages = href.pages_root(dir)
  if not pages then
    return {}
  end
  local out = {}
  for name, kind in vim.fs.dir(pages) do
    if kind == "file" and name:sub(-3) == ".mu" and name:sub(1, 1) ~= "." then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

--- Analyze lines of a page. Micron is parsed line by line, so tags never span lines.
---@param lines string[]
---@param path? string absolute page path; local link checks are skipped without it
---@return vim.Diagnostic[]
function M.analyze(lines, path)
  local diags = {}
  local function add(lnum, col, end_col, msg, severity)
    diags[#diags + 1] =
      { lnum = lnum, col = col, end_col = end_col, message = msg, severity = severity, source = "micron" }
  end

  local literal_open
  for idx, raw in ipairs(lines) do
    local lnum = idx - 1
    local line = raw:gsub("\r$", "")
    if line == "`=" then
      literal_open = not literal_open and lnum or nil
    elseif not literal_open and line:sub(1, 1) ~= "#" then
      -- `[ needs a ] before the next `[ on the same line
      local init = 1
      while true do
        local s = line:find("`[", init, true)
        if not s then
          break
        end
        local close = line:find("]", s + 2, true)
        local nxt = line:find("`[", s + 2, true)
        if not close or (nxt and nxt < close) then
          add(lnum, s - 1, s + 1, "Unclosed Micron link `[", S.ERROR)
        end
        init = s + 2
      end

      init = 1
      while true do
        local s = line:find("`<", init, true)
        if not s then
          break
        end
        local close = line:find(">", s + 2, true)
        local nxt = line:find("`<", s + 2, true)
        if not close or (nxt and nxt < close) then
          add(lnum, s - 1, s + 1, "Unclosed Micron field `<", S.ERROR)
        end
        init = s + 2
      end

      if path then
        for s, body, e in line:gmatch("()`%[([^%]]*)%]()") do
          local parts = vim.split(body, "`", { plain = true })
          local dest = #parts == 1 and parts[1] or (parts[2] or "")
          if dest ~= "" then
            local parsed = href.parse(dest)
            -- Links to other nodes (destination hash) cannot be checked locally.
            if not parsed.node then
              if parsed.kind == "page" and not href.resolve_page(path, dest) then
                local known = list_pages(vim.fs.dirname(path))
                local hint = #known > 0 and (" Known: " .. table.concat(vim.list_slice(known, 1, 8), ", ")) or ""
                add(lnum, s - 1, e - 1, ("Local page not found: %s.%s"):format(parsed.path, hint), S.WARN)
              elseif parsed.kind == "file" and not href.resolve_file(path, dest) then
                local dir = href.files_dir(path)
                add(
                  lnum,
                  s - 1,
                  e - 1,
                  ("Local file not found: %s (looked under %s)"):format(
                    parsed.path,
                    dir or vim.fs.joinpath(href.node_root(path), "files") .. " (missing)"
                  ),
                  S.WARN
                )
              end
            end
          end
        end
      end
    end
  end

  if literal_open then
    add(literal_open, 0, 2, "Literal block `= is never closed (add another `= line)", S.INFO)
  end
  return diags
end

---@param buf integer
function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not config.get().editor.diagnostics then
    vim.diagnostic.reset(M.ns, buf)
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local path = name ~= "" and vim.fs.normalize(vim.fn.fnamemodify(name, ":p")) or nil
  vim.diagnostic.set(M.ns, buf, M.analyze(vim.api.nvim_buf_get_lines(buf, 0, -1, false), path))
end

--- :Micron validate — refresh and report via the location list.
---@param buf integer
function M.validate(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local path = name ~= "" and vim.fs.normalize(vim.fn.fnamemodify(name, ":p")) or nil
  local diags = M.analyze(vim.api.nvim_buf_get_lines(buf, 0, -1, false), path)
  vim.diagnostic.set(M.ns, buf, diags)
  if #diags == 0 then
    vim.notify("Micron: no issues found")
    vim.fn.setloclist(0, {}, "r")
    return
  end
  vim.fn.setloclist(0, vim.diagnostic.toqflist(vim.diagnostic.get(buf, { namespace = M.ns })), "r")
  vim.cmd("lopen")
end

return M
