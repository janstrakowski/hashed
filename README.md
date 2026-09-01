This project is still being developed, even without the core features.
The "README" below is a faked proof-of-concept, meant only to show what I'm heading for approximately.

---

# About

*HashedBuild* helps you describe and instantiate Linux operating systems (and more) with code. It features:
 - output reproducibility (one specific input results in one specific output),
 - incremental updates (a small change should take shorter to build, a big change - longer),
 - standard compliance (what is used here is used also in many other projects),
 - an extensible design (anyone interested is able to write himself/herself any extra features),
 - a standard library (the most common operations are already bulit-in).

See also [NixOS](https://nixos.org/) and [Guix](https://guix.gnu.org/).

# Progress

`hb` is a small CLI: run a program, evaluate an expression, a REPL, and a debug adapter.

```
$ hb --dir here=examples examples/guard-chain.hb   run a program
$ hb -e '1 + 2 * 3'                                evaluate an expression
$ hb                                               the REPL
$ hb dap                                           the debugger, over DAP
```

Debugging is the [Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/) - the same protocol VS Code, nvim-dap, emacs `dape` and Zed already speak, and that GDB itself now exposes - so breakpoints, a call stack and a variables pane come from an editor you already use rather than from a UI shipped here. **[GETTING_STARTED.md](GETTING_STARTED.md)** has the few lines of configuration each one needs.

A real parser and tree-walking evaluator exist now (`src/`, with a full test suite), covering the core expression language - functions, pattern matching, guard chains, real concurrency (`async`, running on actual OS threads) - plus a small set of filesystem builtins with capability-scoped permissions and a genuinely pausable/resumable debugger exposed over the Debug Adapter Protocol. Unlike the aspirational examples further down, the program below actually runs:

```hashedbuild
// examples/option-picker.hb - reads choice.txt out of ctx.dirs.here, the
// directory the command line handed this program, then branches on its exact
// content. "option A" writes an entry starting with "Option A:" followed by
// optiona.txt's content; "option B" does the analogous thing with
// optionb.txt; anything else is an unrecoverable runtime error. The result
// goes into ctx.cache, which names it by its own content hash.
let choice loadfile { .dir = ctx.dirs.here, .path = "choice.txt" } |> filetext;
  choice == "option A" then
    createfile {
      .dir = ctx.cache,
      .content = "Option A:\n" concat filetext (loadfile { .dir = ctx.dirs.here, .path = "optiona.txt" }),
    }
  else choice == "option B" then
    createfile {
      .dir = ctx.cache,
      .content = "Option B:\n" concat filetext (loadfile { .dir = ctx.dirs.here, .path = "optionb.txt" }),
    }
  else
    error "choice.txt must contain exactly \"option A\" or \"option B\""
```

Run it with `./hb --dir here=examples examples/option-picker.hb` - a program reaches exactly the directories the command line names and nothing else, which is why its inputs are visible in how you run it (the example carries that line in its own header, as every example that touches the filesystem does). Or step through it in your editor with `./hb dap` (see [GETTING_STARTED.md](GETTING_STARTED.md)). This one example touches a few of the language's actual design points: files are ordinary values reached through directory handles rather than paths (`loadfile`/`createfile`), branching is built from general composable operators rather than bespoke syntax (`then`/`else` chains into an if/else-if/else), and `error` is a genuinely unrecoverable failure - unlike a failed `then`, no enclosing `else` catches it.

**[LANGUAGE.md](LANGUAGE.md)** is the tour of everything that works today, feature by feature, with a runnable snippet for each and an explicit list of what isn't built yet. **[examples/](examples/)** has a runnable file per feature - all of them executed by the test suite, so they can't drift from the implementation. `SPEC.md` is the full design, including the parts that don't run yet.

# Examples

The examples below are still aspirational - illustrative of where this is heading, not runnable in the language as it exists today.

## `XZ Utils 5.8.3`
```hashedbuild
gnulinux.containerbuild {
    archive = {
        downloadurl = "https://github.com/tukaani-project/xz/releases/download/v5.8.3/xz-5.8.3.tar.gz",
        sha256 = "CTtEvdGgLSf0FZ86UMI0jbd4rRzCPh9FFAdu8ix3Eyg=",
    },
    packages = { gnulinux.stdpkgs.{ autoconf, automake, gettext, libtool } },
    builder = gnulinux.configuremakeinstall {},
}
```

## "Hello, World!" on [Arduino](https://www.arduino.cc/)
```hashedbuild
let
    programtext = """
        void setup() {
          pinMode(LED_BUILTIN, OUTPUT);
        }

        void loop() {
          digitalWrite(LED_BUILTIN, HIGH);
          delay(1000);
          digitalWrite(LED_BUILTIN, LOW);
          delay(1000);
        }
    """
: arduino.deployment {
    inofiles = { fileFromText programtext },
}
```

# Donate
You can support me by a donation via: [a bank transfer](https://janstrakowski.github.io/jansdonations/) or [BuyMeACoffie](https://buymeacoffee.com/janstrakowski).
