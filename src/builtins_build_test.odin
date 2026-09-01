#+build linux, windows
// core:testing doesn't compile for wasm32, so the suite is native-only - the
// WASI backends are covered by scripts/wasi_smoke.sh instead.

package hashedbuild

// The build builtins (builtins_build.odin). The examples cover what each one
// *returns*; these cover the parts an example structurally cannot, because a
// denied or malformed call is a **fatal** failure (§8/§16) - an example that
// tripped one would end rather than evaluate to anything.

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
build_parse :: proc(s: string) -> ast_t {
  return parse(source_t{name = "test", n_bytes = u64(len(s)), data = raw_data(s)}, ast_t{})
}

@(private = "file")
eval_build :: proc(src: string, cache_name := "build_default") -> (val: Value, ok: bool, err: string) {
  ast := build_parse(src)
  defer ast_destroy(&ast)
  cache := fmt.tprintf("%s/.build_test_%s", repo_root(), cache_name)
  interp := Interpreter{ast = &ast, src = src, current_ctx = make_root_context(cache)}
  val, ok = eval_program(&interp, ast.root, make_global_env())
  return val, ok, interp.error_message
}

@(private = "file")
expect_fails_with :: proc(t: ^testing.T, src: string, fragment: string, cache_name := "build_default") {
  _, ok, err := eval_build(src, cache_name)
  if !testing.expect(t, !ok, fmt.tprintf("expected %s to fail, but it succeeded", src)) do return
  testing.expect(
    t,
    strings.contains(err, fragment),
    fmt.tprintf("expected the failure for %s to mention %q, got %q", src, fragment, err),
  )
}

// ---- fold ---------------------------------------------------------------------

// The ordering promise, on the one case that would expose a hash-order or an
// entry-order walk: keys of two kinds, written out of order. Ascending order
// puts the Integer keys first and the Utf8 keys after, each group sorted.
@(test)
test_fold_visits_in_ascending_key_order :: proc(t: ^testing.T) {
  val, ok, err := eval_build(`fold {
    .table = { .b = "B", [2] = "2", .a = "A", [1] = "1" },
    .init = "",
    .step = (let s; s.acc concat s.value),
  }`)
  testing.expect(t, ok, err)
  if !ok do return
  testing.expect_value(t, val.(string), "12AB")
}

// §6 ignores the order a Table's entries were written in, so a fold over two
// equal Tables has to agree - which walking `entries` as stored would not.
@(test)
test_fold_agrees_on_equal_tables :: proc(t: ^testing.T) {
  val, ok, err := eval_build(`let digits (let tbl;
      fold { .table = tbl, .init = 0, .step = (let s; s.acc * 10 + s.value) });
    (digits { .a = 1, .b = 2, .c = 3 }) == (digits { .c = 3, .a = 1, .b = 2 })`)
  testing.expect(t, ok, err)
  if !ok do return
  testing.expect_value(t, val.(bool), true)
}

@(test)
test_fold_rejects_a_non_function_step :: proc(t: ^testing.T) {
  expect_fails_with(t, `fold { .table = {1}, .init = 0, .step = 7 }`, "must be a Function")
}

@(test)
test_fold_propagates_a_failing_step :: proc(t: ^testing.T) {
  expect_fails_with(
    t,
    `fold { .table = {1, 2}, .init = 0, .step = (let s; error "step gave up") }`,
    "step gave up",
  )
}

// ---- textlen / textslice ------------------------------------------------------

// Codepoints, not bytes: "héllo" is 5 characters in 6 bytes, and slicing at 2
// must not cut the é in half.
@(test)
test_text_builtins_count_codepoints_not_bytes :: proc(t: ^testing.T) {
  val, ok, err := eval_build(`{
    .len = textlen "héllo",
    .cut = textslice { .text = "héllo", .start = 2, .count = 2 },
  }`)
  testing.expect(t, ok, err)
  if !ok do return
  testing.expect_value(t, format_value(val), `{len: 5, cut: "él"}`)
}

