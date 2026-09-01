package main

// hashmake - a build tool whose build files are HashedBuild programs.
//
// `hashmake.hb` evaluates to a graph. Every node is an ordinary function from
// its prerequisites to the artifact it builds, and `.needs` maps a local alias
// to the name of the target producing it, so a build function is handed
// exactly `{ alias -> artifact }` and never a path.
//
// What this tool does is deliberately small: find the build file, evaluate it,
// order the graph, refuse cycles, and call each node with what it asked for.
// It does no caching of its own - a node opts in by writing `cached` around
// its own work, and the language's content-addressed cache (SPEC.md §15) then
// gives correct incremental rebuilds, because an input is a File and a File is
// its content (§3). There are no timestamps in this program.
//
// Usage: odin build tools/hashmake -out:hashmake

import "core:fmt"
import "core:os"
import "core:strings"
import hb "../../src"

VERSION :: "0.1.0"

USAGE :: `Usage: hashmake [options] [target...]

Builds targets from the hashmake.hb in the current directory.
With no target, builds the graph's .default.

Options:
  -C, --directory <dir>  Run as if started in <dir>
  -f, --file <path>      The build file (default: hashmake.hb)
  -n, --dry-run          Print the order targets would be built in, and stop
      --graph            Print the dependency graph, and stop
      --allow-any-path   Let the build file resolve paths outside its own
                         directory (by default it is contained to it)
      --cache-dir <path> Where cached entries are kept
  -h, --help             Print this help and exit
      --version          Print the version and exit`

Mode :: enum { Build, Graph, Dry_Run, Help, Version }

Options :: struct {
  mode:           Mode,
  directory:      string,
  file:           string,
  cache_dir:      string,
  allow_any_path: bool,
  targets:        [dynamic]string,
}

// A pure function of argv, like hb's own parse_args: no printing and no
// os.exit in here, so main stays a thin dispatch and the whole flag surface is
// testable.
parse_args :: proc(args: []string) -> (opts: Options, err_msg: string, ok: bool) {
  opts.file = "hashmake.hb"
  want_help := false
  want_version := false
  graph := false
  dry_run := false

  for i := 0; i < len(args); i += 1 {
    switch args[i] {
    case "-h", "--help":
      want_help = true
    case "--version":
      want_version = true
    case "--graph":
      graph = true
    case "-n", "--dry-run":
      dry_run = true
    case "--allow-any-path":
      opts.allow_any_path = true
    case "-C", "--directory":
      i += 1
      if i >= len(args) do return opts, "-C/--directory requires a path argument", false
      opts.directory = args[i]
    case "-f", "--file":
      i += 1
      if i >= len(args) do return opts, "-f/--file requires a path argument", false
      opts.file = args[i]
    case "--cache-dir":
      i += 1
      if i >= len(args) do return opts, "--cache-dir requires a path argument", false
      opts.cache_dir = args[i]
    case:
      if strings.has_prefix(args[i], "-") {
        return opts, fmt.tprintf("unknown option %s (see --help)", args[i]), false
      }
      append(&opts.targets, args[i])
    }
  }

  switch {
  case want_help:    opts.mode = .Help
  case want_version: opts.mode = .Version
  case graph:
    if dry_run do return opts, "--graph cannot be combined with -n/--dry-run", false
    opts.mode = .Graph
  case dry_run:      opts.mode = .Dry_Run
  case:              opts.mode = .Build
  }
  return opts, "", true
}

main :: proc() {
  opts, err_msg, ok := parse_args(os.args[1:])
  if !ok {
    fmt.eprintfln("error: %s", err_msg)
    os.exit(1)
  }

  switch opts.mode {
  case .Help:
    fmt.println(USAGE)
    return
  case .Version:
    fmt.println("hashmake", VERSION)
    return
  case .Build, .Graph, .Dry_Run:
  }

  if opts.directory != "" {
    if os.set_working_directory(opts.directory) != nil {
      fmt.eprintfln("error: could not change to %s", opts.directory)
      os.exit(1)
    }
  }

  if !os.exists(opts.file) {
    fmt.eprintfln("error: no %s here (use -f to name one, or -C to run elsewhere)", opts.file)
    os.exit(1)
  }

  run := Run{opts = opts}
  eval_err, eval_ok := hb.eval_source_file_run(
    opts.file,
    hb.Run_Options{cache_dir = opts.cache_dir, contain_to_workdir = !opts.allow_any_path},
    on_graph,
    &run,
  )
  if !eval_ok {
    // An empty message means the parse errors were already printed as part of
    // the AST dump, exactly as hb does it.
    if eval_err != "" do fmt.eprintfln("error: %s", eval_err)
    os.exit(1)
  }
  if run.failed do os.exit(1)
}

