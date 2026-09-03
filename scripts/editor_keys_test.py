#!/usr/bin/env python3
"""Drives the live editor on a real terminal, through a pty.

`odin test` cannot press keys, and CLAUDE.md has long listed the terminal UI as
a coverage exception on the grounds that driving a raw-mode TTY costs more than
it's worth. A pty is about forty lines, so that exception is narrower than it
looked - and these particular keys have already broken twice in ways nothing
caught: Alt+3 (which a browser steals) and Ctrl+N (which a browser never
delivers at all). The browser test covers the substitutes there; this covers the
same chords here, so the two targets cannot drift apart.

`editor_keys_test_windows.py` makes these same checks on a Windows console,
where there is no pty to fork - see its header for why it injects key events
rather than reaching for ConPTY.

Usage: python3 scripts/editor_keys_test.py [path/to/hl]
"""

import os
import pty
import re
import select
import sys
import time

HL = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "hl")
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")

failures = 0


def run(keys, quit_key=b"\x11"):
    """Runs the editor, sends `keys`, and returns everything it drew."""
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["LINES"] = "24"
        os.environ["COLUMNS"] = "120"
        os.execv(HL, ["hl", "-i"])

    out = b""

    def drain(seconds):
        nonlocal out
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    out += os.read(fd, 65536)
                except OSError:
                    return

    drain(1.5)
    for key in keys:
        os.write(fd, key)
        time.sleep(0.45)
        drain(0.45)
    if quit_key:
        os.write(fd, quit_key)
        drain(0.5)

    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    return out.decode("utf8", "replace")


def screen(text):
    return [ANSI.sub("", line).strip() for line in text.split("\n")]


def status_line(text):
    rows = [l for l in screen(text) if "steps" in l and "quit" in l]
    return rows[-1] if rows else ""


def titles(text):
    rows = [l for l in screen(text) if "source" in l and ("ast" in l or "result" in l)]
    return rows[-1] if rows else ""


def check(name, actual, expected):
    global failures
    ok = expected(actual) if callable(expected) else actual == expected
    if ok:
        print(f"ok   {name}")
    else:
        failures += 1
        print(f"FAIL {name}\n  got: {actual!r}")


# A program in the buffer, and the debugger panel shown (Alt+5), so stepping has
# something to step.
BASE = [b"1 + 2", b"\x1b5"]

check("the editor draws", titles(run([])), lambda t: "source" in t and "ast" in t)
check("no steps to begin with", status_line(run(BASE)), lambda t: "debug 0 steps" in t)

# Ctrl+N is the editor's own step key on a terminal...
check("Ctrl+N steps the debugger",
      status_line(run(BASE + [b"\x0e", b"\x0e"])), lambda t: "debug 2 steps" in t)

# ...and Ctrl+Alt+N - ESC then the same control byte, which is what a terminal
# sends for it - has to work identically, because that is what the browser
# substitutes where Ctrl+N never arrives.
check("Ctrl+Alt+N steps the debugger too",
      status_line(run(BASE + [b"\x1b\x0e", b"\x1b\x0e"])), lambda t: "debug 2 steps" in t)

check("the two spellings mix freely",
      status_line(run(BASE + [b"\x0e", b"\x1b\x0e"])), lambda t: "debug 2 steps" in t)

# Alt+3 hides the result pane; Alt+4 brings up steps.
check("Alt+3 hides the result pane",
      titles(run([b"\x1b3"])), lambda t: "result" not in t and "ast" in t)
check("Alt+4 shows the steps pane", titles(run([b"\x1b4"])), lambda t: "steps" in t)

# Ctrl+Alt+Q quits, so nothing else needs to be sent to end the session.
quit_output = run([b"\x1b\x11"], quit_key=None)
check("Ctrl+Alt+Q quits the editor", quit_output, lambda t: "?1049l" in t[-400:])

print("\nall editor key checks passed" if failures == 0 else f"\n{failures} editor key checks failed")
sys.exit(0 if failures == 0 else 1)
