package hashedbuild

import "core:crypto/hash"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// SPEC.md §16: loadfile/createfile/symlink/readlink. Not syntax - ordinary
// Function values pre-bound in the global scope (see make_global_env), each
// gated by ctx.permissions.io (§9) checked live at call time.
//
// Path containment ("a sub path cannot point above its directory", §16) is
// done via a manual, component-by-component walk (resolve_parent_beneath)
// rather than openat2's RESOLVE_BENEATH: tested directly on this project's
// dev machine, openat2's resolve flags turned out to hit an environment-
// specific kernel bug (see the wsl2-openat-dirfd-bug memory) - and more
// generally, openat2 itself is a newer syscall (Linux 5.6+) with uneven
// support, whereas the plain *at() family used here has been portable for
// decades. Each intermediate directory component is opened with O_NOFOLLOW,
// so a symlink placed inside the sandboxed directory - even one that would
// resolve back inside it - is rejected outright, not just one that escapes;
// simpler and safer than trying to distinguish the two.

// ---- root context / global env ------------------------------------------------

// The context every real HashedBuild program starts with (SPEC.md §9):
// io is granted by default at the root; `withctx` narrows it for a sub-scope.
// `cache_dir_override` is the CLI's `--cache-dir`, if given; "" means resolve
// the XDG-default location instead (see resolve_cache_dir).
make_root_context :: proc(cache_dir_override: string = "") -> Value {
  perms := new(Table_Value)
  append(&perms.entries, Table_Entry_Value{key = "io", value = Nothing_Value{}})

  cache := new(Cache_Value)
  cache.dir_path = resolve_cache_dir(cache_dir_override)

  ctx_table := new(Table_Value)
  append(&ctx_table.entries, Table_Entry_Value{key = "permissions", value = perms})
  append(&ctx_table.entries, Table_Entry_Value{key = "cache", value = cache})
  return ctx_table
}

// XDG Base Directory spec: $XDG_CACHE_HOME/hashedbuild, falling back to
// $HOME/.cache/hashedbuild if XDG_CACHE_HOME isn't set (or is empty).
//
// On Windows the fallback is %LOCALAPPDATA%\hashedbuild instead - the place
// Windows keeps regenerable per-user data, which is the role $HOME/.cache
// plays elsewhere. $HOME is normally unset there, so the XDG fallback would
// otherwise land on "/.cache/hashedbuild", i.e. the root of whichever drive
// happened to be current. XDG_CACHE_HOME still wins when it is set, on every
// target, so the documented override behaves the same wherever a program runs.
@(private = "file")
resolve_cache_dir :: proc(override: string) -> string {
  if override != "" do return override
  if xdg := os.get_env_alloc("XDG_CACHE_HOME", context.temp_allocator); xdg != "" {
    return strings.concatenate({to_forward_slashes(xdg), "/hashedbuild"})
  }
  when WINDOWS_PATHS {
    if local := os.get_env_alloc("LOCALAPPDATA", context.temp_allocator); local != "" {
      return strings.concatenate({to_forward_slashes(local), "/hashedbuild"})
    }
  }
  return strings.concatenate({os.get_env_alloc("HOME", context.temp_allocator), "/.cache/hashedbuild"})
}

@(private = "file")
new_native_function :: proc(name: string, fn: Native_Fn, closure: Value = nil) -> Value {
  f := new(Function_Value)
  f.native = fn
  f.native_closure = closure
  f.native_name = name // a native hashes as its name, not its address - see Function_Value
  return f
}

// The global scope every real program's top-level expression evaluates in -
// the filesystem builtins, pre-bound by name (§16).
make_global_env :: proc() -> ^Env {
  env := env_make_child(nil)
  env_bind(env, "loadfile", new_native_function("loadfile", builtin_loadfile))
  env_bind(env, "createfile", new_native_function("createfile", builtin_createfile))
  env_bind(env, "symlink", new_native_function("symlink", builtin_symlink))
  env_bind(env, "readlink", new_native_function("readlink", builtin_readlink))
  env_bind(env, "chperm", new_native_function("chperm", builtin_chperm))
  env_bind(env, "filetext", new_native_function("filetext", builtin_filetext))
  return env
}

