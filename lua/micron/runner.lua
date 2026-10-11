-- Resolve a page to Micron markup: static text, or the stdout of its shebang script.
-- Mirrors rns-micron-vsix src/scriptRunner.ts resolveMicronMarkup.
local config = require("micron.config")
local href = require("micron.href")
local trust = require("micron.trust")

local M = {}

local uv = vim.uv or vim.loop

--- Running page scripts, killed on exit since they run detached.
---@type table<vim.SystemObj, true>
local active = {}

---@param proc vim.SystemObj
local function kill_group(proc)
  if proc:is_closing() then
    return
  end
  -- Negative pid targets the process group created by `detach`.
  pcall(uv.kill, -proc.pid, "sigkill")
  pcall(proc.kill, proc, "sigkill")
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("MicronRunner", { clear = true }),
  callback = function()
    for proc in pairs(active) do
      kill_group(proc)
    end
  end,
})

---@alias micron.ResolveMode "static"|"script"|"script-error"|"skipped"|"untrusted"

---@class micron.ResolveResult
---@field markup string
---@field mode micron.ResolveMode
---@field error? string
---@field stderr? string
---@field stdout? string
---@field exit_code? integer
---@field timed_out? boolean
---@field elapsed_ms? integer
---@field shebang? string
---@field root? string node root that needs trust (mode "untrusted")

---@class micron.Page
---@field path? string absolute path on disk (nil for unnamed buffers)
---@field text string current contents
---@field dirty boolean contents differ from disk

---@param text string
---@return string
local function first_line(text)
  return (text:match("^[^\n]*"):gsub("\r$", ""))
end

--- True for an interpreter line. `#!c=60` / `#!fg=ddd` / `#!bg=222` are Micron header
--- directives on static pages, not shebangs.
---@param text string
---@return boolean
function M.is_shebang(text)
  return text:sub(1, 2) == "#!" and not first_line(text):match("^#!%s*%a+=")
end

---@param shebang string
---@return string[]?
function M.interpreter(shebang)
  local parts = vim.split(vim.trim(shebang:gsub("^#!%s*", "")), "%s+", { trimempty = true })
  if #parts == 0 then
    return nil
  end
  if parts[1]:match("/env$") and #parts >= 2 then
    table.remove(parts, 1)
  end
  return parts
end

---@param path string
---@return boolean
local function is_executable(path)
  return uv.fs_access(path, "X") == true
end

---@class micron.ResolveOpts
---@field fields table<string,string>
---@field execute_scripts? boolean
---@field require_executable_bit? boolean
---@field timeout_ms? integer
---@field extra_env? table<string,string>

--- Build ResolveOpts from config for the given sticky fields.
---@param fields table<string,string>
---@return micron.ResolveOpts
function M.options(fields)
  local p = config.get().preview
  return {
    fields = fields,
    execute_scripts = p.execute_scripts,
    require_executable_bit = p.require_executable_bit,
    timeout_ms = p.script_timeout_ms,
    extra_env = vim.tbl_extend("force", { MICRON_PREVIEW = "1" }, p.request_env or {}, p.extra_env or {}),
  }
end

---@class micron.RunHandle
---@field cancel fun()

