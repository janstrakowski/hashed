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
// scope - "" means nothing extra to bind. ctx.cache points at a scratch dir
// under a name unique to the calling test (not the user's real cache dir,
// and not shared across tests - odin test may run tests in parallel, and
// tests that actually write to the cache need their own directory to avoid
// colliding with each other).
@(private = "file")
eval_with_builtins :: proc(src: string, extra_name: string, extra_val: Value, cache_name := "cache_default") -> (val: Value, ok: bool, err: string) {
  ast := fs_parse(src)
  defer ast_destroy(&ast)

  interp := Interpreter{ast = &ast, src = src, current_ctx = make_root_context(fmt_scratch_path(cache_name))}
  env := make_global_env()
  if extra_name != "" do env_bind(env, extra_name, extra_val)

  // eval_program, like every real entry point: it awaits a bare top-level
  // async and drains any task nothing awaited (eval_async.odin).
  val, ok = eval_program(&interp, ast.root, env)
  return val, ok, interp.error_message
}

// ---- createfile ---------------------------------------------------------------

@(test)
test_builtin_createfile_unsandboxed :: proc(t: ^testing.T) {
  path := fmt_scratch_path("createfile_plain.txt")
  defer os.remove(path)

  src := fmt.aprintf(`createfile {{ .path = "%s", .content = "hello" }}`, path)
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

  src := fmt.aprintf(`createfile {{ .path = "%s", .content = "a" }}`, path)
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

  load_dir_src := fmt.aprintf(`loadfile "%s"`, sd.path)
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
test_builtin_loadfile_unsandboxed_file_and_directory :: proc(t: ^testing.T) {
  path := fmt_scratch_path("loadfile_plain.txt")
  _ = os.write_entire_file(path, transmute([]u8)string("content!"))
  defer os.remove(path)

  load_src := fmt.aprintf(`loadfile "%s"`, path)
  defer delete(load_src)
  val, ok, err := eval_with_builtins(load_src, "", nil)
  testing.expect(t, ok, err)
  fv, is_file := val.(^File_Value)
  testing.expect(t, is_file)
  testing.expect_value(t, fv.kind, File_Kind.Regular)
  testing.expect_value(t, string(fv.content), "content!")

  load_dir_src := fmt.aprintf(`loadfile "%s"`, repo_root())
  defer delete(load_dir_src)
  dir_val, dir_ok, dir_err := eval_with_builtins(load_dir_src, "", nil)
  testing.expect(t, dir_ok, dir_err)
  dfv, is_dir_file := dir_val.(^File_Value)
  testing.expect(t, is_dir_file)
  testing.expect_value(t, dfv.kind, File_Kind.Directory)
  if is_dir_file do fs_close(dfv.dir_fd)
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

  src := fmt.aprintf(`createfile {{ .path = "%s", .content = "x" }} chctx chperm {{ .name = "io", .enabled = 1 > 2 }}`, path)
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

  src := fmt.aprintf(`createfile {{ .path = "%s", .content = "x" }} chctx chperm {{ .name = "io", .enabled = 1 < 2 }}`, path)
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

  src := fmt.aprintf(`filetext (createfile {{ .path = "%s", .content = "hello there" }})`, path)
  defer delete(src)
  val, ok, err := eval_with_builtins(src, "", nil)
  testing.expect(t, ok, err)
  s, is_str := val.(string)
  testing.expect(t, is_str)
  testing.expect_value(t, s, "hello there")
}

@(test)
test_builtin_filetext_rejects_directory :: proc(t: ^testing.T) {
  src := fmt.aprintf(`filetext (loadfile "%s")`, repo_root())
  defer delete(src)
  val, ok, _ := eval_with_builtins(src, "", nil)
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

// NOTE: loadfile's successful dir-relative *read* ({ .dir, .path } naming an
// existing file) is intentionally not covered by a passing test here - this
// dev machine's WSL2 kernel fails openat() via a real directory fd whenever
// O_CREAT is absent (see the wsl2-openat-dirfd-bug memory), which is exactly
// what that read needs. The same containment logic (resolve_parent_beneath/
// resolve_target) is already exercised by the createfile/symlink/readlink
// tests above, which all succeed here since their final *at() calls either
// use O_CREAT or aren't `openat` at all - so the only genuinely untested
// piece is open_and_load's final read-only openat call, which is otherwise
// identical to loadfile's unsandboxed form tested above and should work
// correctly on a Linux host without this specific kernel bug.

// ---- failure semantics (§8/§16) ---------------------------------------------

// SPEC.md §8, resolved 2026-08-27: a failed builtin call is fatal, on the
// same terms as `check`/`error` - no enclosing `else` catches it. §16 used to
// claim the opposite ("catchable by an enclosing then/else"), so this pins
// the rule the evaluator actually implements against the section that now
// documents it.
@(test)
test_builtin_failure_is_not_caught_by_else :: proc(t: ^testing.T) {
  // A missing file: the `else` is right there, and still doesn't catch it.
  _, missing_ok, missing_err := eval_with_builtins(`(loadfile "definitely_not_here.txt") then 1 else 2`, "", nil)
  testing.expect(t, !missing_ok, "a failed loadfile must not be caught by an else")
  testing.expect(t, strings.contains(missing_err, "loadfile"))

  // A denied permission, same story - narrowing io away doesn't produce a
  // recoverable value, it ends the evaluation.
  denied := `(loadfile "SPEC.md" chctx chperm { .name = "io", .enabled = 1 == 0 }) then 1 else 2`
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
    {"/a/b", ".", "/a/b"},              // `loadfile "."` - a directory handle on itself
    {"/a/b", "./c.txt", "/a/b/c.txt"},
    {"/a/b", "../c.txt", "/a/c.txt"},   // only reachable unsandboxed; .dir rejects ".."
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
