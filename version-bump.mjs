import { readFileSync, writeFileSync } from "fs";

// This is Uwe's personal fork, never published under this repo in Obsidian's
// community-plugins.json catalog (that entry still points at
// coddingtonbear/obsidian-local-rest-api). So `npm version <bump>` writing a
// real semver here serves no purpose and is actively dangerous: it would
// silently undo the update-lock version in manifest.json, which is what
// keeps Obsidian's own updater from ever seeing this install as outdated.
// Flip AUTO_UPDATE_ENABLED to true only if that stops being true (e.g. this
// fork gets published under its own id/repo and real version numbers start
// mattering again).
const AUTO_UPDATE_ENABLED = false;
const UPDATE_LOCK_VERSION = "9999.0.0";

const targetVersion = AUTO_UPDATE_ENABLED
  ? process.env.npm_package_version
  : UPDATE_LOCK_VERSION;

// read minAppVersion from manifest.json and bump version to target version
let manifest = JSON.parse(readFileSync("manifest.json", "utf8"));
const { minAppVersion } = manifest;
manifest.version = targetVersion;
writeFileSync("manifest.json", JSON.stringify(manifest, null, "\t"));

// update versions.json with target version and minAppVersion from manifest.json
let versions = JSON.parse(readFileSync("versions.json", "utf8"));
versions[targetVersion] = minAppVersion;
writeFileSync("versions.json", JSON.stringify(versions, null, "\t"));
