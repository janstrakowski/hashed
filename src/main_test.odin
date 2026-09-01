// Tests run natively, never in a WASI build: core:testing pulls in
// core:log and core:terminal, neither of which compiles for wasm32.
#+build linux, windows
package hashedbuild

import "core:strings"
import "core:testing"

// parse_args (main.odin) is the whole CLI surface as a pure function: these
// cover each flag, each way of getting the argument wrong, and the
// precedence rules between flags that can't be combined.

@(test)
test_parse_args_defaults_to_repl :: proc(t: ^testing.T) {
  opts, _, ok := parse_args([]string{})
  testing.expect(t, ok)
  testing.expect_value(t, opts.mode, Cli_Mode.Repl)
  testing.expect_value(t, opts.show_ast, false)
  testing.expect_value(t, opts.cache_dir, "")
}

@(test)
test_parse_args_file_and_ast_flag :: proc(t: ^testing.T) {
  opts, _, ok := parse_args([]string{"prog.hb"})
  testing.expect(t, ok)
  testing.expect_value(t, opts.mode, Cli_Mode.File)
  testing.expect_value(t, opts.file_path, "prog.hb")

  with_ast, _, ok2 := parse_args([]string{"-a", "prog.hb"})
  testing.expect(t, ok2)
  testing.expect_value(t, with_ast.mode, Cli_Mode.File)
  testing.expect_value(t, with_ast.show_ast, true)

  // A second positional is ignored rather than being an error.
  two_files, _, ok3 := parse_args([]string{"first.hb", "second.hb"})
  testing.expect(t, ok3)
  testing.expect_value(t, two_files.file_path, "first.hb")
}

@(test)
test_parse_args_eval_expression :: proc(t: ^testing.T) {
  short, _, ok := parse_args([]string{"-e", "1 + 1"})
  testing.expect(t, ok)
  testing.expect_value(t, short.mode, Cli_Mode.Eval)
  testing.expect_value(t, short.eval_expr, "1 + 1")

  long, _, ok2 := parse_args([]string{"--eval", "1 + 1"})
  testing.expect(t, ok2)
  testing.expect_value(t, long.mode, Cli_Mode.Eval)
  testing.expect_value(t, long.eval_expr, "1 + 1")

  // An expression starting with '-' is still an argument, not a flag.
  negative, _, ok3 := parse_args([]string{"-e", "-1 + 2"})
  testing.expect(t, ok3)
  testing.expect_value(t, negative.eval_expr, "-1 + 2")
}

@(test)
test_parse_args_flags_needing_an_argument_reject_a_missing_one :: proc(t: ^testing.T) {
  _, eval_err, eval_ok := parse_args([]string{"-e"})
  testing.expect(t, !eval_ok, "-e with nothing after it must be an error")
  testing.expect(t, strings.contains(eval_err, "-e/--eval"))

  _, cache_err, cache_ok := parse_args([]string{"--cache-dir"})
  testing.expect(t, !cache_ok, "--cache-dir with nothing after it must be an error")
  testing.expect(t, strings.contains(cache_err, "--cache-dir"))

  _, dir_err, dir_ok := parse_args([]string{"--dir"})
  testing.expect(t, !dir_ok, "--dir with nothing after it must be an error")
  testing.expect(t, strings.contains(dir_err, "--dir"))
}

// One flag, two jobs (SPEC.md §9): a bare path is ctx.dir, a <name>=<path> is
// an entry in ctx.dirs. The "=" is what tells them apart, and it is the first
// one, so a path may contain another.
@(test)
test_parse_args_dir_is_the_main_directory_or_a_named_one :: proc(t: ^testing.T) {
  main_only, _, ok := parse_args([]string{"--dir", "build/out", "prog.hb"})
  testing.expect(t, ok)
  testing.expect_value(t, main_only.main_dir, "build/out")
  testing.expect_value(t, len(main_only.named_dirs), 0)
  testing.expect(t, !main_only.no_main_dir)

  named, _, ok2 := parse_args([]string{"--dir", "src=./src", "--dir", "out=/tmp/o=1", "prog.hb"})
  testing.expect(t, ok2)
  testing.expect_value(t, named.main_dir, "") // untouched: neither of these is the main one
  testing.expect_value(t, len(named.named_dirs), 2)
  if len(named.named_dirs) == 2 {
    testing.expect_value(t, named.named_dirs[0].name, "src")
    testing.expect_value(t, named.named_dirs[0].path, "./src")
    testing.expect_value(t, named.named_dirs[1].name, "out")
    testing.expect_value(t, named.named_dirs[1].path, "/tmp/o=1") // split at the *first* "="
  }
}

