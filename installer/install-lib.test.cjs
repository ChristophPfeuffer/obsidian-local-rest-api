// Tests for install-lib.cjs. Kept IDENTICAL in all three repositories, like
// the library itself. Run with:  node --test "installer/*.test.cjs"

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { PassThrough } = require("node:stream");
const lib = require("./install-lib.cjs");

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "install-lib-"));
}

function quietLog() {
  const lines = [];
  const rec = (kind) => (msg) => lines.push(`${kind}: ${msg}`);
  return { lines, section: rec("section"), debug: rec("debug"), ok: rec("ok"), warn: rec("warn"), fail: rec("fail") };
}

// A prompter that answers from a fixed list and records what was asked.
function scriptedPrompter(answers) {
  const asked = [];
  return {
    asked,
    async confirm(q) {
      asked.push(q);
      return lib.isYes(answers.shift() ?? "", true);
    },
  };
}

test("appDataRoot: %LOCALAPPDATA% on Windows, Application Support on macOS", () => {
  assert.equal(lib.appDataRoot({ platform: "win32", env: { LOCALAPPDATA: "C:\\Users\\u\\AppData\\Local" }, home: "C:\\Users\\u" }), "C:\\Users\\u\\AppData\\Local");
  assert.equal(lib.appDataRoot({ platform: "darwin", env: {}, home: "/Users/u" }), path.join("/Users/u", "Library", "Application Support"));
  assert.equal(lib.defaultTarget("node", { platform: "darwin", env: {}, home: "/Users/u" }), path.join("/Users/u", "Library", "Application Support", "node"));
});

test("stripQuotes: removes the quotes a dragged-in path arrives with", () => {
  assert.equal(lib.stripQuotes('"C:\\My Folder"'), "C:\\My Folder");
  assert.equal(lib.stripQuotes("'/Users/u/x y'"), "/Users/u/x y");
  assert.equal(lib.stripQuotes("  plain  "), "plain");
});

test("isYes: empty answer takes the default; y/yes/j/ja are yes", () => {
  assert.equal(lib.isYes("", true), true);
  assert.equal(lib.isYes("", false), false);
  for (const a of ["y", "YES", "j", "Ja"]) assert.equal(lib.isYes(a, false), true);
  assert.equal(lib.isYes("n", true), false);
});

test("createPrompter.askPath: Enter keeps the default, a typed path replaces it", async () => {
  const input = new PassThrough();
  const output = new PassThrough();
  const p = lib.createPrompter(input, output);
  input.write("\n");
  input.write('"/tmp/other place"\n');
  input.end();
  assert.equal(await p.askPath("Target", "/default"), "/default");
  assert.equal(await p.askPath("Target", "/default"), path.resolve("/tmp/other place"));
  p.close();
});

test("deepEqual: key order doesn't matter, values do", () => {
  assert.ok(lib.deepEqual({ a: 1, b: { c: [1, 2] } }, { b: { c: [1, 2] }, a: 1 }));
  assert.ok(!lib.deepEqual({ a: 1 }, { a: 1, b: undefined }));
  assert.ok(!lib.deepEqual([1, 2], [2, 1]));
});

test("writeIfChanged: created -> unchanged -> updated", () => {
  const f = path.join(tmpDir(), "sub", "x.txt");
  assert.equal(lib.writeIfChanged(f, "a"), "created");
  const mtime = fs.statSync(f).mtimeMs;
  assert.equal(lib.writeIfChanged(f, "a"), "unchanged");
  assert.equal(fs.statSync(f).mtimeMs, mtime, "an unchanged file must not be rewritten");
  assert.equal(lib.writeIfChanged(f, "b"), "updated");
  assert.equal(fs.readFileSync(f, "utf8"), "b");
});

