#!/usr/bin/env python3
"""Drives docs/playground.html - the web terminal - in a real headless browser,
and the WASI shim it runs on (docs/wasi.js) in the same browser.

Two halves:

  shim      docs/wasi.js is a hand-written WASI host, and a mistake in it looks
            like a broken interpreter. It used to be exercised under Node; it is
            exercised here instead, in a page, which is the engine it actually
            ships to. The example-by-example comparison against the native build
            is still the strongest check in it - the values come from ./hb in
            this process and go into the page as data.

  terminal   the shell around the interpreter, the REPL, the live editor, and
             above all persistence, which cannot be tested without a browser's
             IndexedDB.

Usage: python3 scripts/playground_browser_test.py [chrome-path]
  CHROME_PATH  same thing, as an environment variable
  WAIT_MS      how long to wait for the page (default 60000)
  THROTTLE     CPU throttling factor, e.g. 2

Needs docs/hb.wasm and docs/repo-files.json built (see CLAUDE.md), a
Chrome/Chromium binary, and nothing else - no npm, no package manager.
Python 3 standard library plus scripts/cdp.py.
"""

import http.server
import json
import mimetypes
import os
import re
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import Browser, ALT, CTRL  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(REPO, "docs")
EXAMPLES = os.path.join(REPO, "examples")
CHROME = (sys.argv[1] if len(sys.argv) > 1 else
          os.environ.get("CHROME_PATH", "/usr/bin/chromium"))
# Generous on purpose: a boot fetches a ~500KB interpreter and a ~550KB
# manifest, instantiates the module, and may reload once for cross-origin
# isolation - on a throttled CI runner that adds up well past a default wait.
WAIT_MS = int(os.environ.get("WAIT_MS", 60000))
THROTTLE = float(os.environ["THROTTLE"]) if os.environ.get("THROTTLE") else None
PORT = 8899

failures = 0


def check(name, actual, expected):
    """expected is a value to equal, or a predicate."""
    global failures
    ok = expected(actual) if callable(expected) else actual == expected
    if ok:
        print(f"ok   {name}")
    else:
        failures += 1
        shown = json.dumps(actual) if not isinstance(actual, str) or len(actual) < 400 \
            else json.dumps(actual[-400:])
        print(f"FAIL {name}\n  got: {shown}")


# ---- the two servers ---------------------------------------------------------
#
# The page can get cross-origin isolation two ways and both are worth knowing
# about:
#
#   isolated  sends COOP/COEP itself, the way a host that can set headers
#             would. Deterministic, and what the bulk of the test runs on.
#   plain     sends nothing, so isolation has to come from coi-serviceworker -
#             which is the GitHub Pages situation, and is checked on its own
#             below rather than underneath every assertion.

mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("text/javascript", ".js")

# Loaded into the isolated server as a route of its own rather than a file in
# docs/: it is test scaffolding, not part of the site.
SHIM_HARNESS = """<!doctype html><meta charset="utf-8"><title>shim harness</title>
<script type="module">
import { FileSystem, run } from "./wasi.js";
const enc = new TextEncoder(), dec = new TextDecoder();
const wasm = new Uint8Array(await (await fetch("./hb.wasm")).arrayBuffer());
const manifest = await (await fetch("./repo-files.json")).json();

// The same seed the shim test has always used.
function seeded() {
  const fs = new FileSystem();
  fs.writeFile("/examples/optiona.txt", enc.encode("This is the payload for option A.\\n"));
  fs.writeFile("/examples/choice.txt", enc.encode("option A"));
  fs.symlink("/examples/link-to-optiona", "optiona.txt");
  return fs;
}

// Every example, from the manifest the page itself boots on.
function seedExamples() {
  const fs = new FileSystem();
  for (const [path, entry] of Object.entries(manifest.files)) {
    if (!path.startsWith("examples/")) continue;
    const name = "/" + path;
    if (entry.type === "symlink") fs.symlink(name, entry.target);
    else fs.writeFile(name, enc.encode(entry.text));
  }
  return fs;
}

async function invoke(args, fs) {
  const out = [], err = [];
  const code = await run({ wasmBytes: wasm, fs, args,
    onStdout: (s) => out.push(s), onStderr: (s) => err.push(s) });
  return { code, out: out.join("").trim(), err: err.join("").trim() };
}

window.__hb = {
  // Runs a program, keeping its filesystem around so a caller can look in it
  // or restore a snapshot of it - which is exactly what the page does.
  async evaluate(source, { restore = false, examples = false } = {}) {
    const fs = restore ? FileSystem.fromSnapshot(window.__hb.last.snapshot())
             : examples ? seedExamples() : seeded();
    fs.writeFile("/main.hb", enc.encode(source));
    const r = await invoke(["hb", "/main.hb"], fs);
    window.__hb.last = fs;
    return r;
  },
  async args(argv) { return invoke(argv, seeded()); },
  async example(name) {
    const r = await invoke(["hb", "/examples/" + name], seedExamples());
    return (r.out + "\\n" + r.err).trim();
  },
  fileInSnapshot(name) {
    const entry = window.__hb.last.snapshot()[name];
    if (!entry) return null;
    return { type: entry.type, text: dec.decode(Uint8Array.from(entry.data ?? [])) };
  },
};
window.__hbReady = true;
</script>
"""


