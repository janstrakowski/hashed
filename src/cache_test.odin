// Tests run natively, never in a WASI build - see eval_test.odin.
#+build linux, windows
package hashedbuild

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// SPEC.md §15's `cached`: the key (hash_function.odin), the on-disk layout
// (cache_store.odin) and the text format (cache_format.odin), exercised
// through the language itself wherever that is possible.
//
// Every test here gets its own cache directory. `odin test` runs tests
// concurrently, and these actually write - two tests sharing a directory
// would race on the entries in it.

@(private = "file")
cache_scratch :: proc(name: string) -> string {
  return strings.concatenate({repo_root(), "/.cache_test_", name})
}

// The same scratch entry as a sub-path of the checkout, which is how the
// source under test names it: ctx.dir here is the checkout, and §16 gives a
// program no way to write a path that isn't relative to a handle.
@(private = "file")
cache_scratch_name :: proc(name: string) -> string {
  return strings.concatenate({".cache_test_", name})
}

@(private = "file")
remove_cache_scratch :: proc(path: string) {
  remove_recursively(path)
}

// os.remove refuses a non-empty directory, and a cache entry holding a
// directory value nests arbitrarily deep, so cleanup has to recurse.
//
// The is_dir check is not an optimisation: os.open succeeds on a regular file
// too, and reading a directory listing out of that handle is not something
// every target survives.
@(private = "file")
remove_recursively :: proc(path: string) {
  if is_dir, err := fs_stat_is_dir_at(fs_cwd_dir(), path, true); err == .None && is_dir {
    entries, _ := fs_list_dir(path, context.temp_allocator)
    for entry in entries do remove_recursively(fmt.tprintf("%s/%s", path, entry.name))
  }
  os.remove(path)
}

// Evaluates with the real global environment and a root context whose
// ctx.cache points at `cache_dir` - the same setup a real run has, since
// `cached` is only meaningful against a real store. ctx.dir is the checkout,
// so a test program reads its scratch files by sub-path (§16).
@(private = "file")
eval_cached_src :: proc(src: string, cache_dir: string) -> (val: Value, ok: bool, err: string) {
  ast := parse(source_t{name = "test", n_bytes = u64(len(src)), data = raw_data(src)}, ast_t{})
  interp := Interpreter{ast = &ast, src = src, current_ctx = test_root_context(cache_dir, repo_root())}
  val, ok = eval_program(&interp, ast.root, make_global_env())
  return val, ok, interp.error_message
}

@(private = "file")
expect_int :: proc(t: ^testing.T, src: string, cache_dir: string, want: i64) {
  val, ok, err := eval_cached_src(src, cache_dir)
  testing.expect(t, ok, err)
  got, is_int := val.(i64)
  testing.expect(t, is_int, "expected an Integer result")
  testing.expect_value(t, got, want)
}

@(private = "file")
expect_failure :: proc(t: ^testing.T, src: string, cache_dir: string) -> string {
  _, ok, err := eval_cached_src(src, cache_dir)
  testing.expect(t, !ok, "expected this to fail")
  return err
}

// The names directly inside a directory, sorted - what a test asserts the
// layout with.
@(private = "file")
entry_names :: proc(path: string) -> []string {
  entries, err := fs_list_dir(path, context.temp_allocator)
  if err != .None do return nil
  names := make([dynamic]string, 0, len(entries), context.temp_allocator)
  for entry in entries do append(&names, entry.name)
  return names[:]
}

// ---- the basic contract -----------------------------------------------------

@(test)
test_cached_returns_the_value_and_writes_one_entry :: proc(t: ^testing.T) {
  dir := cache_scratch("basic")
  defer delete(dir)                 // LIFO: the path has to outlive the cleanup
  defer remove_cache_scratch(dir)

  expect_int(t, `cached (1 + 2)`, dir, 3)
  expect_int(t, `cached (1 + 2)`, dir, 3)

  names := entry_names(dir)
  testing.expect_value(t, len(names), 1)
  if len(names) != 1 do return
  testing.expect(t, strings.has_prefix(names[0], "sha256-"), "an entry is named by its key")
  testing.expect(t, strings.has_suffix(names[0], ".hb"), "a non-File value is stored as text")
}

