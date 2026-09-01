# HashedBuild

An Odin implementation of the HashedBuild language. `SPEC.md` is the source of
truth for language behavior — when code and spec disagree, the spec wins, and a
change to behavior means changing both in the same commit.

## Build and test

```sh
odin build src -out:hb                        # the CLI (the shipped binary, kept current)
odin test src                                 # full suite
./hb -e '<expr>'                              # evaluate one expression
scripts/build_wasi.sh                         # portable WASI -> hb.wasm
scripts/build_wasi.sh --threads               # wasi-threads -> hb-threads.wasm
scripts/wasi_smoke.sh ./hb ./hb.wasm wasmtime # both targets agree
(cd dap-tests && npm install && npm test)     # the debug adapter
python3 scripts/install_vscode_debug.py       # the VS Code extension -> ~/.vscode
```

On Windows the same two commands, spelled `-out:hb.exe` and
`-out:hbtest.exe` — `odin test` otherwise drops `src.exe` in the working
directory. Linking needs the Windows SDK (Visual Studio Build Tools' C++
workload); without it Odin stops at `Windows SDK not found.` before compiling.
`scripts/` is shell, so the WASI targets want Git Bash there. Two local
environment traps, neither a project problem: **Smart App Control** blocks
freshly built unsigned binaries with "An Application Control policy has blocked
this file" (build outside the repo, or just build again), and **`symlink` needs
Developer Mode** or an elevated shell, without which the symlink round trip and
`files-symlink.hb` skip themselves with a logged reason rather than failing.

**There is no interactive UI in this repository, and that is deliberate.**
A terminal editor with a debugger panel, and a browser playground hosting it,
both lived here until 2026-09-01 and were removed together: they were a large,
hand-rolled surface (a TUI, three terminal backends, a hand-written WASI host
in JavaScript, a CDP client to drive a browser) whose bugs were their own
rather than the language's. What replaced them is `hb dap` - a Debug Adapter
Protocol server, so the UI is somebody else's: VS Code, nvim-dap, `dape` and
Zed all speak it. `hb` itself is a compiler-shaped CLI again: run a file,
evaluate an expression, a REPL, and a debug adapter.

**Outside the Odin toolchain: pinned binaries, the Python standard library,
and npm for the debug-adapter tests only.**

| what | why |
| --- | --- |
| Python 3, stdlib only | `scripts/install_vscode_debug.py`, which copies the VS Code extension into place |
| PowerShell (Windows only, optional) | `scripts/register_hb_windows.ps1`, the `.hb` file association |