class Handler(http.server.SimpleHTTPRequestHandler):
    isolated = True

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=DOCS, **kw)

    def log_message(self, *a):
        pass

    def end_headers(self):
        if self.isolated:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        super().end_headers()

    def do_GET(self):
        if self.path.split("?")[0] == "/__shim__.html":
            body = SHIM_HARNESS.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()


def serve(port, isolated):
    handler = type("Handler", (Handler,), {"isolated": isolated})
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def require(path, how):
    if not os.path.exists(path):
        sys.exit(f"{path} is missing - build it with: {how}")


def main():
    global failures
    require(os.path.join(DOCS, "hb.wasm"),
            "scripts/build_wasi.sh --threads-web -out:docs/hb.wasm")
    require(os.path.join(DOCS, "repo-files.json"),
            "python3 scripts/build_playground_files.py")

    server = serve(PORT, True)
    plain = serve(PORT + 1, False)
    browser = Browser(CHROME, wait_ms=WAIT_MS)
    try:
        shim_checks(browser)
        terminal_checks(browser)
        service_worker_checks(browser)
    finally:
        browser.close()
        server.shutdown()
        plain.shutdown()

    print("\nall playground checks passed" if failures == 0
          else f"\n{failures} playground checks failed")
    return 0 if failures == 0 else 1


# ---- the shim ----------------------------------------------------------------

def shim_checks(browser):
    page = browser.new_page()
    page.goto(f"http://localhost:{PORT}/__shim__.html")
    page.wait_for("window.__hbReady === true", "the shim harness to load")
    check("the harness is cross-origin isolated", page.evaluate("self.crossOriginIsolated"), True)

    def run(source, **opts):
        return page.evaluate(f"__hb.evaluate({json.dumps(source)}, {json.dumps(opts)})",
                             timeout=120)

    # --- the language runs at all ---------------------------------------------
    check("arithmetic", run("1 + 2 * 3")["out"], "7")
    check("tables", run("{ .a = 1 } concat { .b = 2 }")["out"], "{a: 1, b: 2}")
    check("patterns", run("(:.ok 42) is :.ok as v then v else 0")["out"], "42")

    # --- the filesystem is the shim's, and behaves like the real one ----------
    check("loadfile + filetext",
          run('filetext (loadfile "/examples/optiona.txt")')["out"],
          '"This is the payload for option A.\\n"')
    check("File displays its path",
          run('loadfile "/examples/optiona.txt"')["out"],
          "<file: /examples/optiona.txt>")
    check("directory handle",
          run('filetext (loadfile { .dir = loadfile "/examples", .path = "optiona.txt" })')["out"],
          '"This is the payload for option A.\\n"')
    check("readlink returns the stored target",
          run('readlink { .dir = loadfile "/examples", .path = "link-to-optiona" }')["out"],
          '"optiona.txt"')

    # Containment: a sub-path may not climb out of its directory handle (§16).
    escaped = run('loadfile { .dir = loadfile "/examples", .path = "../main.hb" }')
    check("containment refuses ..", escaped["code"], 1)
    check("containment says why", "escapes its directory" in escaped["err"], True)

    # --- writes land in the filesystem the page persists ----------------------
    written = run('createfile { .path = "/out.txt", .content = "written" }')
    check("createfile succeeds", written["code"], 0)
    entry = page.evaluate('__hb.fileInSnapshot("out.txt")')
    check("createfile is visible in the snapshot", (entry or {}).get("type"), "file")
    check("createfile wrote the bytes", (entry or {}).get("text"), "written")

    # A snapshot round-trip is exactly what the page stores and restores.
    run('createfile { .path = "/kept.txt", .content = "still here" }')
    check("a restored snapshot still has the file",
          run('filetext (loadfile "/kept.txt")', restore=True)["out"], '"still here"')

    # --- failures behave like failures ----------------------------------------
    boom = run('error "boom"')
    check("error exits non-zero", boom["code"], 1)
    check("error prints its message", "boom" in boom["err"], True)

    # This harness gives run() no thread-spawn, so the module is the portable
    # one as far as `async` is concerned - and must say so rather than
    # silently running the body in sequence.
    spawnless = run("async (1 + 1)")
    check("async refuses when the host cannot spawn", spawnless["code"], 1)
    check("async says why", "could not start a thread" in spawnless["err"], True)

    # --- the CLI surface the page drives --------------------------------------
    dash_e = page.evaluate('__hb.args(["hb", "-e", "6 * 7"])')
    check("-e evaluates one expression", dash_e["out"], "42")
    check("-e exits cleanly", dash_e["code"], 0)

    # --- the wasm behaves like the interpreter it was built from ---------------
    #
    # Every example, through this shim, against the native build. Bytes can't be
    # compared - Odin's wasm output isn't reproducible run to run (the type
    # section reorders) - so behaviour is the comparison.
    native_hb = os.path.join(REPO, "hb")
    if os.path.exists(native_hb):
        # Displayed paths differ by construction (checkout vs preopen), and
        # async needs a thread-spawn this harness does not give it - both
        # covered above. running-a-program.hb drives clang: a browser cannot
        # start a process at all, so `exec` there reports exactly that and
        # there is no answer for the two to agree on (same reason it is
        # skipped in scripts/wasi_smoke.sh).
        skip = {"files-sandboxed.hb", "option-picker.hb",
                "async-basics.hb", "async-branching.hb", "async-table.hb",
                "running-a-program.hb"}
        compared = 0
        for name in sorted(n for n in os.listdir(EXAMPLES) if n.endswith(".hb")):
            if name in skip:
                continue
            native = subprocess.run([native_hb, os.path.join(EXAMPLES, name)],
                                    capture_output=True, text=True).stdout.strip()
            through_shim = page.evaluate(f"__hb.example({json.dumps(name)})", timeout=120)
            compared += 1
            check(f"example {name} matches native", through_shim, native)
        check("compared a real number of examples", compared >= 15, True)
    else:
        print("skip  example comparison (no ./hb built)")

    check("no errors from the shim harness", " | ".join(page.problems), "")
    page.close()


