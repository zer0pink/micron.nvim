if vim.g.loaded_micron then
  return
end
vim.g.loaded_micron = true

if vim.fn.has("nvim-0.11") == 0 then
  vim.notify("micron.nvim requires Neovim 0.11+", vim.log.levels.ERROR)
  return
end

require("micron.preview.hl").define_static()

local group = vim.api.nvim_create_augroup("Micron", { clear = true })

vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = { "micron", "python" },
  callback = function(ev)
    local micron = require("micron")
    if micron.is_page(ev.buf) then
      micron.attach(ev.buf)
    end
  end,
})

vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = function()
    local hl = require("micron.preview.hl")
    hl.reset()
    hl.define_static()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.b[buf].micron_attached then
        require("micron").refresh_buffer(buf)
      end
    end
  end,
})

vim.api.nvim_create_user_command("Micron", function(opts)
  require("micron").command(opts)
end, {
  nargs = "+",
  range = true,
  desc = "Micron page tools (see :help micron-commands)",
  complete = function(arglead, line)
    return require("micron").complete(arglead, line)
  end,
})

-- Buffers that were already detected before the plugin loaded (lazy loading).
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(buf) and (vim.bo[buf].filetype == "micron" or vim.b[buf].micron_page) then
    require("micron").attach(buf)
  end
end
