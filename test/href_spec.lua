-- Parity with rns-micron-vsix (fixtures generated from its scriptRunner/previewConfig).
local href = require("micron.href")
local runner = require("micron.runner")

local root = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
local fd = assert(io.open(root .. "/fixtures/reference.json"))
local ref = vim.json.decode(fd:read("*a"), { luanil = { object = true } })
fd:close()

local function eq(expected, actual, ctx)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\nactual:   %s"):format(ctx, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function tmpnode()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/pages/sub", "p")
  vim.fn.mkdir(dir .. "/files", "p")
  for _, p in ipairs({ "pages/index.mu", "pages/sub/deep.mu", "files/a.zip" }) do
    local f = assert(io.open(dir .. "/" .. p, "w"))
    f:write("x")
    f:close()
  end
  return vim.fs.normalize(dir)
end

return {
  ["parse matches reference"] = function()
    for _, case in ipairs(ref.parse) do
      local r = href.parse(case.input)
      eq(
        { case.kind, case.path, case.request_vars },
        { r.kind, r.path, r.request_vars },
        "parse " .. vim.inspect(case.input)
      )
    end
  end,

  ["parse records the destination node hash"] = function()
    eq("0123456789abcdef0123456789abcdef", href.parse("0123456789ABCDEF0123456789abcdef:/page/x.mu").node, "node")
    eq(nil, href.parse(":/page/x.mu").node, "local link")
  end,

  ["merge_fields matches reference"] = function()
    for _, case in ipairs(ref.merge) do
      eq(case.expected, href.merge_fields(case.sticky, case.incoming, case.vars), "merge " .. vim.inspect(case))
    end
  end,

  ["shebang detection matches reference"] = function()
    for _, case in ipairs(ref.shebang) do
      eq(case.expected, runner.is_shebang(case.input), "shebang " .. vim.inspect(case.input))
    end
  end,

  ["build_env exports field_ aliases and lets explicit keys win"] = function()
    local env = href.build_env({ name = "ivan", field_age = "3", var_x = "1", q = "a", field_q = "b" }, { E = "e" }, {})
    eq("ivan", env.name, "name")
    eq("ivan", env.field_name, "field_name")
    eq("3", env.age, "bare from field_")
    eq(nil, env.field_var_x, "var_ not aliased")
    eq("a", env.q, "explicit bare")
    eq("b", env.field_q, "explicit field_ beats derived")
    eq("e", env.E, "extra env")
  end,

  ["build_env does not override existing bare env from field_"] = function()
    local env = href.build_env({ field_HOME = "/x" }, {}, { HOME = "/home/me" })
    eq("/home/me", env.HOME, "HOME")
  end,

  ["resolve_page: relative to page, then pages root; rejects .."] = function()
    local node = tmpnode()
    local from = node .. "/pages/sub/deep.mu"
    eq(node .. "/pages/index.mu", href.resolve_page(from, ":/page/index.mu"), "pages root fallback")
    eq(node .. "/pages/sub/deep.mu", href.resolve_page(node .. "/pages/index.mu", "/page/sub/deep.mu"), "nested")
    eq(nil, href.resolve_page(from, ":/page/../pages/index.mu"), "dotdot")
    eq(nil, href.resolve_page(from, ":/page/missing.mu"), "missing")
  end,

  ["resolve_file and files_dir use the node files/ directory"] = function()
    local node = tmpnode()
    local from = node .. "/pages/sub/deep.mu"
    eq(node .. "/files/a.zip", href.resolve_file(from, ":/file/a.zip"), "file")
    eq(nil, href.resolve_file(from, ":/file/b.zip"), "missing file")
    eq(node .. "/files", href.files_dir(from), "files dir")
    vim.fn.delete(node .. "/files", "rf")
    eq(nil, href.files_dir(from), "absent files dir")
  end,
}
