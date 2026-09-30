// Tests for the plugin installer's own logic (install.js). Run with:
//   npm run test:installer
// Vault handling is shared and tested in install-lib.test.cjs.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const inst = require("../install.js");

test("needsDependencyInstall: missing node_modules, or esbuild built for another system", () => {
  const has = (set) => (p) => set.some((s) => p.endsWith(s));
  assert.match(inst.needsDependencyInstall("/r", { exists: has([]) }), /missing/);
  assert.match(
    inst.needsDependencyInstall("/r", { platform: "darwin", arch: "arm64", exists: has(["node_modules", path.join("@esbuild", "win32-x64")]) }),
    /no esbuild binary for darwin-arm64/
  );
  assert.equal(inst.needsDependencyInstall("/r", { platform: "win32", arch: "x64", exists: has(["node_modules", path.join("@esbuild", "win32-x64")]) }), null);
});
