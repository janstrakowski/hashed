package hashedbuild

import "core:crypto/hash"
import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"
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
@(private = "file")
resolve_cache_dir :: proc(override: string) -> string {
  if override != "" do return override
  if xdg := os.get_env_alloc("XDG_CACHE_HOME", context.temp_allocator); xdg != "" {
    return strings.concatenate({xdg, "/hashedbuild"})
  }
  return strings.concatenate({os.get_env_alloc("HOME", context.temp_allocator), "/.cache/hashedbuild"})
}

@(private = "file")
new_native_function :: proc(fn: Native_Fn, closure: Value = nil) -> Value {
  f := new(Function_Value)
  f.native = fn
  f.native_closure = closure
  return f
}

// The global scope every real program's top-level expression evaluates in -
// the filesystem builtins, pre-bound by name (§16).
make_global_env :: proc() -> ^Env {
  env := env_make_child(nil)
  env_bind(env, "loadfile", new_native_function(builtin_loadfile))
  env_bind(env, "createfile", new_native_function(builtin_createfile))
  env_bind(env, "symlink", new_native_function(builtin_symlink))
  env_bind(env, "readlink", new_native_function(builtin_readlink))
  env_bind(env, "chperm", new_native_function(builtin_chperm))
  env_bind(env, "filetext", new_native_function(builtin_filetext))
  return env
}

@(private = "file")
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
unsandboxed_dir_fd :: proc(interp: ^Interpreter) -> linux.Fd {
  if interp.has_base_dir do return interp.base_dir_fd
  return linux.AT_FDCWD
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
resolve_parent_beneath :: proc(base_fd: linux.Fd, sub_path: string) -> (parent_fd: linux.Fd, basename: string, errno: linux.Errno) {
  if len(sub_path) == 0 || sub_path[0] == '/' {
    return {}, "", .EACCES
  }

  cur_fd := base_fd
  remaining := sub_path
  for {
    slash := strings.index_byte(remaining, '/')
    if slash < 0 {
      if remaining == "" || remaining == ".." {
        if cur_fd != base_fd do linux.close(cur_fd)
        return {}, "", .EACCES
      }
      return cur_fd, remaining, .NONE
    }

    component := remaining[:slash]
    remaining = remaining[slash + 1:]
    if component == "" || component == ".." {
      if cur_fd != base_fd do linux.close(cur_fd)
      return {}, "", .EACCES
    }
    if component == "." do continue // stays at the same fd

    cpath := strings.clone_to_cstring(component, context.temp_allocator)
    next_fd, open_errno := linux.openat(cur_fd, cpath, {.DIRECTORY, .NOFOLLOW})
    if cur_fd != base_fd do linux.close(cur_fd)
    if open_errno != .NONE do return {}, "", open_errno
    cur_fd = next_fd
  }
}

@(private = "file")
Resolved_Path :: struct {
  fd:          linux.Fd,
  basename:    string,
  needs_close: bool, // true iff `fd` was freshly opened by resolve_parent_beneath, not just the caller's own dir handle
}

@(private = "file")
close_resolved :: proc(r: Resolved_Path) {
  if r.needs_close do linux.close(r.fd)
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
    return Resolved_Path{fd = unsandboxed_dir_fd(interp), basename = path_str}, "", true
  }
  dir_file, dir_ok := dir_val.(^File_Value)
  if !dir_ok || dir_file.kind != .Directory {
    return {}, ".dir must be a directory File", false
  }
  parent_fd, basename, rerr := resolve_parent_beneath(dir_file.dir_fd, path_str)
  if rerr != .NONE {
    return {}, fmt.tprintf("path escapes its directory or doesn't exist (%v)", rerr), false
  }
  return Resolved_Path{fd = parent_fd, basename = basename, needs_close = parent_fd != dir_file.dir_fd}, "", true
}

// ---- loadfile ---------------------------------------------------------------------

@(private = "file")
open_and_load :: proc(interp: ^Interpreter, dir_fd: linux.Fd, path: string, no_follow_final: bool) -> (Value, bool) {
  cpath := strings.clone_to_cstring(path, context.temp_allocator)
  open_flags: linux.Open_Flags = no_follow_final ? {.NOFOLLOW} : {}

  fd, errno := linux.openat(dir_fd, cpath, open_flags)
  if errno != .NONE do return fail(interp, fmt.tprintf("loadfile: could not open %s (%v)", path, errno))
  defer linux.close(fd)

  st: linux.Stat
  if serr := linux.fstat(fd, &st); serr != .NONE {
    return fail(interp, fmt.tprintf("loadfile: could not stat %s (%v)", path, serr))
  }

  if .IFDIR in st.mode {
    dir_fd2, derr := linux.openat(dir_fd, cpath, open_flags | {.DIRECTORY})
    if derr != .NONE do return fail(interp, fmt.tprintf("loadfile: could not open directory %s (%v)", path, derr))
    fv := new(File_Value)
    fv.kind = .Directory
    fv.dir_fd = dir_fd2
    return fv, true
  }

  size := int(st.size)
  content := make([]u8, size)
  total := 0
  for total < size {
    n, rerr := linux.read(fd, content[total:])
    if rerr != .NONE do return fail(interp, fmt.tprintf("loadfile: read error on %s (%v)", path, rerr))
    if n == 0 do break
    total += n
  }
  fv := new(File_Value)
  fv.kind = .Regular
  fv.content = content[:total]
  return fv, true
}