// The one test that distinguishes a cache from a very elaborate way of
// evaluating twice: the file the expression reads is changed underneath it,
// and the second call still answers with what the first one stored. Nothing
// in the key mentions the file's contents, so the entry stays valid.
@(test)
test_cached_hit_survives_the_source_changing :: proc(t: ^testing.T) {
  dir := cache_scratch("hit")
  defer delete(dir)                 // LIFO: the path has to outlive the cleanup
  defer remove_cache_scratch(dir)

  data := cache_scratch("hit_data")
  defer delete(data)
  defer remove_cache_scratch(data)
  os.make_directory(data)
  path := fmt.tprintf("%s/f.txt", data)
  _ = os.write_entire_file(path, transmute([]u8)string("first"))

  sub := cache_scratch_name("hit_data")
  defer delete(sub)
  src := fmt.aprintf(`filetext cached (loadfile "%s/f.txt")`, sub)
  defer delete(src)

  val, ok, err := eval_cached_src(src, dir)
  testing.expect(t, ok, err)
  testing.expect_value(t, val.(string), "first")

  os.remove(path)
  _ = os.write_entire_file(path, transmute([]u8)string("SECOND"))

  // Uncached, the change is visible...
  fresh := fmt.aprintf(`filetext (loadfile "%s/f.txt")`, sub)
  defer delete(fresh)
  val2, ok2, err2 := eval_cached_src(fresh, dir)
  testing.expect(t, ok2, err2)
  testing.expect_value(t, val2.(string), "SECOND")

  // ...and through `cached` it is not: the stored answer is returned.
  val3, ok3, err3 := eval_cached_src(src, dir)
  testing.expect(t, ok3, err3)
  testing.expect_value(t, val3.(string), "first")
}

// The half of §15's key that has to be right for a hit to be correct: two
// expressions with identical code but different captured values are different
// entries. Get this wrong and the second call returns the first one's answer.
@(test)
test_cached_key_covers_the_values_the_expression_uses :: proc(t: ^testing.T) {
  dir := cache_scratch("key")
  defer delete(dir)                 // LIFO: the path has to outlive the cleanup
  defer remove_cache_scratch(dir)

  expect_int(t, `let x 1; cached (x + 10)`, dir, 11)
  expect_int(t, `let x 2; cached (x + 10)`, dir, 12)
  expect_int(t, `let x 1; cached (x + 10)`, dir, 11)

  testing.expect_value(t, len(entry_names(dir)), 2)
}

// A closure captures its environment; `#arg`/`#self` (§9) are dynamic lookups
// that it does not capture, so the key has to reach them separately. This is
// the case that returned a *wrong answer* before it did: identical code, a
// different argument, one entry.
@(test)
test_cached_key_covers_the_implicit_names_it_reads :: proc(t: ^testing.T) {
  dir := cache_scratch("implicit")
  defer delete(dir)
  defer remove_cache_scratch(dir)

  expect_int(t, `let f func (cached (#arg + 1)); f 1`, dir, 2)
  expect_int(t, `let f func (cached (#arg + 1)); f 10`, dir, 11)
  expect_int(t, `let f func (cached (#arg + 1)); f 1`, dir, 2)

  // The same through `|>`, which pushes onto the same stack...
  expect_int(t, `1 |> cached (#arg + 100)`, dir, 101)
  expect_int(t, `5 |> cached (#arg + 100)`, dir, 105)

  // ...and at a level further out, where the reach has to be counted rather
  // than assumed to be one.
  expect_int(t, `let f func ((func (cached (#arg2 * 2))) 0); f 3`, dir, 6)
  expect_int(t, `let f func ((func (cached (#arg2 * 2))) 0); f 4`, dir, 8)
  expect_int(t, `let f func ((func (cached (#arg2 * 2))) 0); f 3`, dir, 6)
}

