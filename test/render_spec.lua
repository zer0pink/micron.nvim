local render = require("micron.preview.render")

local function eq(expected, actual, ctx)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\nactual:   %s"):format(ctx or "", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function doc(markup, opts)
  return render.render(markup, vim.tbl_extend("force", { dark = true, width = 40 }, opts or {}))
end

--- Highlight definition covering (row, col).
local function hl_at(d, row, col)
  local best
  for _, m in ipairs(d.marks) do
    if not m.line and m.row == row and col >= m.col and col < m.end_col and m.priority == 110 then
      best = m.hl
    end
  end
  return best and vim.api.nvim_get_hl(0, { name = best }) or {}
end

return {
  ["comments, directives, tag-only lines and depth resets produce no rows"] = function()
    local d = doc("#!c=60\n# comment\n`F0a0\nhello\n<\n`c")
    eq({ "hello" }, d.lines)
  end,

  ["formatting persists across lines until reset"] = function()
    local d = doc("`!`F0a0bold\nstill\n``plain")
    eq({ "bold", "still", "plain" }, d.lines)
    eq(true, hl_at(d, 1, 0).bold, "bold carries to next line")
    eq(0x00aa00, hl_at(d, 1, 0).fg, "fg carries")
    eq(nil, hl_at(d, 2, 0).bold, "`` resets")
  end,

  ["24-bit and gray colours"] = function()
    local d = doc("`FT102030a`Bg50b")
    eq(0x102030, hl_at(d, 0, 0).fg)
    eq(0x7f7f7f, hl_at(d, 0, 1).bg)
  end,

  ["headings indent by depth and set anchors; text keeps heading colours"] = function()
    local d = doc(">Top\n>>Sub `!Bold`!\ntext")
    eq({ "Top", "  Sub Bold", "  text" }, d.lines)
    eq({ top = 0, ["sub-bold"] = 1 }, d.anchors)
    eq({ 0, 1 }, d.heading_rows)
    eq(0x999999, hl_at(d, 1, 2).bg, "heading2 background")
  end,

  ["literal block is not parsed and closes on the next `= line"] = function()
    local d = doc("`=\n`[x] >h\n\\`=\n`=\n`!b`!")
    eq({ "`[x] >h", "`=", "b" }, d.lines)
    eq(0, #d.links)
  end,

  ["center and right alignment pad to the window width"] = function()
    local d = doc("`cab\n`rxy\n`aleft", { width = 10 })
    eq({ "    ab", "        xy", "left" }, d.lines)
  end,

  ["links: label defaults to the url as written, scheme stripped from target"] = function()
    local d = doc("go `[nomadnetwork://:/page/a.mu] `[Send`:/page/b.mu`name|*|k=v]")
    eq("go nomadnetwork://:/page/a.mu Send", d.lines[1])
    eq({ row = 0, col = 3, end_col = 29, url = ":/page/a.mu", fields = {} }, d.links[1])
    eq({ "name", "*", "k=v" }, d.links[2].fields)
    eq(30, d.links[2].col)
  end,

  ["fields reflect form values; checkbox and radio state"] = function()
    local markup = "`<8|user`def>\n`<!|pw`secret>\n`<?|opt|a`A> `<?|opt|b|*`B>\n`<^|r|x`X> `<^|r|y|*`Y>"
    local d = doc(markup)
    eq({ "def     ", "******                  ", "[ ] A [X] B", "( ) X (X) Y" }, d.lines)
    d = doc(markup, { form = { user = "ivan", opt = "a", r = "x" } })
    eq("ivan    ", d.lines[1])
    eq("[X] A [ ] B", d.lines[3])
    eq("(X) X ( ) Y", d.lines[4])
    eq("ivan", d.widgets[1].value)
    eq(true, d.widgets[2].masked)
  end,

  ["tables align cells and honour max width"] = function()
    local d = doc("`t\nName|N\n-|:-:\nApple|3\n`t")
    eq({
      "┌───────┬───┐",
      "│ Name  │ N │",
      "├───────┼───┤",
      "│ Apple │ 3 │",
      "└───────┴───┘",
    }, d.lines)
    -- max width 14 = 1 + (6 + 3) + (1 + 3): the widest column shrinks to 6 cells
    d = doc("`t14\nLongheader|x\n-|-\nv|y\n`t")
    eq("│ Longh… │ x │", d.lines[2])
  end,

  ["dividers fill the width minus indent"] = function()
    local d = doc("-\n>>S\n-=", { width = 10 })
    eq({ string.rep("─", 10), "  S", "  " .. string.rep("=", 8) }, d.lines)
  end,

  ["page background from #!bg header"] = function()
    eq("#222222", doc("#!bg=222\nx").page_bg)
    eq(nil, doc("x\n#!bg=222").page_bg)
  end,

  ["partials: placeholder, then spliced content shifts later rows"] = function()
    local d = doc("`{:/page/p.mu`5`a|pid=7}\n`[L`:/page/x.mu]")
    eq(
      { row = 0, key = ":/page/p.mu`5`a|pid=7", url = ":/page/p.mu", refresh = 5, fields = { "a", "pid=7" }, id = "7" },
      d.partials[1]
    )
    eq(1, d.links[1].row)
    local sub = doc("one\ntwo `[In`:/page/y.mu]")
    d = doc("`{:/page/p.mu`5`a|pid=7}\n`[L`:/page/x.mu]", { partials = { [":/page/p.mu`5`a|pid=7"] = { doc = sub } } })
    eq({ "one", "two In", "L" }, d.lines)
    eq({ 1, 2 }, { d.links[1].row, d.links[2].row })
  end,

  ["slugify strips tags"] = function()
    eq("hello-world", render.slugify("`!Hello`! `F0a0World`f!"))
    eq("a-b", render.slugify("`:anchor a b"))
  end,
}