@(private = "file")
builtin_loadfile :: proc(interp: ^Interpreter, _: Value, arg: Value) -> (Value, bool) {
  if !ctx_allows_io(interp) do return fail(interp, "loadfile: io permission not granted in the current context")

  if path, is_str := arg.(string); is_str {
    return open_and_load(interp, unsandboxed_dir_fd(interp), path, false)
  }

  t, is_table := arg.(^Table_Value)
  if !is_table do return fail(interp, "loadfile expects a Utf8 path or a { .dir, .path } Table")
  path_val, has_path := table_find(t, "path")
  path_str, path_ok := path_val.(string)
  if !has_path || !path_ok do return fail(interp, "loadfile's Table form needs a Utf8 .path")

  r, err_msg, ok := resolve_target(interp, t, path_str, true)
  if !ok do return fail(interp, fmt.tprintf("loadfile: %s", err_msg))
  defer close_resolved(r)

  return open_and_load(interp, r.fd, r.basename, true)
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

  cpath := strings.clone_to_cstring(r.basename, context.temp_allocator)
  // Exclusive for now (SPEC.md §16) - fails if the file already exists.
  fd, errno := linux.openat(r.fd, cpath, {.CREAT, .EXCL, .WRONLY}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
  if errno != .NONE do return fail(interp, fmt.tprintf("createfile: could not create %s (%v)", r.basename, errno))
  defer linux.close(fd)

  written := 0
  for written < len(content_bytes) {
    n, werr := linux.write(fd, content_bytes[written:])
    if werr != .NONE do return fail(interp, fmt.tprintf("createfile: write error (%v)", werr))
    if n == 0 do break
    written += n
  }

  fv := new(File_Value)
  fv.kind = .Regular
  fv.content = slice.clone(content_bytes)
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

// Creates `path` and every missing ancestor directory (like `mkdir -p`),
// tolerating any component that already exists.
@(private = "file")
make_dir_all :: proc(path: string) {
  start := 0
  if len(path) > 0 && path[0] == '/' do start = 1
  for i := start; i <= len(path); i += 1 {
    if i < len(path) && path[i] != '/' do continue
    if i == 0 do continue
    prefix := path[:i]
    linux.mkdir(strings.clone_to_cstring(prefix, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
  }
}

// Opens (creating if necessary) the cache's backing directory, the first
// time it's actually needed - not at program start, so a program that never
// touches the cache never creates it.
@(private = "file")
ensure_cache_dir_open :: proc(cache: ^Cache_Value) -> linux.Errno {
  if cache.opened do return .NONE
  make_dir_all(cache.dir_path)
  fd, errno := linux.openat(linux.AT_FDCWD, strings.clone_to_cstring(cache.dir_path, context.temp_allocator), {.DIRECTORY})
  if errno != .NONE do return errno
  cache.dir_fd = fd
  cache.opened = true
  return .NONE
}

@(private = "file")
createfile_in_cache :: proc(interp: ^Interpreter, cache: ^Cache_Value, content: []u8) -> (Value, bool) {
  if errno := ensure_cache_dir_open(cache); errno != .NONE {
    return fail(interp, fmt.tprintf("createfile: could not open cache directory %s (%v)", cache.dir_path, errno))
  }

  name := cache_entry_name(content)
  cname := strings.clone_to_cstring(name, context.temp_allocator)

  fd, errno := linux.openat(cache.dir_fd, cname, {.CREAT, .EXCL, .WRONLY}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
  #partial switch errno {
  case .NONE:
    defer linux.close(fd)
    written := 0
    for written < len(content) {
      n, werr := linux.write(fd, content[written:])
      if werr != .NONE do return fail(interp, fmt.tprintf("createfile: cache write error (%v)", werr))
      if n == 0 do break
      written += n
    }
  case .EEXIST:
    // Dedup: an entry with this exact content hash already exists (from this
    // run or a previous one) - reuse it rather than failing or rewriting.
  case:
    return fail(interp, fmt.tprintf("createfile: could not write to cache (%v)", errno))
  }

  fv := new(File_Value)
  fv.kind = .Regular
  fv.content = slice.clone(content)
  fv.cache_display_path = strings.concatenate({cache.dir_path, "/", name})
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

  cpath := strings.clone_to_cstring(r.basename, context.temp_allocator)
  ctarget := strings.clone_to_cstring(target_str, context.temp_allocator)
  ret := linux.syscall(linux.SYS_symlinkat, cast(rawptr)ctarget, r.fd, cast(rawptr)cpath)
  if ret < 0 do return fail(interp, fmt.tprintf("symlink: could not create %s (%v)", r.basename, linux.Errno(-ret)))

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

  cpath := strings.clone_to_cstring(r.basename, context.temp_allocator)
  buf := make([]u8, 4096, context.temp_allocator)
  ret := linux.syscall(linux.SYS_readlinkat, r.fd, cast(rawptr)cpath, raw_data(buf), len(buf))
  if ret < 0 do return fail(interp, fmt.tprintf("readlink: could not read %s (%v)", r.basename, linux.Errno(-ret)))

  return strings.clone(string(buf[:ret])), true
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
  return new_native_function(apply_chperm, closure), true
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