# ---- the terminal ------------------------------------------------------------

def terminal_checks(browser):
    page = browser.new_page()
    # A fixed viewport, because the editor is a full-screen TUI: its column
    # count follows the window, and at a narrow one the status line wraps and
    # the examples picker draws its short header - failing assertions about
    # nothing. Pinning it makes the layout the same on every machine.
    page.set_viewport(1280, 900)
    # CI runners are slower than a dev machine, and that difference already hid
    # a real bug once (typing merged into a running command). Throttling makes
    # the fast path stop flattering us.
    if THROTTLE:
        page.throttle_cpu(THROTTLE)

    url = f"http://localhost:{PORT}/playground.html"
    screen = lambda: page.evaluate("document.getElementById('screen').textContent")
    entry_ready = "!document.getElementById('entry').disabled"

    def type_line(line):
        """Types a line and waits for the command to actually finish. The screen
        growing is not that signal - it grows the moment the command is echoed,
        before it runs. The prompt being enabled again is."""
        page.wait_for(entry_ready, "the prompt to accept input")
        # Start from an empty line: an earlier history recall can leave text in
        # the field, and typing onto the end of it makes a different command.
        page.evaluate("(() => { const e = document.getElementById('entry');"
                      " e.value = ''; e.focus(); return true; })()")
        page.type_text(line)
        page.press("Enter")
        page.wait_for(entry_ready, "the command to finish")

    def booted():
        # The last boot line differs between a fresh visit and a restored one,
        # so wait for either rather than for one of them.
        page.wait_for("document.getElementById('screen').textContent.includes('Type `help`')"
                      " || document.getElementById('screen').textContent.includes('Restored your files')",
                      "the terminal to boot")

    page.goto(url)
    booted()
    check("terminal boots", screen(), lambda t: "compiled to WebAssembly" in t)
    check("page is cross-origin isolated", page.evaluate("self.crossOriginIsolated"), True)

    # The filesystem is the repository, 1:1 - not a curated sample of it.
    type_line("ls")
    check("the repo is there", screen(),
          lambda t: "/SPEC.md" in t and "/src/eval.odin" in t and "/examples/guard-chain.hb" in t)
    check("ctx.cache has a home", screen(), lambda t: "/cache/hashedbuild" in t)

    type_line("cat examples/choice.txt")
    check("cat prints a file", screen(), lambda t: "option A" in t)

    # Running a program: the real CLI path, argv and all.
    type_line("hb examples/guard-chain.hb")
    check("a repo example runs", screen(), lambda t: t.rstrip().endswith("5"))

    type_line("hb -e '6 * 7'")
    check("-e evaluates an expression", screen(), lambda t: t.rstrip().endswith("42"))

    # The REPL, for real: bare `hb` runs the interpreter's own loop, reading
    # stdin. The banner and the prompts below come out of the module - if this
    # passes, blocking stdin works.
    type_line("hb")
    check("the interpreter's REPL starts", screen(), lambda t: "HashedBuild REPL" in t)
    type_line("1 + 1")
    check("its continuation prompt is the module's", screen(), lambda t: "... " in t)
    type_line("")
    check("a blank line evaluates the buffer", screen(), lambda t: "hb> 1 + 1\n... \n2\n" in t)
    type_line('filetext (loadfile "/README.md") |> (#arg == #arg)')
    type_line("")
    check("the REPL can read the repo", screen(), lambda t: "... \ntrue\n" in t)
    type_line(":q")
    check("':q' ends the REPL", screen(), lambda t: ":q" in t)

    # async, on real threads. The page hands each spawned thread its own
    # instance of the module against the same shared memory (wasi-threads), so
    # these are genuinely concurrent - and each one reads a file through the
    # same filesystem, which is what the RPC layer exists for.
    type_line("hb examples/async-basics.hb")
    check("async runs on real threads", screen(),
          lambda t: '"This is the payload for option A.\\nThis is the payload for option B.\\n"' in t)
    type_line("hb examples/async-table.hb")
    check("concurrent table entries all resolve", screen(),
          lambda t: '{a: 2, b: 6, c: "This is the payload for option A.\\n"}' in t)

    # ctx.cache, which is why /cache exists.
    type_line("hb -e 'createfile { .dir = ctx.cache, .content = \"cached\" }'")
    check("ctx.cache writes into /cache", screen(),
          lambda t: "<file: /cache/hashedbuild/sha256_" in t)

    # Writing a file, and the point of the whole thing: it is still there after
    # a reload, with no server and no database anywhere.
    type_line("hb -e 'createfile { .path = \"/greeting.txt\", .content = \"written from the browser\" }'")
    check("createfile reports what it wrote", screen(), lambda t: "<file: /greeting.txt>" in t)

    page.reload()
    booted()
    check("state is restored", screen(), lambda t: "Restored your files" in t)
    type_line("cat greeting.txt")
    check("the written file survived the reload", screen(),
          lambda t: "written from the browser" in t)
    type_line("ls /cache")
    check("the cache entry survived too", screen(), lambda t: "sha256_" in t)

    # And the language's own rules still hold in there: createfile is exclusive.
    type_line("hb -e 'createfile { .path = \"/greeting.txt\", .content = \"again\" }'")
    check("a second write fails, exclusively", screen(), lambda t: "Exists" in t)

    # History, because a terminal without it is a nuisance.
    page.evaluate("(() => { document.getElementById('entry').focus(); return true; })()")
    page.press("ArrowUp")
    check("up-arrow recalls the last command",
          page.evaluate("document.getElementById('entry').value"),
          lambda v: "createfile" in v)

    editor_checks(page, screen)
    stale_filesystem_checks(page, screen, type_line, booted)

    check("no page errors", " | ".join(page.problems), "")
    page.close()


