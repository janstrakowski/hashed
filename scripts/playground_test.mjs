// Tests the WASI shim the playground runs on (docs/wasi.js), headlessly.
//
// The shim is the one part of the browser story that can be wrong in ways the
// Odin suite can't see: it is a hand-written host, and a mistake in it looks
// like a broken interpreter. Node runs it unchanged, so the same code the page
// loads is what gets tested here.
//
// Usage: node scripts/playground_test.mjs [path/to/hb.wasm]

import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { FileSystem, run } from "../docs/wasi.js";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const wasmPath = process.argv[2] ?? join(repo, "docs", "hb.wasm");
const wasm = readFileSync(wasmPath);
const enc = new TextEncoder();

let failures = 0;
function check(name, actual, expected) {
  const ok = actual === expected;
  if (!ok) {
    failures++;
    console.log(`FAIL ${name}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(actual)}`);
  } else {
    console.log(`ok   ${name}`);
  }
}

function seeded() {
  const fs = new FileSystem();
  fs.writeFile("/examples/optiona.txt", enc.encode("This is the payload for option A.\n"));
  fs.writeFile("/examples/choice.txt", enc.encode("option A"));
  fs.symlink("/examples/link-to-optiona", "optiona.txt");
  return fs;
}

async function evaluate(source, fs = seeded()) {
  const out = [];
  const err = [];
  fs.writeFile("/main.hb", enc.encode(source));
  const code = await run({
    wasmBytes: wasm, fs, args: ["hb", "/main.hb"],
    onStdout: (s) => out.push(s), onStderr: (s) => err.push(s),
  });
  return { code, out: out.join("").trim(), err: err.join("").trim(), fs };
}

// --- the language runs at all -----------------------------------------------

check("arithmetic", (await evaluate("1 + 2 * 3")).out, "7");
check("tables", (await evaluate('{ .a = 1 } concat { .b = 2 }')).out, "{a: 1, b: 2}");
check("patterns", (await evaluate('(:.ok 42) is :.ok as v then v else 0')).out, "42");

// --- the filesystem is the shim's, and behaves like the real one -------------

check("loadfile + filetext",
  (await evaluate('filetext (loadfile "/examples/optiona.txt")')).out,
  '"This is the payload for option A.\\n"');

check("File displays its path",
  (await evaluate('loadfile "/examples/optiona.txt"')).out,
  "<file: /examples/optiona.txt>");

check("directory handle",
  (await evaluate('filetext (loadfile { .dir = loadfile "/examples", .path = "optiona.txt" })')).out,
  '"This is the payload for option A.\\n"');

check("readlink returns the stored target",
  (await evaluate('readlink { .dir = loadfile "/examples", .path = "link-to-optiona" }')).out,
  '"optiona.txt"');

{
  // Containment: a sub-path may not climb out of its directory handle (§16).
  const escaped = await evaluate('loadfile { .dir = loadfile "/examples", .path = "../main.hb" }');
  check("containment refuses ..", escaped.code, 1);
  check("containment says why", escaped.err.includes("escapes its directory"), true);
}

// --- writes land in the filesystem the page persists ------------------------

{
  const r = await evaluate('createfile { .path = "/out.txt", .content = "written" }');
  check("createfile succeeds", r.code, 0);
  const written = r.fs.snapshot()["out.txt"];
  check("createfile is visible in the snapshot", written?.type, "file");
  check("createfile wrote the bytes", new TextDecoder().decode(Uint8Array.from(written?.data ?? [])), "written");
}

{
  // A snapshot round-trip is exactly what the page stores and restores.
  const first = await evaluate('createfile { .path = "/kept.txt", .content = "still here" }');
  const restored = FileSystem.fromSnapshot(first.fs.snapshot());
  const second = await evaluate('filetext (loadfile "/kept.txt")', restored);
  check("a restored snapshot still has the file", second.out, '"still here"');
}

// --- failures behave like failures ------------------------------------------

{
  const r = await evaluate('error "boom"');
  check("error exits non-zero", r.code, 1);
  check("error prints its message", r.err.includes("boom"), true);
}

{
  const r = await evaluate('async (1 + 1)');
  check("async refuses when the host cannot spawn", r.code, 1);
  check("async says why", r.err.includes("could not start a thread"), true);
}

// --- the CLI surface the page drives ----------------------------------------

{
  const fs = seeded();
  const out = [];
  const code = await run({
    wasmBytes: wasm, fs, args: ["hb", "-e", "6 * 7"],
    onStdout: (s) => out.push(s), onStderr: () => {},
  });
  check("-e evaluates one expression", out.join("").trim(), "42");
  check("-e exits cleanly", code, 0);
}

// --- the committed wasm still is the current interpreter ---------------------
//
// docs/hb.wasm is committed so Pages can serve it, which makes it exactly the
// kind of artifact that goes stale. Bytes can't be compared - Odin's wasm
// output isn't reproducible run to run (the type section reorders) - so
// behaviour is: every example, through this shim, against the native build.
// A language change with a forgotten rebuild shows up here as a mismatch.

const nativeHb = join(repo, "hb");
if (existsSync(nativeHb)) {
  // Displayed paths differ by construction (checkout vs preopen), and async
  // works natively while the portable wasm refuses it - both covered above.
  const skip = new Set(["files-sandboxed.hb", "option-picker.hb",
                        "async-basics.hb", "async-branching.hb", "async-table.hb"]);

  const examplesDir = join(repo, "examples");
  const seedExamples = () => {
    const fs = new FileSystem();
    for (const name of readdirSync(examplesDir)) {
      const full = join(examplesDir, name);
      try {
        fs.writeFile("/examples/" + name, new Uint8Array(readFileSync(full)));
      } catch { /* a directory or a symlink git materialised oddly */ }
    }
    fs.symlink("/examples/link-to-optiona", "optiona.txt");
    return fs;
  };

  let compared = 0;
  for (const name of readdirSync(examplesDir).filter((n) => n.endsWith(".hb")).sort()) {
    if (skip.has(name)) continue;
    const native = execFileSync(nativeHb, [join(examplesDir, name)], { encoding: "utf8" }).trim();
    const out = [];
    await run({
      wasmBytes: wasm, fs: seedExamples(), args: ["hb", "/examples/" + name],
      onStdout: (s) => out.push(s), onStderr: (s) => out.push(s),
    });
    compared++;
    check(`example ${name} matches native`, out.join("").trim(), native);
  }
  check("compared a real number of examples", compared >= 15, true);
} else {
  console.log("skip  example comparison (no ./hb built)");
}

console.log(failures === 0 ? "\nall shim checks passed" : `\n${failures} shim checks failed`);
process.exit(failures === 0 ? 0 : 1);
