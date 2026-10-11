-- Usage: nvim --clean --headless -l test/run.lua
-- Minimal harness: each test/*_spec.lua returns { ["name"] = function() ... end }.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
vim.opt.rtp:prepend(root)
package.path = root .. "/test/?.lua;" .. package.path

local failures, total = 0, 0
local specs = vim.fn.globpath(root .. "/test", "*_spec.lua", false, true)
table.sort(specs)
for _, file in ipairs(specs) do
  local suite = dofile(file)
  local names = vim.tbl_keys(suite)
  table.sort(names)
  for _, name in ipairs(names) do
    total = total + 1
    local ok, err = xpcall(suite[name], debug.traceback)
    if ok then
      io.write(("ok   %s: %s\n"):format(vim.fs.basename(file), name))
    else
      failures = failures + 1
      io.write(("FAIL %s: %s\n%s\n"):format(vim.fs.basename(file), name, err))
    end
  end
end
io.write(("\n%d/%d passed\n"):format(total - failures, total))
os.exit(failures == 0 and 0 or 1)
