local M = {}

---@class micron.Config
M.defaults = {
  preview = {
    -- Re-render while typing (debounced by debounce_ms).
    live_update = true,
    debounce_ms = 120,
    -- Run shebang (#!) pages and preview their stdout. Requires a trusted node root.
    execute_scripts = true,
    -- Only run on-disk scripts with the executable bit (matches rns-page-node).
    require_executable_bit = false,
    script_timeout_ms = 15000,
    -- "auto" follows 'background'; "dark" / "light" force the Micron palette.
    theme = "auto",
    -- Extra environment for scripted pages.
    extra_env = {},
    -- Initial form field values (exported as name and field_name).
    default_fields = {},
    -- Simulated request environment for scripted pages.
    request_env = { link_id = "preview-link", remote_identity = "preview-identity" },
    -- Open the preview automatically when entering a Micron buffer.
    auto_open = false,
    -- Re-render when the node files/ directory changes.
    watch_files = true,
    -- "vertical" | "horizontal" | "tab"
    split = "vertical",
  },
  editor = {
    -- Shebang Python .mu pages get filetype=python plus Micron tag highlights in strings.
    python_shebang = true,
    diagnostics = true,
    -- Highlight `Fxxx / `Bxxx digits with their colour.
    color_swatches = true,
  },
}

---@type micron.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- Dictionaries are replaced, not merged, so users can remove default keys.
  for _, key in ipairs({ "extra_env", "default_fields", "request_env" }) do
    if opts and opts.preview and opts.preview[key] ~= nil then
      M.options.preview[key] = vim.deepcopy(opts.preview[key])
    end
  end
end

---@return micron.Config
function M.get()
  return M.options
end

---@return boolean
function M.is_dark()
  local theme = M.options.preview.theme
  if theme == "dark" then
    return true
  elseif theme == "light" then
    return false
  end
  return vim.o.background ~= "light"
end

return M