@(test)
test_textslice_refuses_to_run_past_the_end :: proc(t: ^testing.T) {
  expect_fails_with(t, `textslice { .text = "abc", .start = 3, .count = 2 }`, "past the end")
}

@(test)
test_textslice_start_is_one_based :: proc(t: ^testing.T) {
  expect_fails_with(t, `textslice { .text = "abc", .start = 0, .count = 1 }`, "1-based")
}

// ---- listdir ------------------------------------------------------------------

@(test)
test_listdir_refuses_a_regular_file :: proc(t: ^testing.T) {
  expect_fails_with(t, `listdir (loadfile "examples/optiona.txt")`, "not a regular file")
}

@(test)
test_listdir_needs_io :: proc(t: ^testing.T) {
  expect_fails_with(
    t,
    `(listdir (loadfile "examples")) chctx chperm { .name = "io", .enabled = 1 == 0 }`,
    "io permission not granted",
  )
}

// ---- ctx.dir and the ambient path modes ---------------------------------------

// The containment the examples describe but cannot demonstrate, since each of
// these ends the program rather than evaluating to anything.
@(private = "file")
CONTAINED ::
  ` chctx chperm { .name = "anypath", .enabled = 1 == 0 }` +
  ` chctx chperm { .name = "workdir", .enabled = 1 == 1 }`

@(test)
test_workdir_refuses_an_absolute_path :: proc(t: ^testing.T) {
  expect_fails_with(t, `(loadfile "/etc/hostname")` + CONTAINED, "escapes its directory")
}

@(test)
test_workdir_refuses_dot_dot :: proc(t: ^testing.T) {
  expect_fails_with(t, `(loadfile "../README.md")` + CONTAINED, "escapes its directory")
}

// The `.` component specifically: it is the one that looks like it stays put
// and can still be written through to get out.
@(test)
test_workdir_refuses_dot_dot_behind_a_dot :: proc(t: ^testing.T) {
  expect_fails_with(t, `(loadfile "./../README.md")` + CONTAINED, "escapes its directory")
}

@(test)
test_workdir_allows_a_path_inside :: proc(t: ^testing.T) {
  val, ok, err := eval_build(`(filetext (loadfile "examples/optiona.txt"))` + CONTAINED)
  testing.expect(t, ok, err)
  if !ok do return
  testing.expect_value(t, val.(string), "This is the payload for option A.\n")
}

// Neither permission: only the handle forms work at all.
@(test)
test_neither_permission_denies_a_handle_less_path :: proc(t: ^testing.T) {
  expect_fails_with(
    t,
    `(loadfile "examples/optiona.txt") chctx chperm { .name = "anypath", .enabled = 1 == 0 }`,
    "needs the workdir or anypath permission",
  )
}

// ctx.dir is accepted wherever a directory handle is, exactly as ctx.cache is.
@(test)
test_ctx_dir_works_as_a_directory_handle :: proc(t: ^testing.T) {
  val, ok, err := eval_build(`filetext (loadfile { .dir = ctx.dir, .path = "examples/optiona.txt" })`)
  testing.expect(t, ok, err)
  if !ok do return
  testing.expect_value(t, val.(string), "This is the payload for option A.\n")
}

// The reason ctx.dir is its own type rather than a directory File: §15 puts
// the whole ctx into every cache key, and a directory File hashes over its
// contents (§3), so a File here would make every entry depend on every byte of
// the tree. Hashing as a bare tag is what keeps a cache key stable while the
// project changes around it.
@(test)
test_ctx_dir_hashes_as_a_constant :: proc(t: ^testing.T) {
  // Two handles rooted at different directories must hash alike. That is the
  // property the whole incremental story rests on: §15 puts the entire ctx
  // into every cache key, so if ctx.dir encoded either its contents or its
  // path, every entry would depend on the whole project tree or on where the
  // checkout happens to live.
  //
  // Asserted on constructed values rather than by hashing a real directory:
  // the point is that nothing about the directory reaches the digest, and a
  // test that walked a tree to show it would be testing the walk. (An earlier
  // version compared against `sha256 (loadfile ".")`, which hashed the whole
  // checkout - .git included - and failed on Windows for an unrelated reason.)
  here := new(Workdir_Value)
  here.dir_path = "/some/checkout"
  elsewhere := new(Workdir_Value)
  elsewhere.dir_path = "/a/quite/different/place"

  a, a_fail := value_digest(Value(here))
  b, b_fail := value_digest(Value(elsewhere))
  testing.expect(t, a_fail.kind == .None, "hashing ctx.dir should not fail")
  testing.expect(t, b_fail.kind == .None, "hashing ctx.dir should not fail")
  testing.expect(t, a == b, "two ctx.dir handles must hash alike - a path in the key would invalidate a moved checkout")
}

