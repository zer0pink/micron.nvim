local config = require("micron.config")

local M = {}

local api = vim.api
local uv = vim.uv or vim.loop

---@param opts? table see :help micron-config
function M.setup(opts)
  config.setup(opts)
  -- Re-apply to already attached buffers (e.g. diagnostics toggled off).
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if vim.b[buf].micron_attached then
      M.refresh_buffer(buf)
    end
  end
end

---@param buf integer
---@return boolean
function M.is_page(buf)
  return vim.bo[buf].filetype == "micron" or vim.b[buf].micron_page == true
end

---@param buf integer
function M.refresh_buffer(buf)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  require("micron.diagnostics").refresh(buf)
  require("micron.colors").refresh(buf)
  if vim.bo[buf].filetype == "python" then
    require("micron.strings").refresh(buf)
  end
end

--- Filetype a .mu buffer should have given its first line.
---@param buf integer
---@return string
local function wanted_filetype(buf)
  local first = api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  if config.get().editor.python_shebang and first:sub(1, 2) == "#!" and first:lower():find("python", 1, true) then
    return "python"
  end
  return "micron"
end

---@type table<integer, uv.uv_timer_t>
local timers = {}

--- Attach editor features (diagnostics, swatches, Python string tags) to a page buffer.
---@param buf integer
function M.attach(buf)
  if vim.b[buf].micron_attached then
    M.refresh_buffer(buf)
    return
  end
  vim.b[buf].micron_attached = true
  local group = api.nvim_create_augroup("MicronBuffer" .. buf, { clear = true })
  local timer = assert(uv.new_timer())
  timers[buf] = timer
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      timer:stop()
      timer:start(
        150,
        0,
        vim.schedule_wrap(function()
          M.refresh_buffer(buf)
        end)
      )
    end,
  })
  api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = buf,
    callback = function()
      if api.nvim_buf_get_name(buf):sub(-3) == ".mu" then
        local ft = wanted_filetype(buf)
        if vim.bo[buf].filetype ~= ft then
          vim.bo[buf].filetype = ft
        end
      end
      M.refresh_buffer(buf)
    end,
  })
  api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = buf,
    callback = function()
      local preview = require("micron.preview")
      if config.get().preview.auto_open then
        local path = vim.fs.normalize(vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":p"))
        if not preview.is_open() or preview.source() ~= path then
          preview.open(buf)
        end
      end
    end,
  })
  api.nvim_create_autocmd({ "BufUnload", "FileType" }, {
    group = group,
    buffer = buf,
    callback = function(ev)
      if ev.event == "FileType" and M.is_page(buf) then
        M.refresh_buffer(buf)
        return
      end
      timer:stop()
      timer:close()
      timers[buf] = nil
      vim.b[buf].micron_attached = nil
      vim.diagnostic.reset(require("micron.diagnostics").ns, buf)
      api.nvim_buf_clear_namespace(buf, require("micron.colors").ns, 0, -1)
      api.nvim_buf_clear_namespace(buf, require("micron.strings").ns, 0, -1)
      api.nvim_del_augroup_by_id(group)
    end,
  })
  M.refresh_buffer(buf)
  if config.get().preview.auto_open and buf == api.nvim_get_current_buf() then
    vim.schedule(function()
      require("micron.preview").open(buf)
    end)
  end
end

