if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = true

vim.bo.commentstring = "# %s"
vim.bo.comments = ":#"
vim.bo.omnifunc = "v:lua.require'micron.complete'.omnifunc"
-- K shows the tag hint for the cursor position.
vim.bo.keywordprg = ":Micron hover"
vim.opt_local.matchpairs:append("<:>")
vim.opt_local.foldmethod = "expr"
vim.opt_local.foldexpr = "v:lua.require'micron.fold'.expr(v:lnum)"
vim.opt_local.foldlevel = 99

local group = vim.api.nvim_create_augroup("MicronFtplugin" .. vim.api.nvim_get_current_buf(), { clear = true })
vim.api.nvim_create_autocmd("CompleteDone", {
  group = group,
  buffer = 0,
  callback = function()
    require("micron.complete").on_complete_done()
  end,
})

vim.b.undo_ftplugin = table.concat({
  "setlocal commentstring< comments< omnifunc< keywordprg< matchpairs< foldmethod< foldexpr< foldlevel<",
  "silent! autocmd! MicronFtplugin" .. vim.api.nvim_get_current_buf(),
  "unlet! b:did_ftplugin",
}, " | ")