// An expression that reads no implicit name is not affected by any of the
// above: its key is the closure digest alone, and stays stable across calls
// made at different depths.
@(test)
test_cached_key_is_unchanged_by_depth_when_nothing_is_read :: proc(t: ^testing.T) {
  dir := cache_scratch("depth")
  defer delete(dir)
  defer remove_cache_scratch(dir)

  expect_int(t, `cached (6 * 7)`, dir, 42)
  expect_int(t, `let f func (cached (6 * 7)); f 1`, dir, 42)
  expect_int(t, `let f func (cached (6 * 7)); f 99`, dir, 42)

  testing.expect_value(t, len(entry_names(dir)), 1)
}

// ---- the three layouts ------------------------------------------------------

// "if it is straight a file, keep it that way": a File value is the entry, not
// something wrapped in one, so what a build produced stays a file you can open.
@(test)
test_cached_file_value_is_stored_as_a_file :: proc(t: ^testing.T) {
  dir := cache_scratch("file")
  defer delete(dir)                 // LIFO: the path has to outlive the cleanup
  defer remove_cache_scratch(dir)

  src := fmt.aprintf(`cached (loadfile "README.md")`)
  defer delete(src)
  val, ok, err := eval_cached_src(src, dir)
  testing.expect(t, ok, err)

  fv, is_file := val.(^File_Value)
  testing.expect(t, is_file, "a cached File is still a File")
  if !is_file do return
  testing.expect_value(t, fv.kind, File_Kind.Regular)
  testing.expect(t, strings.has_prefix(fv.display_path, dir), "a hit displays where it lives (§3)")

  names := entry_names(dir)
  testing.expect_value(t, len(names), 1)
  if len(names) != 1 do return
  testing.expect(t, !strings.has_suffix(names[0], ".hb"), "a File entry carries no .hb suffix")
}

// The same for a directory, which is the case that needs the whole tree copied
// - and copied faithfully enough that the restored value hashes as the
// original did (§3). That equality is the test: it covers names, contents and
// nesting in one assertion.
@(test)
test_cached_directory_value_round_trips :: proc(t: ^testing.T) {
  dir := cache_scratch("tree")
  defer delete(dir)                 // LIFO: the path has to outlive the cleanup
  defer remove_cache_scratch(dir)

  // A tree built here rather than one of the repo's own: nothing else writes
  // into it (async-branching drops marker files into examples/ as it runs, and
  // tests run concurrently), and the two hashes here have to see one tree.
  tree := cache_scratch("tree_src")
  defer delete(tree)
  defer remove_cache_scratch(tree)
  os.make_directory(tree)
  _ = os.write_entire_file(fmt.tprintf("%s/a.txt", tree), transmute([]u8)string("alpha"))
  os.make_directory(fmt.tprintf("%s/sub", tree))
  _ = os.write_entire_file(fmt.tprintf("%s/sub/b.txt", tree), transmute([]u8)string("beta"))

  tree_sub := cache_scratch_name("tree_src")
  defer delete(tree_sub)
  src := fmt.aprintf(
    `(sha256 cached (loadfile "%s")) == (sha256 loadfile "%s")`, tree_sub, tree_sub,
  )
  defer delete(src)
  val, ok, err := eval_cached_src(src, dir)
  testing.expect(t, ok, err)
  testing.expect(t, val.(bool), "a cached directory is the same value it was")

  names := entry_names(dir)
  testing.expect_value(t, len(names), 1)
  if len(names) != 1 do return
  is_dir, _ := fs_stat_is_dir_at(fs_cwd_dir(), fmt.tprintf("%s/%s", dir, names[0]), true)
  testing.expect(t, is_dir, "a directory value is stored as a directory")
}

