// Drives docs/playground.html - the web terminal - in a real headless browser.
// The shim test (playground_test.mjs) covers the WASI host; this covers the
// terminal around it: the shell, the REPL mode, and above all persistence,
// which cannot be tested without a browser's IndexedDB.
//
// Usage: node scripts/playground_browser_test.mjs [chrome-path]
// Needs puppeteer-core installed and a Chrome/Chromium binary.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join, extname } from "node:path";
import puppeteer from "puppeteer-core";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const CHROME = process.argv[2] ?? process.env.CHROME_PATH ?? "/usr/bin/chromium";
// Generous on purpose: a boot fetches a ~500KB interpreter and a ~550KB
// manifest, instantiates the module, and may reload once for cross-origin
// isolation - on a throttled CI runner that adds up well past a default wait.
const WAIT = Number(process.env.WAIT_MS ?? 60000);
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

// Two servers, because the page can get cross-origin isolation two ways and
// both are worth knowing about:
//
//   isolated  sends COOP/COEP itself, the way a host that can set headers
//             would. Deterministic, and what the bulk of the test runs on.
//   plain     sends nothing, so isolation has to come from
//             coi-serviceworker - which is the GitHub Pages situation, and is
//             checked on its own below rather than underneath every assertion.
const TYPES = {
  ".html": "text/html", ".js": "text/javascript", ".css": "text/css",
  ".json": "application/json", ".wasm": "application/wasm",
};

function serve(port, isolated) {
  const server = createServer(async (req, res) => {
    const path = join(repo, "docs", decodeURIComponent(req.url.split("?")[0]));
    try {
      const body = await readFile(path);
      const headers = { "Content-Type": TYPES[extname(path)] ?? "application/octet-stream" };
      if (isolated) {
        headers["Cross-Origin-Opener-Policy"] = "same-origin";
        headers["Cross-Origin-Embedder-Policy"] = "require-corp";
        headers["Cross-Origin-Resource-Policy"] = "cross-origin";
      }
      res.writeHead(200, headers).end(body);
    } catch {
      res.writeHead(404).end("not found");
    }
  });
  server.listen(port);
  return server;
}

