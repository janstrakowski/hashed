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
  const problems = [];
  page.on("pageerror", (e) => problems.push("pageerror: " + e.message));
  page.on("console", (m) => { if (m.type() === "error") problems.push("console: " + m.text()); });

  const url = `http://localhost:${PORT}/playground.html`;
  const screenText = () => page.$eval("#screen", (el) => el.textContent);
  const prompt = () => page.$eval("#prompt", (el) => el.textContent);

  // Types a line and waits for the terminal to finish handling it. Each
  // command instantiates the module, so waiting on the screen growing is the
  // honest signal that it is done.
  const type = async (line) => {
    const before = (await screenText()).length;
    await page.type("#entry", line);
    await page.keyboard.press("Enter");
    await page.waitForFunction(
      (n) => document.getElementById("screen").textContent.length > n,
      { timeout: 15000 }, before,
    );
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
  check("prompt is a shell prompt", await prompt(), "$ ");

  // The shell's own commands.
  await type("ls");
  check("ls lists the seeded files", await screenText(), (t) => t.includes("/tour.hb"));

  await type("cat examples/choice.txt");
  check("cat prints a file", await screenText(), (t) => t.includes("option A"));

  // Running a program: the real CLI path, argv and all.
  await type("hb tour.hb");
  check("a program runs", await screenText(), (t) => t.includes('text: "hello, world"'));
  check("it read a file through loadfile", await screenText(),
    (t) => t.includes("This is the payload for option A."));

  await type("hb -e '6 * 7'");
  check("-e evaluates an expression", await screenText(), (t) => t.trimEnd().endsWith("42"));

  // REPL mode: bare `hb`, then an expression, then a blank line.
  await type("hb");
  check("REPL prints its banner", await screenText(), (t) => t.includes("HashedBuild REPL"));
  check("REPL prompt", await prompt(), "hb> ");
  await type("1 + 1");
  check("continuation prompt while buffering", await prompt(), "... ");
  await type("");
  check("blank line evaluates the buffer", await screenText(), (t) => t.trimEnd().endsWith("2"));
  await type(":q");
  check("':q' leaves the REPL", await prompt(), "$ ");

  // Writing a file, and the point of the whole thing: it is still there after
  // a reload, with no server and no database anywhere.
  await type("hb write-a-file.hb");
  check("createfile reports what it wrote", await screenText(), (t) => t.includes("<file: /greeting.txt>"));

  await page.reload({ waitUntil: "networkidle0" });
  await booted();
  check("state is restored", await screenText(), (t) => t.includes("Restored your files"));
  await type("cat greeting.txt");
  check("the written file survived the reload", await screenText(),
    (t) => t.includes("written from the browser"));

  // And the language's own rules still hold in there: createfile is exclusive.
  await type("hb write-a-file.hb");
  check("a second write fails, exclusively", await screenText(), (t) => t.includes("Exists"));

  // History, because a terminal without it is a nuisance.
  await page.keyboard.press("ArrowUp");
  check("up-arrow recalls the last command",
    await page.$eval("#entry", (el) => el.value), "hb write-a-file.hb");

  check("no page errors", problems.join(" | "), "");
} finally {
  await browser.close();
  server.kill();
}

console.log(failures === 0 ? "\nall terminal checks passed" : `\n${failures} terminal checks failed`);
process.exit(failures === 0 ? 0 : 1);
