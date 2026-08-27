package hashedbuild

import "core:strings"
import "core:sys/wasm/wasi"

// The WASI half of fs.odin, against preview1. It lines up with fs_linux.odin
// almost call for call - `path_open` is `openat`, `fd_read`/`fd_write` are
// `read`/`write`, `path_symlink`/`path_readlink` are the *at() forms - which
// is the point: §16's containment rules were already descriptor-relative, so
// nothing above this file has to know which target it is on.
//
// Two things genuinely differ, and both are WASI being stricter rather than
// poorer:
//
//   - **There is no cwd, and no absolute paths.** A program can only reach
//     what the host preopened for it, addressed relative to those
//     descriptors. That is exactly §9's permission model enforced by the
//     runtime instead of by us: if the host preopens nothing, `io` is denied
//     no matter what `ctx` says.
//   - **Following a symlink is opt-in** (the SYMLINK_FOLLOW lookup flag),
//     the inverse of O_NOFOLLOW. The `no_follow` argument is negated here,
//     which is why it is a parameter rather than a flag set built by callers.

// preview1 ties rights to file type, and asking for the wrong ones is an
// error rather than a downgrade: requesting FD_WRITE while opening a
// directory gets EISDIR from wasmtime, not a read-only directory handle. So
// the three sets below are per file type, and each open asks for exactly the
// set its target can hold.
//
// A directory's *inheriting* rights are the union, since a directory handle
// exists precisely to open files through (§16).
@(private = "file")
FILE_RIGHTS :: wasi.rights_t{
  .FD_READ, .FD_WRITE, .FD_SEEK, .FD_TELL, .FD_FILESTAT_GET,
  .FD_ALLOCATE, .FD_FILESTAT_SET_SIZE, .FD_DATASYNC, .FD_SYNC,
}

@(private = "file")
DIR_RIGHTS :: wasi.rights_t{
  .FD_READDIR, .FD_FILESTAT_GET,
  .PATH_OPEN, .PATH_CREATE_FILE, .PATH_CREATE_DIRECTORY, .PATH_FILESTAT_GET,
  .PATH_READLINK, .PATH_SYMLINK, .PATH_UNLINK_FILE, .PATH_REMOVE_DIRECTORY,
}

@(private = "file")
INHERITED_RIGHTS :: DIR_RIGHTS + FILE_RIGHTS

@(private = "file")
to_fs_error :: proc(errno: wasi.errno_t) -> Fs_Error {
  #partial switch errno {
  case .SUCCESS: return .None
  case .NOENT:   return .Not_Found
  case .EXIST:   return .Exists
  case .ACCESS, .PERM, .NOTCAPABLE: return .Access
  case .NOTDIR:  return .Not_Directory
  }
  return .Io
}

// ---- preopens ----------------------------------------------------------------

// What the host granted this program, as (descriptor, mounted path) pairs.
// preview1 hands these out starting at descriptor 3, and the only way to
// learn their names is to ask one at a time until the enumeration ends.
@(private = "file")
Preopen :: struct {
  fd:   Fs_Fd,
  path: string,
}

@(private = "file")
preopens: [dynamic]Preopen

@(private = "file")
preopens_loaded: bool

@(private = "file")
load_preopens :: proc() {
  if preopens_loaded do return
  preopens_loaded = true

  for raw := wasi.fd_t(3); ; raw += 1 {
    desc, err := wasi.fd_prestat_get(raw)
    if err != .SUCCESS do break // end of the preopen list, or nothing granted
    if desc.tag != .DIR do continue

    name_buf := make([]u8, int(desc.dir.pr_name_len))
    if nerr := wasi.fd_prestat_dir_name(raw, name_buf); nerr != .SUCCESS {
      delete(name_buf)
      continue
    }
    append(&preopens, Preopen{fd = Fs_Fd(raw), path = clean_path(string(name_buf))})
  }
}

// The preopen a path lives under, plus the path relative to it. Longest
// mounted prefix wins, so a host that preopens both "/" and "/work" resolves
// "/work/x" through the more specific one.
@(private = "file")
resolve_preopen :: proc(path: string) -> (fd: Fs_Fd, rel: string, ok: bool) {
  load_preopens()
  cleaned := clean_path(path)

  best_len := -1
  for pre in preopens {
    if pre.path == "/" || pre.path == "." || strings.has_prefix(cleaned, pre.path) {
      if len(pre.path) > best_len {
        best_len = len(pre.path)
        fd = pre.fd
        rel = strings.trim_prefix(strings.trim_prefix(cleaned, pre.path), "/")
        if rel == "" do rel = "."
        ok = true
      }
    }
  }
  return
}