test("syncFiles / filesDiffer: only changed files are reported and copied", () => {
  const src = tmpDir();
  const dst = tmpDir();
  fs.writeFileSync(path.join(src, "a.js"), "A");
  fs.writeFileSync(path.join(src, "b.js"), "B");
  fs.writeFileSync(path.join(dst, "a.js"), "A");
  assert.deepEqual(lib.filesDiffer(src, dst, ["a.js", "b.js"]), ["b.js"]);
  assert.deepEqual(lib.syncFiles(src, dst, ["a.js", "b.js"]), { created: ["b.js"], updated: [], unchanged: ["a.js"] });
  assert.deepEqual(lib.filesDiffer(src, dst, ["a.js", "b.js"]), []);
});

test("candidateConfigPaths + resolveConfigPath: standard and Store locations on Windows", () => {
  const local = tmpDir();
  fs.mkdirSync(path.join(local, "Packages", "Claude_abc123"), { recursive: true });
  const c = lib.candidateConfigPaths({ platform: "win32", env: { APPDATA: "R", LOCALAPPDATA: local }, home: "H" });
  assert.equal(c[0].tag, "standard");
  assert.equal(c[1].tag, "store");
  assert.match(c[1].path, /Claude_abc123[\\/]LocalCache[\\/]Roaming[\\/]Claude[\\/]claude_desktop_config\.json$/);
  assert.equal(lib.resolveConfigPath(c, () => false).tag, "store", "nothing exists yet -> Store path");
  assert.equal(lib.resolveConfigPath(c, (p) => p === c[0].path).tag, "standard", "existing file wins");
});

test("planEntry: unchanged / new / changed (with masked key in the change list)", () => {
  const entry = { command: "n", args: ["x"], env: { OBSIDIAN_API_KEY: "abcdefghijklmnop" } };
  const config = { mcpServers: { obsidian: { args: ["x"], env: { OBSIDIAN_API_KEY: "abcdefghijklmnop" }, command: "n" } } };
  assert.equal(lib.planEntry(config, "obsidian", entry).status, "unchanged");
  assert.equal(lib.planEntry({ mcpServers: {} }, "obsidian", entry).status, "new");
  const changed = lib.planEntry(config, "obsidian", { ...entry, env: { OBSIDIAN_API_KEY: "zzzzefghijklzzzz" } });
  assert.equal(changed.status, "changed");
  assert.equal(changed.changes.length, 1);
  assert.ok(!changed.changes[0].includes("abcdefghijklmnop"), "old key must be masked");
  assert.ok(!changed.changes[0].includes("zzzzefghijklzzzz"), "new key must be masked");
});

test("applyClaudeEntry: an identical entry asks nothing and writes nothing", async () => {
  const dir = tmpDir();
  const configPath = path.join(dir, "claude_desktop_config.json");
  const entry = { command: "n", args: ["x"] };
  fs.writeFileSync(configPath, JSON.stringify({ mcpServers: { zotero: entry }, other: 1 }));
  const before = fs.readFileSync(configPath, "utf8");
  const prompter = scriptedPrompter([]);
  const status = await lib.applyClaudeEntry({ configPath, name: "zotero", entry: { ...entry }, prompter, log: quietLog() });
  assert.equal(status, "unchanged");
  assert.equal(prompter.asked.length, 0, "no question when nothing would change");
  assert.equal(fs.readFileSync(configPath, "utf8"), before);
  assert.equal(fs.readdirSync(dir).length, 1, "no backup file either");
});

test("applyClaudeEntry: a changed entry asks once, backs up, keeps other servers and keys", async () => {
  const dir = tmpDir();
  const configPath = path.join(dir, "claude_desktop_config.json");
  fs.writeFileSync(configPath, JSON.stringify({ mcpServers: { zotero: { command: "old" }, other: { command: "keep" } }, globalShortcut: "x" }));
  const prompter = scriptedPrompter(["y"]);
  const status = await lib.applyClaudeEntry({ configPath, name: "zotero", entry: { command: "new" }, prompter, log: quietLog() });
  assert.equal(status, "changed");
  assert.equal(prompter.asked.length, 1);
  const written = JSON.parse(fs.readFileSync(configPath, "utf8"));
  assert.deepEqual(written, { mcpServers: { zotero: { command: "new" }, other: { command: "keep" } }, globalShortcut: "x" });
  assert.equal(fs.readdirSync(dir).filter((f) => f.includes(".bak-")).length, 1);
});