// Anything else becomes `value.hb`, with each File it holds written out beside
// it and named by that File's own content hash - the "systematically" half of
// the layout. A composite with one file in it therefore has exactly two names
// inside its entry.
@(test)
test_cached_composite_holds_its_files_beside_the_text :: proc(t: ^testing.T) {
  dir := cache_scratch("composite")
  defer delete(dir)                 // LIFO: the path has to outlive the cleanup
  defer remove_cache_scratch(dir)

  // strings.concatenate, not fmt.aprintf: the value being cached is a Table
  // literal, and fmt reads its `{` as the start of a format verb.
  src := strings.concatenate({`cached { .doc = loadfile "README.md", .n = 7 }`})
  defer delete(src)
  val, ok, err := eval_cached_src(src, dir)
  testing.expect(t, ok, err)

  table, is_table := val.(^Table_Value)
  testing.expect(t, is_table, "a cached Table is still a Table")
  if !is_table do return
  doc, found := table_find(table, "doc")
  testing.expect(t, found)
  _, doc_is_file := doc.(^File_Value)
  testing.expect(t, doc_is_file, "the File inside came back as a File")

  outer := entry_names(dir)
  testing.expect_value(t, len(outer), 1)
  if len(outer) != 1 do return
  inner := entry_names(fmt.tprintf("%s/%s", dir, outer[0]))
  testing.expect_value(t, len(inner), 2)

  has_text, has_file := false, false
  for name in inner {
    if name == "value.hb" do has_text = true
    if strings.has_prefix(name, "sha256-") do has_file = true
  }
  testing.expect(t, has_text, "the entry holds its value.hb")
  testing.expect(t, has_file, "and the File it refers to, named by content")
}

// §10's `let rec` can build a Table that reaches itself, so the format has to
// write one down and read it back. The assertion that matters is the digest:
// the restored value has to *be* the value that was stored, and §6 compares
// cyclic values by bisimulation, so an unfolding to the wrong depth or a lost
// back-edge would show up here.
@(test)
test_cached_round_trips_a_cyclic_value :: proc(t: ^testing.T) {
  dir := cache_scratch("cyclic")
  defer delete(dir)
  defer remove_cache_scratch(dir)

  self := `let rec t { .name = "alice", .self = t }; `
  same := strings.concatenate({self, `(sha256 cached t) == (sha256 t)`})
  defer delete(same)
  val, ok, err := eval_cached_src(same, dir)
  testing.expect(t, ok, err)
  testing.expect(t, val.(bool), "a cached cyclic value is the value it was")

  // ...and the back-edge is a real one, not an unfolding that ran out.
  deep := strings.concatenate({self, `(cached t).self.self.self.name`})
  defer delete(deep)
  val2, ok2, err2 := eval_cached_src(deep, dir)
  testing.expect(t, ok2, err2)
  testing.expect_value(t, val2.(string), "alice")
}

// Two Tables that reach each other, which is the shape §10 actually produces -
// a `let rec` whose entries mention their siblings. The cycle here runs through
// two nodes rather than one, so a writer that only handled self-reference would
// pass the test above and fail this one.
@(test)
test_cached_round_trips_a_mutual_cycle :: proc(t: ^testing.T) {
  dir := cache_scratch("mutual")
  defer delete(dir)
  defer remove_cache_scratch(dir)

  people := `let rec people { .alice = { .name = "alice", .friend = people.bob }, ` +
            `.bob = { .name = "bob", .friend = people.alice } }; `
  src := strings.concatenate({people, `(sha256 cached people) == (sha256 people)`})
  defer delete(src)
  val, ok, err := eval_cached_src(src, dir)
  testing.expect(t, ok, err)
  testing.expect(t, val.(bool))

  hop := strings.concatenate({people, `(cached people).alice.friend.friend.name`})
  defer delete(hop)
  val2, ok2, err2 := eval_cached_src(hop, dir)
  testing.expect(t, ok2, err2)
  testing.expect_value(t, val2.(string), "alice")
}

// ---- what `cached` refuses --------------------------------------------------

