// Tests run natively, never in a WASI build: core:testing pulls in
// core:log and core:terminal, neither of which compiles for wasm32.
#+build linux, windows
package hashedbuild

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// Every examples/*.hb runs the way `hb <file>` runs it (eval_source_file,
// main.odin) and is asserted against the value its own header comment
// documents. This is the only end-to-end coverage in the suite - parser,
// evaluator, async, and the filesystem builtins all at once - and it keeps
// the examples from rotting silently as the language moves underneath them.
// test_every_example_is_covered_by_a_test (bottom) makes forgetting to add a
// new example here a failure rather than an omission.
//
// Paths are built from repo_root() (builtins_fs_test.odin), which resolves at
// compile time from the source location - `odin test` promises no particular
// working directory, and CI checks out somewhere else entirely.

@(private = "file")
Example_Case :: struct {
  file:     string,
  expected: string, // exactly what format_value should produce
}

@(private = "file")
EXAMPLE_CASES := []Example_Case{
  {"arithmetic.hb", "{int_div: 3, float_div: 3.5, remainder: 1, precedence: 14, negation: -3}"},
  {"async-basics.hb", `"This is the payload for option A.\nThis is the payload for option B.\n"`},
  {"async-branching.hb", `"medium"`},
  {"async-table.hb", `{a: 2, b: 6, c: "This is the payload for option A.\n"}`},
  {"check-and-invariants.hb", "100"},
  {"comparison-and-logic.hb", "{ordered: true, both: true, either: true, mixed: false}"},
  {"context-permissions.hb", "{ambient: {io: nothing}, io_denied: {}, replaced: {}, still_ambient: {io: nothing}}"},
  {"files-symlink.hb", `"optiona.txt"`},
  {"functions.hb", "121"},
  {"functions-and-holes.hb", "{section: 11, explicit: 49, nested: 507, stored: 42, asserted: 9}"},
  {"guard-chain.hb", "5"},
  {"hashing.hb", `{text: "Ar9oHTBiuRDqs+ZdbYD2daaU7RcvIDTJNB3UICNP92A=", file: "ZT6vBQgoXEojRYd890EDlZWhUF/uGfXa+C9BNGBykI0=", key_order_is_irrelevant: true, same_content_same_file: true, integer_is_not_float: false}`},
  {"numeric-literals.hb", "{hex: 42, octal: 42, binary: 42, grouped: 1000000, exponent: 1500, bases_agree: true}"},
  {"nothing-and-empty.hb", "{unit: nothing, zero_table: {}, present_case: 42, empty_case: -1, same: false}"},
  {"optional.hb", "42"},
  {"sequence-pattern.hb", "30"},
  {"strings.hb", `{joined: "hello, world", escaped: "quoted \"inline\", tabbed\tand broken\n", same: true}`},
  {"table-and-concat.hb", `{archive: "https://example.com/x.tar.gz", sha256: "def456"}`},
  {"table-destructuring.hb", `{name: "xz", digest: "abc123", has_url: false}`},
  {"tables-map.hb", `{name: "xz", sha256: "abc123", version: "5.8.4"}`},
  {"tables-sequence.hb", "{second: 20, sum: 60, merged: {2: 20, 3: 30, 1: 99}}"},
  {"variant.hb", "42"},
  {"variants-dynamic.hb", `{literal: 42, computed: "green", tested: 42, other_tag: "not err"}`},
}

// Examples whose result is machine-specific (a cache path, a checkout path)
// can't be a fixed string, so they get their own tests below. Listed here so
// the coverage check counts them as covered rather than missing.
@(private = "file")
EXAMPLES_WITH_THEIR_OWN_TEST := []string{"option-picker.hb", "files-sandboxed.hb"}

