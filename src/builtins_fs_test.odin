package hashedbuild

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
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

  fd, ferr := linux.openat(linux.AT_FDCWD, strings.clone_to_cstring(path, context.temp_allocator), {.DIRECTORY})
  testing.expect(t, ferr == .NONE, "could not open scratch test directory")

  h := new(File_Value)
  h.kind = .Directory
  h.dir_fd = fd
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
  linux.close(s.handle.dir_fd)
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

  val, ok = eval(&interp, ast.root, env)
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
  if dfv, is_file := dir_val.(^File_Value); is_file do linux.close(dfv.dir_fd)
}

// ---- symlink / readlink ---------------------------------------------------------

@(test)
test_builtin_symlink_and_readlink_round_trip :: proc(t: ^testing.T) {
  sd := make_scratch_dir(t, "symlink_dir")
  defer remove_scratch_dir(sd)

  _, ok1, err1 := eval_with_builtins(`symlink { .dir = d, .path = "link", .target = "some/target" }`, "d", sd.handle)
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
  if is_dir_file do linux.close(dfv.dir_fd)
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