`logo/hashedbuild.ico` and the VS Code extension'''s `icon.png` are built from
`logo/hashedbuild.png` by `scripts/make_icon.py` (stdlib: PNG is zlib plus a
filter per scanline, ICO is a table plus bitmaps). They are committed rather
than generated on demand, unlike the playground artifacts that used to live
here: they change only when the logo does, so nothing tracked goes stale
behind them, and registering a file type should not need a toolchain.
| `wasmtime` (pinned) | the portable WASI smoke test |
| WAMR's `iwasm` (pinned, built from source) | the threaded WASI smoke test - wasmtime dropped wasi-threads in June 2026 |
| npm, in `dap-tests/` only | `@vscode/debugadapter-testsupport`, the harness the DAP ecosystem actually uses |

That last row is a deliberate reversal, so it needs its reason written down.
This repository used to be `npm`-free on purpose: `scripts/cdp.py` existed
because what the browser tests used of puppeteer-core was a handful of protocol
calls, and it was the last npm dependency. The DAP harness is a different
case. It is not a thin convenience over a protocol we already speak - it is the
reference client for the protocol `hb dap` has to satisfy, maintained by the
people who define that protocol, and testing an adapter against a hand-rolled
client mostly proves the two agree with each other. Everything else stays
install-free: `npm install` is needed only to run `dap-tests/`, and only that
directory has a `package.json`.

**Three targets.** Anything touching the filesystem goes through `fs.odin`
(`fs_linux.odin` / `fs_windows.odin` / `fs_wasi.odin`) and anything spawning a
thread through `task.odin` (`task_native.odin` for both native targets, since
`core:thread` is already portable; `task_wasi.odin` where a spawn can fail);
nothing above them names a syscall or a thread API. Odin picks the file by
suffix, so a `_linux.odin` file simply isn't compiled for the others - which is
also why the test files carry `#+build linux, windows`. `odin test` only ever
builds natively, so Linux and
Windows are covered by the suite itself (a CI job each) while the WASI backends
are covered by the smoke script above - once per flavour, the threaded one
under WAMR's iwasm, since wasmtime dropped wasi-threads.

**Windows has no `openat()`,** and that is the one place the three backends
genuinely differ rather than just spelling the same call differently. Nothing
in Win32 opens a name relative to a directory descriptor, so `fs_windows.odin`
numbers its handles in a table and reaches a child by joining onto its parent's
path. Its header says exactly what that preserves (no-follow on the final
component is still atomic; containment still holds for every path a program can
write) and what it does not (the walk is not immune to a concurrent rename).
Read it before changing anything there.

**Paths are `/`-separated on every target,** including Windows, where a display
path reads `C:/Users/you/project`. The Windows-shaped parts of that - a drive
or UNC root, backslash as a second separator, a colon meaning a drive or an
alternate data stream - live behind `WINDOWS_PATHS` in `builtins_fs.odin` and
are `when`-guarded rather than universal, because a backslash is an ordinary
character in a Linux filename and folding it there would rename files.

**The threaded WASI build has a hand-written piece.** `src/thread_start.s` is
the wasi-threads entry point: the host instantiates the module afresh per
thread, and wasm globals are per-instance, so `__stack_pointer` still points
at the main thread's stack until that stub repoints it. Odin cannot touch
that global, which is why those few lines are assembly and why
`scripts/build_wasi.sh` compiles and links them rather than `odin build`
doing everything.

`./hb` is gitignored, not tracked — but it is the binary you and any hand-testing
actually run, so rebuild it as part of every completed feature, not just at the
end of a session.

CI (`.github/workflows/ci.yml`) builds and runs the suite on every push to
`main` and every PR, using the pinned `ODIN_VERSION` — deliberately not on
`dev`, which is allowed to be red. It is a net under the rules below, not a
substitute for running the suite yourself before landing.

Tests must not hardcode an absolute path: `repo_root()` (`builtins_fs_test.odin`)
derives the checkout location from `#directory` at compile time, because CI
checks out somewhere else and `odin test` promises no particular working
directory.

## Odin notes

Traps this project has actually hit, collected because they cost time to
rediscover and the compiler's message doesn't always point at the fix:

- A **composite literal in a `for`/`if` header needs parentheses**:
  `for x in ([]string{"a", "b"})`. Without them it's a syntax error at the
  first comma — the brace is read as the loop body.
- **`fmt` treats `{` as the start of a format verb.** Building an expectation
  that is mostly braces (a Table's printed form, say) with `fmt.tprintf`
  yields `%!(MISSING CLOSE BRACE)`; use `strings.concatenate` instead.
- **A proc can't return a compound-literal slice** — it lives in the callee's
  stack frame. Make it a file-scope `X := []T{...}` value.
- **`os.read_entire_file` returns an `Error`, not a `bool`** (`err != nil`,
  not `!ok`) in the Odin this project tracks.
- **The WASI build needs `-o:size`** (or `-o:none`/`-o:speed`). Odin's default
  for wasm32 is `-o:minimal`, which on `dev-2026-08` emits a module that fails
  validation — `Invalid input WebAssembly code: type mismatch: expected i64,
  found i32`, inside one arbitrary function. It is a codegen bug, not ours:
  the same source builds valid wasm at every other optimisation level, and on
  a newer compiler at `-o:minimal` too. Linking also needs `wasm-ld`, which
  comes from `lld`, not from clang.

## Changing the language

**The language is the user's call. Ask before changing it.** Syntax, semantics,
what a builtin does, what a value displays as, what fails and how — none of it
changes without asking first, however obvious the change looks, and however
much a port or a refactor seems to force it. Present the options and what each
costs; don't pick one and report it afterwards.

What doesn't need asking: implementation work that leaves observable behaviour
identical, and fixing code that contradicts `SPEC.md` — there the spec already
decided, and the code is simply wrong (see the top of this file).

The edge worth naming, because it has already come up: when `SPEC.md`
contradicts *itself*, resolving it is a design decision, not a bug fix. If one
reading is clearly stale — superseded by a later dated resolution, or
self-contradictory in its own sentence — say so and fix it. If both readings
are coherent and pick out different behaviour, stop and ask; the §8/§16
resolution went the first way, and a case like it that went the second way
would be the user's to settle.

## Docs and examples

`main` is public. Anyone who finds this repo should be able to see what the
language can do **today** and try each of it themselves, without reading the
evaluator or guessing which parts of `SPEC.md` are real. Documentation and
examples are therefore part of a feature, not follow-up work — a feature that
nobody outside this repo can discover or run is not finished.

**Every user-visible feature is documented in `LANGUAGE.md`**, the
feature-by-feature tour of what runs. Each entry carries a snippet the reader
can paste straight into `./hb -e '…'` and a pointer to the example that
demonstrates it. Run the snippets before committing them; a doc that lies is
worse than a missing one.

**A program declares its own inputs.** `#Directory here .` and friends (§17)
sit in a prologue before the expression, and their paths are relative to the
source file - so `./hb examples/anything.hb` works from any directory, with no
flags. A run that also passes `--dir` is refused unless it passes `--override`
too. The suite runs every example exactly as a reader would, with no arguments
at all, which is what keeps the two the same thing.

**Every language feature gets an example in `examples/`.** One runnable file
per feature, with a header comment saying what it evaluates to, in the style
the existing ones use. Features where a runnable file isn't the natural
demonstration — a CLI flag, the terminal UI, the debugger — are documented in
`GETTING_STARTED.md` instead; say which route you took in the commit body.

**Docs state what is implemented, never what is planned.** `SPEC.md` is the
design and deliberately runs ahead; `LANGUAGE.md`'s "what isn't built yet"
section is what keeps that difference legible to a reader. Updating it is part
of implementing a feature, and part of removing one. When a feature turns out
to be missing something a user would reasonably expect — no boolean literals,
a failure that can't be caught — say so in the docs rather than writing around
it.

Three parts of this are mechanical, so they can't rot quietly: every
`examples/*.hb` is executed by the suite and asserted against its documented
value; `test_every_example_is_covered_by_a_test` fails when an example lands
without an assertion; and code quoted in `README.md` is compared against the
example it claims to be (`docs_test.odin`), because it drifted once already.

## Opening and watching the pull request

Work reaches `main` through a pull request, and **opening it is the agent's
job, once we have agreed the work is ready.** Not before: a green suite is a
precondition, not the signal. Push the branch as you go, then say what landed
and what you're unsure about, and wait for the answer.

When it comes back that it's ready, open the PR — don't ask a second time.

**Then watch it.** A pull request is not handed off when it's opened; the work
continues there. Review comments, review bots and CI results are instructions
in exactly the way a prompt in the session is — the only difference is where
they arrive — so read them and act: push the fix, or say plainly why it isn't
one. Nothing is waiting for a prompt to repeat what a reviewer already said.

Red CI or a merge conflict is work now, whatever the review state; only a
green, mergeable branch is waiting on anyone. Keep watching until it merges or
closes.
