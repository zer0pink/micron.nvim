vim.filetype.add({
  extension = {
    mu = function(_, bufnr)
      local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
      if
        require("micron.config").get().editor.python_shebang
        and first:sub(1, 2) == "#!"
        and first:lower():find("python", 1, true)
      then
        return "python", function(b)
          vim.b[b].micron_page = true
        end
      end
      return "micron", function(b)
        vim.b[b].micron_page = true
      end
    end,
  },
})
