// Regenerate test/fixtures/reference.json from the VS Code extension:
//   (cd ../rns-micron-vsix && npm run compile)
//   node test/gen-reference.js ../rns-micron-vsix > test/fixtures/reference.json
const path = require("path");
const Module = require("module");

const vsix = path.resolve(process.argv[2] || "../rns-micron-vsix");
const load = Module._load;
Module._load = function (request, ...rest) {
  if (request === "vscode") return { workspace: {}, window: {} };
  return load.call(this, request, ...rest);
};
const { parseMicronHref, isShebangScript } = require(path.join(vsix, "out/scriptRunner.js"));
const { mergePreviewFields } = require(path.join(vsix, "out/previewConfig.js"));

const hrefs = [
  "", "#", "#tables", ":/page/index.mu", "/page/a/b.mu", "page/x.mu", "/file/notes.zip", "file/x.txt",
  "nomadnetwork://:/page/index.mu", "lxmf://abc", "https://example.com/x", "HTTP://EXAMPLE.com",
  "0123456789abcdef0123456789abcdef:/page/remote.mu", "abcdef:/page/short.mu",
  ":/page/search.mu`q=hello|page=2", ":/page/x.mu`=bad|noeq|k=v=w", "plain.mu", "/something/else",
  "  :/page/trim.mu  ",
];
const parse = hrefs.map((input) => {
  const r = parseMicronHref(input);
  return { input, kind: r.kind, path: r.path, request_vars: r.requestVars };
});
const merge = [
  { sticky: { a: "1", b: "2" }, incoming: { b: "3", c: "4" }, vars: {} },
  { sticky: { a: "1", b: "2" }, incoming: { a: "" }, vars: { d: "5" } },
  { sticky: { a: "1" }, incoming: { clear: "1", x: "y" }, vars: {} },
  { sticky: { clear: "old" }, incoming: {}, vars: { a: "" } },
].map((m) => ({ ...m, expected: mergePreviewFields(m.sticky, m.incoming, m.vars) }));
const shebang = ["#!/usr/bin/env python3\nprint()", "#!c=60\n>Static", "#!fg=ddd", "#! /bin/sh", ">no", "#!bg=222"].map(
  (input) => ({ input, expected: isShebangScript(input) }),
);

console.log(JSON.stringify({ parse, merge, shebang }, null, 2));