// The other half of the same promise: a directory File still hashes over its
// contents, so what a program reads *through* ctx.dir is unaffected. Uses the
// three-file fixture rather than the checkout root, which is large and, on
// Windows, contains entries the runner cannot open.
@(test)
test_a_directory_file_still_hashes_by_content :: proc(t: ^testing.T) {
  val, ok, err := eval_build(`(sha256 (loadfile "examples/listing")) == (sha256 ctx.dir)`)
  testing.expect(t, ok, err)
  if !ok do return
  testing.expect(t, !val.(bool), "a directory File must not hash as the ctx.dir constant")
}

// ---- exec ---------------------------------------------------------------------

@(test)
test_exec_needs_its_own_permission :: proc(t: ^testing.T) {
  expect_fails_with(
    t,
    `(exec { .cmd = "clang" }) chctx chperm { .name = "exec", .enabled = 1 == 0 }`,
    "exec permission not granted",
  )
}

@(test)
test_exec_rejects_a_missing_cmd :: proc(t: ^testing.T) {
  expect_fails_with(t, `exec { .args = { "x" } }`, "needs a Utf8 .cmd")
}

// A non-zero exit is a value, not a failure - the whole reason `.status` is
// returned rather than the call dying on the caller's behalf.
@(test)
test_exec_reports_a_non_zero_exit_as_a_value :: proc(t: ^testing.T) {
  if !clang_available() {
    log.info("skipping: clang is not on PATH in this environment")
    return
  }
  exec_status_cache := fmt.tprintf("%s/.build_test_exec_status", repo_root())
  remove_dir_and_entries(exec_status_cache)
  defer remove_dir_and_entries(exec_status_cache)
  val, ok, err := eval_build(
    `(exec { .cmd = "clang", .args = { "--no-such-flag-at-all" } }).status == 0`,
    "exec_status",
  )
  testing.expect(t, ok, err)
  if !ok do return
  testing.expect_value(t, val.(bool), false)
}

// A declared output that the program did not produce is fatal: silently
// handing back a graph node with no artifact would turn a broken build into a
// mysterious one further along.
@(test)
test_exec_requires_its_declared_outputs :: proc(t: ^testing.T) {
  if !clang_available() {
    log.info("skipping: clang is not on PATH in this environment")
    return
  }
  exec_outputs_cache := fmt.tprintf("%s/.build_test_exec_outputs", repo_root())
  remove_dir_and_entries(exec_outputs_cache)
  defer remove_dir_and_entries(exec_outputs_cache)
  expect_fails_with(
    t,
    `exec { .cmd = "clang", .args = { "--version" }, .outputs = { "nothing.o" } }`,
    "declared no output named nothing.o",
    "exec_outputs",
  )
}

@(private = "file")
clang_available :: proc() -> bool {
  path_env := os.get_env("PATH", context.temp_allocator)
  sep := ";" when ODIN_OS == .Windows else ":"
  for dir in strings.split(path_env, sep, context.temp_allocator) {
    if dir == "" do continue
    if os.exists(strings.concatenate({dir, "/clang"}, context.temp_allocator)) do return true
    when ODIN_OS == .Windows {
      if os.exists(strings.concatenate({dir, "/clang.exe"}, context.temp_allocator)) do return true
    }
  }
  return false
}
