# hashmake

A build tool whose build files are HashedBuild programs.

`hashmake` looks for a `hashmake.hb` in the current directory, evaluates it to a
dependency graph, orders the graph, refuses cycles, and calls each node with
what it asked for. That is the whole of it — in particular it has **no cache of
its own**. Incremental rebuilds come from the language: a node wraps its own
work in `cached` (SPEC.md §15), whose key is the code plus the *values* it
reads, and a `File` is its content (§3). There are no timestamps in this
program.

## Building it

```sh
odin build tools/hashmake -out:hashmake
```

It imports `src` (the interpreter) directly, so there is nothing to install and
nothing to keep in sync — the tool and the language are built from the same
tree.

## Usage

```
hashmake [options] [target...]

  -C, --directory <dir>  Run as if started in <dir>
  -f, --file <path>      The build file (default: hashmake.hb)
  -n, --dry-run          Print the order targets would be built in, and stop
      --graph            Print the dependency graph, and stop
      --allow-any-path   Let the build file resolve paths outside its own directory
      --cache-dir <path> Where cached entries are kept
  -h, --help / --version
```

With no target, the graph's `.default` is built.

## What a `hashmake.hb` must evaluate to

A HashedBuild program is one expression, and this one evaluates to:

```hashedbuild
{
  .default = "run",
  .targets = {
    .<name> = {
      .needs = { .<alias> = "<target-name>", ... },   // may be `empty`
      .build = <function>,                            // prerequisites -> artifact
    },
    ...
  },
}
```

- **`.needs` maps a local alias to the name of the target that produces it.**
  hashmake builds each dependency first and hands `.build` exactly
  `{ alias -> artifact }` — never a path, and never a filename to look up.
- **`.build` returns the artifact**, which is a `File`.
- **A target that returns something other than a `File` has produced no
  artifact.** That is allowed and useful — a "run" target exists for its effect
  — but nothing may depend on one, and hashmake says so rather than passing a
  non-artifact along. If it returns `Utf8`, hashmake prints it, which is how a
  run target's output reaches your terminal.
- A bare `Table` of targets is accepted too, if you don't need `.default`.

## What it enforces

- **Cycles are refused before anything is built**, and named in full:
  `error: dependency cycle: a -> b -> c -> a`. `--graph` and `-n` check this too,
  so you can find a loop without running a compiler.
- **A `.needs` naming a target that doesn't exist** is a clean error, not a
  crash.
- **The build file is contained to its own directory.** hashmake evaluates it
  with `ctx.dir` set to the build file's directory and only the `workdir`
  permission (SPEC.md §9), so `loadfile "../../etc/passwd"` fails. Pass
  `--allow-any-path` when a build genuinely needs to reach outside.

  This bounds what the *build description* can read. It does not bound what a
  compiler it starts can read — see `exec`'s note in SPEC.md §16.

## Caching, and what invalidates what

Nothing is cached unless a node asks. A node that wants to be looks like:

```hashedbuild
.build = (let prereqs; cached (
  let r exec { .cmd = "clang", .args = { ... }, .inputs = { ... }, .outputs = { "x.o" } };
  check(r.status == 0, "clang failed") r.outputs["x.o"]))
```

Because `exec` takes its inputs as `File` values and returns its outputs as
`File` values, the cache key contains the *content* of every input. So editing
one source invalidates that object and everything downstream of it, and nothing
else. Restoring the file restores the hit — which is a thing a timestamp-based
tool cannot do.

`examples/hashmake/` is a worked example that builds a real C library this way.