test("applyClaudeEntry: declining leaves the file untouched", async () => {
  const dir = tmpDir();
  const configPath = path.join(dir, "claude_desktop_config.json");
  fs.writeFileSync(configPath, JSON.stringify({ mcpServers: {} }));
  const before = fs.readFileSync(configPath, "utf8");
  const status = await lib.applyClaudeEntry({ configPath, name: "z", entry: { command: "c" }, prompter: scriptedPrompter(["n"]), log: quietLog() });
  assert.equal(status, "declined");
  assert.equal(fs.readFileSync(configPath, "utf8"), before);
});

test("readClaudeConfig: missing file -> empty config; broken JSON -> clear error", () => {
  const dir = tmpDir();
  assert.deepEqual(lib.readClaudeConfig(path.join(dir, "none.json")), { mcpServers: {} });
  const bad = path.join(dir, "bad.json");
  fs.writeFileSync(bad, "{ not json");
  assert.throws(() => lib.readClaudeConfig(bad), /isn't valid JSON/);
});

test("ensureNodeCommand: Windows writes the wrapper once, then reports unchanged; macOS uses the absolute path", () => {
  const dir = tmpDir();
  const a = lib.ensureNodeCommand({ wrapperDir: dir, platform: "win32", execPath: "C:\\node\\node.exe" });
  assert.equal(a.status, "created");
  assert.equal(a.command, path.join(dir, "node-wrapper.cmd"));
  assert.match(fs.readFileSync(a.command, "utf8"), /"C:\\node\\node\.exe" %\*\r\n/);
  assert.equal(lib.ensureNodeCommand({ wrapperDir: dir, platform: "win32", execPath: "C:\\node\\node.exe" }).status, "unchanged");
  assert.equal(lib.ensureNodeCommand({ wrapperDir: dir, platform: "win32", execPath: "C:\\node2\\node.exe" }).status, "updated");
  assert.deepEqual(lib.ensureNodeCommand({ wrapperDir: dir, platform: "darwin", execPath: "/opt/node/bin/node" }), { command: "/opt/node/bin/node", status: "not-needed" });
});

test("maskSecret: never shows the full secret", () => {
  assert.equal(lib.maskSecret("12345678"), "********");
  assert.equal(lib.maskSecret("abcdefghijkl"), "abcd****ijkl");
});

test("obsidianConfigPath: Obsidian's vault list on Windows and macOS", () => {
  assert.equal(
    lib.obsidianConfigPath({ platform: "win32", env: { APPDATA: "C:\\Users\\u\\AppData\\Roaming" }, home: "C:\\Users\\u" }),
    path.join("C:\\Users\\u\\AppData\\Roaming", "obsidian", "obsidian.json")
  );
  assert.equal(lib.obsidianConfigPath({ platform: "darwin", env: {}, home: "/Users/u" }), path.join("/Users/u", "Library", "Application Support", "obsidian", "obsidian.json"));
});

test("parseVaultList: newest first; broken or empty files give an empty list", () => {
  const json = JSON.stringify({ vaults: { a: { path: "/old", ts: 1 }, b: { path: "/new", ts: 5, open: true }, c: { ts: 9 } } });
  assert.deepEqual(lib.parseVaultList(json), ["/new", "/old"]);
  assert.deepEqual(lib.parseVaultList("not json"), []);
  assert.deepEqual(lib.parseVaultList(""), []);
  assert.deepEqual(lib.parseVaultList("{}"), []);
});

test("chooseVault: remembered vault or the only known vault is used without asking", async () => {
  const v1 = tmpDir();
  fs.mkdirSync(path.join(v1, ".obsidian"));
  const noAsk = { ask: async () => assert.fail("must not ask") };
  assert.equal(await lib.chooseVault(noAsk, { remembered: v1, vaults: ["/other"], log: quietLog() }), v1);
  assert.equal(await lib.chooseVault(noAsk, { vaults: [v1], log: quietLog() }), v1);
});

test("chooseVault: several vaults -> Enter picks the most recent, a number picks that one", async () => {
  const a = tmpDir();
  const b = tmpDir();
  fs.mkdirSync(path.join(a, ".obsidian"));
  fs.mkdirSync(path.join(b, ".obsidian"));
  const answers = ["", "2"];
  const p = { ask: async () => answers.shift() };
  const log = console.log;
  console.log = () => {};
  try {
    assert.equal(await lib.chooseVault(p, { vaults: [a, b], log: quietLog() }), a);
    assert.equal(await lib.chooseVault(p, { vaults: [a, b], log: quietLog() }), b);
  } finally {
    console.log = log;
  }
});

test("chooseVault: a folder without .obsidian is refused", async () => {
  const notVault = tmpDir();
  await assert.rejects(() => lib.chooseVault({ ask: async () => notVault }, { vaults: [], log: quietLog() }), /doesn't look like an Obsidian vault/);
});

test("npmInvocation: runs npm-cli.js with the current Node — no shell (Windows and macOS layouts)", () => {
  const win = lib.npmInvocation(["test"], { platform: "win32", execPath: "C:\\node\\node.exe", exists: (p) => p.endsWith("npm-cli.js") });
  assert.equal(win.shell, false);
  assert.equal(win.command, "C:\\node\\node.exe");
  assert.equal(win.args[0], "C:\\node\\node_modules\\npm\\bin\\npm-cli.js");
  assert.deepEqual(win.args.slice(1), ["test"]);
  const mac = lib.npmInvocation(["ci"], { platform: "darwin", execPath: "/n/bin/node", exists: (p) => p.endsWith("npm-cli.js") });
  assert.equal(mac.shell, false);
  assert.equal(mac.args[0], "/n/lib/node_modules/npm/bin/npm-cli.js");
});

test("npmInvocation: without npm-cli.js, macOS uses npm from PATH without a shell", () => {
  assert.deepEqual(lib.npmInvocation(["test"], { platform: "darwin", execPath: "/x/node", exists: () => false }), { command: "npm", args: ["test"], shell: false });
});

test("npmInvocation: Windows shell fallback is one fixed string (no argument list -> no DEP0190), unsafe args refused", () => {
  const inv = lib.npmInvocation(["ci", "--omit=dev", "--no-fund"], { platform: "win32", execPath: "C:\\x\\node.exe", exists: () => false });
  assert.deepEqual(inv, { command: "npm ci --omit=dev --no-fund", args: null, shell: true });
  assert.throws(() => lib.npmInvocation(["test", "& calc"], { platform: "win32", execPath: "C:\\x\\node.exe", exists: () => false }), /Refusing/);
});

test("runNpm: quiet by default — output only shown when the command fails", () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, "package.json"), JSON.stringify({ scripts: { good: "node -e \"console.log('SHOULD-NOT-SHOW')\"", bad: "node -e \"console.log('SHOULD-SHOW');process.exit(3)\"" } }));
  const log = quietLog();
  const printed = [];
  const orig = console.log;
  console.log = (m) => printed.push(String(m));
  try {
    assert.equal(lib.runNpm(["run", "good"], dir, { log }), 0);
    assert.ok(!printed.join("\n").includes("SHOULD-NOT-SHOW"));
    assert.notEqual(lib.runNpm(["run", "bad"], dir, { log }), 0);
    assert.ok(printed.join("\n").includes("SHOULD-SHOW"));
  } finally {
    console.log = orig;
  }
});