@(test)
test_parse_args_rejects_a_malformed_or_repeated_dir :: proc(t: ^testing.T) {
  _, empty_name_err, empty_name_ok := parse_args([]string{"--dir", "=/tmp"})
  testing.expect(t, !empty_name_ok, "a named --dir needs a name")
  testing.expect(t, strings.contains(empty_name_err, "empty name"))

  _, empty_path_err, empty_path_ok := parse_args([]string{"--dir", "src="})
  testing.expect(t, !empty_path_ok, "a named --dir needs a path")
  testing.expect(t, strings.contains(empty_path_err, "empty path"))

  // Two handles under one name would leave which one wins to table_find.
  _, dup_err, dup_ok := parse_args([]string{"--dir", "src=./a", "--dir", "src=./b"})
  testing.expect(t, !dup_ok, "one name, two directories, is a contradiction")
  testing.expect(t, strings.contains(dup_err, "twice"))
}

// --no-default-dir says the program gets no ctx.dir; --dir <path> says which
// one it gets. Together they say nothing coherent, so neither is silently
// preferred (SPEC.md §9).
@(test)
test_parse_args_no_default_dir :: proc(t: ^testing.T) {
  opts, _, ok := parse_args([]string{"--no-default-dir", "prog.hb"})
  testing.expect(t, ok)
  testing.expect(t, opts.no_main_dir)

  // A *named* directory is not the main one, so it combines fine: this is how
  // a program is given handles and no default at all.
  with_named, _, ok2 := parse_args([]string{"--no-default-dir", "--dir", "src=./src", "prog.hb"})
  testing.expect(t, ok2)
  testing.expect(t, with_named.no_main_dir)
  testing.expect_value(t, len(with_named.named_dirs), 1)

  _, err, conflict_ok := parse_args([]string{"--no-default-dir", "--dir", "./x", "prog.hb"})
  testing.expect(t, !conflict_ok, "--dir <path> and --no-default-dir contradict each other")
  testing.expect(t, strings.contains(err, "--no-default-dir"))
}

@(test)
test_parse_args_cache_dir :: proc(t: ^testing.T) {
  opts, _, ok := parse_args([]string{"--cache-dir", "/tmp/hbcache", "prog.hb"})
  testing.expect(t, ok)
  testing.expect_value(t, opts.cache_dir, "/tmp/hbcache")
  testing.expect_value(t, opts.mode, Cli_Mode.File)
  testing.expect_value(t, opts.file_path, "prog.hb")
}

@(test)
test_parse_args_rejects_unknown_option :: proc(t: ^testing.T) {
  _, err, ok := parse_args([]string{"--nope"})
  testing.expect(t, !ok, "an unknown option must be an error, not a file name")
  testing.expect(t, strings.contains(err, "unknown option"))
}

@(test)
test_parse_args_help_and_version_win_over_other_flags :: proc(t: ^testing.T) {
  for args in ([][]string{{"-h"}, {"--help"}, {"-i", "--help"}, {"--help", "prog.hb"}}) {
    opts, _, ok := parse_args(args)
    testing.expect(t, ok)
    testing.expect_value(t, opts.mode, Cli_Mode.Help)
  }

  version, _, ok := parse_args([]string{"--version"})
  testing.expect(t, ok)
  testing.expect_value(t, version.mode, Cli_Mode.Version)
}

@(test)
test_parse_args_eval_cannot_combine_with_editor_or_file :: proc(t: ^testing.T) {
  _, editor_err, editor_ok := parse_args([]string{"-e", "1", "-i"})
  testing.expect(t, !editor_ok, "-e and -i are mutually exclusive")
  testing.expect(t, strings.contains(editor_err, "interactive"))

  _, file_err, file_ok := parse_args([]string{"-e", "1", "prog.hb"})
  testing.expect(t, !file_ok, "-e and a file argument are mutually exclusive")
  testing.expect(t, strings.contains(file_err, "file"))
}

@(test)
test_parse_args_interactive_selects_the_editor :: proc(t: ^testing.T) {
  opts, _, ok := parse_args([]string{"-i"})
  testing.expect(t, ok)
  testing.expect_value(t, opts.mode, Cli_Mode.Editor)

  long, _, ok2 := parse_args([]string{"--interactive"})
  testing.expect(t, ok2)
  testing.expect_value(t, long.mode, Cli_Mode.Editor)
}
