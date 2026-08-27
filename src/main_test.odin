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
