// Re-points Claude Desktop from replaced Node.js binaries to the current one.
//
// Run by installMAC.command / installWIN.cmd before they delete or leave a
// Node.js (an older copy in the shared Node folder, or when moving to another
// installed Node.js):
//   node installer/relink-node.cjs [--to=<new node>] <old node path> [...]
//
// What runs Node for Claude Desktop:
//   macOS    entries with the node binary's absolute path as "command"
//   Windows  entries whose "command" is node-wrapper.cmd, a small file that
//            forwards to node.exe (see nodeWrapperContent in install-lib.cjs);
//            also the default %LOCALAPPDATA%\node-wrapper\node-wrapper.cmd
// Each of these that points to one of the old binaries — or to a node binary
// that no longer exists — is switched to --to (default: process.execPath).
// No questions (the installers' own Node.js); compared first, the config is
// backed up before it is written.
// Exit code: 0 done or nothing to do, 1 error (then nothing may be deleted).
//
// Kept IDENTICAL in MCP-Zotero and obsidian-local-rest-api (under installer/).

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const lib = require("./install-lib.cjs");

const WRAPPER_FILE = "node-wrapper.cmd";

// Windows paths compare case-insensitively; win32 path functions understand
// both / and \, so they work for macOS and Windows paths alike.
const same = (a, b) => typeof a === "string" && typeof b === "string" && path.win32.normalize(a).toLowerCase() === path.win32.normalize(b).toLowerCase();
const isNodeBinary = (p) => typeof p === "string" && path.win32.isAbsolute(p) && ["node", "node.exe"].includes(path.win32.basename(p).toLowerCase());

// True if `target` (a node binary path) should be replaced.
function isOld(target, oldPaths, newPath, exists) {
  if (!isNodeBinary(target) || same(target, newPath)) return false;
  return [].concat(oldPaths || []).some((o) => same(o, target)) || !exists(target);
}

// Names of the entries whose command is an old node binary.
function entriesToRelink(config, oldPaths, newPath, exists = fs.existsSync) {
  const servers = (config && config.mcpServers) || {};
  return Object.keys(servers).filter((name) => isOld(servers[name] && servers[name].command, oldPaths, newPath, exists));
}

function relinked(config, names, newPath) {
  const mcpServers = { ...config.mcpServers };
  for (const name of names) mcpServers[name] = { ...mcpServers[name], command: newPath };
  return { ...config, mcpServers };
}

// node-wrapper.cmd files (from the entries, plus the default one) that
// forward to an old node binary.
function wrappersToRelink(config, oldPaths, newPath, { defaultWrapper = null, exists = fs.existsSync, readTarget = lib.readWrapperTarget } = {}) {
  const files = [];
  const add = (f) => {
    if (f && !files.some((x) => same(x, f)) && exists(f)) files.push(f);
  };
  for (const entry of Object.values((config && config.mcpServers) || {})) {
    const cmd = entry && entry.command;
    if (typeof cmd === "string" && path.win32.basename(cmd).toLowerCase() === WRAPPER_FILE) add(cmd);
  }
  add(defaultWrapper);
  return files.filter((f) => isOld(readTarget(f), oldPaths, newPath, exists));
}

// --to=<path> sets the new command (default: this node binary); the rest are old paths.
function parseArgs(argv) {
  let newPath = process.execPath;
  const oldPaths = [];
  for (const a of argv) {
    if (a.startsWith("--to=")) newPath = a.slice(5);
    else oldPaths.push(a);
  }
  return { newPath, oldPaths };
}

function main() {
  const { newPath, oldPaths } = parseArgs(process.argv.slice(2));
  const configPath = lib.resolveConfigPath(lib.candidateConfigPaths()).path;
  const config = fs.existsSync(configPath) ? lib.readClaudeConfig(configPath) : { mcpServers: {} };

  if (process.platform === "win32") {
    const defaultWrapper = path.join(lib.defaultTarget("node-wrapper"), WRAPPER_FILE);
    for (const file of wrappersToRelink(config, oldPaths, newPath, { defaultWrapper })) {
      lib.writeIfChanged(file, lib.nodeWrapperContent(newPath));
      lib.out.ok(`${file} now forwards to ${newPath}`);
    }
  }

  const names = entriesToRelink(config, oldPaths, newPath);
  if (names.length === 0) return;
  const backup = `${configPath}.bak-${Date.now()}`;
  fs.copyFileSync(configPath, backup);
  fs.writeFileSync(configPath, JSON.stringify(relinked(config, names, newPath), null, 2) + "\n", "utf8");
  lib.out.ok(`Claude Desktop: ${names.join(", ")} now use${names.length === 1 ? "s" : ""} ${newPath}`);
  lib.out.debug(`Backup: ${backup} — restart Claude Desktop to apply.`);
}

if (require.main === module) {
  try {
    main();
  } catch (e) {
    lib.out.warn(`Could not update Claude Desktop: ${e.message}`);
    process.exitCode = 1;
  }
}

module.exports = { entriesToRelink, relinked, wrappersToRelink, parseArgs };
