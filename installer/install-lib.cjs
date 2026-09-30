// Shared installer helpers for the Zotero MCP, the Obsidian REST API plugin
// and the Obsidian MCP bridge. This file is kept IDENTICAL in all three
// repositories (MCP-Zotero, obsidian-local-rest-api, MCP-Bridge-Obsidian, each
// under installer/) — change it in one, copy it to the others, and run all
// three test suites.
//
// Rules every installer built on this follows:
//   - Install targets live in the per-user app-data folder, not in the repo:
//       Windows  %LOCALAPPDATA%\<name>
//       macOS    ~/Library/Application Support/<name>
//     The repo is only the source. Each target can be changed in the console
//     dialog; the choice is remembered where the installed thing itself
//     records it (e.g. the Claude Desktop entry), so re-runs don't re-ask.
//   - Compare before writing: a file or config entry that would not change is
//     left alone, and the user is only asked when something would change.
//   - Claude Desktop's config is backed up before every write.
//   - Secrets (API keys) are masked in everything printed.
//
// CommonJS on purpose: the Obsidian repo is CommonJS and the Zotero repo is
// ESM; a .cjs file can be required by the first and imported by the second.

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const readline = require("node:readline");
const { spawnSync } = require("node:child_process");

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

const out = {
  section(title) {
    console.log(`\n\x1b[1m${title}\x1b[0m`);
  },
  debug(msg) {
    console.log(`\x1b[2m  · ${msg}\x1b[0m`);
  },
  ok(msg) {
    console.log(`  \x1b[32m✔\x1b[0m ${msg}`);
  },
  warn(msg) {
    console.log(`  \x1b[33m⚠\x1b[0m ${msg}`);
  },
  fail(msg) {
    console.error(`  \x1b[31m✘\x1b[0m ${msg}`);
    process.exit(1);
  },
};

// Masks a secret in the middle so it can be shown for confirmation without
// re-displaying it in full.
function maskSecret(secret) {
  if (typeof secret !== "string") return secret;
  if (secret.length <= 8) return "*".repeat(secret.length);
  return `${secret.slice(0, 4)}${"*".repeat(secret.length - 8)}${secret.slice(-4)}`;
}

// ---------------------------------------------------------------------------
// Console dialog
//
// One shared readline interface consumed as an async iterator: rl.question()
// loses input on the second and later prompts when stdin is piped (Node reads
// all available lines up front, question() only listens just-in-time).
// ---------------------------------------------------------------------------

function createPrompter(input = process.stdin, output = process.stdout) {
  const rl = readline.createInterface({ input, output, terminal: false });
  const lines = rl[Symbol.asyncIterator]();
  async function ask(query) {
    output.write(`\x1b[1m❯\x1b[0m ${query}`);
    const { value, done } = await lines.next();
    return done ? "" : String(value);
  }
  return {
    ask,
    // Shows the default; Enter keeps it, anything else replaces it.
    async askPath(label, defaultPath) {
      const answer = (await ask(`${label}\n    [${defaultPath}]\n    Enter = keep, or type another folder: `)).trim();
      return answer === "" ? defaultPath : path.resolve(stripQuotes(answer));
    },
    async confirm(query, defaultYes = true) {
      return isYes(await ask(`${query} ${defaultYes ? "[Y/n]" : "[y/N]"}: `), defaultYes);
    },
    close() {
      rl.close();
    },
  };
}

// Paths dragged into a terminal often arrive wrapped in quotes.
function stripQuotes(s) {
  const t = s.trim();
  if (t.length >= 2 && ((t[0] === '"' && t.at(-1) === '"') || (t[0] === "'" && t.at(-1) === "'"))) {
    return t.slice(1, -1);
  }
  return t;
}

function isYes(answer, defaultYes) {
  const a = String(answer).trim().toLowerCase();
  if (a === "") return defaultYes;
  return a === "y" || a === "yes" || a === "j" || a === "ja";
}

// ---------------------------------------------------------------------------
// Locations
// ---------------------------------------------------------------------------

