package hashedbuild

import "core:os"
import "core:strings"
import "core:sys/linux"

// The Linux half of fs.odin, using the *at() syscall family directly. This is
// the code §16's builtins used to call inline; moving it here is what lets
// the same builtins run on WASI.
//
// openat2's RESOLVE_BENEATH is deliberately not used: it hit an
// environment-specific kernel bug during development (openat via a real
// directory fd failing unless O_CREAT is set, on at least one WSL2 build),
// and it is a newer syscall with uneven support, whereas the plain *at()
// family here has been portable for decades. Containment is done a component
// at a time by the caller instead - see resolve_parent_beneath.

// Shared with source_linux.odin, which opens the program's own source file
// outside the builtins' path entirely.
fs_errno_to_error :: proc(errno: linux.Errno) -> Fs_Error {
  #partial switch errno {
  case .NONE:   return .None
  case .ENOENT: return .Not_Found
  case .EEXIST: return .Exists
  case .EACCES, .EPERM: return .Access
  case .ENOTDIR: return .Not_Directory
  }
  return .Io
}

// The directory an unsandboxed call resolves against when the interpreter has
// no base directory of its own: the process's own working directory.
fs_cwd_dir :: proc() -> Fs_Fd {
  return Fs_Fd(linux.AT_FDCWD)
}

@(private = "file")
open_at :: proc(parent: Fs_Fd, name: string, flags: linux.Open_Flags) -> (Fs_Fd, Fs_Error) {
  cname := strings.clone_to_cstring(name, context.temp_allocator)
  fd, errno := linux.openat(linux.Fd(parent), cname, flags)
  if errno != .NONE do return FS_INVALID_FD, fs_errno_to_error(errno)
  return Fs_Fd(fd), .None
}

// `no_follow` refuses a symlink at the final component (O_NOFOLLOW), which is
// how the contained form of loadfile keeps a symlink from stepping outside
// its directory (§16).
fs_open_dir_at :: proc(parent: Fs_Fd, name: string, no_follow: bool) -> (Fs_Fd, Fs_Error) {
  flags: linux.Open_Flags = {.DIRECTORY}
  if no_follow do flags += {.NOFOLLOW}
  return open_at(parent, name, flags)
}

fs_open_read_at :: proc(parent: Fs_Fd, name: string, no_follow: bool) -> (Fs_Fd, Fs_Error) {
  flags: linux.Open_Flags = no_follow ? {.NOFOLLOW} : {}
  return open_at(parent, name, flags)
}

