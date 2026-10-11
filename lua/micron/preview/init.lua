-- Terminal preview window: runs/renders the page, follows links, edits fields, refreshes partials.
local config = require("micron.config")
local href = require("micron.href")
local hl = require("micron.preview.hl")
local render = require("micron.preview.render")
local runner = require("micron.runner")
local trust = require("micron.trust")

local M = {}

local uv = vim.uv or vim.loop
local api = vim.api
local ns = api.nvim_create_namespace("micron_preview")
local augroup = api.nvim_create_augroup("MicronPreview", { clear = true })

local BINARY_EXT =
  { zip = true, dosz = true, exe = true, com = true, bat = true, bin = true, ["7z"] = true, rar = true }
local HISTORY_MAX = 40

---@class micron.PartialEntry
---@field markup? string
---@field error? string
---@field loading? boolean
---@field timer? uv.uv_timer_t
---@field handle? micron.RunHandle

---@class micron.Preview
---@field buf integer
---@field win? integer
---@field src_win? integer
---@field src_path string
---@field fields table<string,string> sticky fields (script env)
---@field form table<string,string> unsubmitted widget edits
---@field history {path:string, fields:table<string,string>}[]
---@field raw boolean
---@field result? micron.ResolveResult
---@field doc? micron.Doc
---@field offset integer rows used by the error header
---@field running boolean
---@field handle? micron.RunHandle
---@field partials table<string, micron.PartialEntry>
---@field debounce uv.uv_timer_t
---@field watcher? uv.uv_fs_event_t
---@field watch_dir? string
---@field declined table<string, true> node roots the user declined to trust this session

---@type micron.Preview?
local P

local function notify(msg, level)
  vim.notify("Micron: " .. msg, level or vim.log.levels.INFO)
end

--- Page path relative to its node root (e.g. pages/index.mu).
---@param path string
local function relpath(path)
  local root = href.node_root(path)
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return vim.fn.fnamemodify(path, ":~")
end

