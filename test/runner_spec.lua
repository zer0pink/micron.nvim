local runner = require("micron.runner")
local trust = require("micron.trust")

local function eq(expected, actual, ctx)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\nactual:   %s"):format(ctx or "", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function with_trust(value, fn)
  local orig = trust.is_trusted
  trust.is_trusted = function()
    return value
  end
  local ok, err = pcall(fn)
  trust.is_trusted = orig
  if not ok then
    error(err, 0)
  end
end

local function page(text, opts)
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir .. "/pages", "p")
  local path = dir .. "/pages/p.mu"
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
  return vim.tbl_extend("force", { path = path, text = text, dirty = false }, opts or {})
end

local function resolve(pg, opts)
  local result
  runner.resolve(
    pg,
    vim.tbl_extend("force", { fields = {}, execute_scripts = true, timeout_ms = 5000, extra_env = {} }, opts or {}),
    function(r)
      result = r
    end
  )
  assert(
    vim.wait(6000, function()
      return result ~= nil
    end, 10),
    "resolve timed out"
  )
  return result
end

local SCRIPT = '#!/bin/sh\nprintf "%s|%s|%s" "$field_name" "$name" "$EXTRA"\n'

return {
  ["static pages and #! directives are not executed"] = function()
    eq("static", resolve(page(">x\n")).mode)
    eq("static", resolve(page("#!c=60\n>x\n")).mode)
  end,

  ["execute_scripts=false previews the source as skipped"] = function()
    local r = resolve(page(SCRIPT), { execute_scripts = false })
    eq({ "skipped", SCRIPT }, { r.mode, r.markup })
  end,

  ["untrusted roots are never executed"] = function()
    with_trust(false, function()
      local r = resolve(page(SCRIPT))
      eq("untrusted", r.mode)
      eq(SCRIPT, r.markup)
      assert(r.root and r.root:match("/[^/]+$"), "root reported")
    end)
  end,

  ["script stdout becomes markup, fields exported to env"] = function()
    with_trust(true, function()
      local r = resolve(page(SCRIPT), { fields = { name = "ivan" }, extra_env = { EXTRA = "e" } })
      eq({ "script", "ivan|ivan|e", 0 }, { r.mode, r.markup, r.exit_code })
    end)
  end,

  ["unsaved buffers run a temporary copy next to the page"] = function()
    with_trust(true, function()
      local pg = page(SCRIPT)
      pg.text = '#!/bin/sh\necho "edited $(basename "$0")"\n'
      pg.dirty = true
      local r = resolve(pg)
      eq("edited .micron-preview-p.mu\n", r.markup)
      eq(0, vim.fn.filereadable(vim.fs.dirname(pg.path) .. "/.micron-preview-p.mu"), "temp copy removed")
    end)
  end,

  ["non-zero exit is a script error with stderr"] = function()
    with_trust(true, function()
      local r = resolve(page("#!/bin/sh\necho boom >&2\nexit 3\n"))
      eq({ "script-error", 3, "Script exited with code 3", "boom\n" }, { r.mode, r.exit_code, r.error, r.stderr })
    end)
  end,

  ["timeouts kill the script"] = function()
    with_trust(true, function()
      local r = resolve(page("#!/bin/sh\nsleep 5\n"), { timeout_ms = 100 })
      eq({ "script-error", true }, { r.mode, r.timed_out })
      assert(r.elapsed_ms < 2000, "killed promptly")
    end)
  end,

  ["require_executable_bit skips non-executable scripts"] = function()
    with_trust(true, function()
      local r = resolve(page(SCRIPT), { require_executable_bit = true })
      eq("skipped", r.mode)
      assert(r.error)
    end)
  end,

  ["cancel suppresses the callback"] = function()
    with_trust(true, function()
      local called = false
      local h = runner.resolve(
        page("#!/bin/sh\nsleep 1\n"),
        { fields = {}, execute_scripts = true, timeout_ms = 5000 },
        function()
          called = true
        end
      )
      h.cancel()
      vim.wait(300)
      eq(false, called)
    end)
  end,

  ["interpreter parsing handles env and args"] = function()
    eq({ "python3", "-u" }, runner.interpreter("#!/usr/bin/env python3 -u"))
    eq({ "/bin/sh" }, runner.interpreter("#! /bin/sh"))
  end,
}