def editor_checks(page, screen):
    """`hb -i` is a full-screen TUI: raw keystrokes in, ANSI out, xterm.js
    rendering it. Nothing else on this page needs an emulator, and until this
    landed the WASI build refused -i outright."""
    tui_rows = lambda: page.evaluate(
        "(() => { const rows = document.querySelector('#tui .xterm-rows');"
        " return rows ? [...rows.children].map(r => r.textContent.replace(/\\s+$/, '')).join('\\n') : ''; })()")
    settle = lambda ms=1500: time.sleep(ms / 1000)

    page.wait_for("!document.getElementById('entry').disabled", "the prompt")
    page.evaluate("(() => { const e = document.getElementById('entry');"
                  " e.value = ''; e.focus(); return true; })()")
    page.type_text("hb -i")
    page.press("Enter")
    page.wait_for("document.body.classList.contains('tui')", "the editor to open")
    settle(3500)
    check("the editor draws itself", tui_rows(), lambda t: "HashedBuild live parser" in t)
    check("its panes are there", tui_rows(),
          lambda t: "source" in t and "ast" in t and "result" in t)

    # Typing goes straight to the program, which re-parses on every keystroke.
    for ch in "5 |> (*2 + 1)":
        page.press("Space" if ch == " " else ch)
    settle(2000)
    check("keystrokes reach the editor", tui_rows(), lambda t: "5 |> (*2 + 1)" in t)
    check("it parses and evaluates live", tui_rows(), lambda t: "Op_Pipe" in t and "11" in t)

    # Ctrl+E opens the examples picker, which lists a real directory - the one
    # piece of this that needed fd_readdir.
    page.key_down("Control")
    page.press("KeyE", CTRL)
    page.key_up("Control")
    settle()
    check("the examples picker lists the repo", tui_rows(),
          lambda t: "select an example" in t and "guard-chain.hb" in t)
    page.type_text("guard")
    settle(800)
    page.press("Enter")
    settle(2500)
    check("an example loads and evaluates", tui_rows(),
          lambda t: "guard-chain" in t or "canonical guard" in t)

    # The debugger panel needs a thread of its own, which this build now has.
    page.key_down("Alt")
    page.press("Digit5", ALT)
    page.key_up("Alt")
    settle(2500)
    check("the debugger panel is live", tui_rows(),
          lambda t: "debug" in t and "no thread support" not in t)

    # Ctrl+N and Ctrl+Q never reach a page - the browser opens a window and
    # quits, respectively, before dispatching anything - so the editor's step
    # and quit keys are reachable here only as Ctrl+Alt chords.
    check("the status line advertises the browser's keys", tui_rows(),
          lambda t: "^⌥N step" in t and "^⌥Q quit" in t)

    def ctrl_alt(code):
        page.key_down("Control")
        page.key_down("Alt", CTRL)
        page.press(code, CTRL | ALT)
        page.key_up("Alt", CTRL)
        page.key_up("Control")
        settle(1200)

    ctrl_alt("KeyN")
    ctrl_alt("KeyN")
    check("Ctrl+Alt+N steps the debugger", tui_rows(),
          lambda t: re.search(r"debug [1-9]\d* steps", t) is not None)

    # Ctrl+Alt+Q leaves the editor and hands the shell back.
    ctrl_alt("KeyQ")
    page.wait_for("!document.body.classList.contains('tui')", "the editor to quit")
    check("quitting returns to the shell", screen(), lambda t: "left the editor" in t)


