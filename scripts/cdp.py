"""A very small Chrome DevTools Protocol client - enough to drive the
playground's tests, and nothing else.

This exists so the browser tests need no npm: puppeteer-core was the project's
only package dependency, and what the tests actually use of it is a handful of
CDP calls. Chrome speaks CDP over a WebSocket, and a client for the one frame
type we need is about eighty lines, so the dependency was mostly convenience.

Python 3 standard library only, like the editor key tests - see CLAUDE.md.

Deliberately not general: text frames only (CDP sends nothing else), synchronous
request/response, and waiting is polling rather than a subscription. A test that
drives a browser spends its time waiting for a page, not for the protocol.
"""

import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import urllib.request

# Input.dispatchKeyEvent's modifier bitmask.
ALT, CTRL, META, SHIFT = 1, 2, 4, 8

# Named keys the tests press, as (key, code, keyCode, text).
NAMED_KEYS = {
    "Enter":      ("Enter", "Enter", 13, "\r"),
    "Space":      (" ", "Space", 32, " "),
    "Backspace":  ("Backspace", "Backspace", 8, ""),
    "Escape":     ("Escape", "Escape", 27, ""),
    "Tab":        ("Tab", "Tab", 9, "\t"),
    "ArrowUp":    ("ArrowUp", "ArrowUp", 38, ""),
    "ArrowDown":  ("ArrowDown", "ArrowDown", 40, ""),
    "ArrowLeft":  ("ArrowLeft", "ArrowLeft", 37, ""),
    "ArrowRight": ("ArrowRight", "ArrowRight", 39, ""),
    "Control":    ("Control", "ControlLeft", 17, ""),
    "Alt":        ("Alt", "AltLeft", 18, ""),
    "Shift":      ("Shift", "ShiftLeft", 16, ""),
}

# US-layout codes for the punctuation the tests type. `code` is the part that
# matters beyond `text`: the playground keys its Alt and Ctrl+Alt chords on
# event.code, so a layout that spells the character differently still works.
PUNCT_CODES = {
    " ": ("Space", 32, False),      "-": ("Minus", 189, False),
    "=": ("Equal", 187, False),     "[": ("BracketLeft", 219, False),
    "]": ("BracketRight", 221, False), "\\": ("Backslash", 220, False),
    ";": ("Semicolon", 186, False), "'": ("Quote", 222, False),
    ",": ("Comma", 188, False),     ".": ("Period", 190, False),
    "/": ("Slash", 191, False),     "`": ("Backquote", 192, False),
    "!": ("Digit1", 49, True),      "@": ("Digit2", 50, True),
    "#": ("Digit3", 51, True),      "$": ("Digit4", 52, True),
    "%": ("Digit5", 53, True),      "^": ("Digit6", 54, True),
    "&": ("Digit7", 55, True),      "*": ("Digit8", 56, True),
    "(": ("Digit9", 57, True),      ")": ("Digit0", 48, True),
    "_": ("Minus", 189, True),      "+": ("Equal", 187, True),
    "{": ("BracketLeft", 219, True), "}": ("BracketRight", 221, True),
    "|": ("Backslash", 220, True),  ":": ("Semicolon", 186, True),
    '"': ("Quote", 222, True),      "<": ("Comma", 188, True),
    ">": ("Period", 190, True),     "?": ("Slash", 191, True),
    "~": ("Backquote", 192, True),
}


def describe_key(name):
    """(key, code, keyCode, text, needs_shift) for a puppeteer-style key name."""
    if name in NAMED_KEYS:
        key, code, key_code, text = NAMED_KEYS[name]
        return key, code, key_code, text, False
    if name.startswith("Key") and len(name) == 4:          # KeyE
        letter = name[3].lower()
        return letter, name, ord(letter.upper()), letter, False
    if name.startswith("Digit") and len(name) == 6:        # Digit5
        return name[5], name, ord(name[5]), name[5], False
    if len(name) == 1:
        ch = name
        if ch.isalpha():
            return ch, "Key" + ch.upper(), ord(ch.upper()), ch, ch.isupper()
        if ch.isdigit():
            return ch, "Digit" + ch, ord(ch), ch, False
        code, key_code, shift = PUNCT_CODES.get(ch, ("", 0, False))
        return ch, code, key_code, ch, shift
    raise ValueError(f"unknown key {name!r}")