// Also read by eval.odin, where `cached` (§15) gates on it: the cache is a
// directory on disk, so reading or writing an entry is as much an I/O
// operation as §16's builtins are.
ctx_allows_io :: proc(interp: ^Interpreter) -> bool {
  t, is_table := interp.current_ctx.(^Table_Value)
  if !is_table do return false
  perms_val, found := table_find(t, "permissions")
  if !found do return false
  perms, perms_is_table := perms_val.(^Table_Value)
  if !perms_is_table do return false
  _, io_found := table_find(perms, "io")
  return io_found
}

// The directory unsandboxed (no .dir given) loadfile/createfile calls
// resolve relative paths against - the running source file's own directory
// if one was set up (see Interpreter.base_dir_fd), else the process's cwd.
@(private = "file")
unsandboxed_dir_fd :: proc(interp: ^Interpreter) -> Fs_Fd {
  if interp.has_base_dir do return interp.base_dir_fd
  return fs_cwd_dir()
}

// ---- path containment -----------------------------------------------------------

// Resolves `sub_path` relative to `base_fd`, walking one component at a time
// and refusing to leave `base_fd`'s subtree: a literal ".."/absolute path is
// rejected outright, and every intermediate directory is opened with
// O_NOFOLLOW so a symlink anywhere along the way - not just one that would
// resolve outside - is rejected too. Returns the fd of the final component's
// *parent* plus that component's own name, so the caller acts on it with an
// ordinary *at() syscall (open/create/symlinkat/readlinkat) - the final
// component can't itself smuggle a "..", since any "/" in it would mean the
// split below was wrong, not that this single name escapes anything.
@(private = "file")
resolve_parent_beneath :: proc(base_fd: Fs_Fd, sub_path: string) -> (parent_fd: Fs_Fd, basename: string, err: Fs_Error) {
  if len(sub_path) == 0 || is_absolute_path(sub_path) {
    return FS_INVALID_FD, "", .Access
  }
  when WINDOWS_PATHS {
    // A colon is never part of an ordinary name on Windows. It introduces
    // either a drive-relative path ("C:x", which resolves against that
    // drive's own working directory, not against anything here) or an
    // alternate data stream ("name:stream", a second body hidden behind the
    // same entry). Neither is a sub path of this directory, so both are
    // refused outright rather than walked - the walk below splits on
    // separators, and would otherwise hand either one through as a basename.
    if strings.index_byte(sub_path, ':') >= 0 {
      return FS_INVALID_FD, "", .Access
    }
  }

  cur_fd := base_fd
  remaining := sub_path
  for {
    slash := index_path_sep(remaining)
    if slash < 0 {
      if remaining == "" || remaining == ".." {
        if cur_fd != base_fd do fs_close(cur_fd)
        return FS_INVALID_FD, "", .Access
      }
      return cur_fd, remaining, .None
    }

    component := remaining[:slash]
    remaining = remaining[slash + 1:]
    if component == "" || component == ".." {
      if cur_fd != base_fd do fs_close(cur_fd)
      return FS_INVALID_FD, "", .Access
    }
    if component == "." do continue // stays at the same fd

    next_fd, open_err := fs_open_dir_at(cur_fd, component, true)
    if cur_fd != base_fd do fs_close(cur_fd)
    if open_err != .None do return FS_INVALID_FD, "", open_err
    cur_fd = next_fd
  }
}

@(private = "file")
Resolved_Path :: struct {
  fd:          Fs_Fd,
  basename:    string,
  needs_close: bool, // true iff `fd` was freshly opened by resolve_parent_beneath, not just the caller's own dir handle
  // The directory this resolved against, as a path - the handle's own
  // display path, or the base directory for an unsandboxed call. The File
  // this produces displays `display_dir` joined with the sub-path the caller
  // asked for (§3), which is why it travels alongside the descriptor.
  display_dir: string,
}

@(private = "file")
close_resolved :: proc(r: Resolved_Path) {
  if r.needs_close do fs_close(r.fd)
}

