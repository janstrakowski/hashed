package hashedbuild

import "core:fmt"
import "core:os"
import "core:strings"
import "core:bufio"

VERSION :: "0.1.0"

USAGE :: `Usage: hb [options] [file]
       hb dap

Runs the given HashedBuild source file, or starts a REPL if none is given.
hb dap speaks the Debug Adapter Protocol on stdin/stdout, for an editor to
drive - see GETTING_STARTED.md for what to put in a launch configuration.

Options:
  -a, --ast           Print the parsed AST before evaluating
  -e, --eval <expr>   Evaluate <expr> like one REPL submission and exit
      --dir <name>=<path>
                       Open <path> as ctx.dirs.<name>, a directory the
                       program may read and write inside. Repeatable
      --cache-dir <path>
                       Override where ctx.cache and cached keep
                       their entries (SPEC.md §15/§16)
  -h, --help           Print this help and exit
      --version        Print the version and exit

A program reaches the filesystem only through the directories named by --dir
(SPEC.md §9/§16): it can read and write inside them, by name, and cannot name
anything else - no absolute path, no "..", no symlink pointing out. A run that
names none cannot touch the filesystem at all.`

// What the CLI was asked to do, parsed out of argv as a plain value: no
// printing and no os.exit in here, so main stays a thin dispatch over the
// result and the whole flag surface is testable (main_test.odin).
Cli_Mode :: enum {
  Repl,    // no file and no -e: the read-eval-print loop
  File,    // run a source file
  Eval,    // -e/--eval: evaluate one expression, then exit
  Dap,     // `hb dap`: a debug adapter on stdin/stdout (dap.odin)
  Help,
  Version,
}

Cli_Options :: struct {
  mode:      Cli_Mode,
  show_ast:  bool,
  file_path: string,
  cache_dir: string, // "" means resolve the XDG default (SPEC.md §9/§16) instead
  eval_expr: string,
  // --dir <name>=<path>, in the order given: ctx.dirs (SPEC.md §9), and the
  // whole of what a program can reach. Empty means it reaches nothing.
  named_dirs: [dynamic]Named_Dir,
}

// -h/--version win wherever they appear (`hb -i --help` prints help rather
// than opening the editor), which is what exiting on sight used to do.
parse_args :: proc(args: []string) -> (opts: Cli_Options, err_msg: string, ok: bool) {
  has_eval := false
  want_dap := false
  want_help := false
  want_version := false

  for i := 0; i < len(args); i += 1 {
    switch args[i] {
    case "-h", "--help":
      want_help = true
    case "--version":
      want_version = true
    case "-a", "--ast":
      opts.show_ast = true
    case "--cache-dir":
      i += 1
      if i >= len(args) do return opts, "--cache-dir requires a path argument", false
      opts.cache_dir = args[i]
    case "--dir":
      i += 1
      if i >= len(args) do return opts, "--dir requires a <name>=<path> argument", false
      // Split at the *first* "=", so a path may contain one and a name may
      // not - which is what makes the name the part in front of it.
      eq := strings.index_byte(args[i], '=')
      if eq < 0 {
        return opts, fmt.tprintf("--dir %s needs a name: --dir <name>=<path>", args[i]), false
      }
      name := args[i][:eq]
      path := args[i][eq + 1:]
      if name == "" do return opts, fmt.tprintf("--dir %s has an empty name", args[i]), false
      if path == "" do return opts, fmt.tprintf("--dir %s has an empty path", args[i]), false
      for existing in opts.named_dirs {
        if existing.name == name {
          return opts, fmt.tprintf("--dir %s= given twice", name), false
        }
      }
      append(&opts.named_dirs, Named_Dir{name = name, path = path})
    case "-e", "--eval":
      i += 1
      if i >= len(args) do return opts, "-e/--eval requires an expression argument", false
      opts.eval_expr = args[i]
      has_eval = true
    case "dap":
      // A subcommand, not a flag: it takes over stdin and stdout entirely,
      // and everything a session needs arrives in the client's `launch`
      // request rather than on this command line (dap.odin).
      want_dap = true
    case:
      if strings.has_prefix(args[i], "-") {
        return opts, fmt.tprintf("unknown option %s (see --help)", args[i]), false
      }
      if opts.file_path == "" do opts.file_path = args[i] // extra positionals are ignored
    }
  }

  switch {
  case want_help:
    opts.mode = .Help
  case want_version:
    opts.mode = .Version
  case want_dap:
    if has_eval do return opts, "hb dap cannot be combined with -e/--eval", false
    if opts.file_path != "" do return opts, "hb dap takes no file - the client's launch request names one", false
    opts.mode = .Dap
  case has_eval:
    if opts.file_path != "" do return opts, "-e/--eval cannot be combined with a file argument", false
    opts.mode = .Eval
  case opts.file_path != "":
    opts.mode = .File
  case:
    opts.mode = .Repl
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
  case .Version:
    fmt.println("hb", VERSION)
  case .Eval:
    eval_once(opts.eval_expr, opts.show_ast, opts)
  case .Dap:
    run_dap_server(opts)
  case .File:
    run_file(opts.file_path, opts.show_ast, opts)
  case .Repl:
    run_eval_repl(opts.show_ast, opts)
  }
}