// The per-user app-data root: %LOCALAPPDATA% on Windows,
// ~/Library/Application Support on macOS (Apple's place for per-user app
// support files), $XDG_DATA_HOME or ~/.local/share elsewhere.
function appDataRoot({ platform = process.platform, env = process.env, home = os.homedir() } = {}) {
  if (platform === "win32") return env.LOCALAPPDATA || path.join(home, "AppData", "Local");
  if (platform === "darwin") return path.join(home, "Library", "Application Support");
  return env.XDG_DATA_HOME || path.join(home, ".local", "share");
}

// Default install folder for one component, e.g. defaultTarget("zotero-mcp").
function defaultTarget(name, opts) {
  return path.join(appDataRoot(opts), name);
}

// Every plausible Claude Desktop config location. On Windows a Store/MSIX
// install redirects "Roaming" into %LOCALAPPDATA%\Packages\Claude_<id>\...,
// so that folder is scanned for.
function candidateConfigPaths({ platform = process.platform, env = process.env, home = os.homedir() } = {}) {
  const candidates = [];
  if (platform === "win32") {
    const appData = env.APPDATA || path.join(home, "AppData", "Roaming");
    candidates.push({ path: path.join(appData, "Claude", "claude_desktop_config.json"), tag: "standard" });
    const packagesDir = path.join(env.LOCALAPPDATA || path.join(home, "AppData", "Local"), "Packages");
    try {
      for (const entry of fs.readdirSync(packagesDir, { withFileTypes: true })) {
        if (entry.isDirectory() && entry.name.startsWith("Claude_")) {
          candidates.push({
            path: path.join(packagesDir, entry.name, "LocalCache", "Roaming", "Claude", "claude_desktop_config.json"),
            tag: "store",
          });
        }
      }
    } catch {
      // No Packages folder — one fewer place to check.
    }
  } else if (platform === "darwin") {
    candidates.push({ path: path.join(home, "Library", "Application Support", "Claude", "claude_desktop_config.json"), tag: "standard" });
  } else {
    candidates.push({ path: path.join(env.XDG_CONFIG_HOME || path.join(home, ".config"), "Claude", "claude_desktop_config.json"), tag: "standard" });
  }
  return candidates;
}

// The first existing candidate; if none exists yet, the Store one (that's
// where a Store app looks), else the standard one.
function resolveConfigPath(candidates, exists = fs.existsSync) {
  return candidates.find((c) => exists(c.path)) || candidates.find((c) => c.tag === "store") || candidates[0];
}

// ---------------------------------------------------------------------------
// Compare-before-write
// ---------------------------------------------------------------------------

// Deep equality for JSON-like values; object key order doesn't matter.
function deepEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== typeof b || a === null || b === null || typeof a !== "object") return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a)) return a.length === b.length && a.every((v, i) => deepEqual(v, b[i]));
  const ka = Object.keys(a);
  const kb = Object.keys(b);
  return ka.length === kb.length && ka.every((k) => Object.prototype.hasOwnProperty.call(b, k) && deepEqual(a[k], b[k]));
}

// Writes `content` only if the file doesn't already hold exactly that.
// Returns "created" | "updated" | "unchanged".
function writeIfChanged(file, content) {
  const data = Buffer.isBuffer(content) ? content : Buffer.from(content, "utf8");
  if (fs.existsSync(file)) {
    if (fs.readFileSync(file).equals(data)) return "unchanged";
    fs.writeFileSync(file, data);
    return "updated";
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, data);
  return "created";
}

function copyIfChanged(src, dst) {
  return writeIfChanged(dst, fs.readFileSync(src));
}

// Copies a list of files (relative to srcDir) into dstDir, each only if it
// changed. Returns { created: [], updated: [], unchanged: [] }.
function syncFiles(srcDir, dstDir, relPaths) {
  const result = { created: [], updated: [], unchanged: [] };
  for (const rel of relPaths) {
    const status = copyIfChanged(path.join(srcDir, rel), path.join(dstDir, rel));
    result[status].push(rel);
  }
  return result;
}

