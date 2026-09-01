// Tests run natively, never in a WASI build: core:testing pulls in
// core:log and core:terminal, neither of which compiles for wasm32.
#+build linux, windows
package hashedbuild

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// A fresh scratch directory (removed afterward) plus a File_Value directory
// handle already opened onto it, for tests that need `.dir`.
@(private = "file")
Scratch_Dir :: struct {
  path:   string,
  handle: ^File_Value,
}

@(private = "file")
make_scratch_dir :: proc(t: ^testing.T, name: string) -> Scratch_Dir {
  path := fmt_scratch_path(name)
  err := os.make_directory(path)
  testing.expect(t, err == nil, "could not create scratch test directory")

  fd, ferr := fs_open_dir_path(path)
  testing.expect(t, ferr == .None, "could not open scratch test directory")

  h := new(File_Value)
  h.kind = .Directory
  h.dir_fd = fd
  // Same as loadfile would set: a directory handle carries the path it was
  // reached by, and everything opened through it displays relative to that
  // (§3). Without it the handle is real but anonymous, and Files opened
  // through it would display a bare basename.
  h.display_path = path
  return Scratch_Dir{path = path, handle = h}
}

// The repo root, derived from this source file's own location: #directory
// resolves at compile time to "<repo>/src/", so trimming that suffix gives
// the root wherever the repo is checked out - a CI runner's workspace as
// readily as a dev machine - with no dependence on the working directory
// `odin test` happens to inherit. Trimmed rather than "+ \"..\"" because
// these paths get compared against the kernel's own resolved answer for a
// File's display path (§3), which never contains a ".." component.
repo_root :: proc() -> string {
  return strings.trim_suffix(strings.trim_suffix(#directory, "/"), "/src")
}

@(private = "file")
fmt_scratch_path :: proc(name: string) -> string {
  return strings.concatenate({repo_root(), "/.builtins_fs_test_", name})
}

// The same scratch entry as a *sub-path* of the checkout, which is how a test
// program names it: §16 has no other kind of path, and the checkout is what
// these tests hand over as `ctx.dirs.here` (test_root_context, below).
@(private = "file")
scratch_name :: proc(name: string) -> string {
  return strings.concatenate({".builtins_fs_test_", name})
}

// The root context the tests evaluate under: `io` granted, `ctx.cache` on a
// scratch directory, and one handle in `ctx.dirs` - `here`, opened on
// `here_dir`, the same name the examples' `run:` lines use - since a program
// holding no handles reaches nothing at all (§16). Pass "" for `here_dir` to
// build exactly that: a context with no directories in it.
//
// Package-visible because hash_test and cache_test evaluate real programs too,
// and every one of them has to name a handle to read anything.
test_root_context :: proc(cache_dir: string, here_dir: string) -> Value {
  named: []Named_Dir
  one := [1]Named_Dir{{name = "here", path = here_dir}}
  if here_dir != "" do named = one[:]
  dirs, _, _ := open_root_dirs(cache_dir, named)
  return make_root_context(dirs)
}

@(private = "file")
remove_scratch_dir :: proc(s: Scratch_Dir) {
  fs_close(s.handle.dir_fd)
  // Best-effort cleanup, one level deep: os.remove won't take a non-empty
  // directory, and a leftover scratch directory makes the *next* run of the
  // same test fail (createfile is exclusive, §16). Tests here only ever put
  // entries directly inside, so no recursion needed.
  if handle, err := os.open(s.path); err == nil {
    entries, _ := os.read_dir(handle, -1, context.temp_allocator)
    for entry in entries do os.remove(fmt.tprintf("%s/%s", s.path, entry.name))
    os.close(handle)
  }
  os.remove(s.path)
}

@(private = "file")
fs_parse :: proc(s: string) -> ast_t {
  return parse(source_t{name = "test", n_bytes = u64(len(s)), data = raw_data(s)}, ast_t{})
}

// Evaluates `src` with the real global environment/root context (the
// filesystem builtins, io granted) bound in, plus one extra name (e.g. a
// scratch directory handle) additionally bound into that same top-level
// scope - "" means nothing extra to bind. `ctx.dirs.here` is the checkout, so
// a program with no handle passed in as `d` still has one to name, exactly as
// `hb --dir repo=. prog.hb` would give it (§16).
// ctx.cache points at a scratch dir under a name unique to the calling test
// (not the user's real cache dir, and not shared across tests - odin test may
// run tests in parallel, and tests that actually write to the cache need
// their own directory to avoid colliding with each other).
@(private = "file")
eval_with_builtins :: proc(src: string, extra_name: string, extra_val: Value, cache_name := "cache_default") -> (val: Value, ok: bool, err: string) {
  ast := fs_parse(src)
  defer ast_destroy(&ast)

  interp := Interpreter{ast = &ast, src = src, current_ctx = test_root_context(fmt_scratch_path(cache_name), repo_root())}
  env := make_global_env()
  if extra_name != "" do env_bind(env, extra_name, extra_val)

  // eval_program, like every real entry point: it awaits a bare top-level
  // async and drains any task nothing awaited (eval_async.odin).
  val, ok = eval_program(&interp, ast.root, env)
  return val, ok, interp.error_message
}

// ---- createfile ---------------------------------------------------------------

// A handle from the context, rather than one bound into scope by the test:
// the same operation either way (§16), and the shape a real program has, where
// every handle traces back to a `--dir` the run named.
@(test)
test_builtin_createfile_through_a_ctx_dirs_handle :: proc(t: ^testing.T) {
  path := fmt_scratch_path("createfile_plain.txt")
  defer os.remove(path)
  name := scratch_name("createfile_plain.txt")
  defer delete(name)

  src := fmt.aprintf(`createfile {{ .dir = ctx.dirs.here, .path = "%s", .content = "hello" }}`, name)
  defer delete(src)
  val, ok, err := eval_with_builtins(src, "", nil)
  testing.expect(t, ok, err)
  fv, is_file := val.(^File_Value)
  testing.expect(t, is_file)
  testing.expect_value(t, fv.kind, File_Kind.Regular)
  testing.expect_value(t, string(fv.content), "hello")

  data, rerr := os.read_entire_file(path, context.allocator)
  testing.expect(t, rerr == nil)
  testing.expect_value(t, string(data), "hello")
}

@(test)
test_builtin_createfile_is_exclusive :: proc(t: ^testing.T) {
  path := fmt_scratch_path("createfile_excl.txt")
  defer os.remove(path)
  name := scratch_name("createfile_excl.txt")
  defer delete(name)

  src := fmt.aprintf(`createfile {{ .dir = ctx.dirs.here, .path = "%s", .content = "a" }}`, name)
  defer delete(src)
  _, ok1, _ := eval_with_builtins(src, "", nil)
  testing.expect(t, ok1)

  _, ok2, err2 := eval_with_builtins(src, "", nil) // same path again - must fail, no overwrite
  testing.expect(t, !ok2, "createfile should refuse to overwrite an existing file")
  testing.expect(t, strings.contains(err2, "createfile"))
}

@(test)
test_builtin_createfile_sandboxed_to_dir :: proc(t: ^testing.T) {
  sd := make_scratch_dir(t, "createfile_dir")
  defer remove_scratch_dir(sd)

  val, ok, err := eval_with_builtins(`createfile { .dir = d, .path = "in.txt", .content = "x" }`, "d", sd.handle)
  testing.expect(t, ok, err)
  fv, is_file := val.(^File_Value)
  testing.expect(t, is_file)
  testing.expect_value(t, string(fv.content), "x")

  // .. must be rejected before ever touching the filesystem.
  _, ok2, _ := eval_with_builtins(`createfile { .dir = d, .path = "../escape.txt", .content = "x" }`, "d", sd.handle)
  testing.expect(t, !ok2, "createfile must reject a path that escapes its directory")
}

// ---- display (§3) ---------------------------------------------------------------

// SPEC.md §3: every File displays its actual filesystem path, not its size
// or content - and an absolute one, even when the call site named it
// relative to a .dir handle.
@(test)
test_file_display_shows_path :: proc(t: ^testing.T) {
  sd := make_scratch_dir(t, "display_dir")
  defer remove_scratch_dir(sd)

  made, ok1, err1 := eval_with_builtins(`createfile { .dir = d, .path = "made.txt", .content = "x" }`, "d", sd.handle)
  testing.expect(t, ok1, err1)
  testing.expect_value(t, format_value(made), fmt.tprintf("<file: %s/made.txt>", sd.path))

  loaded, ok2, err2 := eval_with_builtins(`loadfile { .dir = d, .path = "made.txt" }`, "d", sd.handle)
  testing.expect(t, ok2, err2)
  testing.expect_value(t, format_value(loaded), fmt.tprintf("<file: %s/made.txt>", sd.path))

  // The same directory reached the other way - as a sub-path of the checkout
  // handle rather than as the handle itself - displays the same absolute
  // path (§3).
  dir_name := scratch_name("display_dir")
  defer delete(dir_name)
  load_dir_src := fmt.aprintf(`loadfile {{ .dir = ctx.dirs.here, .path = "%s" }}`, dir_name)
  defer delete(load_dir_src)
  dir_val, ok3, err3 := eval_with_builtins(load_dir_src, "", nil)
  testing.expect(t, ok3, err3)
  testing.expect_value(t, format_value(dir_val), fmt.tprintf("<directory: %s>", sd.path))
  if dfv, is_file := dir_val.(^File_Value); is_file do fs_close(dfv.dir_fd)
}

// ---- symlink / readlink ---------------------------------------------------------

// Creating a symlink on Windows needs a privilege an ordinary process does
// not have: either Developer Mode is on or the process is elevated
// (fs_windows.odin). Where neither holds, §16's documented answer is the
// .Access refusal - "not allowed" - and there is no way to go on and test the
// round trip. Skipping is the honest outcome; failing would leave the suite
// permanently red on a stock Windows machine and say nothing about the code.
//
// Deliberately narrow: it only excuses .Access, only on Windows, and only
// after asserting the refusal reads the way §16 says it should. A symlink
// failure anywhere else, or for any other reason, is still a failure.
@(private = "file")
symlinks_unavailable :: proc(t: ^testing.T, err: string) -> bool {
  when ODIN_OS != .Windows {
    return false
  } else {
    if !strings.contains(err, "(Access)") do return false
    testing.expect(t, strings.contains(err, "symlink"), err)
    log.infof(
      "skipping the symlink round trip: this Windows process may not create symlinks "+
      "(enable Developer Mode, or run elevated, to cover it). Refusal was: %s",
      err,
    )
    return true
  }
}

@(test)
test_builtin_symlink_and_readlink_round_trip :: proc(t: ^testing.T) {
  sd := make_scratch_dir(t, "symlink_dir")
  defer remove_scratch_dir(sd)

  _, ok1, err1 := eval_with_builtins(`symlink { .dir = d, .path = "link", .target = "some/target" }`, "d", sd.handle)
  if !ok1 && symlinks_unavailable(t, err1) do return
  testing.expect(t, ok1, err1)

  val, ok2, err2 := eval_with_builtins(`readlink { .dir = d, .path = "link" }`, "d", sd.handle)
  testing.expect(t, ok2, err2)
  target, is_str := val.(string)
  testing.expect(t, is_str)
  testing.expect_value(t, target, "some/target")
}

@(test)
test_builtin_symlink_rejects_path_escape :: proc(t: ^testing.T) {
  sd := make_scratch_dir(t, "symlink_escape_dir")
  defer remove_scratch_dir(sd)

  _, ok, _ := eval_with_builtins(`symlink { .dir = d, .path = "../escaped_link", .target = "x" }`, "d", sd.handle)
  testing.expect(t, !ok, "symlink must reject a path that escapes its directory")
}

// ---- loadfile -------------------------------------------------------------------

@(test)
test_builtin_loadfile_through_a_ctx_dirs_handle :: proc(t: ^testing.T) {
  path := fmt_scratch_path("loadfile_plain.txt")
  _ = os.write_entire_file(path, transmute([]u8)string("content!"))
  defer os.remove(path)
  name := scratch_name("loadfile_plain.txt")
  defer delete(name)

  load_src := fmt.aprintf(`loadfile {{ .dir = ctx.dirs.here, .path = "%s" }}`, name)
  defer delete(load_src)
  val, ok, err := eval_with_builtins(load_src, "", nil)
  testing.expect(t, ok, err)
  fv, is_file := val.(^File_Value)
  testing.expect(t, is_file)
  testing.expect_value(t, fv.kind, File_Kind.Regular)
  testing.expect_value(t, string(fv.content), "content!")

  // A directory reached the same way is a handle like any other (§16).
  dir_val, dir_ok, dir_err := eval_with_builtins(`loadfile { .dir = ctx.dirs.here, .path = "examples" }`, "", nil)
  testing.expect(t, dir_ok, dir_err)
  dfv, is_dir_file := dir_val.(^File_Value)
  testing.expect(t, is_dir_file)
  testing.expect_value(t, dfv.kind, File_Kind.Directory)
  if is_dir_file do fs_close(dfv.dir_fd)
}

// The rule §16 states as one sentence: a sub-path is a sequence of ordinary
// names, so a root, an empty segment, and "." or ".." **anywhere** are all
// refused - including the spellings that would have reduced to something
// inside. None of these touches the filesystem before being rejected.
@(test)
test_sub_paths_may_not_say_dot_dotdot_or_a_root :: proc(t: ^testing.T) {
  sd := make_scratch_dir(t, "sub_path_rules")
  defer remove_scratch_dir(sd)

  for bad in ([]string{
    ".",           // the handle itself is already a value; there is nothing to name
    "..",
    "a/./b",       // would reduce to "a/b", and is still refused
    "a/../b",      // would reduce to "b"
    "./a",
    "a/..",
    "a//b",        // an empty segment
    "a/",          // ditto, at the end
    "",
  }) {
    src := fmt.aprintf(`loadfile {{ .dir = d, .path = "%s" }}`, bad)
    defer delete(src)
    _, ok, err := eval_with_builtins(src, "d", sd.handle)
    testing.expect(t, !ok, fmt.tprintf("%q must be refused as a sub-path", bad))
    testing.expect(t, strings.contains(err, "sub-path"), err)
  }

  // The same rule for a handle that came out of the context rather than out
  // of the test's own scope - it is one kind of thing, not two.
  _, ok, err := eval_with_builtins(`loadfile { .dir = ctx.dirs.here, .path = "../SPEC.md" }`, "", nil)
  testing.expect(t, !ok, "a handle from ctx.dirs is a sandbox like any other")
  testing.expect(t, strings.contains(err, "sub-path"), err)
}

// Absolute paths are the other half of the same rule, and the spelling
// differs per target: a leading "/" everywhere, plus a drive, a drive-relative
// name and an alternate data stream on Windows (fs_windows.odin).
@(test)
test_sub_paths_may_not_be_rooted :: proc(t: ^testing.T) {
  sd := make_scratch_dir(t, "sub_path_roots")
  defer remove_scratch_dir(sd)

  rooted := []string{"/etc/passwd", "/"}
  when ODIN_OS == .Windows {
    rooted = []string{"/etc/passwd", "/", "C:/Windows", "C:passwd", `\\server\share`, "name:stream"}
  }
  for bad in rooted {
    src := fmt.aprintf(`loadfile {{ .dir = d, .path = "%s" }}`, bad)
    defer delete(src)
    _, ok, err := eval_with_builtins(src, "d", sd.handle)
    testing.expect(t, !ok, fmt.tprintf("%q must be refused as a sub-path", bad))
    testing.expect(t, strings.contains(err, "sub-path"), err)
  }
}

// `.dir` is required, with nothing standing in for it: a call without one is
// an error naming the fix, not a call that falls back to somewhere (§16).
@(test)
test_a_call_without_a_dir_is_an_error :: proc(t: ^testing.T) {
  _, ok, err := eval_with_builtins(`loadfile { .path = "README.md" }`, "", nil)
  testing.expect(t, !ok, "a call has to name the directory it means")
  testing.expect(t, strings.contains(err, ".dir"), err)
  testing.expect(t, strings.contains(err, "ctx.dirs"), "the message should say where a handle comes from")

  // And a bare path is not a second spelling of it - the error says so
  // rather than guessing a directory.
  _, str_ok, str_err := eval_with_builtins(`loadfile "README.md"`, "", nil)
  testing.expect(t, !str_ok, "there is no bare-path form")
  testing.expect(t, strings.contains(str_err, "no bare-path form"), str_err)
}

// A run told about no directories cannot touch the filesystem at all - the
// permission is not what stops it, having nothing to name is.
@(test)
test_a_run_with_no_dirs_reaches_nothing :: proc(t: ^testing.T) {
  src := `ctx.dirs`
  ast := fs_parse(src)
  defer ast_destroy(&ast)

  interp := Interpreter{ast = &ast, src = src, current_ctx = test_root_context(fmt_scratch_path("no_dirs_cache"), "")}
  val, ok := eval_program(&interp, ast.root, make_global_env())
  testing.expect(t, ok, interp.error_message)
  dirs_table, is_table := val.(^Table_Value)
  testing.expect(t, is_table, "ctx.dirs is always a Table, even when it is empty")
  if is_table do testing.expect_value(t, len(dirs_table.entries), 0)
}

@(test)
test_builtin_loadfile_rejects_path_escape :: proc(t: ^testing.T) {
  sd := make_scratch_dir(t, "loadfile_escape_dir")
  defer remove_scratch_dir(sd)

  // Rejected by resolve_parent_beneath's own component check - a pure
  // string/logic decision, verifiable regardless of environment.
  _, ok, err := eval_with_builtins(`loadfile { .dir = d, .path = "../../etc/passwd" }`, "d", sd.handle)
  testing.expect(t, !ok, "loadfile must reject a path that escapes its directory")
  testing.expect(t, strings.contains(err, "loadfile"))
}

// ---- chperm / chctx ---------------------------------------------------------------

@(test)
test_builtin_chperm_denies_io_for_wrapped_expr :: proc(t: ^testing.T) {
  path := fmt_scratch_path("chperm_denied.txt")
  defer os.remove(path)
  name := scratch_name("chperm_denied.txt")
  defer delete(name)

  src := fmt.aprintf(`createfile {{ .dir = ctx.dirs.here, .path = "%s", .content = "x" }} chctx chperm {{ .name = "io", .enabled = 1 > 2 }}`, name)
  defer delete(src)
  _, ok, err := eval_with_builtins(src, "", nil)
  testing.expect(t, !ok, "createfile should be denied once chperm revokes io")
  testing.expect(t, strings.contains(err, "io permission not granted"))
  testing.expect(t, !os.exists(path), "no file should have been created")
}

@(test)
test_builtin_chperm_keeps_io_granted :: proc(t: ^testing.T) {
  path := fmt_scratch_path("chperm_allowed.txt")
  defer os.remove(path)
  name := scratch_name("chperm_allowed.txt")
  defer delete(name)

  src := fmt.aprintf(`createfile {{ .dir = ctx.dirs.here, .path = "%s", .content = "x" }} chctx chperm {{ .name = "io", .enabled = 1 < 2 }}`, name)
  defer delete(src)
  val, ok, err := eval_with_builtins(src, "", nil)
  testing.expect(t, ok, err)
  _, is_file := val.(^File_Value)
  testing.expect(t, is_file)
}

@(test)
test_builtin_chperm_leaves_other_permissions_alone :: proc(t: ^testing.T) {
  val, ok, err := eval_with_builtins(`ctx chctx chperm { .name = "net", .enabled = 1 < 2 }`, "", nil)
  testing.expect(t, ok, err)
  t2, is_table := val.(^Table_Value)
  testing.expect(t, is_table)
  perms_val, found := table_find(t2, "permissions")
  testing.expect(t, found)
  perms, perms_is_table := perms_val.(^Table_Value)
  testing.expect(t, perms_is_table)
  _, has_io := table_find(perms, "io") // root context grants io by default - chperm's "net" edit shouldn't remove it
  testing.expect(t, has_io)
  _, has_net := table_find(perms, "net")
  testing.expect(t, has_net)
}

// ---- filetext -----------------------------------------------------------------

@(test)
test_builtin_filetext_round_trips_createfile_content :: proc(t: ^testing.T) {
  path := fmt_scratch_path("filetext.txt")
  defer os.remove(path)
  name := scratch_name("filetext.txt")
  defer delete(name)

  src := fmt.aprintf(`filetext (createfile {{ .dir = ctx.dirs.here, .path = "%s", .content = "hello there" }})`, name)
  defer delete(src)
  val, ok, err := eval_with_builtins(src, "", nil)
  testing.expect(t, ok, err)
  s, is_str := val.(string)
  testing.expect(t, is_str)
  testing.expect_value(t, s, "hello there")
}

@(test)
test_builtin_filetext_rejects_directory :: proc(t: ^testing.T) {
  val, ok, _ := eval_with_builtins(`filetext (loadfile { .dir = ctx.dirs.here, .path = "examples" })`, "", nil)
  _ = val
  testing.expect(t, !ok, "filetext should refuse a directory File")
}

// ---- ctx.cache ------------------------------------------------------------------

@(private = "file")
remove_scratch_cache_dir :: proc(name: string) {
  dir := fmt_scratch_path(name)
  handle, err := os.open(dir)
  if err == nil {
    entries, _ := os.read_dir(handle, -1, context.temp_allocator)
    for entry in entries do os.remove(fmt.tprintf("%s/%s", dir, entry.name))
    os.close(handle)
  }
  os.remove(dir)
}

@(test)
test_builtin_cache_write_and_dedup :: proc(t: ^testing.T) {
  defer remove_scratch_cache_dir("cache_dedup")

  val1, ok1, err1 := eval_with_builtins(`createfile { .dir = ctx.cache, .content = "cached content" }`, "", nil, "cache_dedup")
  testing.expect(t, ok1, err1)
  fv1, is_file1 := val1.(^File_Value)
  testing.expect(t, is_file1)
  testing.expect_value(t, fv1.kind, File_Kind.Regular)
  testing.expect_value(t, string(fv1.content), "cached content")
  testing.expect(t, fv1.display_path != "")
  testing.expect(t, strings.contains(fv1.display_path, "sha256_"))

  // Writing the exact same content again dedupes - same display path, and
  // still only one file on disk (not an error, not a second entry).
  val2, ok2, err2 := eval_with_builtins(`createfile { .dir = ctx.cache, .content = "cached content" }`, "", nil, "cache_dedup")
  testing.expect(t, ok2, err2)
  fv2 := val2.(^File_Value)
  testing.expect_value(t, fv1.display_path, fv2.display_path)

  dir := fmt_scratch_path("cache_dedup")
  handle, derr := os.open(dir)
  testing.expect(t, derr == nil)
  entries, _ := os.read_dir(handle, -1, context.temp_allocator)
  os.close(handle)
  testing.expect_value(t, len(entries), 1)
}

@(test)
test_builtin_cache_different_content_gets_different_name :: proc(t: ^testing.T) {
  defer remove_scratch_cache_dir("cache_different")

  val1, ok1, _ := eval_with_builtins(`createfile { .dir = ctx.cache, .content = "content one" }`, "", nil, "cache_different")
  testing.expect(t, ok1)
  val2, ok2, _ := eval_with_builtins(`createfile { .dir = ctx.cache, .content = "content two" }`, "", nil, "cache_different")
  testing.expect(t, ok2)
  fv1 := val1.(^File_Value)
  fv2 := val2.(^File_Value)
  testing.expect(t, fv1.display_path != fv2.display_path)
}

@(test)
test_builtin_cache_is_not_searchable :: proc(t: ^testing.T) {
  defer remove_scratch_cache_dir("cache_not_searchable")

  // loadfile/symlink/readlink don't accept a Cache as .dir - only createfile
  // does. There's no way to look an entry back up by name from HashedBuild
  // source, only to write new content in.
  _, ok, _ := eval_with_builtins(`loadfile { .dir = ctx.cache, .path = "anything" }`, "", nil, "cache_not_searchable")
  testing.expect(t, !ok, "loadfile must not accept ctx.cache as a directory handle")
}

// NOTE: loadfile's successful read through an explicitly named `.dir` handle
// is intentionally not covered by a passing test here - this dev machine's
// WSL2 kernel fails openat() via a real directory fd whenever O_CREAT is
// absent (see the wsl2-openat-dirfd-bug memory), which is exactly what that
// read needs. The same containment logic (validate_sub_path/
// resolve_parent_beneath/resolve_target) is already exercised by the
// createfile/symlink/readlink tests above, which all succeed here since their
// final *at() calls either use O_CREAT or aren't `openat` at all. So the only
// piece this machine cannot run is open_and_load's read-only openat against a
// directory handle, which should work on a Linux host without this specific
// kernel bug.

// ---- failure semantics (§8/§16) ---------------------------------------------

// SPEC.md §8, resolved 2026-08-27: a failed builtin call is fatal, on the
// same terms as `check`/`error` - no enclosing `else` catches it. §16 used to
// claim the opposite ("catchable by an enclosing then/else"), so this pins
// the rule the evaluator actually implements against the section that now
// documents it.
@(test)
test_builtin_failure_is_not_caught_by_else :: proc(t: ^testing.T) {
  // A missing file: the `else` is right there, and still doesn't catch it.
  _, missing_ok, missing_err := eval_with_builtins(`(loadfile { .dir = ctx.dirs.here, .path = "definitely_not_here.txt" }) then 1 else 2`, "", nil)
  testing.expect(t, !missing_ok, "a failed loadfile must not be caught by an else")
  testing.expect(t, strings.contains(missing_err, "loadfile"))

  // A denied permission, same story - narrowing io away doesn't produce a
  // recoverable value, it ends the evaluation.
  denied := `(loadfile { .dir = ctx.dirs.here, .path = "SPEC.md" } chctx chperm { .name = "io", .enabled = 1 == 0 }) then 1 else 2`
  _, denied_ok, denied_err := eval_with_builtins(denied, "", nil)
  testing.expect(t, !denied_ok, "a denied loadfile must not be caught by an else")
  testing.expect(t, strings.contains(denied_err, "permission"))

  // A containment violation is a failure like any other (§16).
  sd := make_scratch_dir(t, "fatal_escape_dir")
  defer remove_scratch_dir(sd)
  _, escape_ok, _ := eval_with_builtins(`(loadfile { .dir = d, .path = "../SPEC.md" }) then 1 else 2`, "d", sd.handle)
  testing.expect(t, !escape_ok, "an escaping path must not be caught by an else")
}

// The other half of the same rule, for the two failure sources §8 always
// described that way - kept next to the builtin case so the three read as one
// rule rather than three coincidences.
@(test)
test_check_and_error_are_not_caught_by_else :: proc(t: ^testing.T) {
  _, check_ok, check_err := eval_with_builtins(`check(1 < 0, "invariant broken") 5 then 1 else 2`, "", nil)
  testing.expect(t, !check_ok, "a failed check must not be caught by an else")
  testing.expect(t, strings.contains(check_err, "invariant broken"))

  _, error_ok, error_err := eval_with_builtins(`(error "boom") then 1 else 2`, "", nil)
  testing.expect(t, !error_ok, "an error must not be caught by an else")
  testing.expect(t, strings.contains(error_err, "boom"))
}

// ---- display path construction (§3) -----------------------------------------

// A File's displayed path is now built as the value is, rather than read back
// off /proc/self/fd, because WASI can't turn a descriptor into a path at all.
// These pin the lexical rules that replaced the kernel's normalisation.
@(test)
test_display_join_cleans_paths_lexically :: proc(t: ^testing.T) {
  Case :: struct{ dir, name, want: string }
  for c in ([]Case{
    {"/a/b", "c.txt", "/a/b/c.txt"},
    // The four below can no longer arrive from a program - §16 refuses ".",
    // "..", and a root in a sub-path (validate_sub_path). They are still
    // pinned because display_join also builds the display paths of the
    // directories `--dir` named and of ctx.cache, out of what the *command
    // line* said, where all four are ordinary (open_root_dirs,
    // absolute_dir_path).
    {"/a/b", ".", "/a/b"},
    {"/a/b", "./c.txt", "/a/b/c.txt"},
    {"/a/b", "../c.txt", "/a/c.txt"},
    {"/a/b", "/elsewhere", "/elsewhere"}, // an absolute name replaces the directory
    {"/a//b", "c", "/a/b/c"},
    {"", "c.txt", "c.txt"},             // no base directory known
  }) {
    got := display_join(c.dir, c.name)
    defer delete(got)
    testing.expect_value(t, got, c.want)
  }
}

@(test)
test_clean_path_handles_roots_and_relatives :: proc(t: ^testing.T) {
  Case :: struct{ path, want: string }
  for c in ([]Case{
    {"/a/b/../..", "/"},   // popping past the root stops at the root
    {"/..", "/"},
    {"a/../b", "b"},
    {"a/../..", ".."},     // a relative path has no known parent, so ".." survives
    {".", "."},
    {"/a/./b/", "/a/b"},
  }) {
    got := clean_path(c.path)
    defer delete(got)
    testing.expect_value(t, got, c.want)
  }
}

// A fatal failure ends the program wherever it happens (§8), but §2 has
// already started any async work in reach - including down branches whose
// value gets discarded. The run therefore waits for those tasks before it
// ends, so a program can't exit with a createfile half-written. Here the
// `error` fires while the write is still in flight, and the file must exist
// afterwards regardless.
@(test)
test_async_work_finishes_even_when_the_program_fails :: proc(t: ^testing.T) {
  sd := make_scratch_dir(t, "async_drain_dir")
  defer remove_scratch_dir(sd)

  src := `let pending (async (createfile { .dir = d, .path = "written.txt", .content = "survived" })); error "fatal"`
  _, ok, err := eval_with_builtins(src, "d", sd.handle)
  testing.expect(t, !ok, "the error must still be fatal")
  testing.expect(t, strings.contains(err, "fatal"))

  content, read_err := os.read_entire_file(fmt.tprintf("%s/written.txt", sd.path), context.temp_allocator)
  testing.expect(t, read_err == nil, "the async write must have completed before the program ended")
  if read_err == nil do testing.expect_value(t, string(content), "survived")
}
