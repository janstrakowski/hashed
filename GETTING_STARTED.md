# Getting started

Everything in [README.md](README.md) and [LANGUAGE.md](LANGUAGE.md) is real, runnable code. This walks through setting HashedBuild up and trying it yourself.

## Setup

You need the [Odin compiler](https://odin-lang.org/) (this project tracks a recent nightly - `odin version` should print something like `dev-2026-08:...`; if your build fails with an unrelated syntax error, your Odin is probably too old).

```sh
git clone https://github.com/janstrakowski/hashedbuild.git
cd hashedbuild
odin build src -out:hb -debug
```

That produces an `hb` binary in the repo root. Everything below assumes you're running it from there (`./hb ...`).

Sanity check:

```sh
./hb -a examples/functions.hb
```

You should see an AST dump followed by `121`.

### On Windows

The same, with `hb.exe`. Odin links Windows binaries through the MSVC toolchain, so you also need the **Windows SDK** — otherwise the build stops at `Windows SDK not found.` before compiling anything. Visual Studio Build Tools with the "Desktop development with C++" workload is the smallest thing that provides it:

```
winget install Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

Get Odin itself from the [release page](https://github.com/odin-lang/Odin/releases), not from winget: the `odin-lang.Odin` package lags the nightlies badly enough to matter — it was still on `dev-2026-05` while CI pinned `dev-2026-08`, and `winget upgrade` reports nothing available. Unzip `odin-windows-amd64-<version>.zip` somewhere and put that directory on your `PATH`; it is self-contained, linkers included.

Then clone and build. Clone with `core.symlinks=true` so `examples/link-to-optiona` arrives as a real symlink rather than a text file — that needs Developer Mode on, or an elevated shell, which is the same privilege `symlink` itself needs:

```
git clone -c core.symlinks=true https://github.com/janstrakowski/hashedbuild.git
cd hashedbuild
odin build src -out:hb.exe -debug
.\hb.exe -a examples/functions.hb
```

Everything below reads `./hb`; on Windows that is `.\hb.exe`. Read `-out:hb` as `-out:hb.exe` too. `scripts/` is shell, so the WASI builds want Git Bash (which ships with Git for Windows) rather than PowerShell.

### Teaching Windows about `.hb`

Optional, and per-user - it writes under `HKCU\Software\Classes`, needs no
administrator, and undoes itself:

```powershell
powershell -ExecutionPolicy Bypass -File scripts
egister_hb_windows.ps1
powershell -ExecutionPolicy Bypass -File scripts
egister_hb_windows.ps1 -Unregister
```

Explorer then calls a `.hb` file a *HashedBuild program*, shows it with the
project'''s logo, double-clicking one runs it in a console that waits before
closing, and right-click > **Edit in VS Code** opens it instead.

The icon is `logo/hashedbuild.ico`, built from `logo/hashedbuild.png` by
`python3 scripts/make_icon.py` - rerun that if the logo changes.

A program started by double-click is handed no `--dir`, so it can read and
write nothing at all (SPEC.md §9/§16) - which is what makes running one on a
double-click a safe default rather than a reckless one. A file that needs a
directory says so:

```
error: no such key in Table: "here" (it holds nothing)
```

That is `ctx.dirs.here` in a run that was given no `here`. Run it from a
terminal with the `--dir` its header's `run:` line names, or debug it from VS
Code, where the launch configuration carries the same thing.

If a freshly built binary refuses to start with *"An Application Control policy has blocked this file"*, that is [Smart App Control](https://support.microsoft.com/en-us/topic/what-is-smart-app-control-285ea03d-fa88-4495-bf75-c251c8d88d29) rather than anything wrong with the build — it blocks unsigned executables it has no reputation for. Building to a path outside the repository, or simply building again, usually gets past it.

## The ways to run something

- **`./hb path/to/program.hb`** - run a file for real, print its result.
- **`./hb -e '<expression>'`** - evaluate one expression and exit, like a single REPL submission. Handy for trying anything on this page without opening a file: `./hb -e '{ .a = 1 } concat { .b = 2 }'`.
- **`./hb`** (no arguments) - a line-based REPL. Type an expression, then an empty line to evaluate it; `:q` to quit.
- **`./hb -a path/to/program.hb`** - print the full AST before evaluating. Works with `-e` too.
- **`./hb --dir <name>=<path> ...`** - open `<path>` and hand it to the program as `ctx.dirs.<name>`. This is the *only* way a program reaches the filesystem: it can read and write inside the directories named here, by name, and cannot name anything else. Repeatable, so `--dir src=./src --dir out=/tmp/out` hands over two. A run with no `--dir` hands over nothing, and such a program cannot touch the filesystem at all. Any path the shell accepts works here - absolute, relative, `..` and all - because it is resolved before the program starts; the sub-paths a *program* writes may say none of that.

  Most programs do not need this flag at all, because they say it themselves - see **Program attributes** below.
- **`./hb --override ...`** - let the options above win over a program's own attributes. Without it, a program that declares its inputs refuses to be given different ones.
- **`./hb --cache-dir <path> ...`** - override where `ctx.cache` writes to, and where `cached` keeps its entries (defaults to your XDG cache dir; `%LOCALAPPDATA%\hashedbuild` on Windows). Handy for a throwaway cache: point it somewhere temporary and `cached` starts from nothing.
- **`hb dap`** - a debug adapter on stdin/stdout, for an editor to drive. Not something you run by hand; see [Debugging](#debugging) below.
- **`./hb --help`**, **`./hb --version`** - usage and version.

## Try each part

### 1. The parser - see the AST

`-a` is the same flag used in the video:

```sh
echo '5 |> (*2 + 1) |> (let x; x * x)' > demo.hb
./hb -a demo.hb
```

You'll see the whole expression grammar at work - pipe chaining (`|>`), an omission section (`*2 + 1`, a function of its omitted argument), and a `let`-bind with its value omitted (`let x; x * x`, a function whose argument is named) - as one real tree, followed by the evaluated result.

### 2. The evaluator - the REPL

```sh
./hb
```

Type `12 * (3 + 4) - 5`, press Enter, then Enter again on an empty line. You should get `79`. `:q` exits.

### 3. Real concurrency - `async`

The video's timing demo used a deliberately slow computation (a large lookup-heavy sum) specifically so the speedup was visible on a stopwatch. There is a real `fib` to reach for now that `let rec` exists (`./hb -e 'let rec fib (let n; (n < 2) then n else (fib (n - 1)) + (fib (n - 2))); fib 25'` takes a visible moment), but the everyday example already in the repo makes the point with less ceremony:

```sh
./hb examples/async-basics.hb
```

Open `examples/async-basics.hb` in an editor - it reads two files with `async`, so both reads fire concurrently rather than one after the other, and each is only actually awaited once something (here, `concat`) needs its real value. `examples/async-table.hb` (concurrent entries in a `Table`) and `examples/async-branching.hb` (an untaken branch's `async` work still has to finish, per SPEC.md §2) are worth a look too.

If you want to reproduce something closer to the video's *measured* 2-second comparison: `let t {0, 0, ..., 0}; t[1] + t[2] + ... + t[N]` (many bracket lookups into a large sequence-shaped table) gets slower roughly with `N²`; wrapping several of those in `async` and timing `hb` with and without it will show the same effect. Tune `N` for your machine.

## Program attributes

A program can declare how it is run, in a prologue before its expression
(SPEC.md §17):

```hashedbuild
#Directory here .

filetext (loadfile { .dir = ctx.dirs.here, .path = "notes.txt" })
```

`#Directory <name> <path>` opens a directory and hands it over as
`ctx.dirs.<name>`; `#Cache-Dir <path>` says where `ctx.cache` and `cached`
write. **Paths are relative to the source file**, so this runs from anywhere:

```sh
./hb examples/option-picker.hb      # no flags, from any directory
```

They are syntax rather than a comment convention, so a misspelling is a parse
error rather than a line that quietly does nothing. And since `#arg` is a
program in its own right, an attribute's name is capitalised and an implicit
name's is not.

A program that declares its inputs will not be handed different ones by
accident:

```sh
./hb --dir here=/tmp prog.hb              # error: the two disagree
./hb --override --dir here=/tmp prog.hb   # attributes, then this on top
./hb --override --dir here= prog.hb       # an empty path removes one
```

The same is true of a debug session: a launch configuration that sets `dirs`
for a program that declares its own is refused unless it also sets
`overrideAttributes`.

## Debugging

There is no debugger UI in this repository, on purpose. `hb dap` speaks the
[Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/) —
the same protocol VS Code, nvim-dap, emacs `dape` and Zed already implement, and
that GDB itself now exposes — so breakpoints, a call stack and a variables pane
come from an editor you already know how to use.

Two things about it are specific to this language, and both follow from what the
language is:

- **Every expression has two stops: before it, and after it.** HashedBuild has
  no statements - a program is one expression - so a stop says either `-> 2 + 3
  * 4`, meaning that is about to be evaluated, or `2 + 3 * 4 => 14`, meaning it
  has been. Only the second has a **Result** scope, because only the second has
  a result; the **Locals** scope holds the `let` bindings in scope, and is there
  either way. A **breakpoint stops before**, which is what a breakpoint means
  everywhere else and the only point at which what the line does can still be
  headed off.
- **A session reaches only the directories its launch configuration names**,
  exactly as a command line does (SPEC.md §9/§16). `dirs` in the configuration
  is `--dir` on the command line; a session with no `dirs` cannot touch the
  filesystem at all.

`async` (§2) tasks are real OS threads, so they appear as threads — the program
is thread 1 — and they stop together. They also run *concurrently*, so stepping
through a program with `async` in it walks both tasks at once: the line jumps
back and forth between them, because that is what the program is really doing.

### Walking a whole program

**Continue** (F5) runs to the next breakpoint, so a program with no breakpoint
left to hit finishes on the first click. To see every step instead, launch with
`"stopOnEntry": true` — this repository's *Step through the open .hb file*
configuration does — and use the step buttons from there:

| | | |
| --- | --- | --- |
| **Step Into** | F11 | the next stop of any kind - hold it down to watch the whole program |
| **Step Over** | F10 | run this whole expression and stop on its way out, where its value is |
| **Step Out** | Shift+F11 | run until the call you are inside of returns |

Step Into walks down into an expression and back out of it, so a line reads as
a descent and then a commentary:

```
-> loadfile { .dir = ctx.dirs.here, .path = "choice.txt" }
-> ctx.dirs.here
-> ctx.dirs
-> ctx
   ctx => {permissions: {io: nothing}, cache: <cache>, dirs: {here: <directory: ...>}}
   ctx.dirs => {here: <directory: ...>}
```

Step Over is the other one worth knowing, and it is measured in expressions
rather than in function calls: from `-> 2 + 3 * 4` it runs the whole thing and
stops at `2 + 3 * 4 => 14`. That is the answer to "I broke on this line, now
what did it come to" — one F10.

### nvim-dap

```lua
local dap = require("dap")

dap.adapters.hashedbuild = {
  type = "executable",
  command = "/path/to/hb",
  args = { "dap" },
}

dap.configurations.hashedbuild = {
  {
    type = "hashedbuild",
    request = "launch",
    name = "Run this file",
    program = "${file}",
    -- What the program may reach, by name: ctx.dirs.here inside it.
    dirs = { here = "${fileDirname}" },
  },
}
```

`:lua vim.bo.filetype = "hashedbuild"` on a `.hb` buffer, then `:DapToggleBreakpoint`
and `:DapContinue`.

### VS Code

VS Code will not talk to a bare adapter: something has to *contribute* the
debugger type. That contribution ships here, in `editors/vscode/`, and it is
one `package.json` with no code in it - nothing to compile, no npm.

The only thing that cannot be committed is where your `hb` binary is, since a
debugger contribution resolves its adapter path relative to the extension
folder rather than to your workspace. So one script copies the extension into
your extension directory and fills that in:

```sh
odin build src -out:hb.exe                     # or -out:hb on Linux
python3 scripts/install_vscode_debug.py        # pass a path to use another binary
```

Restart VS Code, **open a folder** (File -> Open Folder), open a `.hb` file in
it and press **F5**. Re-run the script after moving the repository or building
the binary somewhere else.

The folder matters: F5 reads `.vscode/launch.json`, which belongs to a folder,
so a lone file opened on its own gets *Select and Start Debug Configuration*
instead of a run. Picking **HashedBuild** there works too - it runs the active
file with no directories, which is all a program that declares its own (§17)
needs.

This repository's own `.vscode/launch.json` already has two configurations -
the open file, and `examples/option-picker.hb` - and neither names a directory,
because every example declares its own (§17). So F5 works in a fresh clone. For your own project:

```json
{
  "type": "hashedbuild",
  "request": "launch",
  "name": "Run this file",
  "program": "${file}"
}
```

That is the whole of it for a program that declares its own directories (§17).
For one that does not, `dirs` is `--dir` written down - each entry becomes
`ctx.dirs.<name>`, and it is the whole of what the program may read or write:

```json
  "dirs": { "here": "${fileDirname}" }
```

Setting it for a program that *does* declare its own is refused, exactly as on
the command line, unless the configuration also sets
`"overrideAttributes": true`.

### What the adapter supports

`initialize`, `launch`, `setBreakpoints`, `configurationDone`, `threads`,
`stackTrace`, `scopes`, `variables`, `continue`, `next`, `stepIn`, `stepOut`,
`evaluate`, `disconnect` and `terminate`. `evaluate` really evaluates, in the
scope the run stopped in — so a watch expression that calls a filesystem builtin
touches the filesystem, exactly as it would in the program.

Breakpoints are verified per line: a line no expression starts on - a comment,
a blank line, a closing brace - comes back unverified, so a client can grey it
out rather than pretend. A line that opens a multi-line expression is a
breakpoint on that whole expression, and fires once when the run reaches it,
not once per expression nested inside it. Breakpoints in files this session is
not running come back unverified too: a session debugs one program, and a
breakpoint you left in another file is not a breakpoint in this one.

`dap-tests/` drives all of this with the protocol's own reference client — see
CLAUDE.md for why that one directory has a `package.json`.

Clients disagree about the order they send `launch` and `configurationDone` in:
VS Code launches first and configures after, while the protocol's own
recommended order - and nvim-dap - is the other way round. Both work; the run
is parked until whichever arrives second.

### When a session does nothing

The client spawns the adapter, so there is no terminal to watch and a failed
launch can look like nothing happening at all. Set `HB_DAP_LOG` before starting
the editor and every message either way is appended to that file:

```sh
HB_DAP_LOG=/tmp/hb-dap.log code .     # or set it however your editor is started
```

`hb dap --log <path>` does the same thing for a client whose configuration you
can add arguments to.

## Where to go next

- **[LANGUAGE.md](LANGUAGE.md)** - every feature that works today, with runnable snippets: values, operators, Tables, functions, pattern matching, failure, files, permissions, concurrency - and an explicit list of what isn't built yet.
- **[examples/](examples/)** - a runnable file per feature, indexed in [examples/README.md](examples/README.md). The test suite runs all of them.
- **`SPEC.md`** - the full, evolving language design, including the parts that don't run yet.
- **`SPEC.md` §9/§16** - why a program reaches only the directories `--dir` names.