// Runs a HashedBuild source file as a real program, printing the result -
// `hb <file>`. Every failure here is fatal to the process; eval_source_file
// below is the same work without the printing or the exiting.
run_file :: proc(path_str: string, show_ast: bool, opts: Cli_Options) {
  dirs, dir_err, dir_ok := open_root_dirs(opts.cache_dir, opts.named_dirs[:])
  if !dir_ok {
    fmt.eprintfln("error: %s", dir_err)
    os.exit(1)
  }
  defer close_root_dirs(dirs)

  formatted, err_msg, ok := eval_source_file(path_str, show_ast, dirs)
  if !ok {
    // An empty message means the parse errors were already printed as part
    // of the AST, which is the only way to make sense of them.
    if err_msg != "" do fmt.eprintfln("error: %s", err_msg)
    os.exit(1)
  }
  defer delete(formatted)
  fmt.println(formatted)
}

// Read, parse, evaluate, format - the whole of running a source file, minus
// the two things a test can't live with (printing and os.exit). The global
// scope has the filesystem builtins (§16) bound in and the root context
// grants `io` by default (§9) - the same environment the REPL and the live
// editor evaluate under. Split out of run_file so the examples can be run
// end to end as tests (examples_test.odin).
eval_source_file :: proc(path_str: string, show_ast: bool, dirs: Root_Dirs) -> (formatted: string, err_msg: string, ok: bool) {
  source, errno := load_source_file(path_str)
  if errno != .None {
    return "", fmt.tprintf("could not read %s (%v)", path_str, errno), false
  }
  defer free_source_file(source)

  src := string(source.data[:source.n_bytes])
  ast := parse(source, ast_t{})
  defer ast_destroy(&ast)

  if show_ast {
    print_ast(&ast, src)
  }
  if len(ast.errors) > 0 {
    if !show_ast do print_ast(&ast, src) // errors always need the tree to make sense of them
    return "", "", false
  }

  interp := Interpreter{ast = &ast, src = src, current_ctx = make_root_context(dirs)}
  // eval_program, not eval: it also resolves a bare top-level `async` (§2)
  // and waits for any task nothing awaited, so the program can't exit with
  // work half-done (eval_async.odin).
  val, eval_ok := eval_program(&interp, ast.root, make_global_env())
  if !eval_ok {
    return "", strings.clone(interp.error_message), false
  }
  return format_value(val), "", true
}

