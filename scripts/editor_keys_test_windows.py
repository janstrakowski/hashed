#!/usr/bin/env python3
"""Drives the live editor on a real Windows console, by injecting key events.

The Windows counterpart to editor_keys_test.py, which uses a pty - a POSIX-only
thing. The obvious substitute is ConPTY, but it is the wrong tool for this
particular test: ConPTY turns the bytes you write into console key events and
then, because the editor sets ENABLE_VIRTUAL_TERMINAL_INPUT, turns them back
into escape sequences. Feeding it "\x1b3" would mostly test that round trip.

So this skips the pseudo-console and drives the real one. It allocates a
console, starts `hl -i` attached to it, and injects genuine KEY_EVENT_RECORDs
with WriteConsoleInputW - a virtual key code plus a control-key state, which is
what a keyboard actually produces. Conhost's own VT-input translation then
turns those into the escape sequences the editor reads. That translation is
exactly the thing term_windows.odin bets on and nothing else covers, so it is
the thing under test here.

Reading back differs for the same reason. There is no byte stream to capture:
the editor's escapes are interpreted by conhost, so what exists afterwards is a
rendered screen. ReadConsoleOutputCharacterW reads it directly, which means the
assertions below compare text on screen rather than ANSI-stripped output. The
checks are otherwise the same ones the pty test makes, so the two targets
cannot drift apart.

Usage: python scripts/editor_keys_test_windows.py [path/to/hl.exe]
"""

import ctypes
import os
import subprocess
import sys
import time
from ctypes import wintypes

if sys.platform != "win32":
    print("this test drives a Windows console; use editor_keys_test.py elsewhere")
    sys.exit(0)

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
u32 = ctypes.WinDLL("user32", use_last_error=True)

HL = os.path.abspath(
    sys.argv[1] if len(sys.argv) > 1
    else os.path.join(os.path.dirname(__file__), "..", "hl.exe")
)

KEY_EVENT = 0x0001
LEFT_ALT_PRESSED = 0x0002
LEFT_CTRL_PRESSED = 0x0008

failures = 0


# ---- the Win32 structures WriteConsoleInputW and friends need -----------------

class COORD(ctypes.Structure):
    _fields_ = [("X", ctypes.c_short), ("Y", ctypes.c_short)]


class SMALL_RECT(ctypes.Structure):
    _fields_ = [("Left", ctypes.c_short), ("Top", ctypes.c_short),
                ("Right", ctypes.c_short), ("Bottom", ctypes.c_short)]


class CONSOLE_SCREEN_BUFFER_INFO(ctypes.Structure):
    _fields_ = [("dwSize", COORD), ("dwCursorPosition", COORD),
                ("wAttributes", wintypes.WORD), ("srWindow", SMALL_RECT),
                ("dwMaximumWindowSize", COORD)]


class SECURITY_ATTRIBUTES(ctypes.Structure):
    _fields_ = [("nLength", wintypes.DWORD), ("lpSecurityDescriptor", wintypes.LPVOID),
                ("bInheritHandle", wintypes.BOOL)]


class _CHAR(ctypes.Union):
    _fields_ = [("UnicodeChar", ctypes.c_wchar), ("AsciiChar", ctypes.c_char)]


class KEY_EVENT_RECORD(ctypes.Structure):
    _fields_ = [("bKeyDown", wintypes.BOOL), ("wRepeatCount", wintypes.WORD),
                ("wVirtualKeyCode", wintypes.WORD), ("wVirtualScanCode", wintypes.WORD),
                ("uChar", _CHAR), ("dwControlKeyState", wintypes.DWORD)]


class _EVENT(ctypes.Union):
    # Padded to the union's real size: the other event records (mouse, resize)
    # are what decide it, and INPUT_RECORD's layout has to match theirs.
    _fields_ = [("KeyEvent", KEY_EVENT_RECORD), ("pad", ctypes.c_byte * 16)]


class INPUT_RECORD(ctypes.Structure):
    _fields_ = [("EventType", wintypes.WORD), ("Event", _EVENT)]