fs_create_exclusive_at :: proc(parent: Fs_Fd, name: string) -> (Fs_Fd, Fs_Error) {
  cname := strings.clone_to_cstring(name, context.temp_allocator)
  fd, errno := linux.openat(linux.Fd(parent), cname, {.CREAT, .EXCL, .WRONLY}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
  if errno != .NONE do return FS_INVALID_FD, fs_errno_to_error(errno)
  return Fs_Fd(fd), .None
}

// Asked before opening, so a directory is never opened as if it were a file.
// Linux tolerates that (an O_RDONLY directory fd is legal, just unreadable);
// WASI does not, so the check moved ahead of the open on both.
fs_stat_is_dir_at :: proc(parent: Fs_Fd, name: string, no_follow: bool) -> (bool, Fs_Error) {
  cname := strings.clone_to_cstring(name, context.temp_allocator)
  st: linux.Stat
  flags: linux.FD_Flags = no_follow ? {.SYMLINK_NOFOLLOW} : {}
  if errno := linux.fstatat(linux.Fd(parent), cname, &st, flags); errno != .NONE {
    return false, fs_errno_to_error(errno)
  }
  return .IFDIR in st.mode, .None
}

fs_is_directory :: proc(fd: Fs_Fd) -> (bool, Fs_Error) {
  st: linux.Stat
  if errno := linux.fstat(linux.Fd(fd), &st); errno != .NONE do return false, fs_errno_to_error(errno)
  return .IFDIR in st.mode, .None
}

// Reads to EOF. The size from fstat is a starting point, not a promise - the
// loop is what actually decides, since a short read is legal.
fs_read_all :: proc(fd: Fs_Fd) -> ([]u8, Fs_Error) {
  st: linux.Stat
  if errno := linux.fstat(linux.Fd(fd), &st); errno != .NONE do return nil, fs_errno_to_error(errno)

  size := int(st.size)
  buf := make([]u8, size)
  total := 0
  for total < size {
    n, errno := linux.read(linux.Fd(fd), buf[total:])
    if errno != .NONE {
      delete(buf)
      return nil, fs_errno_to_error(errno)
    }
    if n == 0 do break
    total += n
  }
  return buf[:total], .None
}

fs_write_all :: proc(fd: Fs_Fd, data: []u8) -> Fs_Error {
  written := 0
  for written < len(data) {
    n, errno := linux.write(linux.Fd(fd), data[written:])
    if errno != .NONE do return fs_errno_to_error(errno)
    if n == 0 do break
    written += n
  }
  return .None
}

fs_close :: proc(fd: Fs_Fd) {
  linux.close(linux.Fd(fd))
}

fs_symlink_at :: proc(parent: Fs_Fd, name: string, target: string) -> Fs_Error {
  cname := strings.clone_to_cstring(name, context.temp_allocator)
  ctarget := strings.clone_to_cstring(target, context.temp_allocator)
  ret := linux.syscall(linux.SYS_symlinkat, cast(rawptr)ctarget, linux.Fd(parent), cast(rawptr)cname)
  if ret < 0 do return fs_errno_to_error(linux.Errno(-ret))
  return .None
}

// The target string exactly as stored - not resolved, per §3's treatment of
// symlinks as directory metadata.
fs_readlink_at :: proc(parent: Fs_Fd, name: string) -> (string, Fs_Error) {
  cname := strings.clone_to_cstring(name, context.temp_allocator)
  buf := make([]u8, 4096, context.temp_allocator)
  ret := linux.syscall(linux.SYS_readlinkat, linux.Fd(parent), cast(rawptr)cname, raw_data(buf), len(buf))
  if ret < 0 do return "", fs_errno_to_error(linux.Errno(-ret))
  return strings.clone(string(buf[:ret])), .None
}

// ---- the two path-taking operations, for ctx.cache (§9) ----------------------

fs_open_dir_path :: proc(path: string) -> (Fs_Fd, Fs_Error) {
  return open_at(Fs_Fd(linux.AT_FDCWD), path, {.DIRECTORY})
}

// mkdir -p: creates every missing ancestor, tolerating those that exist.
fs_make_dirs :: proc(path: string) -> Fs_Error {
  start := 0
  if len(path) > 0 && path[0] == '/' do start = 1
  for i := start; i <= len(path); i += 1 {
    if i < len(path) && path[i] != '/' do continue
    if i == 0 do continue
    prefix := strings.clone_to_cstring(path[:i], context.temp_allocator)
    linux.mkdir(prefix, {.IRUSR, .IWUSR, .IXUSR})
  }
  return .None
}

// ---- the directory hash's listing (SPEC.md §3) -------------------------------

// getdents64 against a descriptor, plus one fstatat per name for the kind and
// the mode. The d_type getdents already reports is deliberately *not* trusted
// on its own: it is documented as possibly .UNKNOWN (some filesystems fill it
// in, some don't), and the exec bit needs the stat regardless - so one call
// answers both questions rather than two answering one each.
//
// The listing is done through a *fresh* descriptor rather than `parent`
// itself. getdents advances the descriptor's own offset, and `parent` is a
// long-lived handle a program keeps using as a `.dir` (§16) - reading its
// entries must not be something the program can observe afterwards. Opening
// "." relative to it costs one syscall and keeps the caller's handle exactly
// as it was found.
fs_list_entries_at :: proc(parent: Fs_Fd, allocator := context.allocator) -> ([]Fs_Dir_Entry, Fs_Error) {
  listing, open_err := open_at(parent, ".", {.DIRECTORY})
  if open_err != .None do return nil, open_err
  defer fs_close(listing)

  entries := make([dynamic]Fs_Dir_Entry, 0, 16, allocator)
  buf := make([]u8, 4096, context.temp_allocator)
  for {
    written, err := linux.getdents(linux.Fd(listing), buf)
    if err != .NONE do return entries[:], fs_errno_to_error(err)
    if written == 0 do break

    offset := 0
    for dirent in linux.dirent_iterate_buf(buf[:written], &offset) {
      name := linux.dirent_name(dirent)
      if name == "." || name == ".." do continue

      cname := strings.clone_to_cstring(name, context.temp_allocator)
      stat: linux.Stat
      // AT_SYMLINK_NOFOLLOW: a link is hashed as its target string (§3), so
      // the entry's own type is what matters, never what it points at.
      if serr := linux.fstatat(linux.Fd(listing), cname, &stat, {.SYMLINK_NOFOLLOW}); serr != .NONE {
        return entries[:], fs_errno_to_error(serr)
      }

      kind := Fs_Node_Kind.Other
      switch {
      case linux.S_ISREG(stat.mode): kind = .Regular
      case linux.S_ISDIR(stat.mode): kind = .Directory
      case linux.S_ISLNK(stat.mode): kind = .Symlink
      }
      append(&entries, Fs_Dir_Entry {
        name          = strings.clone(name, allocator),
        kind          = kind,
        // §3 hashes "the executable flag only - not full POSIX mode", and the
        // owner bit is the one that means "this is a program". Group and other
        // are part of who may run it, which is not part of what it is.
        is_executable = kind == .Regular && .IXUSR in stat.mode,
      })
    }
  }
  return entries[:], .None
}

// Listing goes through core:os here, which is a perfectly good directory
// reader on a platform that has a working directory. (WASI does not, which is
// why fs_wasi.odin implements this against the preopen table instead.)
fs_list_dir :: proc(path: string, allocator := context.allocator) -> ([]Fs_Entry, Fs_Error) {
  infos, err := os.read_all_directory_by_path(path, context.temp_allocator)
  if err != nil do return nil, .Not_Found

  entries := make([dynamic]Fs_Entry, 0, len(infos), allocator)
  for info in infos {
    append(&entries, Fs_Entry{name = strings.clone(info.name, allocator), is_dir = info.type == .Directory})
  }
  return entries[:], .None
}