// A real read-eval-print loop: accumulates lines into a snippet, evaluates it
// once you hit an empty line, and prints the resulting value (or the parse/
// runtime error). `:q`/`:quit`/`:exit` (on their own line, nothing else
// buffered) ends the session. Works the same whether stdin is a terminal or
// piped - unlike the two-pane editor, it needs no raw terminal mode. With
// `-a`/`--ast`, the AST is printed above the value on every evaluation too.
run_eval_repl :: proc(show_ast: bool, opts: Cli_Options) {
  // Opened once for the session, not once per submission: each is a real
  // descriptor, and a fresh set per line typed would leak one per line.
  dirs, dir_err, dir_ok := open_root_dirs(opts.cache_dir, opts.named_dirs[:])
  if !dir_ok {
    fmt.eprintfln("error: %s", dir_err)
    os.exit(1)
  }
  defer close_root_dirs(dirs)

  fmt.println("HashedBuild REPL")
  fmt.println("Type an expression, then an empty line to evaluate it. ':q' to quit.")
  fmt.println()

  scanner: bufio.Scanner
  bufio.scanner_init(&scanner, os.to_stream(os.stdin))
  defer bufio.scanner_destroy(&scanner)

  builder: strings.Builder
  strings.builder_init(&builder)
  defer strings.builder_destroy(&builder)

  for {
    if strings.builder_len(builder) == 0 {
      fmt.print("hb> ")
    } else {
      fmt.print("... ")
    }

    if !bufio.scanner_scan(&scanner) do break // EOF or read error
    line := bufio.scanner_text(&scanner)
    trimmed := strings.trim_space(line)

    if strings.builder_len(builder) == 0 {
      if trimmed == ":q" || trimmed == ":quit" || trimmed == ":exit" do break
      if trimmed == "" do continue // blank line, nothing buffered yet - just reprompt
    }

    if trimmed == "" {
      eval_and_print(strings.to_string(builder), show_ast, dirs)
      strings.builder_reset(&builder)
      continue
    }

    strings.write_string(&builder, line)
    strings.write_byte(&builder, '\n')
  }

  if strings.builder_len(builder) > 0 {
    eval_and_print(strings.to_string(builder), show_ast, dirs) // evaluate whatever's left at EOF
  }
  fmt.println()
}

// Evaluates one expression given on the command line (-e/--eval) exactly like
// a single REPL submission, then exits: parse errors and runtime errors take
// the same exit codes run_file uses for them.
@(private = "file")
eval_once :: proc(src: string, show_ast: bool, opts: Cli_Options) {
  dirs, dir_err, dir_ok := open_root_dirs(opts.cache_dir, opts.named_dirs[:])
  if !dir_ok {
    fmt.eprintfln("error: %s", dir_err)
    os.exit(1)
  }
  defer close_root_dirs(dirs)

  source := source_t{name = "<eval>", n_bytes = u64(len(src)), data = raw_data(src)}
  ast := parse(source, ast_t{})
  defer ast_destroy(&ast)

  if show_ast {
    print_ast(&ast, src)
  }
  if len(ast.errors) > 0 {
    if !show_ast do print_ast(&ast, src) // errors always need the tree to make sense of them
    os.exit(1)
  }

  interp := Interpreter{ast = &ast, src = src, current_ctx = make_root_context(dirs)}
  env := make_global_env()
  val, ok := eval_program(&interp, ast.root, env)
  if !ok {
    fmt.eprintfln("error: %s", interp.error_message)
    os.exit(1)
  }
  formatted := format_value(val)
  defer delete(formatted)
  fmt.println(formatted)
}

@(private = "file")
eval_and_print :: proc(src: string, show_ast: bool, dirs: Root_Dirs) {
  source := source_t{name = "<repl>", n_bytes = u64(len(src)), data = raw_data(src)}
  ast := parse(source, ast_t{})
  defer ast_destroy(&ast)

  if show_ast {
    print_ast(&ast, src)
  }

  if len(ast.errors) > 0 {
    if !show_ast do print_ast(&ast, src) // errors always need the tree to make sense of them
    return
  }

  interp := Interpreter{ast = &ast, src = src, current_ctx = make_root_context(dirs)}
  env := make_global_env()
  val, ok := eval_program(&interp, ast.root, env)
  if !ok {
    fmt.printfln("error: %s", interp.error_message)
    return
  }
  formatted := format_value(val)
  defer delete(formatted)
  fmt.println(formatted)
}