// Without a cwd, "wherever relative paths land" is the first thing the host
// preopened. A program given nothing gets an invalid descriptor, and every
// unsandboxed call through it fails - which is the correct answer, not a bug.
fs_cwd_dir :: proc() -> Fs_Fd {
  load_preopens()
  if len(preopens) == 0 do return FS_INVALID_FD
  return preopens[0].fd
}

// ---- the operations fs.odin names ----------------------------------------------

// WASI has no absolute paths at all - path_open resolves a name relative to
// a descriptor, and an absolute one is refused outright. A program that says
// `loadfile "/examples/x"` means a path rooted at a preopen, so rebase it
// onto whichever preopen covers it and hand path_open the remainder. Linux
// needs no equivalent: openat ignores its dirfd for an absolute path.
@(private = "file")
rebase_absolute :: proc(parent: Fs_Fd, name: string) -> (Fs_Fd, string, bool) {
  if len(name) == 0 || name[0] != '/' do return parent, name, true
  pre, rel, ok := resolve_preopen(name)
  if !ok do return parent, name, false // nothing preopened covers it
  return pre, rel, true
}

@(private = "file")
lookup_flags :: proc(no_follow: bool) -> wasi.lookupflags_t {
  return no_follow ? {} : {.SYMLINK_FOLLOW}
}

@(private = "file")
open_at :: proc(
  parent: Fs_Fd, name: string, no_follow: bool, oflags: wasi.oflags_t,
  base: wasi.rights_t, inheriting: wasi.rights_t,
) -> (Fs_Fd, Fs_Error) {
  dir, rel, ok := rebase_absolute(parent, name)
  if !ok || dir == FS_INVALID_FD do return FS_INVALID_FD, .Access
  fd, err := wasi.path_open(
    wasi.fd_t(dir), lookup_flags(no_follow), rel, oflags,
    base, inheriting, {},
  )
  if err != .SUCCESS do return FS_INVALID_FD, to_fs_error(err)
  return Fs_Fd(fd), .None
}

fs_open_dir_at :: proc(parent: Fs_Fd, name: string, no_follow: bool) -> (Fs_Fd, Fs_Error) {
  return open_at(parent, name, no_follow, {.DIRECTORY}, DIR_RIGHTS, INHERITED_RIGHTS)
}

fs_open_read_at :: proc(parent: Fs_Fd, name: string, no_follow: bool) -> (Fs_Fd, Fs_Error) {
  return open_at(parent, name, no_follow, {}, FILE_RIGHTS, {})
}

fs_create_exclusive_at :: proc(parent: Fs_Fd, name: string) -> (Fs_Fd, Fs_Error) {
  return open_at(parent, name, true, {.CREATE, .EXCL}, FILE_RIGHTS, {})
}

// The check that lets loadfile open a directory at all here: preview1 ties
// rights to file type, so path_open with FD_READ against a directory is
// refused outright. Ask first, then open with the flags that fit.
fs_stat_is_dir_at :: proc(parent: Fs_Fd, name: string, no_follow: bool) -> (bool, Fs_Error) {
  dir, rel, ok := rebase_absolute(parent, name)
  if !ok || dir == FS_INVALID_FD do return false, .Access
  stat, err := wasi.path_filestat_get(wasi.fd_t(dir), lookup_flags(no_follow), rel)
  if err != .SUCCESS do return false, to_fs_error(err)
  return stat.filetype == .DIRECTORY, .None
}

fs_is_directory :: proc(fd: Fs_Fd) -> (bool, Fs_Error) {
  stat, err := wasi.fd_filestat_get(wasi.fd_t(fd))
  if err != .SUCCESS do return false, to_fs_error(err)
  return stat.filetype == .DIRECTORY, .None
}

fs_read_all :: proc(fd: Fs_Fd) -> ([]u8, Fs_Error) {
  stat, serr := wasi.fd_filestat_get(wasi.fd_t(fd))
  if serr != .SUCCESS do return nil, to_fs_error(serr)

  size := int(stat.size)
  buf := make([]u8, size)
  total := 0
  for total < size {
    iov := []wasi.iovec_t{buf[total:]}
    n, err := wasi.fd_read(wasi.fd_t(fd), iov)
    if err != .SUCCESS {
      delete(buf)
      return nil, to_fs_error(err)
    }
    if n == 0 do break
    total += int(n)
  }
  return buf[:total], .None
}

