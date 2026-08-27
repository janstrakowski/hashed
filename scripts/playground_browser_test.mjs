// Drives docs/playground.html - the web terminal - in a real headless browser.
// The shim test (playground_test.mjs) covers the WASI host; this covers the
// terminal around it: the shell, the REPL mode, and above all persistence,
// which cannot be tested without a browser's IndexedDB.
//
// Usage: node scripts/playground_browser_test.mjs [chrome-path]
// Needs puppeteer-core installed and a Chrome/Chromium binary.

import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import puppeteer from "puppeteer-core";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const CHROME = process.argv[2] ?? process.env.CHROME_PATH ?? "/usr/bin/chromium";
const PORT = 8899;

let failures = 0;
const check = (name, actual, expected) => {
  const ok = typeof expected === "function" ? expected(actual) : actual === expected;
  if (!ok) {
    failures++;
    console.log(`FAIL ${name}\n  got: ${JSON.stringify(actual)}`);
  } else {
    console.log(`ok   ${name}`);
  }
};

const server = spawn("python3", ["-m", "http.server", String(PORT)], {
  cwd: join(repo, "docs"), stdio: "ignore",
});
await new Promise((r) => setTimeout(r, 1200));

const browser = await puppeteer.launch({
  executablePath: CHROME,
  args: ["--no-sandbox", "--disable-gpu"],
  headless: true,
});

try {
  const page = await browser.newPage();
  // CI runners are slower than a dev machine, and that difference already hid
  // a real bug once (typing merged into a running command). Throttling makes
  // the fast path stop flattering us.
  if (process.env.THROTTLE) await page.emulateCPUThrottling(Number(process.env.THROTTLE));
  const problems = [];
  page.on("pageerror", (e) => problems.push("pageerror: " + e.message));
  page.on("console", (m) => { if (m.type() === "error") problems.push("console: " + m.text()); });

  const url = `http://localhost:${PORT}/playground.html`;
  const screenText = () => page.$eval("#screen", (el) => el.textContent);

  // Types a line and waits for the command to actually finish. The screen
  // growing is not that signal - it grows the moment the command is echoed,
  // before it runs. The prompt being enabled again is.
  const type = async (line) => {
    await page.waitForFunction(() => !document.getElementById("entry").disabled, { timeout: 20000 });
    await page.type("#entry", line);
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => !document.getElementById("entry").disabled, { timeout: 20000 });
  };

  // The last boot line differs between a fresh visit and a restored one, so
  // wait for either rather than for one of them.
  const booted = async () => {
    await page.waitForFunction(() => {
      const text = document.getElementById("screen").textContent;
      return text.includes("Type `help`") || text.includes("Restored your files");
    }, { timeout: 20000 });
  };

  await page.goto(url, { waitUntil: "networkidle0" });
  await booted();
  check("terminal boots", await screenText(), (t) => t.includes("compiled to WebAssembly"));
  check("page is cross-origin isolated", await page.evaluate(() => self.crossOriginIsolated), true);

  // The filesystem is the repository, 1:1 - not a curated sample of it.
  await type("ls");
  check("the repo is there", await screenText(),
    (t) => t.includes("/SPEC.md") && t.includes("/src/eval.odin") && t.includes("/examples/guard-chain.hb"));
  check("ctx.cache has a home", await screenText(), (t) => t.includes("/cache/hashedbuild"));

  await type("cat examples/choice.txt");
  check("cat prints a file", await screenText(), (t) => t.includes("option A"));

  // Running a program: the real CLI path, argv and all.
  await type("hb examples/guard-chain.hb");
  check("a repo example runs", await screenText(), (t) => t.trimEnd().endsWith("5"));

  await type("hb -e '6 * 7'");
  check("-e evaluates an expression", await screenText(), (t) => t.trimEnd().endsWith("42"));

  // The REPL, for real: bare `hb` runs the interpreter's own loop, reading
  // stdin. The banner and the prompts below come out of the module - if this
  // passes, blocking stdin works.
  await type("hb");
  check("the interpreter's REPL starts", await screenText(), (t) => t.includes("HashedBuild REPL"));
  await type("1 + 1");
  check("its continuation prompt is the module's", await screenText(), (t) => t.includes("... "));
  await type("");
  check("a blank line evaluates the buffer", await screenText(), (t) => t.includes("hb> 1 + 1\n... \n2\n"));
  await type("filetext (loadfile \"/README.md\") |> (#arg == #arg)");
  await type("");
  check("the REPL can read the repo", await screenText(), (t) => t.includes("... \ntrue\n"));
  await type(":q");
  check("':q' ends the REPL", await screenText(), (t) => t.includes(":q"));

  // ctx.cache, which is why /cache exists.
  await type("hb -e 'createfile { .dir = ctx.cache, .content = \"cached\" }'");
  check("ctx.cache writes into /cache", await screenText(),
    (t) => t.includes("<file: /cache/hashedbuild/sha256_"));

  // Writing a file, and the point of the whole thing: it is still there after
  // a reload, with no server and no database anywhere.
  await type("hb -e 'createfile { .path = \"/greeting.txt\", .content = \"written from the browser\" }'");
  check("createfile reports what it wrote", await screenText(), (t) => t.includes("<file: /greeting.txt>"));

  await page.reload({ waitUntil: "networkidle0" });
  await booted();
  check("state is restored", await screenText(), (t) => t.includes("Restored your files"));
  await type("cat greeting.txt");
  check("the written file survived the reload", await screenText(),
    (t) => t.includes("written from the browser"));
  await type("ls /cache");
  check("the cache entry survived too", await screenText(), (t) => t.includes("sha256_"));

  // And the language's own rules still hold in there: createfile is exclusive.
  await type("hb -e 'createfile { .path = \"/greeting.txt\", .content = \"again\" }'");
  check("a second write fails, exclusively", await screenText(), (t) => t.includes("Exists"));

  // History, because a terminal without it is a nuisance.
  await page.keyboard.press("ArrowUp");
  check("up-arrow recalls the last command",
    await page.$eval("#entry", (el) => el.value), (v) => v.includes("createfile"));

  check("no page errors", problems.join(" | "), "");
} finally {
  await browser.close();
  server.kill();
}

console.log(failures === 0 ? "\nall terminal checks passed" : `\n${failures} terminal checks failed`);
process.exit(failures === 0 ? 0 : 1);