// ---- the graph ----------------------------------------------------------------

Node :: struct {
  name:   string,
  needs:  ^hb.Table_Value, // alias -> target name (Utf8)
  build:  ^hb.Function_Value,
  built:  bool,
  result: hb.Value,
}

Run :: struct {
  opts:   Options,
  failed: bool,
  nodes:  map[string]^Node,
  order:  [dynamic]string, // targets in the order the graph declared them
  // Three-colour DFS: a name absent is white, `false` is grey (on the current
  // path, so meeting it again is a cycle) and `true` is black (done).
  visited: map[string]bool,
  path:    [dynamic]string, // the grey stack, so a cycle can be named in full
}

// Called with the value hashmake.hb evaluated to, while the AST behind its
// functions is still alive (see hb.Source_Value_Proc).
on_graph :: proc(interp: ^hb.Interpreter, value: hb.Value, userdata: rawptr) -> bool {
  run := (^Run)(userdata)

  root, is_table := value.(^hb.Table_Value)
  if !is_table {
    return fail(run, "the build file must evaluate to a Table of targets")
  }

  targets_val, has_targets := hb.table_find(root, "targets")
  targets, targets_ok := targets_val.(^hb.Table_Value)
  if !has_targets || !targets_ok {
    // A bare table of targets is accepted too - `.targets`/`.default` is the
    // fuller spelling, and this is the same graph with less ceremony.
    targets = root
  }

  for entry in targets.entries {
    name, name_ok := entry.key.(string)
    if !name_ok do continue
    if name == "default" do continue

    node_t, node_ok := entry.value.(^hb.Table_Value)
    if !node_ok {
      return fail(run, fmt.tprintf("target %s is not a Table", name))
    }
    build_val, has_build := hb.table_find(node_t, "build")
    build_fn, build_ok := build_val.(^hb.Function_Value)
    if !has_build || !build_ok {
      return fail(run, fmt.tprintf("target %s has no .build function", name))
    }
    needs_t: ^hb.Table_Value
    if needs_val, has_needs := hb.table_find(node_t, "needs"); has_needs {
      nt, needs_ok := needs_val.(^hb.Table_Value)
      if !needs_ok do return fail(run, fmt.tprintf("target %s has a .needs that is not a Table", name))
      needs_t = nt
    }

    node := new(Node)
    node.name = name
    node.needs = needs_t
    node.build = build_fn
    run.nodes[name] = node
    append(&run.order, name)
  }

  if len(run.nodes) == 0 do return fail(run, "the build file declares no targets")

  wanted := run.opts.targets[:]
  if len(wanted) == 0 {
    def, has_def := hb.table_find(root, "default")
    def_name, def_ok := def.(string)
    if has_def && def_ok {
      wanted = []string{def_name}
    } else if len(run.order) == 1 {
      wanted = []string{run.order[0]}
    } else {
      return fail(run, "no target given and the graph has no .default")
    }
  }
  for name in wanted {
    if name not_in run.nodes {
      return fail(run, fmt.tprintf("no such target: %s", name))
    }
  }

  // Cycles are refused before anything is built, so a bad graph costs nothing
  // and the error names the whole loop rather than one edge of it.
  for name in wanted {
    if !check_acyclic(run, name) do return false
  }

  switch run.opts.mode {
  case .Graph:
    print_graph(run)
    return true
  case .Dry_Run:
    for name in wanted {
      for step in build_order(run, name) do fmt.println(step)
    }
    return true
  case .Build, .Help, .Version:
  }

  for name in wanted {
    if _, ok := build(run, interp, name); !ok do return false
  }
  return true
}

@(private = "file")
fail :: proc(run: ^Run, msg: string) -> bool {
  fmt.eprintfln("error: %s", msg)
  run.failed = true
  return false
}