// Resolves an optional `.dir` + required `.path` pair out of a builtin's
// Table argument. If `.dir` is absent: unsandboxed (relative to the running
// source file's own directory, or the process's cwd if there isn't one - see
// unsandboxed_dir_fd), unless `dir_required` says otherwise (symlink/
// readlink, §16 - a symlink is always an entry inside some directory).
@(private = "file")
resolve_target :: proc(interp: ^Interpreter, t: ^Table_Value, path_str: string, dir_required: bool) -> (r: Resolved_Path, err_msg: string, ok: bool) {
  dir_val, has_dir := table_find(t, "dir")
  if !has_dir {
    if dir_required do return {}, "requires a .dir directory handle", false
    return Resolved_Path{fd = unsandboxed_dir_fd(interp), basename = path_str, display_dir = unsandboxed_dir_path(interp)}, "", true
  }
  dir_file, dir_ok := dir_val.(^File_Value)
  if !dir_ok || dir_file.kind != .Directory {
    return {}, ".dir must be a directory File", false
  }
  parent_fd, basename, rerr := resolve_parent_beneath(dir_file.dir_fd, path_str)
  if rerr != .None {
    return {}, fmt.tprintf("path escapes its directory or doesn't exist (%v)", rerr), false
  }
  return Resolved_Path{
    fd = parent_fd, basename = basename,
    needs_close = parent_fd != dir_file.dir_fd,
    display_dir = dir_file.display_path,
  }, "", true
}

// ---- display paths (§3) -------------------------------------------------------

// A File shows the path it was reached by (SPEC.md §3), so that path is built
// as the value is - joined from the directory handle it came through, or from
// the base directory for an unsandboxed call - and stored in the File_Value.
//
// It used to be read back off the kernel via /proc/self/fd, which was tidier
// (it resolved symlinks and normalised on its own) but doesn't port: WASI has
// no way at all to turn a descriptor back into a path, and nothing in the
// *at() family offers one either. Constructing the path costs a lexical
// cleanup below and gives the same answer for every path a program can
// actually write, absolute and free of "." and ".." segments.

// The directory an unsandboxed loadfile/createfile resolves against, as a
// path (see Interpreter.base_dir_path): the running source file's own
// directory, or the process's cwd when there isn't one.
@(private = "file")
unsandboxed_dir_path :: proc(interp: ^Interpreter) -> string {
  if interp.has_base_dir && interp.base_dir_path != "" do return interp.base_dir_path
  cwd, err := os.get_working_directory(context.temp_allocator)
  if err != nil do return "" // no cwd to speak of: fall back to the path as written
  return cwd
}

// ---- what a path looks like on this target ------------------------------------
//
// Linux and WASI have one separator ('/') and one root ("/"). Windows has two
// separators and three kinds of root - a named drive ("C:/"), the current
// drive ("/"), and a UNC share ("//server/share") - and, decisively, treats
// '\' as a separator where Linux treats it as an ordinary character in a
// filename. That last difference is why none of this can simply be switched
// on everywhere: folding '\' to '/' on Linux would rename files.
//
// Paths are still carried '/'-separated on every target, so a Windows display
// path reads "C:/Users/you/project" (§3). Win32 accepts that form, and
// fs_windows.odin translates to backslashes at the syscall boundary.
WINDOWS_PATHS :: ODIN_OS == .Windows

is_path_sep :: proc(c: u8) -> bool {
  when WINDOWS_PATHS {
    return c == '/' || c == '\\'
  } else {
    return c == '/'
  }
}

// The first separator in `s`, or -1. What resolve_parent_beneath splits a sub
// path on, which is why it has to know about '\' on Windows: treating a
// backslash as an ordinary character there would hand "..\..\escape" through
// as a single basename, and §16's containment would be enforced on a name
// the OS would then read as three components.
index_path_sep :: proc(s: string) -> int {
  for i in 0 ..< len(s) do if is_path_sep(s[i]) do return i
  return -1
}

// "C:/..." - rooted on a named drive. Always false off Windows, where a colon
// is an ordinary character in a filename.
is_drive_absolute :: proc(p: string) -> bool {
  when !WINDOWS_PATHS {
    return false
  } else {
    if len(p) < 3 || p[1] != ':' || !is_path_sep(p[2]) do return false
    return (p[0] >= 'a' && p[0] <= 'z') || (p[0] >= 'A' && p[0] <= 'Z')
  }
}

// The length of `p`'s root: 0 when relative, 1 for "/x", 3 for "C:/x", and
// through the share name for "//server/share/x".
path_root_len :: proc(p: string) -> int {
  when WINDOWS_PATHS {
    if is_drive_absolute(p) do return 3
    if len(p) >= 2 && is_path_sep(p[0]) && is_path_sep(p[1]) {
      i := 2
      for i < len(p) && !is_path_sep(p[i]) do i += 1 // server
      if i < len(p) do i += 1
      for i < len(p) && !is_path_sep(p[i]) do i += 1 // share
      return i
    }
  }
  if len(p) > 0 && is_path_sep(p[0]) do return 1
  return 0
}

