package hashedbuild

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// Every examples/*.hb runs the way `hb <file>` runs it (eval_source_file,
// main.odin) and is asserted against the value its own header comment
// documents. This is the only end-to-end coverage in the suite - parser,
// evaluator, async, and the filesystem builtins all at once - and it keeps
// the examples from rotting silently as the language moves underneath them.
//
// Paths are absolute because `odin test` doesn't promise a working
// directory, same as the fs builtin tests.

@(private = "file")
REPO :: "/home/janst/hashedbuild"

@(private = "file")
Example_Case :: struct {
  file:     string,
  expected: string, // exactly what format_value should produce
}

@(test)
test_examples_evaluate_to_their_documented_values :: proc(t: ^testing.T) {
  cache := REPO + "/.examples_test_cache"
  defer remove_dir_and_entries(cache)
  // async-branching writes a marker for every branch it walks (§2), and
  // createfile is exclusive (§16), so leftovers from a previous run would
  // make it fail before it ever evaluated.
  clear_branch_markers()
  defer clear_branch_markers()

  cases := []Example_Case{
    {"async-basics.hb", `"This is the payload for option A.\nThis is the payload for option B.\n"`},
    {"async-branching.hb", `"medium"`},
    {"async-table.hb", `{a: 2, b: 6, c: "This is the payload for option A.\n"}`},
    {"functions.hb", "121"},
    {"guard-chain.hb", "5"},
    {"optional.hb", "42"},
    {"sequence-pattern.hb", "30"},
    {"table-and-concat.hb", `{archive: "https://example.com/x.tar.gz", sha256: "def456"}`},
    {"variant.hb", "42"},
  }

  for c in cases {
    path := fmt.tprintf("%s/examples/%s", REPO, c.file)
    formatted, err_msg, ok := eval_source_file(path, false, cache)
    if !testing.expect(t, ok, fmt.tprintf("%s failed to evaluate: %s", c.file, err_msg)) do continue
    defer delete(formatted)
    testing.expect_value(t, formatted, c.expected)
  }
}

// option-picker is the one example whose result isn't a fixed string: it
// writes into ctx.cache, so the File it evaluates to displays a
// content-addressed path (§3/§16) under whatever --cache-dir was given.
@(test)
test_example_option_picker_writes_into_the_cache :: proc(t: ^testing.T) {
  cache := REPO + "/.examples_test_picker_cache"
  defer remove_dir_and_entries(cache)

  path := REPO + "/examples/option-picker.hb"
  formatted, err_msg, ok := eval_source_file(path, false, cache)
  testing.expect(t, ok, err_msg)
  if !ok do return
  defer delete(formatted)

  // choice.txt says "option A", so the entry holds optiona.txt's content -
  // and it lands in the cache under its own hash, not at a named path.
  testing.expect(t, strings.has_prefix(formatted, fmt.tprintf("<file: %s/sha256_", cache)), formatted)

  entries := read_dir_names(cache)
  testing.expect_value(t, len(entries), 1)
  if len(entries) == 1 {
    content, read_err := os.read_entire_file(fmt.tprintf("%s/%s", cache, entries[0]), context.temp_allocator)
    testing.expect(t, read_err == nil)
    testing.expect_value(t, string(content), "Option A:\nThis is the payload for option A.\n")
  }
}

@(private = "file")
read_dir_names :: proc(dir: string) -> []string {
  handle, err := os.open(dir)
  if err != nil do return {}
  defer os.close(handle)
  entries, _ := os.read_dir(handle, -1, context.temp_allocator)
  names := make([]string, len(entries), context.temp_allocator)
  for entry, i in entries do names[i] = entry.name
  return names
}

@(private = "file")
remove_dir_and_entries :: proc(dir: string) {
  for name in read_dir_names(dir) do os.remove(fmt.tprintf("%s/%s", dir, name))
  os.remove(dir)
}

@(private = "file")
clear_branch_markers :: proc() {
  for branch in ([]string{"negative", "high", "medium", "low"}) {
    os.remove(fmt.tprintf("%s/examples/branch-%s.marker", REPO, branch))
  }
}