class WebSocket:
    """Client end of an RFC 6455 connection, text frames only."""

    def __init__(self, host, port, path):
        self.sock = socket.create_connection((host, port))
        # Command-scoped, set by Connection.send: a recv that blocks forever
        # would make every deadline below unenforceable.
        self.sock.settimeout(60)
        self.buf = b""
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n".encode())
        while b"\r\n\r\n" not in self.buf:
            self._fill()
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        if b"101" not in head.split(b"\r\n")[0]:
            raise RuntimeError(f"websocket upgrade refused: {head.decode(errors='replace')}")

    def deadline(self, seconds):
        self.sock.settimeout(seconds)

    def _fill(self):
        try:
            chunk = self.sock.recv(65536)
        except socket.timeout as exc:
            raise TimeoutError("the browser stopped answering") from exc
        if not chunk:
            raise ConnectionError("websocket closed")
        self.buf += chunk

    def _take(self, n):
        while len(self.buf) < n:
            self._fill()
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, text):
        payload = text.encode()
        header = bytearray([0x81])                    # FIN + text
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def recv(self):
        """One complete message, reassembling continuation frames."""
        chunks = []
        while True:
            b0, b1 = self._take(2)
            fin, opcode = b0 & 0x80, b0 & 0x0F
            length = b1 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._take(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._take(8))[0]
            data = self._take(length) if length else b""
            if opcode == 0x9:                          # ping -> pong
                self.sock.sendall(b"\x8a\x80" + os.urandom(4))
                continue
            if opcode == 0xA:                          # pong
                continue
            if opcode == 0x8:
                raise ConnectionError("websocket closed by peer")
            chunks.append(data)
            if fin:
                return b"".join(chunks).decode("utf-8", "replace")

    def close(self):
        try:
            self.sock.sendall(b"\x88\x80" + os.urandom(4))
        except OSError:
            pass
        self.sock.close()