k32.CreateFileW.restype = wintypes.HANDLE
k32.WriteConsoleInputW.argtypes = [wintypes.HANDLE, ctypes.POINTER(INPUT_RECORD),
                                   wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
k32.ReadConsoleOutputCharacterW.argtypes = [wintypes.HANDLE, wintypes.LPWSTR, wintypes.DWORD,
                                            COORD, ctypes.POINTER(wintypes.DWORD)]
k32.GetConsoleScreenBufferInfo.argtypes = [wintypes.HANDLE,
                                           ctypes.POINTER(CONSOLE_SCREEN_BUFFER_INFO)]


# ---- the console -------------------------------------------------------------

# A CI step has no console of its own (its stdio is a pipe), so one is allocated
# rather than assumed. FreeConsole first because AllocConsole fails if the
# process already has one, and a developer running this from a terminal does.
k32.FreeConsole()
if not k32.AllocConsole():
    print("could not allocate a console (error %d)" % ctypes.get_last_error())
    sys.exit(1)

# Inheritable, because the editor is a child process and these become its
# standard handles - that is what makes it see a terminal rather than a pipe.
_sa = SECURITY_ATTRIBUTES(ctypes.sizeof(SECURITY_ATTRIBUTES), None, True)


def _open_console(name):
    return wintypes.HANDLE(
        k32.CreateFileW(name, 0x80000000 | 0x40000000, 0x1 | 0x2, ctypes.byref(_sa), 3, 0, None)
    )


CONIN = _open_console("CONIN$")
CONOUT = _open_console("CONOUT$")

_info = CONSOLE_SCREEN_BUFFER_INFO()
k32.GetConsoleScreenBufferInfo(CONOUT, ctypes.byref(_info))
WIDTH = _info.dwSize.X or 120
HEIGHT = _info.dwSize.Y or 30


def send_key(vk, char, control=0, settle=0.22):
    """One key press and release, as a keyboard would deliver it.

    Both the virtual key code and the character are set: conhost's VT-input
    translation uses the character where there is one, and the key code for
    everything else. The control state is what makes it a chord rather than a
    plain keystroke.
    """
    recs = (INPUT_RECORD * 2)()
    for i, down in enumerate((True, False)):
        recs[i].EventType = KEY_EVENT
        key = recs[i].Event.KeyEvent
        key.bKeyDown = down
        key.wRepeatCount = 1
        key.wVirtualKeyCode = vk
        key.wVirtualScanCode = u32.MapVirtualKeyW(vk, 0)
        key.uChar.UnicodeChar = char
        key.dwControlKeyState = control
    written = wintypes.DWORD(0)
    k32.WriteConsoleInputW(CONIN, recs, 2, ctypes.byref(written))
    time.sleep(settle)


def vk_of(ch):
    return u32.VkKeyScanW(ord(ch)) & 0xFF


def type_text(text):
    for ch in text:
        send_key(vk_of(ch), ch, settle=0.06)


# The chords this test exists for. Ctrl+<letter> carries the control character
# the terminal would send (Ctrl+N is 0x0e), which is what the editor reads.
def alt(ch):
    return lambda: send_key(vk_of(ch), ch, LEFT_ALT_PRESSED)


def ctrl(letter):
    return lambda: send_key(ord(letter), chr(ord(letter) - 64), LEFT_CTRL_PRESSED)


def ctrl_alt(letter):
    return lambda: send_key(ord(letter), chr(ord(letter) - 64),
                            LEFT_CTRL_PRESSED | LEFT_ALT_PRESSED)


def read_screen():
    """The rendered screen, as a list of rows.

    Opened fresh each time: the editor runs on the alternate screen buffer
    (?1049h), and CONOUT$ resolves to whichever buffer is active when it is
    opened, not when it was first opened.
    """
    handle = _open_console("CONOUT$")
    rows = []
    buf = ctypes.create_unicode_buffer(WIDTH)
    count = wintypes.DWORD(0)
    for y in range(HEIGHT):
        if k32.ReadConsoleOutputCharacterW(handle, buf, WIDTH, COORD(0, y), ctypes.byref(count)):
            rows.append(buf[:count.value].rstrip())
    k32.CloseHandle(handle)
    return rows


def _drain_input():
    k32.FlushConsoleInputBuffer(CONIN)


def run(keys, quit_after=True):
    """Starts the editor, applies `keys`, and returns (screen rows, exited)."""
    _drain_input()
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESTDHANDLES
    startup.hStdInput = CONIN.value
    startup.hStdOutput = CONOUT.value
    startup.hStdError = CONOUT.value
    proc = subprocess.Popen([HL, "-i"], startupinfo=startup, close_fds=False)
    time.sleep(1.2)

    for key in keys:
        key()

    rows = read_screen()
    exited = proc.poll() is not None
    if quit_after and not exited:
        proc.kill()
    proc.wait()
    return rows, exited


# ---- assertions --------------------------------------------------------------

def titles(rows):
    for row in rows:
        low = row.lower()
        if "source" in low and ("ast" in low or "result" in low):
            return low
    return ""


def status_line(rows):
    for row in reversed(rows):
        low = row.lower()
        if "steps" in low and "quit" in low:
            return low
    return ""


def check(name, actual, expected):
    global failures
    ok = expected(actual) if callable(expected) else actual == expected
    if ok:
        print("ok   %s" % name)
    else:
        failures += 1
        print("FAIL %s\n  got: %r" % (name, actual))


# A program in the buffer and the debugger panel shown (Alt+5), so stepping has
# something to step - the same setup the pty test uses.
BASE = [lambda: type_text("1 + 2"), alt("5")]

check("the editor draws", titles(run([])[0]),
      lambda t: "source" in t and "ast" in t)

check("no steps to begin with", status_line(run(BASE)[0]),
      lambda t: "debug 0 steps" in t)

# Ctrl+N is the editor's own step key on a terminal...
check("Ctrl+N steps the debugger",
      status_line(run(BASE + [ctrl("N"), ctrl("N")])[0]),
      lambda t: "debug 2 steps" in t)

# ...and Ctrl+Alt+N has to work identically, because that is what the browser
# substitutes where Ctrl+N never arrives.
check("Ctrl+Alt+N steps the debugger too",
      status_line(run(BASE + [ctrl_alt("N"), ctrl_alt("N")])[0]),
      lambda t: "debug 2 steps" in t)

check("the two spellings mix freely",
      status_line(run(BASE + [ctrl("N"), ctrl_alt("N")])[0]),
      lambda t: "debug 2 steps" in t)

# Alt+3 hides the result pane; Alt+4 brings up steps.
check("Alt+3 hides the result pane", titles(run([alt("3")])[0]),
      lambda t: "result" not in t and "ast" in t)

check("Alt+4 shows the steps pane", titles(run([alt("4")])[0]),
      lambda t: "steps" in t)

# Ctrl+Alt+Q quits. The pty test looks for the alternate-buffer restore in the
# byte stream; there is no byte stream here, so the assertion is the stronger
# one anyway - the process is gone without having been killed.
check("Ctrl+Alt+Q quits the editor", run([ctrl_alt("Q")], quit_after=False)[1], True)

print("\nall editor key checks passed" if failures == 0
      else "\n%d editor key checks failed" % failures)
sys.exit(0 if failures == 0 else 1)