// Would syncFiles change anything? (Without writing.)
function filesDiffer(srcDir, dstDir, relPaths) {
  return relPaths.filter((rel) => {
    const dst = path.join(dstDir, rel);
    return !fs.existsSync(dst) || !fs.readFileSync(path.join(srcDir, rel)).equals(fs.readFileSync(dst));
  });
}

// ---------------------------------------------------------------------------
// Claude Desktop config
// ---------------------------------------------------------------------------

function readClaudeConfig(configPath) {
  if (!fs.existsSync(configPath)) return { mcpServers: {} };
  let config;
  try {
    config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  } catch (e) {
    throw new Error(`${configPath} isn't valid JSON (${e.message}) — fix or remove it, then re-run.`);
  }
  if (!config || typeof config !== "object") config = {};
  if (!config.mcpServers || typeof config.mcpServers !== "object") config.mcpServers = {};
  return config;
}

// Decides what to do with one server entry:
//   { status: "unchanged" }             identical — nothing to ask, nothing to write
//   { status: "new", entry }            not there yet
//   { status: "changed", entry, changes } differs; `changes` lists the fields
function planEntry(config, name, newEntry) {
  const existing = config.mcpServers && config.mcpServers[name];
  if (!existing) return { status: "new", entry: newEntry, changes: [] };
  if (deepEqual(existing, newEntry)) return { status: "unchanged", entry: existing, changes: [] };
  return { status: "changed", entry: newEntry, changes: describeChanges(existing, newEntry) };
}

// Human-readable field differences between two entries, secrets masked.
function describeChanges(oldEntry, newEntry, secretKeys = ["ZOTERO_API_KEY", "OBSIDIAN_API_KEY"]) {
  const lines = [];
  const show = (key, v) => (secretKeys.includes(key) && typeof v === "string" ? JSON.stringify(maskSecret(v)) : JSON.stringify(v));
  for (const key of new Set([...Object.keys(oldEntry || {}), ...Object.keys(newEntry || {})])) {
    if (key === "env") continue;
    if (!deepEqual(oldEntry[key], newEntry[key])) {
      lines.push(`${key}: ${show(key, oldEntry[key])} → ${show(key, newEntry[key])}`);
    }
  }
  const oe = (oldEntry && oldEntry.env) || {};
  const ne = (newEntry && newEntry.env) || {};
  for (const key of new Set([...Object.keys(oe), ...Object.keys(ne)])) {
    if (!deepEqual(oe[key], ne[key])) {
      lines.push(`env.${key}: ${oe[key] === undefined ? "(none)" : show(key, oe[key])} → ${ne[key] === undefined ? "(removed)" : show(key, ne[key])}`);
    }
  }
  return lines;
}

// Entry with every secret env value masked, for display.
function maskEntry(entry, secretKeys = ["ZOTERO_API_KEY", "OBSIDIAN_API_KEY"]) {
  if (!entry || !entry.env) return entry;
  const env = { ...entry.env };
  for (const k of secretKeys) if (typeof env[k] === "string") env[k] = maskSecret(env[k]);
  return { ...entry, env };
}

// Writes the config with the one entry set, after a timestamped backup.
// Returns the backup path (or null if there was no file before).
function writeClaudeEntry(configPath, config, name, entry) {
  let backupPath = null;
  if (fs.existsSync(configPath)) {
    backupPath = `${configPath}.bak-${Date.now()}`;
    fs.copyFileSync(configPath, backupPath);
  } else {
    fs.mkdirSync(path.dirname(configPath), { recursive: true });
  }
  const next = { ...config, mcpServers: { ...config.mcpServers, [name]: entry } };
  fs.writeFileSync(configPath, JSON.stringify(next, null, 2) + "\n", "utf8");
  return backupPath;
}