--- Resolve a page. `callback` runs on the main loop and is not called after cancel().
---@param page micron.Page
---@param opts micron.ResolveOpts
---@param callback fun(result: micron.ResolveResult)
---@return micron.RunHandle
function M.resolve(page, opts, callback)
  local cancelled = false
  local handle = { cancel = function() end }
  local function done(result)
    vim.schedule(function()
      if not cancelled then
        callback(result)
      end
    end)
  end

  local text = page.text
  local shebang = M.is_shebang(text) and first_line(text) or nil
  if not shebang or not opts.execute_scripts then
    done({ markup = text, mode = shebang and "skipped" or "static", shebang = shebang })
    return handle
  end

  local root = page.path and href.node_root(page.path) or uv.cwd() or "."
  if not trust.is_trusted(root) then
    done({
      markup = text,
      mode = "untrusted",
      shebang = shebang,
      root = root,
      error = ("Scripted pages under %s are not trusted. Run :Micron trust to allow execution, or disable preview.execute_scripts."):format(
        root
      ),
    })
    return handle
  end

  local started = uv.hrtime()
  local function elapsed()
    return math.floor((uv.hrtime() - started) / 1e6)
  end

  local cwd = page.path and vim.fs.dirname(page.path) or uv.cwd() or "."
  local run_path, cleanup
  if page.path and not page.dirty then
    if opts.require_executable_bit and not is_executable(page.path) then
      done({
        markup = text,
        mode = "skipped",
        shebang = shebang,
        error = "Script has a shebang but is not executable. chmod +x it or set preview.require_executable_bit = false.",
      })
      return handle
    end
    run_path = page.path
  else
    local base = page.path and vim.fs.basename(page.path) or "untitled.mu"
    run_path = vim.fs.joinpath(cwd, ".micron-preview-" .. base:gsub("[^%w._-]+", "_"))
    local fd, err = io.open(run_path, "w")
    if not fd then
      done({ markup = text, mode = "script-error", shebang = shebang, error = err, stderr = err })
      return handle
    end
    fd:write(text)
    fd:close()
    uv.fs_chmod(run_path, tonumber("755", 8))
    cleanup = run_path
  end

  local cmd
  if is_executable(run_path) then
    cmd = { run_path }
  else
    cmd = M.interpreter(shebang)
    if not cmd then
      if cleanup then
        os.remove(cleanup)
      end
      done({ markup = text, mode = "script-error", shebang = shebang, error = "Could not parse shebang interpreter" })
      return handle
    end
    cmd[#cmd + 1] = run_path
  end

  local timed_out = false
  local timer = assert(uv.new_timer())
  local proc
  local ok, spawned = pcall(vim.system, cmd, {
    cwd = cwd,
    env = href.build_env(opts.fields, opts.extra_env),
    clear_env = true,
    text = true,
    -- Own process group, so a timeout/cancel also kills children holding stdout open.
    detach = true,
  }, function(obj)
    timer:stop()
    timer:close()
    if proc then
      active[proc] = nil
    end
    if cleanup then
      os.remove(cleanup)
    end
    local result = {
      markup = text,
      mode = "script-error",
      shebang = shebang,
      elapsed_ms = elapsed(),
      stdout = obj.stdout or "",
      stderr = obj.stderr or "",
      exit_code = obj.code,
      timed_out = timed_out,
    }
    if timed_out then
      result.error = ("Script timed out after %dms"):format(opts.timeout_ms)
      if result.stderr == "" then
        result.stderr = result.error
      end
    elseif obj.signal ~= 0 then
      result.error = ("Script killed by signal %d"):format(obj.signal)
    elseif obj.code ~= 0 then
      -- stderr/stdout are shown separately by the preview; keep the summary short.
      result.error = ("Script exited with code %d"):format(obj.code)
    else
      result.mode = "script"
      result.markup = result.stdout
    end
    done(result)
  end)

  if not ok then
    timer:close()
    if cleanup then
      os.remove(cleanup)
    end
    local msg = tostring(spawned)
    done({ markup = text, mode = "script-error", shebang = shebang, elapsed_ms = elapsed(), error = msg, stderr = msg })
    return handle
  end

  proc = spawned
  active[proc] = true
  timer:start(opts.timeout_ms, 0, function()
    timed_out = true
    kill_group(proc)
  end)

  handle.cancel = function()
    if cancelled then
      return
    end
    cancelled = true
    kill_group(proc)
  end
  return handle
end

--- Read a page from its loaded buffer (unsaved edits included) or from disk.
---@param path string
---@return micron.Page?
function M.page_from_path(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return M.page_from_buf(buf)
  end
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  return { path = path, text = text, dirty = false }
end

---@param buf integer
---@return micron.Page
function M.page_from_buf(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return {
    path = name ~= "" and vim.fs.normalize(name) or nil,
    text = table.concat(lines, "\n") .. (vim.bo[buf].eol and "\n" or ""),
    dirty = vim.bo[buf].modified or name == "",
  }
end

return M