// Does this path start at a root rather than somewhere relative?
is_absolute_path :: proc(p: string) -> bool {
  return path_root_len(p) > 0
}

// Folds '\' to '/' on Windows, where both are separators. A no-op elsewhere -
// and it has to be, since '\' is a legal character in a Linux filename.
// Returns `path` itself when there is nothing to fold, so the result is only
// ever a view; clone it if it needs to outlive the argument.
to_forward_slashes :: proc(path: string, allocator := context.temp_allocator) -> string {
  when !WINDOWS_PATHS {
    return path
  } else {
    if strings.index_byte(path, '\\') < 0 do return path
    b := strings.builder_make(allocator)
    for i in 0 ..< len(path) {
      c := path[i]
      if c == '\\' do c = '/'
      strings.write_byte(&b, c)
    }
    return strings.to_string(b)
  }
}

// Joins `name` onto `dir` and cleans the result lexically: an absolute name
// replaces the directory outright, "." segments drop out, and ".." pops one
// segment. Lexical on purpose - it must not touch the filesystem, since it
// runs for paths that are about to be created as well as ones that exist.
display_join :: proc(dir: string, name: string) -> string {
  joined: string
  switch {
  case is_absolute_path(name):
    joined = name
  case dir == "":
    joined = name
  case:
    joined = strings.concatenate({dir, "/", name}, context.temp_allocator)
  }
  return clean_path(joined)
}

// Makes a directory path absolute against the process's cwd, for the base
// directory a source file's relative paths resolve against. Called once per
// run, at setup, by whoever opens that directory (main.odin, editor.odin).
absolute_dir_path :: proc(dir_path: string) -> string {
  if is_absolute_path(dir_path) do return clean_path(dir_path)
  cwd, err := os.get_working_directory(context.temp_allocator)
  if err != nil do return clean_path(dir_path)
  return display_join(cwd, dir_path)
}

// Lexical path cleanup: collapses "//", drops "." segments, pops a segment
// for each "..", and keeps whatever root the path started at.
clean_path :: proc(path: string, allocator := context.allocator) -> string {
  p := to_forward_slashes(path)

  root_len := path_root_len(p)
  root := p[:root_len]
  absolute := root_len > 0

  segments := make([dynamic]string, 0, 8, context.temp_allocator)
  for segment in strings.split(p[root_len:], "/", context.temp_allocator) {
    switch segment {
    case "", ".":
      continue
    case "..":
      // A ".." above an absolute root has nowhere to go and vanishes; on a
      // relative path it has to be kept, since there's no known parent.
      if len(segments) > 0 && segments[len(segments) - 1] != ".." {
        pop(&segments)
      } else if !absolute {
        append(&segments, segment)
      }
    case:
      append(&segments, segment)
    }
  }
  body := strings.join(segments[:], "/", context.temp_allocator)
  if absolute {
    // "/" and "C:/" already end in a separator; a UNC root does not.
    if is_path_sep(root[len(root) - 1]) do return strings.concatenate({root, body}, allocator)
    if body == "" do return strings.clone(root, allocator)
    return strings.concatenate({root, "/", body}, allocator)
  }
  if body == "" do return strings.clone(".", allocator)
  return strings.clone(body, allocator)
}

// ---- loadfile ---------------------------------------------------------------------