// Full compare → show → ask → write flow for one entry. Asks only when the
// entry would actually change. Returns the plan's status.
async function applyClaudeEntry({ configPath, name, entry, prompter, log = out }) {
  const config = readClaudeConfig(configPath);
  const plan = planEntry(config, name, entry);
  if (plan.status === "unchanged") {
    log.ok(`Claude Desktop entry "${name}" is up to date — nothing to change.`);
    return "unchanged";
  }
  if (plan.status === "new") {
    log.debug(`New entry "${name}":`);
    for (const line of JSON.stringify(maskEntry(entry), null, 2).split("\n")) log.debug(`  ${line}`);
  } else {
    log.debug(`Entry "${name}" would change:`);
    for (const line of plan.changes) log.debug(`  ${line}`);
  }
  if (!(await prompter.confirm(`${plan.status === "new" ? "Add" : "Update"} Claude Desktop entry "${name}"?`))) {
    log.warn(`Claude Desktop entry "${name}" left as it was.`);
    return "declined";
  }
  const backup = writeClaudeEntry(configPath, config, name, entry);
  if (backup) log.debug(`Backup: ${backup}`);
  log.ok(`${plan.status === "new" ? "Added" : "Updated"} "${name}" in ${configPath}`);
  return plan.status;
}

// ---------------------------------------------------------------------------
// Node command for Claude Desktop
// ---------------------------------------------------------------------------

// Windows: Claude Desktop's launch environment can't reliably resolve plain
// "node", so the entry points at a small wrapper that forwards to the exact
// Node binary running this installer. macOS: Claude Desktop doesn't inherit
// the shell PATH either, but an absolute path works directly — no wrapper.
function nodeWrapperContent(execPath) {
  return (
    "@echo off\r\n" +
    "rem Generated by the Zotero MCP / Obsidian MCP installers. Forwards to the\r\n" +
    "rem Node.js binary found when an installer last ran. Re-run it to refresh.\r\n" +
    `"${execPath}" %*\r\n` +
    "exit /b %errorlevel%\r\n"
  );
}

// Returns { command, status } where status tells what happened to the
// wrapper ("created" | "updated" | "unchanged" | "not-needed").
function ensureNodeCommand({ wrapperDir, platform = process.platform, execPath = process.execPath } = {}) {
  if (platform !== "win32") return { command: execPath, status: "not-needed" };
  const wrapperPath = path.join(wrapperDir, "node-wrapper.cmd");
  const status = writeIfChanged(wrapperPath, nodeWrapperContent(execPath));
  return { command: wrapperPath, status };
}

const WRAPPER_FILE = "node-wrapper.cmd";

// The Node binary an existing node-wrapper.cmd forwards to, or null.
function readWrapperTarget(file, readFile = fs.readFileSync) {
  let text;
  try {
    text = readFile(file, "utf8");
  } catch {
    return null;
  }
  const m = /^"([^"\r\n]+)" %\*\r?$/m.exec(text);
  return m ? m[1] : null;
}

// Places a node-wrapper.cmd may already be, most specific first, no duplicates:
// the folder remembered by this installer, folders other Claude Desktop
// entries already use (the wrapper is shared by the Zotero MCP and the
// Obsidian bridge), and the default %LOCALAPPDATA%\node-wrapper.
function wrapperCandidates({ rememberedDir = null, config = null, defaultDir = defaultTarget("node-wrapper", { platform: "win32" }) } = {}) {
  const dirs = [];
  const add = (d) => {
    if (d && !dirs.some((x) => x.toLowerCase() === d.toLowerCase())) dirs.push(d);
  };
  add(rememberedDir);
  const servers = (config && config.mcpServers) || {};
  for (const entry of Object.values(servers)) {
    const cmd = entry && typeof entry.command === "string" ? entry.command : "";
    if (path.win32.basename(cmd).toLowerCase() === WRAPPER_FILE) add(path.win32.dirname(cmd));
  }
  add(defaultDir);
  return dirs;
}