test("readWrapperTarget: the Node path a wrapper forwards to", () => {
  const dir = tmpDir();
  const f = path.join(dir, "node-wrapper.cmd");
  fs.writeFileSync(f, lib.nodeWrapperContent("C:\\Program Files\\nodejs\\node.exe"));
  assert.equal(lib.readWrapperTarget(f), "C:\\Program Files\\nodejs\\node.exe");
  assert.equal(lib.readWrapperTarget(path.join(dir, "missing.cmd")), null);
});

test("wrapperCandidates: remembered, then folders other Claude entries use, then the default — no duplicates", () => {
  const config = { mcpServers: { zotero: { command: "C:\\W\\node-wrapper.cmd" }, other: { command: "node" }, again: { command: "c:\\w\\NODE-WRAPPER.CMD" } } };
  assert.deepEqual(lib.wrapperCandidates({ rememberedDir: "C:\\R", config, defaultDir: "C:\\D" }), ["C:\\R", "C:\\W", "C:\\D"]);
  assert.deepEqual(lib.wrapperCandidates({ config: {}, defaultDir: "C:\\D" }), ["C:\\D"]);
});

test("chooseWrapperDir: an existing wrapper is used without asking (e.g. the one the Zotero entry already uses)", async () => {
  const dir = tmpDir();
  fs.writeFileSync(path.join(dir, "node-wrapper.cmd"), lib.nodeWrapperContent("C:\\n\\node.exe"));
  const config = { mcpServers: { zotero: { command: path.join(dir, "node-wrapper.cmd") } } };
  const noAsk = { askPath: async () => assert.fail("must not ask") };
  const log = quietLog();
  assert.equal(await lib.chooseWrapperDir(noAsk, { config, platform: "win32", execPath: "C:\\n\\node.exe", defaultDir: path.join(dir, "nope"), log }), dir);
  assert.ok(log.lines.some((l) => /up to date/.test(l)));
});

