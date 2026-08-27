// Generates docs/repo-files.json: the repository as the playground's starting
// filesystem, so the terminal opens on what you would have after cloning.
//
// Everything git tracks goes in, minus what would only bloat the download
// without being anything to read: docs/media (1.4MB of video), docs/hb.wasm
// (the interpreter, fetched separately), and docs/vendor (xterm.js, which the
// page loads when the editor opens). Source, docs, examples and scripts - the
// things someone would actually `cat` - all stay.
//
// Usage: node scripts/build_playground_files.mjs [--check]
//   --check verifies the committed manifest is current instead of writing it.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, lstatSync, readlinkSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUT = join(repo, "docs", "repo-files.json");
const SKIP = [/^docs\/media\//, /^docs\/vendor\//, /^docs\/hb\.wasm$/, /^docs\/repo-files\.json$/];

// --cached --others --exclude-standard: everything a clone of this commit
// will contain, whether or not it has been `git add`ed yet. Plain `ls-files`
// looks only at the index, so generating before staging a new file silently
// left it out - and CI, checking out the committed tree, saw a stale
// manifest. Ignored files stay out either way.
const tracked = execFileSync("git", ["ls-files", "--cached", "--others", "--exclude-standard"],
                             { cwd: repo, encoding: "utf8" })
  .split("\n").filter(Boolean).filter((p) => !SKIP.some((re) => re.test(p))).sort();

const files = {};
for (const path of tracked) {
  const full = join(repo, path);
  const stat = lstatSync(full);
  if (stat.isSymbolicLink()) {
    files[path] = { type: "symlink", target: readlinkSync(full) };
    continue;
  }
  const bytes = readFileSync(full);
  // Anything that isn't valid UTF-8 would have to be base64'd, and nothing
  // tracked here needs it once the media is excluded - so say so loudly rather
  // than silently shipping mojibake.
  const text = bytes.toString("utf8");
  if (Buffer.compare(Buffer.from(text, "utf8"), bytes) !== 0) {
    console.error(`${path} is not valid UTF-8 - add it to SKIP or teach this script base64`);
    process.exit(1);
  }
  files[path] = { type: "file", text };
}

const manifest = JSON.stringify({ files }, null, 1) + "\n";

if (process.argv.includes("--check")) {
  const current = readFileSync(OUT, "utf8");
  if (current !== manifest) {
    console.error("docs/repo-files.json is stale - regenerate it with node scripts/build_playground_files.mjs");
    process.exit(1);
  }
  console.log(`docs/repo-files.json is current (${Object.keys(files).length} files)`);
} else {
  writeFileSync(OUT, manifest);
  console.log(`wrote ${Object.keys(files).length} files, ${(manifest.length / 1024).toFixed(0)}KB`);
}