// Windows only (null elsewhere). Uses an existing wrapper without asking —
// wherever it is found among the candidates — and only asks for a folder when
// there is none yet, or when --change-locations was given.
async function chooseWrapperDir(prompter, { rememberedDir = null, config = null, changeLocations = false, platform = process.platform, exists = fs.existsSync, execPath = process.execPath, log = out, defaultDir } = {}) {
  if (platform !== "win32") return null;
  const candidates = wrapperCandidates({ rememberedDir, config, ...(defaultDir ? { defaultDir } : {}) });
  if (!changeLocations) {
    for (const dir of candidates) {
      const file = path.join(dir, WRAPPER_FILE);
      if (!exists(file)) continue;
      const target = readWrapperTarget(file);
      log.debug(
        target && target.toLowerCase() === execPath.toLowerCase()
          ? `Node wrapper: ${file} (already there, up to date)`
          : `Node wrapper: ${file} (already there; points to ${target || "an unknown Node"}, this Node is ${execPath})`
      );
      return dir;
    }
  }
  return prompter.askPath("Node wrapper folder", candidates[0]);
}

// Like ensureNodeCommand, but asks before changing an existing wrapper that
// points to another Node (it's shared, so the other MCP uses it too).
// Returns { command, status }: status "created" | "updated" | "unchanged" |
// "kept" (user declined the update) | "not-needed" (macOS/Linux).
async function ensureNodeWrapper(prompter, { wrapperDir, platform = process.platform, execPath = process.execPath, log = out } = {}) {
  if (platform !== "win32") return { command: execPath, status: "not-needed" };
  const file = path.join(wrapperDir, WRAPPER_FILE);
  if (fs.existsSync(file)) {
    const target = readWrapperTarget(file);
    if (fs.readFileSync(file, "utf8") === nodeWrapperContent(execPath)) return { command: file, status: "unchanged" };
    const q = `node-wrapper.cmd points to ${target || "an unknown Node"}. Point it to ${execPath}? (shared by all MCP entries using it)`;
    if (!(await prompter.confirm(q))) {
      log.warn("node-wrapper.cmd left as it was.");
      return { command: file, status: "kept" };
    }
  }
  return { command: file, status: writeIfChanged(file, nodeWrapperContent(execPath)) };
}

// ---------------------------------------------------------------------------
// Obsidian vaults (used by the plugin and the bridge installers)
// ---------------------------------------------------------------------------

// Where Obsidian keeps its list of known vaults.
function obsidianConfigPath({ platform = process.platform, env = process.env, home = os.homedir() } = {}) {
  if (platform === "win32") return path.join(env.APPDATA || path.join(home, "AppData", "Roaming"), "obsidian", "obsidian.json");
  if (platform === "darwin") return path.join(home, "Library", "Application Support", "obsidian", "obsidian.json");
  return path.join(env.XDG_CONFIG_HOME || path.join(home, ".config"), "obsidian", "obsidian.json");
}

// Vault folders from obsidian.json, most recently used first.
function parseVaultList(jsonText) {
  let data;
  try {
    data = JSON.parse(jsonText);
  } catch {
    return [];
  }
  const vaults = data && typeof data.vaults === "object" && data.vaults ? Object.values(data.vaults) : [];
  return vaults
    .filter((v) => v && typeof v.path === "string" && v.path)
    .sort((a, b) => (b.ts || 0) - (a.ts || 0))
    .map((v) => v.path);
}

// Picks the vault: a remembered one that still exists is used as is; with
// exactly one known vault that one is used; otherwise the known vaults are
// listed (Enter = most recently used) or a folder can be typed/dragged in.
// Throws if the result isn't an Obsidian vault (no .obsidian folder).
async function chooseVault(prompter, { remembered = null, vaults, log = out, exists = fs.existsSync } = {}) {
  const known = vaults || parseVaultList(readTextOrEmpty(obsidianConfigPath()));
  let vault;
  if (remembered && exists(remembered)) {
    vault = remembered;
    log.debug(`Vault: ${vault} (remembered)`);
  } else if (known.length === 1) {
    vault = known[0];
    log.debug(`Vault: ${vault} (the only vault Obsidian knows about)`);
  } else if (known.length > 1) {
    console.log("\n  Vaults Obsidian knows about:");
    known.forEach((v, i) => console.log(`    ${i + 1}) ${v}`));
    const answer = (await prompter.ask("Vault number, or a vault folder [1]: ")).trim();
    const n = answer === "" ? 1 : Number(answer);
    vault = Number.isInteger(n) && n >= 1 && n <= known.length ? known[n - 1] : path.resolve(stripQuotes(answer));
  } else {
    vault = path.resolve(stripQuotes(await prompter.ask("Vault folder (drag it in here): ")));
  }
  if (!exists(path.join(vault, ".obsidian"))) {
    throw new Error(`${vault} doesn't look like an Obsidian vault (no .obsidian folder).`);
  }
  return vault;
}