@(private = "file")
open_and_load :: proc(interp: ^Interpreter, dir_fd: Fs_Fd, path: string, no_follow_final: bool, display: string) -> (Value, bool) {
  // Type first, then open: a directory and a regular file need different
  // opens, and asking afterwards would mean opening a directory as a file -
  // legal on Linux, refused by WASI, whose rights are per file type.
  is_dir, stat_err := fs_stat_is_dir_at(dir_fd, path, no_follow_final)
  if stat_err != .None do return fail(interp, fmt.tprintf("loadfile: could not open %s (%v)", path, stat_err))

  if is_dir {
    // A directory handle outlives this call: it is what further .dir-relative
    // loadfile/createfile/symlink/readlink calls resolve against (§16).
    dir_handle, dir_err := fs_open_dir_at(dir_fd, path, no_follow_final)
    if dir_err != .None do return fail(interp, fmt.tprintf("loadfile: could not open directory %s (%v)", path, dir_err))
    fv := new(File_Value)
    fv.kind = .Directory
    fv.dir_fd = dir_handle
    fv.display_path = display
    return fv, true
  }

  fd, err := fs_open_read_at(dir_fd, path, no_follow_final)
  if err != .None do return fail(interp, fmt.tprintf("loadfile: could not open %s (%v)", path, err))
  defer fs_close(fd)

  content, read_err := fs_read_all(fd)
  if read_err != .None do return fail(interp, fmt.tprintf("loadfile: read error on %s (%v)", path, read_err))
  fv := new(File_Value)
  fv.kind = .Regular
  fv.content = content
  fv.display_path = display
  return fv, true
}

@(private = "file")
builtin_loadfile :: proc(interp: ^Interpreter, _: Value, arg: Value) -> (Value, bool) {
  if !ctx_allows_io(interp) do return fail(interp, "loadfile: io permission not granted in the current context")

  if path, is_str := arg.(string); is_str {
    return open_and_load(interp, unsandboxed_dir_fd(interp), path, false, display_join(unsandboxed_dir_path(interp), path))
  }

  t, is_table := arg.(^Table_Value)
  if !is_table do return fail(interp, "loadfile expects a Utf8 path or a { .dir, .path } Table")
  path_val, has_path := table_find(t, "path")
  path_str, path_ok := path_val.(string)
  if !has_path || !path_ok do return fail(interp, "loadfile's Table form needs a Utf8 .path")

  r, err_msg, ok := resolve_target(interp, t, path_str, true)
  if !ok do return fail(interp, fmt.tprintf("loadfile: %s", err_msg))
  defer close_resolved(r)

  return open_and_load(interp, r.fd, r.basename, true, display_join(r.display_dir, path_str))
}

// ---- filetext ---------------------------------------------------------------------

// filetext <file> -> Utf8 (§16) - the minimal "get content back out of a
// File" accessor: not gated by io, since the actual read already happened
// when loadfile produced the File - this just views the already-in-memory
// bytes as text.
@(private = "file")
builtin_filetext :: proc(interp: ^Interpreter, _: Value, arg: Value) -> (Value, bool) {
  fv, is_file := arg.(^File_Value)
  if !is_file do return fail(interp, "filetext expects a File")
  if fv.kind != .Regular do return fail(interp, "filetext expects a regular file, not a directory")
  if !utf8.valid_string(string(fv.content)) do return fail(interp, "filetext: content is not valid UTF-8")
  return strings.clone(string(fv.content)), true
}

// ---- createfile -------------------------------------------------------------------

@(private = "file")
builtin_createfile :: proc(interp: ^Interpreter, _: Value, arg: Value) -> (Value, bool) {
  if !ctx_allows_io(interp) do return fail(interp, "createfile: io permission not granted in the current context")

  t, is_table := arg.(^Table_Value)
  if !is_table do return fail(interp, "createfile expects a { [.dir], .path, .content } Table")

  content_val, has_content := table_find(t, "content")
  if !has_content do return fail(interp, "createfile needs .content")
  content_bytes: []u8
  #partial switch v in content_val {
  case string: content_bytes = transmute([]u8)v
  case []u8: content_bytes = v
  case:
    return fail(interp, "createfile's .content must be Utf8 or Bytes")
  }

  // ctx.cache (§9/§16) is accepted anywhere a directory handle is - names
  // don't matter there, so .path is unused (not even required) in this case.
  if dir_val, has_dir := table_find(t, "dir"); has_dir {
    if cache, is_cache := dir_val.(^Cache_Value); is_cache {
      return createfile_in_cache(interp, cache, content_bytes)
    }
  }

  path_val, has_path := table_find(t, "path")
  path_str, path_ok := path_val.(string)
  if !has_path || !path_ok do return fail(interp, "createfile needs a Utf8 .path")

  r, err_msg, ok := resolve_target(interp, t, path_str, false)
  if !ok do return fail(interp, fmt.tprintf("createfile: %s", err_msg))
  defer close_resolved(r)

  // Exclusive for now (SPEC.md §16) - fails if the file already exists.
  fd, err := fs_create_exclusive_at(r.fd, r.basename)
  if err != .None do return fail(interp, fmt.tprintf("createfile: could not create %s (%v)", r.basename, err))
  defer fs_close(fd)

  if werr := fs_write_all(fd, content_bytes); werr != .None {
    return fail(interp, fmt.tprintf("createfile: write error (%v)", werr))
  }

  fv := new(File_Value)
  fv.kind = .Regular
  fv.content = slice.clone(content_bytes)
  fv.display_path = display_join(r.display_dir, path_str)
  return fv, true
}