fs_write_all :: proc(fd: Fs_Fd, data: []u8) -> Fs_Error {
  written := 0
  for written < len(data) {
    iov := []wasi.ciovec_t{data[written:]}
    n, err := wasi.fd_write(wasi.fd_t(fd), iov)
    if err != .SUCCESS do return to_fs_error(err)
    if n == 0 do break
    written += int(n)
  }
  return .None
}

fs_close :: proc(fd: Fs_Fd) {
  if fd == FS_INVALID_FD do return
  wasi.fd_close(wasi.fd_t(fd))
}

fs_symlink_at :: proc(parent: Fs_Fd, name: string, target: string) -> Fs_Error {
  dir, rel, ok := rebase_absolute(parent, name)
  if !ok || dir == FS_INVALID_FD do return .Access
  return to_fs_error(wasi.path_symlink(target, wasi.fd_t(dir), rel))
}

fs_readlink_at :: proc(parent: Fs_Fd, name: string) -> (string, Fs_Error) {
  dir, rel, ok := rebase_absolute(parent, name)
  if !ok || dir == FS_INVALID_FD do return "", .Access
  buf := make([]u8, 4096, context.temp_allocator)
  n, err := wasi.path_readlink(wasi.fd_t(dir), rel, buf)
  if err != .SUCCESS do return "", to_fs_error(err)
  return strings.clone(string(buf[:n])), .None
}

// ---- the two path-taking operations, for ctx.cache (§9) -------------------------

fs_open_dir_path :: proc(path: string) -> (Fs_Fd, Fs_Error) {
  parent, rel, ok := resolve_preopen(path)
  if !ok do return FS_INVALID_FD, .Access // nothing preopened covers it
  return fs_open_dir_at(parent, rel, false)
}

// mkdir -p, walked a component at a time relative to the covering preopen.
// An already-existing component is not an error, same as the Linux side.
fs_make_dirs :: proc(path: string) -> Fs_Error {
  parent, rel, ok := resolve_preopen(path)
  if !ok do return .Access
  if rel == "." do return .None

  built: strings.Builder
  strings.builder_init(&built, context.temp_allocator)
  for segment in strings.split(rel, "/", context.temp_allocator) {
    if segment == "" do continue
    if strings.builder_len(built) > 0 do strings.write_byte(&built, '/')
    strings.write_string(&built, segment)
    err := wasi.path_create_directory(wasi.fd_t(parent), strings.to_string(built))
    if err != .SUCCESS && err != .EXIST do return to_fs_error(err)
  }
  return .None
}

// preview1's fd_readdir: entries come back packed as a 24-byte header (next
// cookie, inode, name length, filetype) followed by the raw name, and the
// caller keeps asking until a pass returns less than it asked for.
fs_list_dir :: proc(path: string, allocator := context.allocator) -> ([]Fs_Entry, Fs_Error) {
  dir, err := fs_open_dir_path(path)
  if err != .None do return nil, err
  defer fs_close(dir)

  entries := make([dynamic]Fs_Entry, 0, 16, allocator)
  buf := make([]u8, 4096, context.temp_allocator)
  cookie := wasi.dircookie_t(0)

  for {
    used, read_err := wasi.fd_readdir(wasi.fd_t(dir), buf, cookie)
    if read_err != .SUCCESS do return entries[:], to_fs_error(read_err)
    if used == 0 do break

    offset := 0
    for offset + size_of(wasi.dirent_t) <= int(used) {
      dirent := (^wasi.dirent_t)(raw_data(buf[offset:]))^
      name_start := offset + size_of(wasi.dirent_t)
      name_end := name_start + int(dirent.d_namlen)
      if name_end > int(used) do break // a name split across reads: ask again from d_next

      name := string(buf[name_start:name_end])
      if name != "." && name != ".." {
        append(&entries, Fs_Entry{
          name = strings.clone(name, allocator),
          is_dir = dirent.d_type == .DIRECTORY,
        })
      }
      cookie = dirent.d_next
      offset = name_end
    }
    if int(used) < len(buf) do break
  }
  return entries[:], .None
}
