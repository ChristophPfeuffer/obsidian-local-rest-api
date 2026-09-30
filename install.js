#!/usr/bin/env node
// Installer for the Obsidian "Local REST API with MCP" plugin (this fork).
// Start it with installWIN.cmd (Windows) or installMAC.command (macOS); they
// make sure Node.js 22+ is there first.
//
// It only installs the plugin into a vault. Connecting Claude Desktop to the
// plugin is the job of the separate MCP-Bridge-Obsidian repository and its own
// installer — run that one afterwards.
//
//   1. Checks in this repo: dependencies, lint, unit tests, installer tests,
//      build. Stops on the first failure — nothing is installed from a repo
//      that fails its own checks.
//   2. Plugin -> <vault>/.obsidian/plugins/obsidian-local-rest-api/
//      (main.js, manifest.json, styles.css). Compared first: unchanged files
//      are left alone and you're only asked when something would change.
//      data.json (your API key, certificates and settings) is never touched;
//      the old main.js is kept as main.js.bak when it changes.
//
// The vault: with exactly one vault known to Obsidian it's used directly,
// otherwise you pick from Obsidian's own list (Enter = most recently used).
//
// CommonJS like the rest of the repo; shared helpers are in
// installer/install-lib.cjs (identical in MCP-Zotero and MCP-Bridge-Obsidian).

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const lib = require("./installer/install-lib.cjs");

const { out } = lib;
const HERE = __dirname;
const PLUGIN_ID = "obsidian-local-rest-api";
const PLUGIN_FILES = ["main.js", "manifest.json", "styles.css"];
const MIN_NODE_MAJOR = 22; // package.json "engines"

// npm ci is needed when dependencies are missing or were installed on another
// system: esbuild ships one native binary per platform (@esbuild/<os>-<cpu>),
// so a node_modules synced from Windows can't build on a Mac and vice versa.
function needsDependencyInstall(repoDir, { platform = process.platform, arch = process.arch, exists = fs.existsSync } = {}) {
  if (!exists(path.join(repoDir, "node_modules"))) return "node_modules is missing";
  if (!exists(path.join(repoDir, "node_modules", "@esbuild", `${platform}-${arch}`))) {
    return `node_modules has no esbuild binary for ${platform}-${arch} (installed on another system?)`;
  }
  return null;
}

function runChecks() {
  out.section("1/2 — Checking this repository");
  const [major] = process.versions.node.split(".").map(Number);
  if (major < MIN_NODE_MAJOR) out.fail(`Need Node.js ${MIN_NODE_MAJOR}+ (package.json "engines"). You have ${process.version}.`);
  out.ok(`Node.js ${process.version}`);

  const why = needsDependencyInstall(HERE);
  if (why) {
    out.debug(`Installing dependencies: ${why}`);
    if (lib.runNpm(["ci", "--no-fund", "--no-audit"], HERE) !== 0) out.fail("npm ci failed — see output above.");
    out.ok("Dependencies installed (npm ci, exact versions from package-lock.json).");
  } else {
    out.debug("Dependencies present for this system.");
  }

  for (const [label, args] of [
    ["Lint", ["run", "lint"]],
    ["Unit tests", ["test"]],
    ["Installer tests", ["run", "test:installer"]],
    ["Build", ["run", "build"]],
  ]) {
    out.debug(`${label} …`);
    if (lib.runNpm(args, HERE) !== 0) out.fail(`${label} failed — fix first, then re-run. Nothing was installed.`);
    out.ok(`${label} passed.`);
  }
  for (const f of PLUGIN_FILES) {
    if (!fs.existsSync(path.join(HERE, f))) out.fail(`${f} missing after the build.`);
  }
}

async function installPlugin(prompter, vault) {
  out.section("2/2 — Plugin in the vault");
  const pluginDir = path.join(vault, ".obsidian", "plugins", PLUGIN_ID);
  const changed = lib.filesDiffer(HERE, pluginDir, PLUGIN_FILES);
  if (changed.length === 0) {
    out.ok(`Plugin files in ${pluginDir} are up to date.`);
    return;
  }
  out.debug(`Would change: ${changed.join(", ")}`);
  if (!(await prompter.confirm(`Update the plugin in ${pluginDir}?`))) {
    out.warn("Plugin left as it was.");
    return;
  }
  const oldMain = path.join(pluginDir, "main.js");
  if (changed.includes("main.js") && fs.existsSync(oldMain)) fs.copyFileSync(oldMain, `${oldMain}.bak`);
  const r = lib.syncFiles(HERE, pluginDir, PLUGIN_FILES);
  out.ok(`Plugin updated (${[...r.created, ...r.updated].join(", ")}). data.json untouched.`);
  out.warn("In Obsidian: Settings → Community plugins → turn the plugin off and on again (or restart Obsidian).");
  if (!fs.existsSync(path.join(pluginDir, "data.json"))) {
    out.warn("First install: enable the plugin once in Obsidian, then run the MCP-Bridge-Obsidian installer.");
  }
}

async function main() {
  runChecks();
  const prompter = lib.createPrompter();
  try {
    const vault = await lib.chooseVault(prompter);
    await installPlugin(prompter, vault);
  } finally {
    prompter.close();
  }
}

if (require.main === module) {
  main().catch((e) => out.fail(e.stack || e.message));
}

module.exports = { needsDependencyInstall };