// ---- ctx.cache (§9/§16) -------------------------------------------------------------

// "sha256_<base64url, no padding>" of the content - the entry's name IS its
// content hash, which is what makes writing the same content twice a no-op
// dedup (below) rather than a collision.
@(private = "file")
cache_entry_name :: proc(content: []u8) -> string {
  digest := hash.hash_bytes(.SHA256, content, context.temp_allocator)
  encoded, _ := base64.encode(digest, base64.ENC_URL_TABLE, context.temp_allocator)
  return strings.concatenate({"sha256_", strings.trim_right(encoded, "=")})
}

// Opens (creating if necessary) the cache's backing directory, the first
// time it's actually needed - not at program start, so a program that never
// touches the cache never creates it. §15's `cached` shares the directory and
// so calls this too (cache_store.odin), with the same laziness.
//
// Unsynchronised, and safe to leave that way: two `async` branches reaching
// here at once both open the directory and one of the two descriptors is
// dropped on the floor, which costs a descriptor and nothing else - both are
// valid, and both name the same directory. A mutex would be the wrong shape
// anyway, since the store below is already written to be safe against *other
// processes* on the same directory (see cache_store.odin on committing by
// rename), which is the harder case and covers this one.
ensure_cache_dir_open :: proc(cache: ^Cache_Value) -> Fs_Error {
  if cache.opened do return .None
  fs_make_dirs(cache.dir_path)
  fd, err := fs_open_dir_path(cache.dir_path)
  if err != .None do return err
  cache.dir_fd = fd
  cache.opened = true
  return .None
}

@(private = "file")
createfile_in_cache :: proc(interp: ^Interpreter, cache: ^Cache_Value, content: []u8) -> (Value, bool) {
  if errno := ensure_cache_dir_open(cache); errno != .None {
    return fail(interp, fmt.tprintf("createfile: could not open cache directory %s (%v)", cache.dir_path, errno))
  }

  name := cache_entry_name(content)
  cname := strings.clone_to_cstring(name, context.temp_allocator)

  fd, err := fs_create_exclusive_at(cache.dir_fd, name)
  #partial switch err {
  case .None:
    defer fs_close(fd)
    if werr := fs_write_all(fd, content); werr != .None {
      return fail(interp, fmt.tprintf("createfile: cache write error (%v)", werr))
    }
  case .Exists:
    // Dedup: an entry with this exact content hash already exists (from this
    // run or a previous one) - reuse it rather than failing or rewriting.
  case:
    return fail(interp, fmt.tprintf("createfile: could not write to cache (%v)", err))
  }

  fv := new(File_Value)
  fv.kind = .Regular
  fv.content = slice.clone(content)
  fv.display_path = strings.concatenate({cache.dir_path, "/", name})
  return fv, true
}

// ---- symlink / readlink -------------------------------------------------------------

@(private = "file")
builtin_symlink :: proc(interp: ^Interpreter, _: Value, arg: Value) -> (Value, bool) {
  if !ctx_allows_io(interp) do return fail(interp, "symlink: io permission not granted in the current context")

  t, is_table := arg.(^Table_Value)
  if !is_table do return fail(interp, "symlink expects a { .dir, .path, .target } Table")

  path_val, has_path := table_find(t, "path")
  target_val, has_target := table_find(t, "target")
  path_str, path_ok := path_val.(string)
  target_str, target_ok := target_val.(string)
  if !has_path || !path_ok do return fail(interp, "symlink needs a Utf8 .path")
  if !has_target || !target_ok do return fail(interp, "symlink needs a Utf8 .target")

  r, err_msg, ok := resolve_target(interp, t, path_str, true) // .dir is required - a symlink is always inside some directory
  if !ok do return fail(interp, fmt.tprintf("symlink: %s", err_msg))
  defer close_resolved(r)

  if err := fs_symlink_at(r.fd, r.basename, target_str); err != .None {
    return fail(interp, fmt.tprintf("symlink: could not create %s (%v)", r.basename, err))
  }

  return Nothing_Value{}, true // a symlink isn't a File value in its own right (SPEC.md §3)
}