local function valid_win(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

---@return integer
local function content_width()
  if not P or not valid_win(P.win) then
    return 80
  end
  local info = vim.fn.getwininfo(P.win)[1]
  return math.max(20, info.width - info.textoff)
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

---@param r micron.ResolveResult
---@return string[]
local function error_lines(r)
  local parts = {}
  if r.error then
    vim.list_extend(parts, vim.split(r.error, "\n", { plain = true }))
  end
  local stderr = vim.trim(r.stderr or "")
  if stderr ~= "" and stderr ~= vim.trim(r.error or "") then
    parts[#parts + 1] = "--- stderr ---"
    vim.list_extend(parts, vim.split(stderr, "\n", { plain = true }))
  end
  local stdout = vim.trim(r.stdout or "")
  if r.mode == "script-error" and stdout ~= "" and stderr == "" then
    parts[#parts + 1] = "--- stdout ---"
    vim.list_extend(parts, vim.split(stdout, "\n", { plain = true }))
  end
  return parts
end

local function update_winbar()
  if not P or not valid_win(P.win) then
    return
  end
  local r = P.result
  local bits = {}
  if P.running then
    bits[#bits + 1] = "running…"
  elseif r then
    bits[#bits + 1] = r.mode
  end
  bits[#bits + 1] = relpath(P.src_path)
  if r and r.elapsed_ms and not P.running then
    bits[#bits + 1] = r.elapsed_ms .. "ms"
  end
  if P.raw then
    bits[#bits + 1] = "raw"
  end
  local nfields = vim.tbl_count(P.fields)
  if nfields > 0 then
    bits[#bits + 1] = nfields .. " field" .. (nfields == 1 and "" or "s")
  end
  if #P.history > 0 then
    bits[#bits + 1] = "<BS> back"
  end
  local text = table.concat(bits, " · "):gsub("%%", "%%%%")
  vim.wo[P.win].winbar = "%#MicronPreviewTitle# Micron%* · " .. text .. "%=g? help "
end

local start_partials

--- Re-render the last result into the preview buffer (no script run).
local function draw()
  if not P or not api.nvim_buf_is_valid(P.buf) then
    return
  end
  local r = P.result
  local lines, marks = {}, {}
  local head = r and error_lines(r) or {}
  for _, l in ipairs(head) do
    marks[#marks + 1] = { row = #lines, col = 0, end_col = #l, hl = "MicronPreviewError", priority = 120 }
    lines[#lines + 1] = l
  end
  if #head > 0 then
    lines[#lines + 1] = ""
  end
  P.offset = #lines
  P.doc = nil

  local body_ok = r and r.mode ~= "script-error" and r.mode ~= "untrusted"
  if r and body_ok then
    if P.raw then
      vim.list_extend(lines, vim.split(r.markup, "\n", { plain = true }))
    else
      local width = content_width()
      local dark = config.is_dark()
      local partials = {}
      for key, e in pairs(P.partials) do
        partials[key] = {
          error = e.error,
          doc = e.markup and render.render(e.markup, { dark = dark, width = width, form = P.form }) or nil,
        }
      end
      local doc = render.render(r.markup, { dark = dark, width = width, form = P.form, partials = partials })
      P.doc = doc
      vim.list_extend(lines, doc.lines)
      for _, m in ipairs(doc.marks) do
        marks[#marks + 1] = vim.tbl_extend("force", {}, m, { row = m.row + P.offset })
      end
    end
  end

  local buf = P.buf
  local view = valid_win(P.win) and api.nvim_win_call(P.win, vim.fn.winsaveview) or nil
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.bo[buf].syntax = P.raw and "micron" or ""
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    if m.line then
      api.nvim_buf_set_extmark(buf, ns, m.row, 0, { line_hl_group = m.hl, priority = m.priority })
    else
      api.nvim_buf_set_extmark(buf, ns, m.row, m.col, { end_col = m.end_col, hl_group = m.hl, priority = m.priority })
    end
  end

  if valid_win(P.win) then
    local page_bg = P.doc and P.doc.page_bg
    if page_bg then
      api.nvim_set_hl(0, "MicronPreviewPage", { bg = page_bg })
      vim.wo[P.win].winhighlight = "Normal:MicronPreviewPage,EndOfBuffer:MicronPreviewPage"
    else
      vim.wo[P.win].winhighlight = ""
    end
    if view then
      api.nvim_win_call(P.win, function()
        vim.fn.winrestview(view)
      end)
    end
  end
  update_winbar()
  start_partials()
end

-- ---------------------------------------------------------------------------
-- Running
-- ---------------------------------------------------------------------------

local update, clear_partials

---@param result micron.ResolveResult
local function maybe_prompt_trust(result)
  local root = result.root
  if not P or result.mode ~= "untrusted" or not root or P.declined[root] then
    return
  end
  P.declined[root] = true -- ask once per session; :Micron trust still works
  vim.ui.select({ "Trust and run scripts", "Not now" }, {
    prompt = "Micron: run scripted pages under " .. vim.fn.fnamemodify(root, ":~") .. "?",
  }, function(choice)
    if choice == "Trust and run scripts" then
      trust.trust(root)
      if not P then
        return
      end
      P.declined[root] = nil
      clear_partials()
      update()
    end
  end)
end

--- Resolve the source page and redraw.
update = function()
  if not P then
    return
  end
  if P.handle then
    P.handle.cancel()
  end
  local page = runner.page_from_path(P.src_path)
  if not page then
    P.result = { markup = "", mode = "script-error", error = "Source page is no longer available: " .. P.src_path }
    draw()
    return
  end
  P.running = runner.is_shebang(page.text) and config.get().preview.execute_scripts
  update_winbar()
  local current = P
  P.handle = runner.resolve(page, runner.options(P.fields), function(result)
    if P ~= current then
      return
    end
    P.handle = nil
    P.running = false
    P.result = result
    draw()
    maybe_prompt_trust(result)
  end)
end

local function schedule_update()
  if not P then
    return
  end
  P.debounce:stop()
  P.debounce:start(math.max(0, config.get().preview.debounce_ms), 0, vim.schedule_wrap(update))
end

-- ---------------------------------------------------------------------------
-- Partials
-- ---------------------------------------------------------------------------

---@param entry micron.PartialEntry
local function stop_partial(entry)
  if entry.timer then
    entry.timer:stop()
    entry.timer:close()
    entry.timer = nil
  end
  if entry.handle then
    entry.handle.cancel()
    entry.handle = nil
  end
end

clear_partials = function()
  if not P then
    return
  end
  for _, e in pairs(P.partials) do
    stop_partial(e)
  end
  P.partials = {}
end

---@param p micron.Partial
local function fetch_partial(p)
  local entry = P.partials[p.key]
  local path = href.resolve_page(P.src_path, p.url)
  if not path then
    entry.error, entry.markup = "Partial page not found: " .. p.url, nil
    draw()
    return
  end
  local page = runner.page_from_path(path)
  if not page then
    entry.error, entry.markup = "Cannot read " .. path, nil
    draw()
    return
  end
  local extra = {}
  for _, f in ipairs(p.fields) do
    local eq = f:find("=", 1, true)
    if eq then
      extra[f:sub(1, eq - 1)] = f:sub(eq + 1)
    elseif P.fields[f] ~= nil then
      extra[f] = P.fields[f]
    end
  end
  if entry.handle then
    entry.handle.cancel()
  end
  local current = P
  entry.loading = true
  entry.handle = runner.resolve(page, runner.options(vim.tbl_extend("force", {}, P.fields, extra)), function(result)
    if P ~= current or P.partials[p.key] ~= entry then
      return
    end
    entry.handle, entry.loading = nil, false
    if result.mode == "untrusted" then
      entry.error, entry.markup = "scripts not trusted (:Micron trust)", nil
      maybe_prompt_trust(result)
    elseif result.mode == "script-error" then
      entry.error, entry.markup = (result.error or "partial failed"):gsub("\n.*", ""), nil
    else
      entry.error, entry.markup = nil, result.markup
    end
    draw()
  end)
end

start_partials = function()
  if not P then
    return
  end
  local seen = {}
  for _, p in ipairs(P.doc and P.doc.partials or {}) do
    seen[p.key] = true
    local entry = P.partials[p.key]
    if not entry then
      entry = {}
      P.partials[p.key] = entry
      fetch_partial(p)
    end
    if p.refresh and not entry.timer then
      local ms = math.floor(p.refresh * 1000)
      entry.timer = uv.new_timer()
      entry.timer:start(
        ms,
        ms,
        vim.schedule_wrap(function()
          if P and P.partials[p.key] == entry and not entry.loading then
            fetch_partial(p)
          end
        end)
      )
    end
  end
  -- Partials that disappeared from the page (edits, raw mode, errors) stop refreshing.
  for key, e in pairs(P.partials) do
    if not seen[key] and not P.raw then
      stop_partial(e)
      P.partials[key] = nil
    end
  end
end

-- ---------------------------------------------------------------------------
-- Files watcher
-- ---------------------------------------------------------------------------

local function stop_watcher()
  if P and P.watcher then
    P.watcher:stop()
    P.watcher:close()
    P.watcher, P.watch_dir = nil, nil
  end
end

local function attach_watcher()
  if not P then
    return
  end
  local dir = config.get().preview.watch_files and href.files_dir(P.src_path) or nil
  if dir == P.watch_dir then
    return
  end
  stop_watcher()
  if not dir then
    return
  end
  local w = uv.new_fs_event()
  if not w then
    return
  end
  local ok = w:start(dir, {}, function(err, fname)
    if err or (fname and href.ignore_watch(fname)) then
      return
    end
    vim.schedule(schedule_update)
  end)
  if ok then
    P.watcher, P.watch_dir = w, dir
  else
    w:close()
  end
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

---@param path string
local function show_source(path)
  if not valid_win(P.src_win) then
    return
  end
  local ok, err = pcall(api.nvim_win_call, P.src_win, function()
    if vim.fs.normalize(api.nvim_buf_get_name(0)) ~= path then
      vim.cmd("edit " .. vim.fn.fnameescape(path))
    end
  end)
  if not ok then
    notify(tostring(err), vim.log.levels.WARN)
  end
end

---@param path string
local function set_source(path)
  P.src_path = vim.fs.normalize(path)
  P.form = {}
  clear_partials()
  pcall(api.nvim_buf_set_name, P.buf, "micron-preview://" .. vim.fs.basename(P.src_path))
  attach_watcher()
end

local function push_history()
  local top = P.history[#P.history]
  if top and top.path == P.src_path and vim.deep_equal(top.fields, P.fields) then
    return
  end
  P.history[#P.history + 1] = { path = P.src_path, fields = vim.deepcopy(P.fields) }
  if #P.history > HISTORY_MAX then
    table.remove(P.history, 1)
  end
end

--- Current form values, optionally restricted to the given names.
---@param wanted string[] empty or containing "*" means all
---@return table<string,string>
local function collect(wanted)
  local all = #wanted == 0 or vim.tbl_contains(wanted, "*")
  local names = {}
  for _, n in ipairs(wanted) do
    names[n] = true
  end
  local out = {}
  for _, w in ipairs(P.doc and P.doc.widgets or {}) do
    if all or names[w.name] then
      if w.type == "field" then
        out[w.name] = w.value
      elseif w.type == "checkbox" then
        if w.checked then
          out[w.name] = out[w.name] and (out[w.name] .. "," .. w.value) or w.value
        end
      elseif w.checked then
        out[w.name] = w.value
      end
    end
  end
  return out
end

---@param row integer 0-based buffer row of the activated element
---@param name string anchor name, "" for "next heading"
local function jump_anchor(row, name)
  local doc = P.doc
  if not doc then
    return
  end
  local target
  if name == "" then
    for _, r in ipairs(doc.heading_rows) do
      if r + P.offset > row then
        target = r
        break
      end
    end
  else
    target = doc.anchors[name]
  end
  if target then
    api.nvim_win_set_cursor(P.win, { target + P.offset + 1, 0 })
  else
    notify("anchor not found: #" .. name, vim.log.levels.WARN)
  end
end

---@param url string
---@param fields table<string,string> submitted fields + link request variables
---@param row integer
local function navigate(url, fields, row)
  local parsed = href.parse(url)
  if parsed.kind == "http" then
    vim.ui.open(parsed.path)
    return
  end
  if parsed.kind == "hash" then
    jump_anchor(row, (parsed.path:gsub("^#", "")))
    return
  end
  if parsed.kind == "file" then
    local path = href.resolve_file(P.src_path, url)
    if not path then
      notify(
        ("file not found (%s). Put files under the node files/ directory."):format(parsed.path),
        vim.log.levels.WARN
      )
      return
    end
    local ext = (path:match("%.([^./]+)$") or ""):lower()
    if BINARY_EXT[ext] then
      vim.ui.open(path)
    elseif valid_win(P.src_win) then
      api.nvim_set_current_win(P.src_win)
      vim.cmd("edit " .. vim.fn.fnameescape(path))
    else
      vim.cmd("split " .. vim.fn.fnameescape(path))
    end
    return
  end

  push_history()
  P.fields = href.merge_fields(P.fields, fields, parsed.request_vars)
  P.form = {}
  local page = href.resolve_page(P.src_path, url)
  if page then
    set_source(page)
    show_source(page)
  elseif parsed.kind == "page" then
    notify(
      ("page not found (%s). Staying on current page with submitted fields."):format(parsed.path),
      vim.log.levels.WARN
    )
  end
  update()
end

---@param link micron.Link
---@param row integer
local function follow_link(link, row)
  local wanted, vars = {}, {}
  for _, f in ipairs(link.fields) do
    local eq = f:find("=", 1, true)
    if eq then
      vars[f:sub(1, eq - 1)] = f:sub(eq + 1)
    elseif f ~= "" then
      wanted[#wanted + 1] = f
    end
  end
  local fields = collect(wanted)
  for k, v in pairs(vars) do
    fields[k] = v
  end
  navigate(link.url, fields, row)
end

---@param row integer 0-based buffer row
---@param col integer 0-based byte col
---@return micron.Link?, micron.Widget?
local function element_at(row, col)
  if not P.doc then
    return nil
  end
  local r = row - P.offset
  for _, l in ipairs(P.doc.links) do
    if l.row == r and col >= l.col and col < l.end_col then
      return l, nil
    end
  end
  for _, w in ipairs(P.doc.widgets) do
    if w.row == r and col >= w.col and col < w.end_col then
      return nil, w
    end
  end
  return nil
end

---@param w micron.Widget
local function edit_widget(w)
  if w.type == "field" then
    local input = w.masked and vim.fn.inputsecret or nil
    if input then
      local value = input(w.name .. ": ", w.value)
      P.form[w.name] = value
      draw()
      return
    end
    vim.ui.input({ prompt = w.name .. ": ", default = w.value }, function(value)
      if value ~= nil and P then
        P.form[w.name] = value
        draw()
      end
    end)
  elseif w.type == "checkbox" then
    local values = {}
    for _, other in ipairs(P.doc.widgets) do
      if other.type == "checkbox" and other.name == w.name then
        local on = other.checked
        if other == w then
          on = not on
        end
        if on then
          values[#values + 1] = other.value
        end
      end
    end
    P.form[w.name] = table.concat(values, ",")
    draw()
  else
    P.form[w.name] = w.value
    draw()
  end
end

function M.activate()
  if not P or not P.doc then
    return
  end
  local cur = api.nvim_win_get_cursor(0)
  local link, widget = element_at(cur[1] - 1, cur[2])
  if link then
    follow_link(link, cur[1] - 1)
  elseif widget then
    edit_widget(widget)
  end
end

--- Move to the next/previous link or field.
---@param dir 1|-1
function M.jump(dir)
  if not P or not P.doc then
    return
  end
  local items = {}
  for _, l in ipairs(P.doc.links) do
    items[#items + 1] = { l.row + P.offset, l.col }
  end
  for _, w in ipairs(P.doc.widgets) do
    items[#items + 1] = { w.row + P.offset, w.col }
  end
  if #items == 0 then
    return
  end
  table.sort(items, function(a, b)
    return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
  end)
  local cur = api.nvim_win_get_cursor(0)
  local pos = { cur[1] - 1, cur[2] }
  local function after(a, b)
    return a[1] > b[1] or (a[1] == b[1] and a[2] > b[2])
  end
  local target
  if dir > 0 then
    for _, it in ipairs(items) do
      if after(it, pos) then
        target = it
        break
      end
    end
    target = target or items[1]
  else
    for i = #items, 1, -1 do
      if after(pos, items[i]) then
        target = items[i]
        break
      end
    end
    target = target or items[#items]
  end
  api.nvim_win_set_cursor(0, { target[1] + 1, target[2] })
end

function M.back()
  if not P then
    return
  end
  local prev = table.remove(P.history)
  if not prev then
    notify("no previous page")
    return
  end
  P.fields = prev.fields
  set_source(prev.path)
  show_source(prev.path)
  update()
end

-- ---------------------------------------------------------------------------
-- Fields editor
-- ---------------------------------------------------------------------------

---@param text string
---@return table<string,string>
function M.parse_fields_text(text)
  local out = {}
  for _, line in ipairs(vim.split(text, "\r?\n")) do
    local t = vim.trim(line)
    if t ~= "" and t:sub(1, 1) ~= "#" then
      local eq = t:find("=", 1, true)
      if eq then
        out[vim.trim(t:sub(1, eq - 1))] = t:sub(eq + 1)
      else
        out[t] = ""
      end
    end
  end
  return out
end

function M.edit_fields()
  if not P then
    notify("no preview open", vim.log.levels.WARN)
    return
  end
  local keys = vim.tbl_keys(P.fields)
  table.sort(keys)
  local lines = {}
  for _, k in ipairs(keys) do
    lines[#lines + 1] = k .. "=" .. P.fields[k]
  end
  local name = "micron-fields://" .. vim.fs.basename(P.src_path)
  local stale = vim.fn.bufnr("^" .. name .. "$")
  if stale ~= -1 then
    api.nvim_buf_delete(stale, { force = true })
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "conf"
  vim.bo[buf].modified = false
  local width = math.min(80, math.floor(vim.o.columns * 0.6))
  local height = math.max(6, math.min(#lines + 2, 20))
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = " Micron preview fields ",
    title_pos = "center",
    footer = " name=value per line · :w apply · q close ",
    footer_pos = "center",
  })
  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      if not P then
        return
      end
      P.fields = M.parse_fields_text(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
      P.form = {}
      vim.bo[buf].modified = false
      update()
    end,
  })
  vim.keymap.set("n", "q", function()
    pcall(api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true })
end

function M.clear_fields()
  if not P then
    return
  end
  P.fields = vim.deepcopy(config.get().preview.default_fields)
  P.form = {}
  update()
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function help()
  local lines = {
    "<CR>      follow link / edit field / toggle checkbox",
    "<Tab>     next link or field     <S-Tab> previous",
    "<BS>      back",
    "r         re-run / refresh       R  toggle raw markup",
    "F         edit sticky fields     C  reset fields",
    "q         close preview",
  }
  vim.lsp.util.open_floating_preview(lines, "text", { border = "rounded", title = " Micron preview " })
end

local function dispose()
  if not P then
    return
  end
  if P.handle then
    P.handle.cancel()
  end
  clear_partials()
  stop_watcher()
  P.debounce:stop()
  P.debounce:close()
  P = nil
  api.nvim_clear_autocmds({ group = augroup })
end

local function setup_buffer(buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "micron_preview"
  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "Micron: " .. desc })
  end
  map("<CR>", M.activate, "activate")
  map("<Tab>", function()
    M.jump(1)
  end, "next element")
  map("<S-Tab>", function()
    M.jump(-1)
  end, "previous element")
  map("<BS>", M.back, "back")
  map("r", M.refresh, "refresh")
  map("R", M.toggle_raw, "toggle raw")
  map("F", M.edit_fields, "edit fields")
  map("C", M.clear_fields, "reset fields")
  map("q", M.close, "close")
  map("g?", help, "help")
end

local function setup_window(win)
  local wo = vim.wo[win]
  wo.wrap = true
  wo.linebreak = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.statuscolumn = ""
  wo.list = false
  wo.spell = false
  wo.cursorline = false
  wo.conceallevel = 0
end

local function setup_autocmds()
  api.nvim_clear_autocmds({ group = augroup })
  local function is_source(buf)
    return P and vim.fs.normalize(api.nvim_buf_get_name(buf)) == P.src_path
  end
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    callback = function(ev)
      if is_source(ev.buf) and config.get().preview.live_update then
        schedule_update()
      end
    end,
  })
  api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    callback = function(ev)
      if is_source(ev.buf) then
        update()
      end
    end,
  })
  api.nvim_create_autocmd("WinResized", {
    group = augroup,
    callback = function()
      if P and vim.tbl_contains(vim.v.event.windows or {}, P.win) then
        draw()
      end
    end,
  })
  api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      hl.reset()
      hl.define_static()
      draw()
    end,
  })
  api.nvim_create_autocmd("OptionSet", {
    group = augroup,
    pattern = "background",
    callback = function()
      draw()
    end,
  })
  api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = P.buf,
    callback = function()
      local cur = api.nvim_win_get_cursor(0)
      local link = element_at(cur[1] - 1, cur[2])
      if link then
        local f = #link.fields > 0 and ("  [" .. table.concat(link.fields, "|") .. "]") or ""
        api.nvim_echo({ { link.url .. f, "MicronPreviewInfo" } }, false, {})
      end
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = P.buf,
    callback = dispose,
  })
end

---@param path string
---@return boolean
local function is_page(path)
  return path:sub(-3) == ".mu"
end

--- Open (or retarget) the preview for a buffer.
---@param buf? integer defaults to the current buffer
function M.open(buf)
  buf = buf or api.nvim_get_current_buf()
  local name = api.nvim_buf_get_name(buf)
  if name == "" or not (is_page(name) or vim.bo[buf].filetype == "micron" or vim.b[buf].micron_page) then
    notify("open a .mu / Micron buffer first", vim.log.levels.WARN)
    return
  end
  local path = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
  local src_win = api.nvim_get_current_win()
  if src_win == (P and P.win) then
    src_win = P.src_win
  end

  if P and api.nvim_buf_is_valid(P.buf) then
    P.src_win = src_win
    P.history = {}
    P.fields = vim.deepcopy(config.get().preview.default_fields)
    set_source(path)
    if not valid_win(P.win) then
      P.win = M._open_window(P.buf)
    end
    update()
    return
  end

  local pbuf = api.nvim_create_buf(false, true)
  P = {
    buf = pbuf,
    src_win = src_win,
    src_path = path,
    fields = vim.deepcopy(config.get().preview.default_fields),
    form = {},
    history = {},
    raw = false,
    offset = 0,
    running = false,
    partials = {},
    debounce = assert(uv.new_timer()),
    declined = {},
  }
  setup_buffer(pbuf)
  set_source(path)
  P.win = M._open_window(pbuf)
  setup_autocmds()
  update()
end

---@param buf integer
---@return integer
function M._open_window(buf)
  local cur = api.nvim_get_current_win()
  local split = config.get().preview.split
  if split == "tab" then
    vim.cmd("tab sbuffer " .. buf)
  elseif split == "horizontal" then
    vim.cmd("belowright sbuffer " .. buf)
  else
    vim.cmd("belowright vertical sbuffer " .. buf)
  end
  local win = api.nvim_get_current_win()
  setup_window(win)
  if split ~= "tab" and api.nvim_win_is_valid(cur) then
    api.nvim_set_current_win(cur)
  end
  return win
end

--- Re-run the page and all of its partials.
function M.refresh()
  if P then
    clear_partials()
    update()
  end
end

function M.toggle_raw()
  if not P then
    return
  end
  P.raw = not P.raw
  draw()
end

function M.close()
  if P and api.nvim_buf_is_valid(P.buf) then
    api.nvim_buf_delete(P.buf, { force = true })
  end
end

---@return boolean
function M.is_open()
  return P ~= nil and valid_win(P.win)
end

---@return string?
function M.source()
  return P and P.src_path
end

--- Internal state for tests.
function M._state()
  return P
end

return M
