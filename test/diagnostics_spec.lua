local diagnostics = require("micron.diagnostics")
local complete = require("micron.complete")
local colors = require("micron.colors")

local function eq(expected, actual, ctx)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\nactual:   %s"):format(ctx or "", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function messages(lines, path)
  return vim.tbl_map(function(d)
    return { d.lnum, d.col, d.message:match("^[^:.(]+") }
  end, diagnostics.analyze(lines, path))
end

return {
  ["unclosed links and fields are per line"] = function()
    eq(
      { { 0, 0, "Unclosed Micron link `[" }, { 2, 3, "Unclosed Micron field `<" } },
      messages({ "`[a", "b]", "ok `<x" })
    )
    eq({}, messages({ "`[a`b] `<n`v>" }))
  end,

  ["literal blocks: `= toggles, `` does not close, content is ignored"] = function()
    eq({}, messages({ "`=", "`[ not a link", "`=", "text `` reset" }))
    eq({ { 2, 0, "Literal block `= is never closed " } }, messages({ "`=", "`=", "`=", "x``" }))
  end,

  ["missing local targets warn; remote node links are skipped"] = function()
    local dir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(dir .. "/pages", "p")
    vim.fn.mkdir(dir .. "/files", "p")
    local path = dir .. "/pages/index.mu"
    io.open(path, "w"):close()
    local out = messages({
      "`[ok`:/page/index.mu] `[gone`:/page/gone.mu]",
      "`[f`:/file/none.zip]",
      "`[r`0123456789abcdef0123456789abcdef:/page/remote.mu]",
      "# `[comment`:/page/gone.mu]",
    }, path)
    eq({ { 0, 22, "Local page not found" }, { 1, 0, "Local file not found" } }, out)
  end,

  ["completion candidates follow the last backtick"] = function()
    local start, items = complete.candidates("text `<")
    eq(5, start)
    eq(
      { "`<", "`<?", "`<^" },
      vim.tbl_map(function(i)
        return i.label
      end, items)
    )
    start, items = complete.candidates("  ")
    eq({ 2, ">" }, { start, items[1].label })
    eq(nil, (complete.candidates("plain")))
  end,

  ["colour conversion"] = function()
    eq("0a0", colors.hex_to_micron("#00AA00"))
    eq("fff", colors.hex_to_micron("fefefe"))
    eq("abc", colors.hex_to_micron("#ABC"))
    eq(nil, colors.hex_to_micron("#12345"))
    eq("#00aa00", colors.micron_to_hex("`F0a0"))
    eq(nil, colors.micron_to_hex("zzz"))
  end,
}