test("chooseWrapperDir: asks only when no wrapper exists yet or --change-locations; null on macOS", async () => {
  const empty = tmpDir();
  let asked = 0;
  const p = { askPath: async (_q, d) => (asked++, d) };
  assert.equal(await lib.chooseWrapperDir(p, { platform: "win32", defaultDir: empty, log: quietLog() }), empty);
  assert.equal(asked, 1);
  fs.writeFileSync(path.join(empty, "node-wrapper.cmd"), lib.nodeWrapperContent("x"));
  await lib.chooseWrapperDir(p, { platform: "win32", defaultDir: empty, changeLocations: true, log: quietLog() });
  assert.equal(asked, 2);
  assert.equal(await lib.chooseWrapperDir(p, { platform: "darwin" }), null);
});

test("ensureNodeWrapper: unchanged wrapper -> no question; outdated -> asks; declined -> kept as is", async () => {
  const dir = tmpDir();
  const f = path.join(dir, "node-wrapper.cmd");
  const noAsk = { confirm: async () => assert.fail("must not ask") };
  assert.equal((await lib.ensureNodeWrapper(noAsk, { wrapperDir: dir, platform: "win32", execPath: "C:\\a\\node.exe", log: quietLog() })).status, "created");
  assert.equal((await lib.ensureNodeWrapper(noAsk, { wrapperDir: dir, platform: "win32", execPath: "C:\\a\\node.exe", log: quietLog() })).status, "unchanged");
  const decline = scriptedPrompter(["n"]);
  assert.equal((await lib.ensureNodeWrapper(decline, { wrapperDir: dir, platform: "win32", execPath: "C:\\b\\node.exe", log: quietLog() })).status, "kept");
  assert.equal(lib.readWrapperTarget(f), "C:\\a\\node.exe");
  const accept = scriptedPrompter(["y"]);
  assert.equal((await lib.ensureNodeWrapper(accept, { wrapperDir: dir, platform: "win32", execPath: "C:\\b\\node.exe", log: quietLog() })).status, "updated");
  assert.equal(lib.readWrapperTarget(f), "C:\\b\\node.exe");
  assert.deepEqual(await lib.ensureNodeWrapper(noAsk, { platform: "darwin", execPath: "/n/node" }), { command: "/n/node", status: "not-needed" });
});
