// Tests for relink-node.cjs (kept IDENTICAL in MCP-Zotero and
// obsidian-local-rest-api).

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { entriesToRelink, relinked, wrappersToRelink, parseArgs } = require("./relink-node.cjs");

test("parseArgs: --to sets the new command, the rest are old paths", () => {
  assert.deepEqual(parseArgs(["--to=/opt/homebrew/bin/node", "/a/node", "/b/node"]), { newPath: "/opt/homebrew/bin/node", oldPaths: ["/a/node", "/b/node"] });
  assert.deepEqual(parseArgs(["/a/node"]), { newPath: process.execPath, oldPaths: ["/a/node"] });
});

const OLD = "/Users/u/Library/Application Support/node/node-v20.19.0-darwin-arm64/bin/node";
const NEW = "/Users/u/Library/Application Support/node/node-v24.11.0-darwin-arm64/bin/node";

test("entriesToRelink: old path, vanished node binaries; not new, npx or other commands", () => {
  const config = {
    mcpServers: {
      zotero: { command: OLD, args: ["/x/index.js"] },
      gone: { command: "/opt/homebrew/Cellar/node/20.1.0/bin/node" },
      current: { command: NEW },
      npx: { command: "npx", args: ["-y", "pkg"] },
      other: { command: "/usr/bin/python3" },
    },
  };
  const exists = (p) => p === NEW || p === "/usr/bin/python3";
  assert.deepEqual(entriesToRelink(config, [OLD], NEW, exists), ["zotero", "gone"]);
  assert.deepEqual(entriesToRelink(config, OLD, NEW, exists), ["zotero", "gone"]);
  assert.deepEqual(entriesToRelink(config, [], NEW, () => true), []);
  assert.deepEqual(entriesToRelink({}, [OLD], NEW, exists), []);
});

test("entriesToRelink: Windows node.exe paths, case-insensitive", () => {
  const oldWin = "C:\\Users\\u\\AppData\\Local\\node\\node-v20.19.0-win-x64\\node.exe";
  const newWin = "C:\\Users\\u\\AppData\\Local\\node\\node-v24.11.0-win-x64\\node.exe";
  const config = { mcpServers: { a: { command: oldWin.toUpperCase() }, b: { command: newWin }, w: { command: "C:\\x\\node-wrapper.cmd" } } };
  assert.deepEqual(entriesToRelink(config, [oldWin], newWin, () => true), ["a"]);
});

test("wrappersToRelink: wrappers from entries and the default one that forward to an old node", () => {
  const oldWin = "C:\\L\\node\\node-v20.0.0-win-x64\\node.exe";
  const newWin = "C:\\L\\node\\node-v24.0.0-win-x64\\node.exe";
  const targets = {
    "C:\\L\\node-wrapper\\node-wrapper.cmd": oldWin, // default, also used by an entry
    "D:\\tools\\node-wrapper.cmd": newWin, // already new
    "E:\\w\\node-wrapper.cmd": "C:\\gone\\node.exe", // target vanished
  };
  const exists = (p) => p in targets || p === newWin || p === oldWin;
  const config = {
    mcpServers: {
      zotero: { command: "C:\\L\\node-wrapper\\node-wrapper.cmd" },
      bridge: { command: "D:\\tools\\node-wrapper.cmd" },
      other: { command: "E:\\w\\node-wrapper.cmd" },
      npx: { command: "npx" },
    },
  };
  const got = wrappersToRelink(config, [oldWin], newWin, {
    defaultWrapper: "c:\\l\\node-wrapper\\node-wrapper.cmd",
    exists,
    readTarget: (f) => targets[f],
  });
  assert.deepEqual(got, ["C:\\L\\node-wrapper\\node-wrapper.cmd", "E:\\w\\node-wrapper.cmd"]);
});

test("relinked: only command changes, everything else is kept", () => {
  const config = { other: 1, mcpServers: { zotero: { command: OLD, args: ["a"], env: { K: "v" } }, keep: { command: "npx" } } };
  const next = relinked(config, ["zotero"], NEW);
  assert.deepEqual(next, { other: 1, mcpServers: { zotero: { command: NEW, args: ["a"], env: { K: "v" } }, keep: { command: "npx" } } });
  assert.equal(config.mcpServers.zotero.command, OLD);
});
