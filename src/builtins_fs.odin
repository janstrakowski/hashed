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
// Every one of them is (directory handle, sub-path), with no exceptions and
// no defaults: `.dir` is required, and there is no form that takes a path on
// its own. A program's handles are the ones it was given in `ctx.dirs` (§9,
// one per `--dir <name>=<path>`) and the ones it opened from those, so a run
// told about no directories cannot touch the filesystem at all. Nothing is
// implicit here on purpose - a program's inputs are named where the run is,
// not inferred from where its source file happens to sit.
//
// The only paths arriving from outside a handle are the runtime's own
// (`--dir`, `--cache-dir`), and those are the host's, opened before the
// program starts.
//
// Sub-path containment (§16) is done in two steps. validate_sub_path is the
// pure half: a sub-path is a non-empty sequence of ordinary names, so a root,
// an empty segment, and a "." or ".." segment anywhere are refused before the
// filesystem is touched at all. resolve_parent_beneath is the half that needs
// the disk: it walks the remaining components one at a time, opening each
// with O_NOFOLLOW, so a symlink inside the directory - even one resolving
// back inside it - is rejected outright, not just one that escapes; simpler
// and safer than trying to distinguish the two.
//
// That walk is used rather than openat2's RESOLVE_BENEATH because, tested
// directly on this project's dev machine, openat2's resolve flags turned out
// to hit an environment-specific kernel bug (see the wsl2-openat-dirfd-bug
// memory) - and more generally, openat2 itself is a newer syscall (Linux
// 5.6+) with uneven support, whereas the plain *at() family used here has
// been portable for decades.

// ---- root context / global env ------------------------------------------------

// One `--dir <name>=<path>`: a directory the runtime opens on the program's
// behalf and hands over under that name in `ctx.dirs` (SPEC.md §9).
Named_Dir :: struct {
  name: string,
  path: string,
}

// The same, once opened.
Named_Handle :: struct {
  name:   string,
  handle: ^File_Value,
}

// Everything a root context is built out of: where the cache lives, and the
// directories the run was told to hand over (`ctx.dirs`). The directories are
// handles rather than paths because they are opened **once per process**, not
// once per context - a REPL builds a fresh root context for every line
// submitted, and opening a directory per context would leak a descriptor per
// line.
Root_Dirs :: struct {
  cache_dir: string,         // --cache-dir; "" resolves the XDG default instead
  named:     []Named_Handle, // ctx.dirs; empty means the program reaches nothing
}

// Opens the directories a run was given, turning the command line's paths
// into the handles a root context carries.
//
// The paths here are the *host's*: absolute, relative, "." and ".." are all
// fine, since the OS resolves them before any program runs. §16's rule that a
// path may not say ".", ".." or a root governs sub-paths written *inside* a
// program, which are always resolved against one of these handles.
open_root_dirs :: proc(cache_dir: string, named: []Named_Dir) -> (dirs: Root_Dirs, err_msg: string, ok: bool) {
  dirs.cache_dir = cache_dir
  if len(named) > 0 {
    handles := make([]Named_Handle, len(named))
    for nd, i in named {
      handle, err := open_dir_handle(nd.path)
      if err != .None {
        // Give back what opened before the one that did not: the caller is
        // handed an error and no handles, so nothing else can close these.
        close_root_dirs(Root_Dirs{named = handles[:i]})
        return {}, fmt.tprintf("could not open %s as ctx.dirs.%s (%v)", nd.path, nd.name, err), false
      }
      // Cloned, not borrowed. A handle lives as long as the run does, while
      // the name it came from belongs to whatever parsed it - a request that
      // has already been answered, in the debug adapter's case. Borrowing it
      // once left ctx.dirs keyed on freed memory, which showed up as a
      // garbled name and a lookup that failed only sometimes; keeping the
      // copy here means no caller can make that mistake again.
      handles[i] = Named_Handle{name = strings.clone(nd.name), handle = handle}
    }
    dirs.named = handles
  }
  return dirs, "", true
}

// Releases what open_root_dirs opened, at the end of a run rather than per
// evaluation - see Root_Dirs on why these last as long as the process.
close_root_dirs :: proc(dirs: Root_Dirs) {
  for n in dirs.named {
    fs_close(n.handle.dir_fd)
    delete(n.name)
  }
  delete(dirs.named)
}

// A directory File for a path the *runtime* was handed (§9's ctx.dirs, one
// per --dir) - the one place a path still arrives from outside a program.
// Everything a program opens for itself goes through one of these plus a
// sub-path (§16).
open_dir_handle :: proc(path: string) -> (^File_Value, Fs_Error) {
  fd, err := fs_open_dir_path(path)
  if err != .None do return nil, err
  fv := new(File_Value)
  fv.kind = .Directory
  fv.dir_fd = fd
  fv.display_path = absolute_dir_path(path)
  return fv, .None
}