--- Run the page script in a terminal split (replaces the VS Code F5 / debug handoff).
---@param buf integer
function M.run(buf)
  local runner = require("micron.runner")
  local href = require("micron.href")
  local page = runner.page_from_buf(buf)
  if not page.path or not runner.is_shebang(page.text) then
    vim.notify("Micron: :Micron run needs a saved page with a #! line", vim.log.levels.WARN)
    return
  end
  if page.dirty then
    vim.cmd("write")
  end
  local cmd
  if uv.fs_access(page.path, "X") then
    cmd = { page.path }
  else
    cmd = runner.interpreter(page.text:match("^[^\n]*"))
    if not cmd then
      vim.notify("Micron: could not parse shebang", vim.log.levels.ERROR)
      return
    end
    cmd[#cmd + 1] = page.path
  end
  local preview = require("micron.preview")
  local state = preview._state()
  local fields = state and state.fields or config.get().preview.default_fields
  local env = href.build_env(fields, runner.options(fields).extra_env, {})
  vim.cmd("belowright new")
  vim.fn.jobstart(cmd, { term = true, cwd = vim.fs.dirname(page.path), env = env })
  vim.cmd("startinsert")
end

local function range_arg(opts)
  return opts.range > 0
end

---@type table<string, {fn: fun(opts: table), nargs?: boolean, complete?: fun(): string[]}>
local commands = {
  preview = {
    fn = function()
      require("micron.preview").open()
    end,
  },
  close = {
    fn = function()
      require("micron.preview").close()
    end,
  },
  refresh = {
    fn = function()
      require("micron.preview").refresh()
    end,
  },
  raw = {
    fn = function()
      require("micron.preview").toggle_raw()
    end,
  },
  back = {
    fn = function()
      require("micron.preview").back()
    end,
  },
  fields = {
    fn = function()
      require("micron.preview").edit_fields()
    end,
  },
  ["reset-fields"] = {
    fn = function()
      require("micron.preview").clear_fields()
    end,
  },
  trust = {
    nargs = true,
    fn = function(opts)
      local href = require("micron.href")
      local root = opts.args ~= "" and vim.fs.normalize(vim.fn.fnamemodify(opts.args, ":p"))
        or href.node_root(vim.fn.expand("%:p"))
      require("micron.trust").trust(root)
      vim.notify("Micron: trusted " .. vim.fn.fnamemodify(root, ":~"))
      require("micron.preview").refresh()
    end,
  },
  untrust = {
    nargs = true,
    complete = function()
      return require("micron.trust").list()
    end,
    fn = function(opts)
      local root = opts.args ~= "" and opts.args or require("micron.href").node_root(vim.fn.expand("%:p"))
      local removed = require("micron.trust").untrust(root)
      vim.notify(
        ("Micron: %s %s"):format(removed and "untrusted" or "was not trusted:", vim.fn.fnamemodify(root, ":~"))
      )
    end,
  },
  run = {
    fn = function()
      M.run(api.nvim_get_current_buf())
    end,
  },
  validate = {
    fn = function()
      require("micron.diagnostics").validate(api.nvim_get_current_buf())
    end,
  },
  hover = {
    nargs = true,
    fn = function()
      require("micron.edit").hover()
    end,
  },
  reference = {
    fn = function()
      vim.cmd("help micron-syntax")
    end,
  },
  hex2mu = {
    nargs = true,
    fn = function(opts)
      require("micron.edit").convert("to_micron", opts.args, range_arg(opts))
    end,
  },
  mu2hex = {
    nargs = true,
    fn = function(opts)
      require("micron.edit").convert("to_hex", opts.args, range_arg(opts))
    end,
  },
  fg = {
    nargs = true,
    fn = function(opts)
      require("micron.edit").color("F", opts.args ~= "" and opts.args or nil, range_arg(opts))
    end,
  },
  bg = {
    nargs = true,
    fn = function(opts)
      require("micron.edit").color("B", opts.args ~= "" and opts.args or nil, range_arg(opts))
    end,
  },
  bold = {
    fn = function(opts)
      require("micron.edit").wrap("`!", "`!", range_arg(opts))
    end,
  },
  italic = {
    fn = function(opts)
      require("micron.edit").wrap("`*", "`*", range_arg(opts))
    end,
  },
  underline = {
    fn = function(opts)
      require("micron.edit").wrap("`_", "`_", range_arg(opts))
    end,
  },
}

---@param opts table nvim_create_user_command callback args
function M.command(opts)
  local name, rest = opts.args:match("^(%S+)%s*(.-)$")
  local cmd = name and commands[name]
  if not cmd then
    vim.notify("Micron: unknown subcommand " .. (name or ""), vim.log.levels.ERROR)
    return
  end
  if rest ~= "" and not cmd.nargs then
    vim.notify("Micron: " .. name .. " takes no arguments", vim.log.levels.ERROR)
    return
  end
  cmd.fn(vim.tbl_extend("force", opts, { args = rest }))
end

---@param arglead string
---@param line string
---@return string[]
function M.complete(arglead, line)
  local words = vim.split(line, "%s+", { trimempty = true })
  if #words <= 1 or (#words == 2 and arglead ~= "") then
    local names = vim.tbl_keys(commands)
    table.sort(names)
    return vim.tbl_filter(function(n)
      return n:sub(1, #arglead) == arglead
    end, names)
  end
  local cmd = commands[words[2]]
  return cmd and cmd.complete and cmd.complete() or {}
end

return M