function readTextOrEmpty(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return "";
  }
}

// ---------------------------------------------------------------------------
// npm
// ---------------------------------------------------------------------------

// How to start npm without a shell. npm is itself a Node program
// (npm-cli.js) that ships next to the Node binary, so the installers run it
// with the very Node that runs them: no PATH lookup, no npm.cmd, no shell.
//   Windows:      <dir of node.exe>\node_modules\npm\bin\npm-cli.js
//   macOS/Linux:  <prefix>/lib/node_modules/npm/bin/npm-cli.js (node in <prefix>/bin)
// Only if that file isn't found: macOS/Linux start `npm` from PATH (no shell
// needed there); Windows has to go through the shell, because npm.cmd can't
// be started otherwise (CVE-2024-27980). Then the command is one fixed string
// and every argument is checked against a strict pattern first — passing an
// argument list together with shell: true is what Node warns about (DEP0190),
// since those arguments would be concatenated unescaped.
const SAFE_NPM_ARG = /^[A-Za-z0-9:=._@/-]+$/;

function npmInvocation(args, { platform = process.platform, execPath = process.execPath, exists = fs.existsSync } = {}) {
  const p = platform === "win32" ? path.win32 : path.posix;
  const cliCandidates =
    platform === "win32"
      ? [p.join(p.dirname(execPath), "node_modules", "npm", "bin", "npm-cli.js")]
      : [p.join(p.dirname(execPath), "..", "lib", "node_modules", "npm", "bin", "npm-cli.js")];
  const cli = cliCandidates.find((c) => exists(c));
  if (cli) return { command: execPath, args: [cli, ...args], shell: false };
  if (platform !== "win32") return { command: "npm", args, shell: false };
  for (const a of args) {
    if (!SAFE_NPM_ARG.test(a)) throw new Error(`Refusing to pass "${a}" to npm through the shell.`);
  }
  return { command: ["npm", ...args].join(" "), args: null, shell: true };
}

// Runs npm and returns its exit status. Quiet by default: npm's own output
// (test lists, summaries, progress) is captured and only shown when the
// command fails, so the installer shows just its own one-line results.
function runNpm(args, cwd, { verbose = false, log = out, ...opts } = {}) {
  const inv = npmInvocation(args, opts);
  const spawnOpts = {
    cwd,
    shell: inv.shell,
    stdio: verbose ? "inherit" : ["ignore", "pipe", "pipe"],
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, NO_COLOR: "1", FORCE_COLOR: "0" },
  };
  const r = inv.args === null ? spawnSync(inv.command, spawnOpts) : spawnSync(inv.command, inv.args, spawnOpts);
  if (r.error) throw new Error(`Couldn't run npm (${r.error.message}).`);
  if (r.status !== 0 && !verbose) {
    const output = `${r.stdout || ""}${r.stderr || ""}`.trim();
    if (output) {
      log.warn(`Output of "npm ${args.join(" ")}":`);
      console.log(output);
    }
  }
  return r.status;
}

module.exports = {
  out,
  maskSecret,
  createPrompter,
  stripQuotes,
  isYes,
  appDataRoot,
  defaultTarget,
  candidateConfigPaths,
  resolveConfigPath,
  deepEqual,
  writeIfChanged,
  copyIfChanged,
  syncFiles,
  filesDiffer,
  readClaudeConfig,
  planEntry,
  describeChanges,
  maskEntry,
  writeClaudeEntry,
  applyClaudeEntry,
  nodeWrapperContent,
  ensureNodeCommand,
  readWrapperTarget,
  wrapperCandidates,
  chooseWrapperDir,
  ensureNodeWrapper,
  obsidianConfigPath,
  parseVaultList,
  chooseVault,
  npmInvocation,
  runNpm,
};
