#!/usr/bin/env python3
"""Install the VS Code debug extension from editors/vscode/hashedbuild-debug.

VS Code will not talk to a bare debug adapter: something has to *contribute*
the debugger type. That contribution is one package.json with no code in it
(editors/vscode/), which is why this is a copy rather than a build - there is
nothing to compile and no npm involved.

The one thing that cannot be committed is where `hb` lives, since a debugger
contribution resolves `program` relative to the extension folder rather than
to a workspace. So this copies the extension into the user's extension
directory and rewrites that one field to the absolute path of the binary it
was pointed at.

  python3 scripts/install_vscode_debug.py            # uses ./hb or ./hb.exe
  python3 scripts/install_vscode_debug.py /path/to/hb

Re-run it after moving the repository or rebuilding somewhere else. Restart
VS Code afterwards: extensions are read at startup.
"""

import json
import os
import shutil
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(REPO, "editors", "vscode", "hashedbuild-debug")


def default_binary():
    for name in ("hb.exe", "hb"):
        candidate = os.path.join(REPO, name)
        if os.path.isfile(candidate):
            return candidate
    sys.exit("no hb binary in the repository root - build one first:\n"
             "  odin build src -out:hb.exe   (Windows)\n"
             "  odin build src -out:hb       (Linux)")


def extensions_dir():
    # VS Code keeps user extensions here on every platform; VSCODE_EXTENSIONS
    # overrides it, and portable installs set it.
    override = os.environ.get("VSCODE_EXTENSIONS")
    if override:
        return override
    return os.path.join(os.path.expanduser("~"), ".vscode", "extensions")


def main():
    binary = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else default_binary()
    if not os.path.isfile(binary):
        sys.exit(f"not a file: {binary}")

    target = os.path.join(extensions_dir(), "hashedbuild-debug-0.1.0")
    if os.path.exists(target):
        shutil.rmtree(target)
    shutil.copytree(SOURCE, target)

    # `program` is resolved relative to the extension folder, so the committed
    # placeholder is replaced with wherever the binary actually is. The
    # per-platform overrides go too: an absolute path answers for all three.
    manifest_path = os.path.join(target, "package.json")
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    debugger = manifest["contributes"]["debuggers"][0]
    debugger["program"] = binary.replace("\\", "/")
    for platform in ("windows", "linux", "osx"):
        debugger.pop(platform, None)
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")

    print(f"installed {target}")
    print(f"  adapter: {debugger['program']} {' '.join(debugger['args'])}")
    print("restart VS Code, open a .hb file, and press F5")


if __name__ == "__main__":
    main()