// ---- cycles -------------------------------------------------------------------

check_acyclic :: proc(run: ^Run, name: string) -> bool {
  done, seen := run.visited[name]
  if seen && done do return true
  if seen && !done {
    // `name` is grey: it is on the path we walked to get here.
    start := 0
    for step, i in run.path do if step == name { start = i; break }
    loop := make([dynamic]string, context.temp_allocator)
    for i in start ..< len(run.path) do append(&loop, run.path[i])
    append(&loop, name)
    return fail(run, fmt.tprintf("dependency cycle: %s", strings.join(loop[:], " -> ", context.temp_allocator)))
  }

  run.visited[name] = false
  append(&run.path, name)
  node := run.nodes[name]
  if node.needs != nil {
    for entry in node.needs.entries {
      dep, dep_ok := entry.value.(string)
      if !dep_ok {
        return fail(run, fmt.tprintf("target %s has a .needs entry that is not a target name", name))
      }
      if dep not_in run.nodes {
        return fail(run, fmt.tprintf("target %s needs %s, which no target produces", name, dep))
      }
      if !check_acyclic(run, dep) do return false
    }
  }
  pop(&run.path)
  run.visited[name] = true
  return true
}

// ---- building -----------------------------------------------------------------

build_order :: proc(run: ^Run, name: string) -> []string {
  out := make([dynamic]string, context.temp_allocator)
  seen := make(map[string]bool, context.temp_allocator)
  walk_order(run, name, &out, &seen)
  return out[:]
}

@(private = "file")
walk_order :: proc(run: ^Run, name: string, out: ^[dynamic]string, seen: ^map[string]bool) {
  if name in seen do return
  seen[name] = true
  node := run.nodes[name]
  if node.needs != nil {
    for entry in node.needs.entries {
      if dep, ok := entry.value.(string); ok do walk_order(run, dep, out, seen)
    }
  }
  append(out, name)
}

build :: proc(run: ^Run, interp: ^hb.Interpreter, name: string) -> (hb.Value, bool) {
  node := run.nodes[name]
  if node.built do return node.result, true

  // Prerequisites first, gathered into the Table the build function receives:
  // the alias it asked for, mapped to what that dependency actually produced.
  prereqs := new(hb.Table_Value)
  if node.needs != nil {
    for entry in node.needs.entries {
      alias, alias_ok := entry.key.(string)
      dep, dep_ok := entry.value.(string)
      if !alias_ok || !dep_ok do continue

      artifact, ok := build(run, interp, dep)
      if !ok do return nil, false
      // "Produces no artifact" is enforced here rather than by convention: a
      // target that answered with something other than a File has nothing for
      // a dependent to build from, and saying so beats passing it along.
      if _, is_file := artifact.(^hb.File_Value); !is_file {
        return nil, false_with(run, fmt.tprintf("%s needs %s, but %s produces no artifact", name, dep, dep))
      }
      append(&prereqs.entries, hb.Table_Entry_Value{key = alias, value = artifact})
    }
  }

  fmt.eprintfln("hashmake: %s", name)
  result, ok := hb.call_function(interp, node.build, prereqs)
  if !ok {
    // The interpreter has already recorded why; §8's failures are fatal, so
    // there is nothing to recover and the message is the whole story.
    return nil, false_with(run, interp.error_message)
  }
  node.result = result
  node.built = true

  // A target that answers with text has produced no artifact - it ran for its
  // effect - so show what it said. That is how the demo's own output reaches
  // the terminal.
  if text, is_text := result.(string); is_text && text != "" {
    fmt.print(text)
  }
  return result, true
}

@(private = "file")
false_with :: proc(run: ^Run, msg: string) -> bool {
  fail(run, msg)
  return false
}

print_graph :: proc(run: ^Run) {
  for name in run.order {
    node := run.nodes[name]
    if node.needs == nil || len(node.needs.entries) == 0 {
      fmt.printfln("%s", name)
      continue
    }
    deps := make([dynamic]string, context.temp_allocator)
    for entry in node.needs.entries {
      if dep, ok := entry.value.(string); ok do append(&deps, dep)
    }
    fmt.printfln("%s <- %s", name, strings.join(deps[:], ", ", context.temp_allocator))
  }
}
