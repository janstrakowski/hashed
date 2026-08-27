package hashedbuild

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:bufio"
import "core:sys/linux"

main :: proc() {
  interactive := false
  show_ast := false
  file_path := ""
  cache_dir := "" // "" means resolve the XDG default (SPEC.md §9/§16) instead
  args := os.args[1:]
  for i := 0; i < len(args); i += 1 {
    switch args[i] {
    case "-i", "--interactive":
      interactive = true
    case "-a", "--ast":
      show_ast = true
    case "--cache-dir":
      i += 1
      if i >= len(args) {
        fmt.eprintln("error: --cache-dir requires a path argument")
        os.exit(1)
      }
      cache_dir = args[i]
    case:
      if file_path == "" do file_path = args[i]
    }
  }

  if interactive {
    if !term_is_tty() {
      fmt.eprintln("error: -i/--interactive requires an interactive terminal")
      os.exit(1)
    }
    run_live_editor(cache_dir)
    return
  }

  if file_path != "" {
    run_file(file_path, show_ast, cache_dir)
    return
  }

  run_eval_repl(show_ast, cache_dir)
}

// Runs a HashedBuild source file as a real program: the global scope has the
// filesystem builtins (§16) bound in, and the root context grants `io` by
// default (§9) - same environment the REPL and live editor evaluate under.
run_file :: proc(path_str: string, show_ast: bool, cache_dir: string) {
  path := strings.clone_to_cstring(path_str, context.temp_allocator)
  source, errno := load_source_file(linux.AT_FDCWD, path)
  if errno != .NONE {
    fmt.eprintfln("error: could not read %s (%v)", path_str, errno)
    os.exit(1)
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
    os.exit(1)
  }

  interp := Interpreter{ast = &ast, src = src, current_ctx = make_root_context(cache_dir)}
  // Unsandboxed loadfile/createfile calls (no .dir given) resolve relative
  // paths against the source file's own directory, not the process's cwd -
  // filepath.dir returns "" (not ".") for a bare filename with no directory
  // component, which openat would reject, so normalize that case explicitly.
  dir_path := filepath.dir(path_str)
  if dir_path == "" do dir_path = "."
  dir_fd, dir_errno := linux.openat(linux.AT_FDCWD, strings.clone_to_cstring(dir_path, context.temp_allocator), {.DIRECTORY})
  if dir_errno == .NONE {
    interp.base_dir_fd = dir_fd
    interp.has_base_dir = true
  }

  env := make_global_env()
  val, ok := eval(&interp, ast.root, env)
  if ok do val, ok = await_value(&interp, val) // resolve a bare top-level `async <expr>` (§2)
  if !ok {
    fmt.eprintfln("error: %s", interp.error_message)
    os.exit(1)
  }
  formatted := format_value(val)
  defer delete(formatted)
  fmt.println(formatted)
}

// A real read-eval-print loop: accumulates lines into a snippet, evaluates it
// once you hit an empty line, and prints the resulting value (or the parse/
// runtime error). `:q`/`:quit`/`:exit` (on their own line, nothing else
// buffered) ends the session. Works the same whether stdin is a terminal or
// piped - unlike the two-pane editor, it needs no raw terminal mode. With
// `-a`/`--ast`, the AST is printed above the value on every evaluation too.
run_eval_repl :: proc(show_ast: bool, cache_dir: string) {
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
      eval_and_print(strings.to_string(builder), show_ast, cache_dir)
      strings.builder_reset(&builder)
      continue
    }

    strings.write_string(&builder, line)
    strings.write_byte(&builder, '\n')
  }

  if strings.builder_len(builder) > 0 {
    eval_and_print(strings.to_string(builder), show_ast, cache_dir) // evaluate whatever's left at EOF
  }
  fmt.println()
}

@(private = "file")
eval_and_print :: proc(src: string, show_ast: bool, cache_dir: string) {
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

  interp := Interpreter{ast = &ast, src = src, current_ctx = make_root_context(cache_dir)}
  env := make_global_env()
  val, ok := eval(&interp, ast.root, env)
  if ok do val, ok = await_value(&interp, val)
  if !ok {
    fmt.printfln("error: %s", interp.error_message)
    return
  }
  formatted := format_value(val)
  defer delete(formatted)
  fmt.println(formatted)
}