@(private = "file")
builtin_readlink :: proc(interp: ^Interpreter, _: Value, arg: Value) -> (Value, bool) {
  if !ctx_allows_io(interp) do return fail(interp, "readlink: io permission not granted in the current context")

  t, is_table := arg.(^Table_Value)
  if !is_table do return fail(interp, "readlink expects a { .dir, .path } Table")

  path_val, has_path := table_find(t, "path")
  path_str, path_ok := path_val.(string)
  if !has_path || !path_ok do return fail(interp, "readlink needs a Utf8 .path")

  r, err_msg, ok := resolve_target(interp, t, path_str, true)
  if !ok do return fail(interp, fmt.tprintf("readlink: %s", err_msg))
  defer close_resolved(r)

  target, err := fs_readlink_at(r.fd, r.basename)
  if err != .None do return fail(interp, fmt.tprintf("readlink: could not read %s (%v)", r.basename, err))
  return target, true
}

// ---- chperm (§16) -----------------------------------------------------------------

// chperm { .name = <tag>, .enabled = <bool> } -> a ctx-changing function
// (SPEC.md §7/§9's `chctx`), i.e. this is a curried two-argument builtin:
// calling chperm builds and returns the actual oldctx->newctx function,
// carrying {name, enabled} along via native_closure since Odin `proc` values
// can't otherwise capture locals.
@(private = "file")
builtin_chperm :: proc(interp: ^Interpreter, _: Value, arg: Value) -> (Value, bool) {
  t, is_table := arg.(^Table_Value)
  if !is_table do return fail(interp, "chperm expects a { .name, .enabled } Table")

  name_val, has_name := table_find(t, "name")
  enabled_val, has_enabled := table_find(t, "enabled")
  name_str, name_ok := name_val.(string)
  enabled_bool, enabled_ok := enabled_val.(bool)
  if !has_name || !name_ok do return fail(interp, "chperm needs a Utf8 .name")
  if !has_enabled || !enabled_ok do return fail(interp, "chperm needs a Boolean .enabled")

  closure := new(Table_Value)
  append(&closure.entries, Table_Entry_Value{key = "name", value = name_str})
  append(&closure.entries, Table_Entry_Value{key = "enabled", value = enabled_bool})
  // The name is what this function hashes as (§15, Function_Value), so it has
  // to distinguish the ctx-changer chperm returns from chperm itself; its
  // captured {name, enabled} closure hashes alongside it, which is what makes
  // two differently-configured ctx-changers different values.
  return new_native_function("chperm.apply", apply_chperm, closure), true
}

// The actual oldctx -> newctx function chperm returns: a copy of `old_ctx`
// with `.permissions.<name>` present (enabled) or absent (not), every other
// field - including any other permission - left exactly as it was.
@(private = "file")
apply_chperm :: proc(interp: ^Interpreter, closure: Value, old_ctx: Value) -> (Value, bool) {
  closure_t, _ := closure.(^Table_Value)
  name_val, _ := table_find(closure_t, "name")
  enabled_val, _ := table_find(closure_t, "enabled")
  name_str := name_val.(string)
  enabled := enabled_val.(bool)

  old_t, old_is_table := old_ctx.(^Table_Value)
  old_perms: ^Table_Value
  if old_is_table {
    if p, found := table_find(old_t, "permissions"); found {
      old_perms, _ = p.(^Table_Value)
    }
  }

  new_perms := new(Table_Value)
  if old_perms != nil {
    for entry in old_perms.entries {
      if key_str, ok := entry.key.(string); ok && key_str == name_str do continue // overridden below
      append(&new_perms.entries, entry)
    }
  }
  if enabled {
    append(&new_perms.entries, Table_Entry_Value{key = name_str, value = Nothing_Value{}})
  }

  new_ctx := new(Table_Value)
  if old_is_table {
    for entry in old_t.entries {
      if key_str, ok := entry.key.(string); ok && key_str == "permissions" do continue // overridden below
      append(&new_ctx.entries, entry)
    }
  }
  append(&new_ctx.entries, Table_Entry_Value{key = "permissions", value = new_perms})
  return new_ctx, true
}
