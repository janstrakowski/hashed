package hashedbuild

import "core:fmt"
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

// ---- directory-as-a-value operations (§3's directory hash, §15's cached) -----

@(private = "file") S_IFMT  :: u32(0o170000)
@(private = "file") S_IFDIR :: u32(0o040000)
@(private = "file") S_IFREG :: u32(0o100000)
@(private = "file") S_IFLNK :: u32(0o120000)

// Entries of an already-open directory, classified without following links -
// `fs_list_dir` above answers by path and through core:os, which is the wrong
// shape for a File value (it holds a descriptor, not a trustworthy path) and
// the wrong classification (§3 needs a symlink reported as a symlink, not as
// whatever it points at).
//
// Reading the names goes through /proc/self/fd rather than getdents64 because
// nothing else here needs a raw directory-block parser; the per-entry
// classification below is the part that has to be no-follow, and fstatat with
// SYMLINK_NOFOLLOW against the descriptor is what makes it so.
fs_list_dir_at :: proc(dir: Fs_Fd, allocator := context.allocator) -> ([]Fs_Entry, Fs_Error) {
  proc_path := fmt.tprintf("/proc/self/fd/%d", i32(dir))
  infos, err := os.read_all_directory_by_path(proc_path, context.temp_allocator)
  if err != nil do return nil, .Io

  entries := make([dynamic]Fs_Entry, 0, len(infos), allocator)
  for info in infos {
    st: linux.Stat
    cname := strings.clone_to_cstring(info.name, context.temp_allocator)
    if errno := linux.fstatat(linux.Fd(dir), cname, &st, {.SYMLINK_NOFOLLOW}); errno != .NONE {
      return nil, fs_errno_to_error(errno)
    }
    // The file type is a 4-bit field, not four independent flags - core's
    // Mode_Bits spells the individual bits and so has no IFLNK at all (S_IFLNK
    // is 0o120000, i.e. the IFREG and IFCHR bits together). Masking with
    // S_IFMT is the only way to ask the question that does not misread a
    // symlink as a regular file, or a block device as a directory.
    kind := transmute(u32)st.mode & S_IFMT
    append(&entries, Fs_Entry {
      name          = strings.clone(info.name, allocator),
      is_dir        = kind == S_IFDIR,
      is_symlink    = kind == S_IFLNK,
      is_executable = kind == S_IFREG && .IXUSR in st.mode,
    })
  }
  return entries[:], .None
}

fs_mkdir_at :: proc(parent: Fs_Fd, name: string) -> Fs_Error {
  cname := strings.clone_to_cstring(name, context.temp_allocator)
  ret := linux.syscall(linux.SYS_mkdirat, linux.Fd(parent), cast(rawptr)cname, u32(0o755))
  if ret < 0 do return fs_errno_to_error(linux.Errno(-ret))
  return .None
}

fs_rename_at :: proc(parent: Fs_Fd, old_name: string, new_name: string) -> Fs_Error {
  cold := strings.clone_to_cstring(old_name, context.temp_allocator)
  cnew := strings.clone_to_cstring(new_name, context.temp_allocator)
  ret := linux.syscall(
    linux.SYS_renameat, linux.Fd(parent), cast(rawptr)cold, linux.Fd(parent), cast(rawptr)cnew,
  )
  if ret < 0 do return fs_errno_to_error(linux.Errno(-ret))
  return .None
}

fs_unlink_at :: proc(parent: Fs_Fd, name: string) -> Fs_Error {
  cname := strings.clone_to_cstring(name, context.temp_allocator)
  return fs_errno_to_error(linux.unlinkat(linux.Fd(parent), cname, nil))
}

fs_rmdir_at :: proc(parent: Fs_Fd, name: string) -> Fs_Error {
  cname := strings.clone_to_cstring(name, context.temp_allocator)
  return fs_errno_to_error(linux.unlinkat(linux.Fd(parent), cname, {.REMOVEDIR}))
}

// The executable bit, on the one target that has one. Only ever used to put
// back a bit that was read off a file being copied into the cache, so that
// caching a build output does not quietly strip it - never to grant execute to
// something that did not already have it. Nothing about a value's identity
// depends on it (§3 hashes no permission bit); this is fidelity, not semantics.
fs_set_executable_at :: proc(parent: Fs_Fd, name: string) -> Fs_Error {
  cname := strings.clone_to_cstring(name, context.temp_allocator)
  ret := linux.syscall(linux.SYS_fchmodat, linux.Fd(parent), cast(rawptr)cname, u32(0o755), 0)
  if ret < 0 do return fs_errno_to_error(linux.Errno(-ret))
  return .None
}
