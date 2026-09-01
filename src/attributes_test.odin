// Tests run natively, never in a WASI build - see eval_test.odin.
#+build linux, windows
package hashedbuild

import "core:strings"
import "core:testing"

// SPEC.md §17: the prologue that says how a program is *run*. These pin the
// three things a reader has to be able to rely on - where a prologue ends,
// that a mistake in one is reported rather than ignored, and how it combines
// with a command line that says something different.

@(private = "file")
scan :: proc(src: string) -> Attributes {
  return scan_attributes(src)
}

@(test)
test_attributes_are_read_in_order :: proc(t: ^testing.T) {
  a := scan("#Directory here .\n#Directory src ../src\n\n1 + 2\n")
  defer attributes_destroy(&a)

  testing.expect_value(t, len(a.errors), 0)
  testing.expect_value(t, len(a.list), 2)
  if len(a.list) != 2 do return
  testing.expect_value(t, a.list[0].kind, Attribute_Kind.Directory)
  testing.expect_value(t, a.list[0].args[0], "here")
  testing.expect_value(t, a.list[0].args[1], ".")
  testing.expect_value(t, a.list[1].args[0], "src")
  testing.expect_value(t, a.list[1].args[1], "../src")
}

// A directive ends at a line break or a `;`, so two can share a line.
@(test)
test_a_semicolon_ends_a_directive :: proc(t: ^testing.T) {
  a := scan("#Directory a .; #Directory b ../b\n1\n")
  defer attributes_destroy(&a)
  testing.expect_value(t, len(a.errors), 0)
  testing.expect_value(t, len(a.list), 2)
}

// The prologue is over at the first thing that is not a directive, and what
// follows is the program - including a `#arg`, which is an expression.
@(test)
test_the_prologue_ends_where_the_program_begins :: proc(t: ^testing.T) {
  src := "#Directory here .\n\nfunc (#arg + 1)\n"
  a := scan(src)
  defer attributes_destroy(&a)
  testing.expect_value(t, len(a.list), 1)
  rest := strings.trim_space(src[a.consumed:])
  testing.expect_value(t, rest, "func (#arg + 1)")
}

// §9's implicit names begin with a lower-case letter and attributes with a
// capital, which is what keeps `#arg` a program and `#Directory` a directive.
// A program that *is* `#arg` has no prologue at all.
@(test)
test_a_lowercase_hash_is_an_expression_not_an_attribute :: proc(t: ^testing.T) {
  a := scan("#arg + 1")
  defer attributes_destroy(&a)
  testing.expect_value(t, len(a.list), 0)
  testing.expect_value(t, len(a.errors), 0)
  testing.expect_value(t, a.consumed, 0)
}

// A comment may sit among the directives, or before them.
@(test)
test_comments_may_sit_in_the_prologue :: proc(t: ^testing.T) {
  a := scan("// what this program is\n#Directory here .\n// and why\n#Cache-Dir ./c\n\n1\n")
  defer attributes_destroy(&a)
  testing.expect_value(t, len(a.errors), 0)
  testing.expect_value(t, len(a.list), 2)
}

// A misspelling is a mistake, not a directive that quietly does nothing -
// which is the whole reason these are syntax rather than a comment convention.
@(test)
test_an_unknown_attribute_is_an_error :: proc(t: ^testing.T) {
  a := scan("#Directoy here .\n1\n")
  defer attributes_destroy(&a)
  testing.expect_value(t, len(a.errors), 1)
  if len(a.errors) == 1 {
    testing.expect(t, strings.contains(a.errors[0].message, "#Directoy"), a.errors[0].message)
  }
}

@(test)
test_wrong_arity_is_an_error :: proc(t: ^testing.T) {
  a := scan("#Directory here\n1\n")
  defer attributes_destroy(&a)
  testing.expect_value(t, len(a.errors), 1)
  if len(a.errors) == 1 {
    testing.expect(t, strings.contains(a.errors[0].message, "<name> <path>"), a.errors[0].message)
  }
}

// The parser reports them like any other parse error, which is what makes the
// program refuse to run rather than run with a directive nobody applied.
@(test)
test_the_parser_reports_attribute_errors :: proc(t: ^testing.T) {
  src := "#Nonsense x\n1 + 2\n"
  ast := parse(source_t{name = "test", n_bytes = u64(len(src)), data = raw_data(src)}, ast_t{})
  defer ast_destroy(&ast)
  testing.expect(t, len(ast.errors) > 0, "an unknown attribute must fail the parse")
}

// ---- how a file and a command line combine (§17) -------------------------------

@(private = "file")
resolve :: proc(src: string, cli: []Named_Dir, override: bool) -> (Run_Inputs, string, bool) {
  a := scan_attributes(src)
  defer attributes_destroy(&a)
  return resolve_run_inputs(a, "/base", cli, "", override)
}

@(test)
test_a_file_that_declares_nothing_takes_the_command_line :: proc(t: ^testing.T) {
  cli := []Named_Dir{{name = "here", path = "/tmp/x"}}
  inputs, _, ok := resolve("1 + 2", cli, false)
  testing.expect(t, ok)
  defer run_inputs_destroy(inputs)
  testing.expect_value(t, len(inputs.named_dirs), 1)
  testing.expect_value(t, inputs.named_dirs[0].path, "/tmp/x")
}

// Paths in a file are relative to the file, which is what lets an example run
// from anywhere.
@(test)
test_a_files_paths_resolve_against_the_file :: proc(t: ^testing.T) {
  inputs, _, ok := resolve("#Directory here .\n1", nil, false)
  testing.expect(t, ok)
  defer run_inputs_destroy(inputs)
  testing.expect_value(t, len(inputs.named_dirs), 1)
  testing.expect_value(t, inputs.named_dirs[0].path, "/base")
}

// Both sides setting inputs is refused outright - not merged, and not silently
// resolved in either direction.
@(test)
test_a_file_and_a_command_line_that_disagree_is_refused :: proc(t: ^testing.T) {
  cli := []Named_Dir{{name = "other", path = "/tmp/x"}}
  _, err, ok := resolve("#Directory here .\n1", cli, false)
  testing.expect(t, !ok, "even a different name is a conflict: the two disagree about who decides")
  testing.expect(t, strings.contains(err, "--override"), err)
}

// With --override the file is read and the command line applied on top, name
// by name - and an empty path removes what the file declared.
@(test)
test_override_applies_the_command_line_on_top :: proc(t: ^testing.T) {
  cli := []Named_Dir{{name = "d1", path = ""}, {name = "d2", path = "/tmp/three"}}
  inputs, _, ok := resolve("#Directory d1 one\n#Directory d2 two\n1", cli, true)
  testing.expect(t, ok)
  defer run_inputs_destroy(inputs)

  testing.expect_value(t, len(inputs.named_dirs), 1)
  if len(inputs.named_dirs) == 1 {
    testing.expect_value(t, inputs.named_dirs[0].name, "d2")
    testing.expect_value(t, inputs.named_dirs[0].path, "/tmp/three")
  }
}

// Without a file to override, an empty path has nothing to remove and is
// ignored rather than refused.
@(test)
test_an_empty_path_is_ignored_when_there_is_nothing_to_remove :: proc(t: ^testing.T) {
  cli := []Named_Dir{{name = "here", path = ""}}
  inputs, _, ok := resolve("1 + 2", cli, false)
  testing.expect(t, ok)
  defer run_inputs_destroy(inputs)
  testing.expect_value(t, len(inputs.named_dirs), 0)
}