// examples/link-to-optiona is committed as a symlink, and files-symlink.hb
// reads its target. Git only materialises it as a real symlink where it can:
// on Windows that needs core.symlinks, which needs the same privilege
// creating a symlink does, and without it git writes an ordinary file holding
// the target as text - leaving nothing for readlink to read.
//
// Asked of the checkout rather than assumed from the OS, because a Windows
// clone made with Developer Mode on has the real thing and should run the
// example like anywhere else.
@(private = "file")
repo_has_real_symlinks :: proc() -> bool {
  dir_fd, err := fs_open_dir_path(fmt.tprintf("%s/examples", repo_root()))
  if err != .None do return false
  defer fs_close(dir_fd)
  target, rerr := fs_readlink_at(dir_fd, "link-to-optiona")
  if rerr != .None do return false
  delete(target)
  return true
}

@(test)
test_examples_evaluate_to_their_documented_values :: proc(t: ^testing.T) {
  cache := fmt.tprintf("%s/.examples_test_cache", repo_root())
  defer remove_dir_and_entries(cache)
  // async-branching writes a marker for every branch it walks (§2), and
  // createfile is exclusive (§16), so leftovers from a previous run would
  // make it fail before it ever evaluated.
  clear_branch_markers()
  defer clear_branch_markers()

  has_symlinks := repo_has_real_symlinks()
  for c in EXAMPLE_CASES {
    if c.file == "files-symlink.hb" && !has_symlinks {
      log.infof(
        "skipping %s: examples/link-to-optiona is a plain file in this checkout, not a "+
        "symlink - clone with core.symlinks=true (and the privilege for it) to cover it",
        c.file,
      )
      continue
    }
    path := fmt.tprintf("%s/examples/%s", repo_root(), c.file)
    formatted, err_msg, ok := eval_source_file(path, false, cache)
    if !testing.expect(t, ok, fmt.tprintf("%s failed to evaluate: %s", c.file, err_msg)) do continue
    defer delete(formatted)
    testing.expect_value(t, formatted, c.expected)
  }
}

// option-picker writes into ctx.cache, so the File it evaluates to displays a
// content-addressed path (§3/§16) under whatever --cache-dir was given.
@(test)
test_example_option_picker_writes_into_the_cache :: proc(t: ^testing.T) {
  cache := fmt.tprintf("%s/.examples_test_picker_cache", repo_root())
  defer remove_dir_and_entries(cache)

  path := fmt.tprintf("%s/examples/option-picker.hb", repo_root())
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

// files-sandboxed shows a File displaying its path (§3), which is the
// checkout location - fixed only relative to the repo.
@(test)
test_example_files_sandboxed_displays_real_paths :: proc(t: ^testing.T) {
  path := fmt.tprintf("%s/examples/files-sandboxed.hb", repo_root())
  formatted, err_msg, ok := eval_source_file(path, false, "")
  testing.expect(t, ok, err_msg)
  if !ok do return
  defer delete(formatted)

  // Concatenated rather than tprintf'd: Odin's fmt reads "{" as the start of
  // a format verb, and this expectation is mostly braces.
  expected := strings.concatenate({
    `{dir: <directory: `, repo_root(), `/examples>, file: <file: `, repo_root(),
    `/examples/optiona.txt>, contained_read: "This is the payload for option A.\n"}`,
  }, context.temp_allocator)
  testing.expect_value(t, formatted, expected)
}

// A new example with no assertion is worse than no example: it looks like
// coverage and isn't. Adding examples/foo.hb without listing it above fails
// here rather than passing quietly.
@(test)
test_every_example_is_covered_by_a_test :: proc(t: ^testing.T) {
  covered := make(map[string]bool, context.temp_allocator)
  for c in EXAMPLE_CASES do covered[c.file] = true
  for name in EXAMPLES_WITH_THEIR_OWN_TEST do covered[name] = true

  found := 0
  for name in read_dir_names(fmt.tprintf("%s/examples", repo_root())) {
    if !strings.has_suffix(name, ".hb") do continue
    found += 1
    testing.expect(t, name in covered, fmt.tprintf("examples/%s has no test - add it to examples_test.odin", name))
  }
  // Guards the guard: an empty or unreadable directory would otherwise make
  // this test vacuously pass.
  testing.expect(t, found >= len(EXAMPLE_CASES), "found fewer .hb examples than there are cases")
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
    os.remove(fmt.tprintf("%s/examples/branch-%s.marker", repo_root(), branch))
  }
}
