local M = {}

function M.check()
  local h = vim.health
  h.start("micron.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.11+ is required")
  end

  if vim.o.termguicolors then
    h.ok("'termguicolors' is on (exact Micron colours in the preview)")
  else
    h.warn("'termguicolors' is off: preview colours are approximated to the 256-colour palette")
  end

  if pcall(vim.treesitter.language.inspect, "python") then
    h.ok("Treesitter python parser found (Micron tags highlighted in Python page strings)")
  else
    h.warn("No Treesitter python parser: Micron tags in Python pages are highlighted everywhere, not only in strings")
  end

  local cfg = require("micron.config").get()
  if cfg.preview.execute_scripts then
    for _, exe in ipairs({ "python3", "python" }) do
      if vim.fn.executable(exe) == 1 then
        h.ok(exe .. " found for scripted pages")
        break
      end
    end
    local trusted = require("micron.trust").list()
    if #trusted == 0 then
      h.info("No trusted node roots yet; scripted pages prompt on first preview (:Micron trust)")
    else
      for _, root in ipairs(trusted) do
        h.info("trusted: " .. root)
      end
    end
  else
    h.info("preview.execute_scripts is off: scripted pages are previewed as static source")
  end
end

return M