@(test)
test_cached_needs_io_and_a_cache :: proc(t: ^testing.T) {
  dir := cache_scratch("refuse")
  defer delete(dir)                 // LIFO: the path has to outlive the cleanup
  defer remove_cache_scratch(dir)

  denied := expect_failure(t, `(cached 1) withctx { .permissions = empty, .cache = ctx.cache }`, dir)
  testing.expect(t, strings.contains(denied, "io permission"), denied)

  // §9 lets a program build a context by hand; one that doesn't carry .cache
  // over has no store to use, and says so rather than inventing one.
  no_cache := expect_failure(t, `(cached 1) withctx { .permissions = ctx.permissions }`, dir)
  testing.expect(t, strings.contains(no_cache, "no .cache"), no_cache)

  // Nothing was created: the directory is made lazily, on a real write.
  _, exists := os.stat(dir, context.temp_allocator)
  testing.expect(t, exists != nil, "a refused `cached` creates no cache directory")
}

// A closure's meaning is its environment, so there is nothing to write down
// and read back. The same goes for ctx.cache. Both fail rather than storing
// something that would come back as a different value.
@(test)
test_cached_refuses_a_value_it_cannot_write :: proc(t: ^testing.T) {
  dir := cache_scratch("unwritable")
  defer delete(dir)                 // LIFO: the path has to outlive the cleanup
  defer remove_cache_scratch(dir)

  for src in ([]string{`cached (func 1)`, `cached ctx.cache`, `cached { .f = func 1 }`}) {
    msg := expect_failure(t, src, dir)
    testing.expect(t, strings.contains(msg, "cannot cache"), msg)
  }
}

// A present-but-unreadable entry is a failure, not a miss. Recomputing over a
// corrupt cache would work, and would hide the corruption for as long as the
// cache lived.
@(test)
test_cached_reports_a_corrupt_entry :: proc(t: ^testing.T) {
  dir := cache_scratch("corrupt")
  defer delete(dir)                 // LIFO: the path has to outlive the cleanup
  defer remove_cache_scratch(dir)

  expect_int(t, `cached (1 + 2)`, dir, 3)
  names := entry_names(dir)
  testing.expect_value(t, len(names), 1)
  if len(names) != 1 do return

  value_path := fmt.tprintf("%s/%s/value.hb", dir, names[0])
  os.remove(value_path)
  _ = os.write_entire_file(value_path, transmute([]u8)string("{ this is not a value"))

  msg := expect_failure(t, `cached (1 + 2)`, dir)
  testing.expect(t, strings.contains(msg, "not readable as a value"), msg)
}

// ---- the text format --------------------------------------------------------

// cache_format.odin's round trip, over every kind of value that has a written
// form - and, for the numbers, over the awkward ones. A value that reads back
// even slightly different would hash differently, and `cached` would be
// handing out something other than what it stored.
@(test)
test_cache_format_round_trips_every_writable_value :: proc(t: ^testing.T) {
  nested := new(Table_Value)
  append(&nested.entries, Table_Entry_Value{key = i64(1), value = "one"})
  append(&nested.entries, Table_Entry_Value{key = "needs quotes", value = true})

  table := new(Table_Value)
  append(&table.entries, Table_Entry_Value{key = "nothing", value = Nothing_Value{}})
  append(&table.entries, Table_Entry_Value{key = "yes", value = true})
  append(&table.entries, Table_Entry_Value{key = "no", value = false})
  append(&table.entries, Table_Entry_Value{key = "neg", value = i64(-9223372036854775808)})
  append(&table.entries, Table_Entry_Value{key = "big", value = i64(9223372036854775807)})
  append(&table.entries, Table_Entry_Value{key = "tenth", value = 0.1})
  append(&table.entries, Table_Entry_Value{key = "tiny", value = 5.0e-324})
  append(&table.entries, Table_Entry_Value{key = "third", value = 1.0 / 3.0})
  append(&table.entries, Table_Entry_Value{key = "whole", value = 2.0})
  append(&table.entries, Table_Entry_Value{key = "escapes", value = "quote\" back\\ tab\t nl\n nul\x00 hi\x7f"})
  append(&table.entries, Table_Entry_Value{key = "unicode", value = "é中文 \U0001f600"})
  append(&table.entries, Table_Entry_Value{key = "raw", value = []u8{0, 1, 2, 255}})
  append(&table.entries, Table_Entry_Value{key = "inner", value = nested})
  append(&table.entries, Table_Entry_Value{key = "empty", value = new(Table_Value)})

  names: map[^File_Value]string
  text, wrote, why := cache_format_write(table, names)
  testing.expect(t, wrote, why)

  back, read := cache_format_read(text, nil, nil)
  testing.expect(t, read, text)

  // Hash equality rather than field-by-field comparison: it is the property
  // `cached` actually depends on, and it covers the whole structure at once.
  testing.expect(t, values_hash_equal(table, back), text)
}