class Connection:
    """CDP request/response over one WebSocket, with events collected as they go."""

    def __init__(self, url):
        rest = url.split("://", 1)[1]
        hostport, path = rest.split("/", 1)
        host, port = hostport.split(":")
        self.ws = WebSocket(host, int(port), "/" + path)
        self.next_id = 0
        self.listeners = []

    def on_event(self, fn):
        self.listeners.append(fn)

    def _dispatch(self, msg):
        for fn in self.listeners:
            fn(msg)

    def send(self, method, params=None, session=None, timeout=60):
        self.next_id += 1
        msg = {"id": self.next_id, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        self.ws.deadline(timeout)
        self.ws.send(json.dumps(msg))
        deadline = time.monotonic() + timeout
        while True:
            reply = json.loads(self.ws.recv())
            if reply.get("id") == msg["id"]:
                if "error" in reply:
                    raise RuntimeError(f"{method}: {reply['error']}")
                return reply.get("result", {})
            if "method" in reply:
                self._dispatch(reply)
            if time.monotonic() > deadline:
                raise TimeoutError(f"{method} did not answer within {timeout}s")

    def close(self):
        self.ws.close()


class Page:
    """One attached target: navigation, evaluation, and input."""

    def __init__(self, conn, session, target_id, wait_ms):
        self.conn, self.session, self.target_id = conn, session, target_id
        self.wait = wait_ms / 1000
        self.problems = []
        conn.on_event(self._note_problem)
        self.send("Page.enable")
        self.send("Runtime.enable")

    def send(self, method, params=None, timeout=60):
        return self.conn.send(method, params, session=self.session, timeout=timeout)

    def _note_problem(self, msg):
        if msg.get("sessionId") != self.session:
            return
        if msg["method"] == "Runtime.exceptionThrown":
            details = msg["params"]["exceptionDetails"]
            text = details.get("exception", {}).get("description") or details.get("text", "")
            self.problems.append("pageerror: " + text)
        elif msg["method"] == "Runtime.consoleAPICalled" and msg["params"]["type"] == "error":
            parts = [a.get("value", a.get("description", "")) for a in msg["params"]["args"]]
            self.problems.append("console: " + " ".join(str(p) for p in parts))

    def set_viewport(self, width, height):
        """Pin the viewport, and with it the terminal's column count. Left to
        the window, the editor's width varies with the browser's own chrome and
        the font it manages to measure - and a status line that wraps in a
        different place is a failing assertion about nothing."""
        self.send("Emulation.setDeviceMetricsOverride",
                  {"width": width, "height": height,
                   "deviceScaleFactor": 1, "mobile": False})

    def throttle_cpu(self, rate):
        self.send("Emulation.setCPUThrottlingRate", {"rate": rate})

    def evaluate(self, expression, timeout=60):
        result = self.send("Runtime.evaluate", {
            "expression": expression, "returnByValue": True,
            "awaitPromise": True, "userGesture": True}, timeout=timeout)
        if "exceptionDetails" in result:
            details = result["exceptionDetails"]
            raise RuntimeError(details.get("exception", {}).get("description") or details.get("text"))
        return result["result"].get("value")

    def wait_for(self, expression, what, timeout=None):
        """Poll until a JS expression is truthy. Polling, not a subscription:
        every condition here is page state rather than a protocol event."""
        limit = self.wait if timeout is None else timeout
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            try:
                if self.evaluate(expression):
                    return
            except RuntimeError:
                pass                                   # mid-navigation; try again
            time.sleep(0.05)
        raise TimeoutError(f"timed out after {limit:.0f}s waiting for {what}")

    def goto(self, url):
        self.send("Page.navigate", {"url": url})
        self.wait_for("document.readyState === 'complete'", f"{url} to load")

    def reload(self):
        self.send("Page.reload", {})
        self.wait_for("document.readyState === 'complete'", "the page to reload")

    # ---- input ---------------------------------------------------------------

    def _key(self, event_type, name, modifiers=0):
        key, code, key_code, text, shift = describe_key(name)
        if shift:
            modifiers |= SHIFT
        params = {"type": event_type, "modifiers": modifiers, "key": key, "code": code,
                  "windowsVirtualKeyCode": key_code, "nativeVirtualKeyCode": key_code}
        # Chrome inserts text only for a keyDown that carries it, and a chord
        # (Ctrl or Alt held) produces no text - which is what a terminal sees.
        if event_type == "keyDown" and text and not modifiers & (CTRL | ALT):
            params["type"] = "keyDown"
            params["text"] = text
            params["unmodifiedText"] = text
        self.send("Input.dispatchKeyEvent", params)

    def press(self, name, modifiers=0):
        self._key("keyDown", name, modifiers)
        self._key("keyUp", name, modifiers)

    def key_down(self, name, modifiers=0):
        self._key("keyDown", name, modifiers)

    def key_up(self, name, modifiers=0):
        self._key("keyUp", name, modifiers)

    def type_text(self, text):
        for ch in text:
            self.press(ch)

    def close(self):
        self.conn.send("Target.closeTarget", {"targetId": self.target_id})


class Browser:
    """A headless Chrome, launched and attached to."""

    def __init__(self, executable, wait_ms=60000):
        self.wait_ms = wait_ms
        self.profile = tempfile.mkdtemp(prefix="hl-playground-")
        self.proc = subprocess.Popen(
            [executable, "--headless=new", "--remote-debugging-port=0",
             f"--user-data-dir={self.profile}", "--no-sandbox", "--disable-gpu",
             "--no-first-run", "--disable-dev-shm-usage", "about:blank"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.conn = Connection(self._endpoint())

    def _endpoint(self):
        """Chrome writes the port it chose into DevToolsActivePort."""
        marker = os.path.join(self.profile, "DevToolsActivePort")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if os.path.exists(marker):
                lines = open(marker).read().split("\n")
                if len(lines) >= 2 and lines[0].strip():
                    port = int(lines[0].strip())
                    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version") as r:
                        return json.load(r)["webSocketDebuggerUrl"]
            if self.proc.poll() is not None:
                raise RuntimeError(f"{self.proc.args[0]} exited before listening")
            time.sleep(0.1)
        raise TimeoutError("Chrome never reported a debugging port")

    def new_page(self, context=None):
        params = {"url": "about:blank"}
        if context:
            params["browserContextId"] = context
        target = self.conn.send("Target.createTarget", params)["targetId"]
        session = self.conn.send("Target.attachToTarget",
                                 {"targetId": target, "flatten": True})["sessionId"]
        return Page(self.conn, session, target, self.wait_ms)

    def new_context(self):
        return self.conn.send("Target.createBrowserContext", {})["browserContextId"]

    def dispose_context(self, context):
        self.conn.send("Target.disposeBrowserContext", {"browserContextId": context})

    def close(self):
        try:
            self.conn.send("Browser.close", timeout=10)
        except Exception:
            self.proc.terminate()
        try:
            self.conn.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        shutil.rmtree(self.profile, ignore_errors=True)