def service_worker_checks(browser):
    """The service-worker route to isolation, on its own: this is how the page
    gets there on GitHub Pages, which cannot set headers. A separate browser
    context so it starts without the service worker already installed."""
    context = browser.new_context()
    page = browser.new_page(context)
    page.goto(f"http://localhost:{PORT + 1}/playground.html")
    isolated = False
    for _ in range(30):
        time.sleep(1)
        try:
            isolated = bool(page.evaluate("self.crossOriginIsolated"))
        except RuntimeError:
            isolated = False
        if isolated:
            break
    check("coi-serviceworker reaches isolation without header support", isolated, True)
    page.close()
    browser.dispose_context(context)


def stale_filesystem_checks(page, screen, type_line, booted):
    """The reported symptom was an examples picker listing nothing: a snapshot
    stored before the repository became the filesystem, restored forever after
    because nothing ever re-seeded it. Here that state is planted deliberately."""
    page.evaluate("""(async () => {
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
      const stale = { ...current, seedVersion: "from-an-older-visit", files: {
        "tour.hb": { type: "file", data: [...new TextEncoder().encode("1 + 1\\n")] },
        "mine.hb": { type: "file", data: [...new TextEncoder().encode("42\\n")] },
      } };
      await new Promise((resolve, reject) => {
        const tx = db.transaction("state", "readwrite");
        tx.objectStore("state").put(stale, "state");
        tx.oncomplete = resolve;
        tx.onerror = () => reject(tx.error);
      });
      return true;
    })()""")

    page.reload()
    booted()
    check("a stale filesystem is refreshed", screen(), lambda t: "repository was updated" in t)
    type_line("ls examples")
    check("the examples are back", screen(), lambda t: "/examples/guard-chain.hb" in t)
    type_line("cat mine.hb")
    check("a file of the visitor's own survives the refresh", screen(), lambda t: "42" in t)

    # And with nothing stale, a restore says nothing about updating.
    page.reload()
    booted()
    check("an up-to-date filesystem is left alone", screen(),
          lambda t: "Restored your files from this browser." in t
          and "repository was updated" not in t.split("Restored your files from this browser.")[1])


if __name__ == "__main__":
    sys.exit(main())