const server = serve(PORT, true);
const plainServer = serve(PORT + 1, false);

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
    await page.waitForFunction(() => !document.getElementById("entry").disabled, { timeout: WAIT });
    // Start from an empty line: an earlier history recall can leave text in
    // the field, and typing onto the end of it makes a different command.
    await page.$eval("#entry", (el) => { el.value = ""; });
    await page.type("#entry", line);
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => !document.getElementById("entry").disabled, { timeout: WAIT });
  };

  // The last boot line differs between a fresh visit and a restored one, so
  // wait for either rather than for one of them.
  const booted = async () => {
    await page.waitForFunction(() => {
      const text = document.getElementById("screen").textContent;
      return text.includes("Type `help`") || text.includes("Restored your files");
    }, { timeout: WAIT });
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

  // async, on real threads. The page hands each spawned thread its own
  // instance of the module against the same shared memory (wasi-threads), so
  // these are genuinely concurrent - and each one reads a file through the
  // same filesystem, which is what the RPC layer exists for.
  await type("hb examples/async-basics.hb");
  check("async runs on real threads", await screenText(),
    (t) => t.includes('"This is the payload for option A.\\nThis is the payload for option B.\\n"'));
  await type("hb examples/async-table.hb");
  check("concurrent table entries all resolve", await screenText(),
    (t) => t.includes('{a: 2, b: 6, c: "This is the payload for option A.\\n"}'));

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

  // --- the live editor, in a real terminal emulator -------------------------
  //
  // `hb -i` is a full-screen TUI: raw keystrokes in, ANSI out, xterm.js
  // rendering it. Nothing else on this page needs an emulator, and until this
  // landed the WASI build refused -i outright.
  const tuiRows = async () => page.evaluate(() => {
    const rows = document.querySelector("#tui .xterm-rows");
    return rows ? [...rows.children].map((r) => r.textContent.replace(/\s+$/, "")).join("\n") : "";
  });
  const settle = (ms = 1500) => new Promise((r) => setTimeout(r, ms));

  await page.waitForFunction(() => !document.getElementById("entry").disabled, { timeout: WAIT });
  await page.$eval("#entry", (el) => { el.value = ""; });
  await page.type("#entry", "hb -i");
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => document.body.classList.contains("tui"), { timeout: WAIT });
  await settle(3500);
  check("the editor draws itself", await tuiRows(), (t) => t.includes("HashedBuild live parser"));
  check("its panes are there", await tuiRows(), (t) => t.includes("source") && t.includes("ast") && t.includes("result"));

  // Typing goes straight to the program, which re-parses on every keystroke.
  for (const ch of "5 |> (*2 + 1)") await page.keyboard.press(ch === " " ? "Space" : ch);
  await settle(2000);
  check("keystrokes reach the editor", await tuiRows(), (t) => t.includes("5 |> (*2 + 1)"));
  check("it parses and evaluates live", await tuiRows(), (t) => t.includes("Op_Pipe") && t.includes("11"));

  // Ctrl+E opens the examples picker, which lists a real directory - the one
  // piece of this that needed fd_readdir.
  await page.keyboard.down("Control"); await page.keyboard.press("KeyE"); await page.keyboard.up("Control");
  await settle();
  check("the examples picker lists the repo", await tuiRows(),
    (t) => t.includes("select an example") && t.includes("guard-chain.hb"));
  await page.keyboard.type("guard");
  await settle(800);
  await page.keyboard.press("Enter");
  await settle(2500);
  check("an example loads and evaluates", await tuiRows(),
    (t) => t.includes("guard-chain") || t.includes("canonical guard"));

  // The debugger panel needs a thread of its own, which this build now has.
  await page.keyboard.down("Alt"); await page.keyboard.press("Digit5"); await page.keyboard.up("Alt");
  await settle(2500);
  check("the debugger panel is live", await tuiRows(),
    (t) => t.includes("debug") && !t.includes("no thread support"));

  // Ctrl+Q leaves the editor and hands the shell back.
  await page.keyboard.down("Control"); await page.keyboard.press("KeyQ"); await page.keyboard.up("Control");
  await page.waitForFunction(() => !document.body.classList.contains("tui"), { timeout: WAIT });
  check("quitting returns to the shell", await screenText(), (t) => t.includes("left the editor"));

  // --- a filesystem from an older visit ---------------------------------------
  //
  // The reported symptom was an examples picker listing nothing: a snapshot
  // stored before the repository became the filesystem, restored forever after
  // because nothing ever re-seeded it. Here that state is planted deliberately.
  await page.evaluate(async () => {
    const db = await new Promise((resolve, reject) => {
      const req = indexedDB.open("hashedbuild-playground", 1);
      req.onupgradeneeded = () => req.result.createObjectStore("state");
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
    const current = await new Promise((resolve) => {
      const req = db.transaction("state", "readonly").objectStore("state").get("state");
      req.onsuccess = () => resolve(req.result);
    });
    // An old seed: no examples at all, one file of the visitor's own, and a
    // version that no longer matches the manifest.
    const stale = {
      ...current,
      seedVersion: "from-an-older-visit",
      files: {
        "tour.hb": { type: "file", data: [...new TextEncoder().encode("1 + 1\n")] },
        "mine.hb": { type: "file", data: [...new TextEncoder().encode("42\n")] },
      },
    };
    await new Promise((resolve, reject) => {
      const tx = db.transaction("state", "readwrite");
      tx.objectStore("state").put(stale, "state");
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
    });
  });

  await page.reload({ waitUntil: "networkidle0" });
  await booted();
  check("a stale filesystem is refreshed", await screenText(),
    (t) => t.includes("repository was updated"));
  await type("ls examples");
  check("the examples are back", await screenText(), (t) => t.includes("/examples/guard-chain.hb"));
  await type("cat mine.hb");
  check("a file of the visitor's own survives the refresh", await screenText(), (t) => t.includes("42"));

  // And with nothing stale, a restore says nothing about updating.
  await page.reload({ waitUntil: "networkidle0" });
  await booted();
  check("an up-to-date filesystem is left alone", await screenText(),
    (t) => t.includes("Restored your files from this browser.") && !t.split("Restored your files from this browser.")[1].includes("repository was updated"));

  // The service-worker route to isolation, on its own: this is how the page
  // gets there on GitHub Pages, which cannot set headers. A separate browser
  // context so it starts without the service worker already installed.
  const swContext = await browser.createBrowserContext();
  const swPage = await swContext.newPage();
  await swPage.goto(`http://localhost:${PORT + 1}/playground.html`, { waitUntil: "networkidle0" });
  let isolatedViaWorker = false;
  for (let i = 0; i < 30 && !isolatedViaWorker; i++) {
    await new Promise((r) => setTimeout(r, 1000));
    isolatedViaWorker = await swPage.evaluate(() => self.crossOriginIsolated).catch(() => false);
  }
  check("coi-serviceworker reaches isolation without header support", isolatedViaWorker, true);
  await swContext.close();

  check("no page errors", problems.join(" | "), "");
} finally {
  await browser.close();
  server.close();
  plainServer.close();
}

console.log(failures === 0 ? "\nall terminal checks passed" : `\n${failures} terminal checks failed`);
process.exit(failures === 0 ? 0 : 1);