// The format's own round trip for a cycle, below the language: a Table holding
// itself, written and read back. Asserted through the digest, which §6 computes
// by bisimulation for a cyclic value - so this checks the graph, not the text.
@(test)
test_cache_format_round_trips_a_cycle :: proc(t: ^testing.T) {
  cyclic := new(Table_Value)
  append(&cyclic.entries, Table_Entry_Value{key = "name", value = "alice"})
  append(&cyclic.entries, Table_Entry_Value{key = "self", value = cyclic})

  names: map[^File_Value]string
  text, wrote, why := cache_format_write(cyclic, names)
  testing.expect(t, wrote, why)
  testing.expect(t, strings.contains(text, `node "1"`), text)
  testing.expect(t, strings.contains(text, `ref "1"`), text)

  back, read := cache_format_read(text, nil, nil)
  testing.expect(t, read, text)
  testing.expect(t, values_hash_equal(cyclic, back), text)
}

// A Table reached twice without any cycle is written once and referred to,
// which is why a deeply shared value doesn't expand exponentially on the way
// out. Sharing isn't observable in the value model, so this is about size -
// but the value still has to come back equal.
@(test)
test_cache_format_keeps_sharing :: proc(t: ^testing.T) {
  shared := new(Table_Value)
  append(&shared.entries, Table_Entry_Value{key = "n", value = i64(1)})

  outer := new(Table_Value)
  append(&outer.entries, Table_Entry_Value{key = "a", value = shared})
  append(&outer.entries, Table_Entry_Value{key = "b", value = shared})

  names: map[^File_Value]string
  text, wrote, why := cache_format_write(outer, names)
  testing.expect(t, wrote, why)
  testing.expect(t, strings.contains(text, `ref "1"`), text)

  back, read := cache_format_read(text, nil, nil)
  testing.expect(t, read, text)
  testing.expect(t, values_hash_equal(outer, back), text)
}

// A `ref` with no definition before it, and a label defined twice: both are
// entries that no writer here produces, so both are corruption.
@(test)
test_cache_format_rejects_a_broken_reference :: proc(t: ^testing.T) {
  for src in ([]string{
    `{ .a = ref "1" }`,
    `{ .a = node "1" { .x = 1 }, .b = node "1" { .y = 2 } }`,
    `ref "nope"`,
    `node "1" 5`,
  }) {
    _, ok := cache_format_read(src, nil, nil)
    testing.expect(t, !ok, src)
  }
}

// The reader accepts literals and nothing else, so an entry someone edited
// into a program is a parse failure rather than something that runs.
@(test)
test_cache_format_rejects_anything_that_is_not_a_value :: proc(t: ^testing.T) {
  for src in ([]string{
    `loadfile "/etc/passwd"`,
    `1 + 2`,
    `{ .a = 1 } concat { .b = 2 }`,
    `func 1`,
    `{ .a = }`,
    `"unterminated`,
    `nothing extra`,
    `file "../../escape"`,
  }) {
    _, ok := cache_format_read(src, nil, nil)
    testing.expect(t, !ok, src)
  }
}