// The context every real HashedBuild program starts with (SPEC.md §9): io is
// granted by default at the root, and the directories the runtime was told to
// hand over arrive in `.dirs`, by name. `withctx` narrows any of it for a
// sub-scope - dropping a handle from `.dirs` is as meaningful as dropping a
// permission, and leaves an expression able to use only what it already
// holds.
make_root_context :: proc(dirs: Root_Dirs) -> Value {
  perms := new(Table_Value)
  append(&perms.entries, Table_Entry_Value{key = "io", value = Nothing_Value{}})

  cache := new(Cache_Value)
  cache.dir_path = resolve_cache_dir(dirs.cache_dir)

  ctx_table := new(Table_Value)
  append(&ctx_table.entries, Table_Entry_Value{key = "permissions", value = perms})
  append(&ctx_table.entries, Table_Entry_Value{key = "cache", value = cache})
  // Always present, empty when nothing was named - `ctx.dirs` is a Table to
  // look names up in, and an empty one answers "no such handle" the same way
  // a populated one answers it for a name it does not hold.
  named := new(Table_Value)
  for n in dirs.named {
    append(&named.entries, Table_Entry_Value{key = n.name, value = n.handle})
  }
  append(&ctx_table.entries, Table_Entry_Value{key = "dirs", value = named})
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

// `name` is what the builtin hashes as (hash_function.odin): a native has no
// body to take a shape from, so its identity is the operation it *is*, and
// the name is how that gets written down. It is the binding's own spelling
// below, and must stay stable for the same reason a tag byte must - see the
// note on renumbering in hash.odin.
@(private = "file")
new_native_function :: proc(name: string, fn: Native_Fn, closure: Value = nil) -> Value {
  f := new(Function_Value)
  f.name = name
  f.native = fn
  f.native_closure = closure
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

// Package-visible rather than file-private because two other places ask it: a
// directory File's digest is read off the disk the first time anything needs
// it (hash.odin), and §15's `cached` reads and writes cache entries
// (eval.odin). Both are I/O operations like any other here (SPEC.md §3/§9).
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

// ---- path containment -----------------------------------------------------------

// SPEC.md §16's sub-path rule, as a pure check - no filesystem, so it gives
// the same answer for a name about to be created as for one that exists.
//
// A sub-path names something *inside* a directory handle, and is therefore a
// non-empty sequence of ordinary names: no root, no empty segment, and no "."
// or ".." **anywhere** - not even where they would cancel out. Refusing
// "a/./b" and "a/../b" rather than reducing them is deliberate: a reader
// should not have to run a normaliser in their head to see which directory a
// call lands in, and the ones that would reduce to something outside are then
// not a special case to get right, since none of the three spellings exists.
//
// Returns the reason as a message, because these are the failures a program
// author has to read and fix; the walk below returns an Fs_Error instead,
// since those come from the OS.
validate_sub_path :: proc(sub_path: string) -> (err_msg: string, ok: bool) {
  if len(sub_path) == 0 do return "a sub-path cannot be empty", false
  if is_absolute_path(sub_path) {
    return fmt.tprintf("a sub-path cannot start at a root: %s", sub_path), false
  }
  when WINDOWS_PATHS {
    // A colon is never part of an ordinary name on Windows. It introduces
    // either a drive-relative path ("C:x", which resolves against that
    // drive's own working directory, not against anything here) or an
    // alternate data stream ("name:stream", a second body hidden behind the
    // same entry). Neither is a sub-path of any directory.
    if strings.index_byte(sub_path, ':') >= 0 {
      return fmt.tprintf("a sub-path cannot name a drive or an alternate data stream: %s", sub_path), false
    }
  }
  rest := sub_path
  for {
    slash := index_path_sep(rest)
    segment := rest
    if slash >= 0 do segment = rest[:slash]
    switch segment {
    case "":
      return fmt.tprintf("a sub-path cannot have an empty segment: %s", sub_path), false
    case ".", "..":
      return fmt.tprintf("a sub-path cannot contain a %s segment: %s", segment, sub_path), false
    }
    if slash < 0 do break
    rest = rest[slash + 1:]
  }
  return "", true
}

// Walks an already-validated `sub_path` from `base_fd`, opening every
// intermediate directory with O_NOFOLLOW so a symlink anywhere along the way
// - not just one that would resolve outside - is rejected. Returns the fd of
// the final component's *parent* plus that component's own name, so the
// caller acts on it with an ordinary *at() syscall (open/create/symlinkat/
// readlinkat).
//
// Containment rests on validate_sub_path having run first: with no root, no
// ".." and no symlinked component, every name the walk opens is one level
// further *into* the tree, and the basename it hands back is a single
// ordinary name.
@(private = "file")
resolve_parent_beneath :: proc(base_fd: Fs_Fd, sub_path: string) -> (parent_fd: Fs_Fd, basename: string, err: Fs_Error) {
  cur_fd := base_fd
  remaining := sub_path
  for {
    slash := index_path_sep(remaining)
    if slash < 0 do return cur_fd, remaining, .None

    component := remaining[:slash]
    remaining = remaining[slash + 1:]
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
  // display path. The File this produces displays `display_dir` joined with
  // the sub-path the caller asked for (§3), which is why it travels alongside
  // the descriptor.
  display_dir: string,
}

@(private = "file")
close_resolved :: proc(r: Resolved_Path) {
  if r.needs_close do fs_close(r.fd)
}

// The directory a call resolves against, which it must name itself (§16):
// there is no default, and nothing in the context stands in for one. A
// program holds handles or it holds nothing.
@(private = "file")
target_dir :: proc(t: ^Table_Value) -> (dir: ^File_Value, err_msg: string, ok: bool) {
  dir_val, has_dir := table_find(t, "dir")
  if !has_dir {
    return nil, "needs a .dir directory handle - a path is always a sub-path of one (try ctx.dirs.<name>)", false
  }
  dir_file, is_file := dir_val.(^File_Value)
  if !is_file || dir_file.kind != .Directory do return nil, ".dir must be a directory File", false
  return dir_file, "", true
}

// Resolves a builtin's (directory, sub-path) pair: the handle from `.dir`,
// and the sub-path checked against §16's rule and then walked.
@(private = "file")
resolve_target :: proc(interp: ^Interpreter, t: ^Table_Value, path_str: string) -> (r: Resolved_Path, err_msg: string, ok: bool) {
  dir_file, dir_err, dir_ok := target_dir(t)
  if !dir_ok do return {}, dir_err, false

  if verr, valid := validate_sub_path(path_str); !valid do return {}, verr, false

  parent_fd, basename, rerr := resolve_parent_beneath(dir_file.dir_fd, path_str)
  if rerr != .None {
    return {}, fmt.tprintf("%s is not reachable inside %s (%v)", path_str, dir_file.display_path, rerr), false
  }
  return Resolved_Path{
    fd = parent_fd, basename = basename,
    needs_close = parent_fd != dir_file.dir_fd,
    display_dir = dir_file.display_path,
  }, "", true
}

// ---- display paths (§3) -------------------------------------------------------

// A File shows the path it was reached by (SPEC.md §3), so that path is built
// as the value is - joined from the display path of the directory handle it
// came through - and stored in the File_Value.
//
// It used to be read back off the kernel via /proc/self/fd, which was tidier
// (it resolved symlinks and normalised on its own) but doesn't port: WASI has
// no way at all to turn a descriptor back into a path, and nothing in the
// *at() family offers one either. Constructing the path costs a lexical
// cleanup below and gives the same answer for every path a program can
// actually write, absolute and free of "." and ".." segments.

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

// `no_follow_final` is true for every caller now that there is no unsandboxed
// form: a symlink is refused as the last component exactly as it is as an
// intermediate one (§16), so a handle plus a sub-path can never read through
// a link out of the tree. Kept as a parameter rather than folded in because
// it is what the two fs calls below are actually passed, and reading the
// policy at the call site beats reading it here.
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

// One form, and deliberately no shorthand: a bare `loadfile "notes.txt"` would
// have to resolve against something the call did not name, and §16 has nothing
// for it to resolve against. A string argument is therefore an error with the
// fix in it, not a second, weaker spelling.
@(private = "file")
builtin_loadfile :: proc(interp: ^Interpreter, _: Value, arg: Value) -> (Value, bool) {
  if !ctx_allows_io(interp) do return fail(interp, "loadfile: io permission not granted in the current context")

  if _, is_str := arg.(string); is_str {
    return fail(interp, `loadfile expects a { .dir, .path } Table - there is no bare-path form, since a path is always a sub-path of a directory handle (try loadfile { .dir = ctx.dirs.<name>, .path = ... })`)
  }
  t, is_table := arg.(^Table_Value)
  if !is_table do return fail(interp, "loadfile expects a { .dir, .path } Table")
  path_val, has_path := table_find(t, "path")
  path_str, path_ok := path_val.(string)
  if !has_path || !path_ok do return fail(interp, "loadfile needs a Utf8 .path")

  r, err_msg, ok := resolve_target(interp, t, path_str)
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
  if !is_table do return fail(interp, "createfile expects a { .dir, .path, .content } Table")

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

  r, err_msg, ok := resolve_target(interp, t, path_str)
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

  r, err_msg, ok := resolve_target(interp, t, path_str)
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

  r, err_msg, ok := resolve_target(interp, t, path_str)
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
