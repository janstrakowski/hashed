#!/usr/bin/env python3
"""Generates docs/repo-files.json: the repository as the playground's starting
filesystem, so the terminal opens on what you would have after cloning.

Everything git tracks goes in, minus what would only bloat the download
without being anything to read: docs/media (1.4MB of video), docs/hb.wasm
(the interpreter, fetched separately), and docs/vendor (xterm.js, which the
page loads when the editor opens). Source, docs, examples and scripts - the
things someone would actually `cat` - all stay.

Usage: python3 scripts/build_playground_files.py [--check]
  --check verifies an existing manifest is current instead of writing it.

Python 3 standard library only, like the editor key tests - see CLAUDE.md.
"""

import hashlib
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "docs", "repo-files.json")
SKIP = [re.compile(p) for p in (
    r"^docs/media/", r"^docs/vendor/", r"^docs/hb\.wasm$", r"^docs/repo-files\.json$",
    # A submodule is one gitlink entry in `git ls-files`, not its contents, so
    # reading it as a file would fail - and the playground has no use for a
    # vendored C library anyway. examples/hashmake's build needs the checkout;
    # the browser terminal does not, since it cannot run a compiler.
    r"^examples/hashmake/vendor/")]


def tracked_paths():
    # --cached --others --exclude-standard: everything a clone of this commit
    # will contain, whether or not it has been `git add`ed yet. Plain `ls-files`
    # looks only at the index, so generating before staging a new file silently
    # left it out - and CI, checking out the committed tree, saw a stale
    # manifest. Ignored files stay out either way.
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=REPO, check=True, capture_output=True, text=True).stdout
    paths = [p for p in out.split("\n") if p and not any(s.search(p) for s in SKIP)]
    return sorted(paths)


def collect(paths):
    files = {}
    for path in paths:
        full = os.path.join(REPO, path)
        if os.path.islink(full):
            files[path] = {"type": "symlink", "target": os.readlink(full)}
            continue
        with open(full, "rb") as fh:
            data = fh.read()
        # Anything that isn't valid UTF-8 would have to be base64'd, and nothing
        # tracked here needs it once the media is excluded - so say so loudly
        # rather than silently shipping mojibake.
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            sys.exit(f"{path} is not valid UTF-8 - add it to SKIP or teach this script base64")
        files[path] = {"type": "file", "text": text}
    return files


def render(files):
    # Written to match what JSON.stringify produced, byte for byte, so replacing
    # the Node generator does not by itself change the version and re-seed every
    # returning visitor's filesystem. Compact form for the hash, one-space indent
    # for the file, no ASCII escaping, keys in insertion (sorted path) order.
    compact = json.dumps(files, ensure_ascii=False, separators=(",", ":"))
    # A version the page can compare against what it last seeded, so a returning
    # visitor's copy of the repository gets refreshed when the repository moves -
    # without touching anything they wrote themselves.
    version = hashlib.sha256(compact.encode("utf-8")).hexdigest()[:16]
    manifest = json.dumps({"version": version, "files": files},
                          ensure_ascii=False, indent=1) + "\n"
    return version, manifest


def main():
    files = collect(tracked_paths())
    version, manifest = render(files)

    if "--check" in sys.argv[1:]:
        try:
            with open(OUT, encoding="utf-8") as fh:
                current = fh.read()
        except FileNotFoundError:
            sys.exit(f"{OUT} does not exist - generate it with python3 scripts/build_playground_files.py")
        if current != manifest:
            sys.exit("docs/repo-files.json is stale - regenerate it with "
                     "python3 scripts/build_playground_files.py")
        print(f"docs/repo-files.json is current ({len(files)} files, version {version})")
        return

    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(manifest)
    print(f"wrote {len(files)} files, {len(manifest.encode('utf-8')) / 1024:.0f}KB, version {version}")


if __name__ == "__main__":
    main()
