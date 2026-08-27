// Drives docs/playground.html in a real headless browser: the shim test
// (playground_test.mjs) covers the WASI side, this covers the page around it -
// booting, running, and above all persistence, which is the one thing that
// cannot be tested without a browser's IndexedDB.
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
  const ready = async () => {
    await page.waitForFunction(() => document.getElementById("status").textContent !== "loading…");
  };

  await page.goto(url, { waitUntil: "networkidle0" });
  await ready();
  check("page boots", await page.$eval("#status", (el) => el.textContent), "ready");
  check("starting files are listed", (await page.$$(".file")).length, (n) => n >= 5);

  // The interpreter really runs, and produces the value the tour promises.
  await page.click("#run");
  await page.waitForFunction(() => document.getElementById("output").textContent.length > 0);
  const tour = await page.$eval("#output", (el) => el.textContent);
  check("tour program evaluates", tour.includes('text: "hello, world"'), true);
  check("it can read a seeded file", tour.includes("This is the payload for option A."), true);

  const selectFile = async (name) => {
    await page.evaluate((n) => {
      [...document.querySelectorAll(".file")].find((b) => b.textContent.includes(n)).click();
    }, name);
  };

  // A write lands in the virtual filesystem and shows up in the file list.
  await selectFile("write-a-file.hb");
  await page.click("#run");
  await page.waitForFunction(() => document.getElementById("status").textContent !== "ready");
  check("createfile reports the file it wrote",
    await page.$eval("#output", (el) => el.textContent), (t) => t.includes("<file: /greeting.txt>"));
  check("the new file appears in the list",
    await page.$$eval(".file", (bs) => bs.map((b) => b.textContent).join(" ")),
    (t) => t.includes("greeting.txt"));

  // The point of the whole exercise: it is still there after a reload, with no
  // server and no database anywhere.
  await page.reload({ waitUntil: "networkidle0" });
  await ready();
  check("state is restored from the browser",
    await page.$eval("#status", (el) => el.textContent), "restored from this browser");
  check("the written file survived the reload",
    await page.$$eval(".file", (bs) => bs.map((b) => b.textContent).join(" ")),
    (t) => t.includes("greeting.txt"));

  // And the language's own rules still hold in there: createfile is exclusive.
  await selectFile("write-a-file.hb");
  await page.click("#run");
  await page.waitForFunction(() => document.getElementById("status").textContent.includes("exited"));
  check("a second write fails, exclusively",
    await page.$eval("#output", (el) => el.textContent), (t) => t.includes("Exists"));

  check("no page errors", problems.join(" | "), "");
} finally {
  await browser.close();
  server.kill();
}

console.log(failures === 0 ? "\nall playground checks passed" : `\n${failures} playground checks failed`);
process.exit(failures === 0 ? 0 : 1);
