package hashedbuild

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:sys/windows"

// The Windows half of fs.odin - the third backend beside fs_linux.odin (the
// *at() syscall family) and fs_wasi.odin (preview1).
//
// Windows is the odd one out: it has no openat(). No documented Win32 call
// takes "this name, relative to that open descriptor" at all - the nearest
// equivalent is NtCreateFile's OBJECT_ATTRIBUTES.RootDirectory, which is
// ntdll, semi-documented, and would need UNICODE_STRING plumbing for every
// operation here. So a directory handle on this target is a *path* plus an
// open handle on the directory itself, and a child is reached by joining the
// name onto that path.
//
// Two consequences, spelled out because fs.odin promises the same containment
// on every target and one of these is genuinely weaker than Linux's:
//
//   * The final component is still opened atomically without following a
//     link. FILE_FLAG_OPEN_REPARSE_POINT opens the reparse point itself
//     rather than its target, and the resulting handle's own attributes are
//     what gets checked - so the thing inspected is exactly the thing that
//     was opened, which is what makes O_NOFOLLOW trustworthy. Symlinks and
//     junctions are both refused, since both are reparse points.
//   * The walk across intermediate components is by path rather than by a
//     chain of descriptors, so unlike the *at() family it is not immune to
//     another process renaming a directory mid-walk. Every component is still
//     opened no-follow and checked, and "..", rooted and drive-qualified
//     sub-paths never reach the walk at all (resolve_parent_beneath rejects
//     them, backslash separators included). So no path a *program* can write
//     escapes its directory; only a concurrent rename by another process
//     could, which is outside what §16 describes.
//
// Descriptors are numbered rather than passed around raw because Fs_Fd is an
// i32 and a Windows HANDLE is a pointer. The table below is that numbering.
// Slot 0 is always the process's working directory, so fs_cwd_dir() can hand
// back a stable descriptor that nobody has to close - the role AT_FDCWD plays
// on the Linux side.

// ---- descriptor table -------------------------------------------------------

@(private = "file")
Fs_Slot :: struct {
  used:   bool,
  is_dir: bool,
  handle: windows.HANDLE, // the open object; for a directory, held so the handle is a real thing
  // Directories only: the absolute path this descriptor stands for,
  // '/'-separated and already cleaned, which children are joined onto.
  path:   string,
}

// Guarded because `async` runs on real OS threads (task.odin) and a spawned
// interpreter inherits base_dir_fd (eval_async.odin), so two threads can be
// opening and closing descriptors at the same time.
@(private = "file")
fs_table: struct {
  mutex:     sync.Mutex,
  slots:     [dynamic]Fs_Slot,
  cwd_ready: bool,
}

// Everything this table owns - the slot array and each directory's path - is
// allocated straight from the heap rather than from context.allocator.
//
// A descriptor outlives the thread and the call that opened it: `async` hands
// one to a spawned interpreter (eval_async.odin), and a spawned thread gets
// its own context. Under `odin test` it is starker still, since the runner
// gives every test its own tracking allocator and runs them concurrently - so
// context.allocator here would mean one test's allocator growing an array
// that another test then reallocates and a third frees. The heap allocator is
// process-wide and thread-safe, which is what a process-wide table needs.
// (This is the same reasoning task_native.odin gives for leaving cleanup to
// task_join; the Linux backend never meets it, because there a descriptor is
// just an integer the kernel owns.)
@(private = "file")
fs_allocator :: proc() -> runtime.Allocator {
  return runtime.heap_allocator()
}

@(private = "file")
own_path :: proc(p: string) -> string {
  return strings.clone(p, fs_allocator())
}

@(private = "file")
FS_CWD :: Fs_Fd(0)

// Slot 0 is reserved for the working directory before anything else can claim
// it, and filled in on first use. Called with the table already locked.
@(private = "file")
ensure_cwd_slot :: proc() {
  if fs_table.cwd_ready do return
  fs_table.cwd_ready = true
  if fs_table.slots == nil do fs_table.slots = make([dynamic]Fs_Slot, 0, 8, fs_allocator())
  if len(fs_table.slots) == 0 do append(&fs_table.slots, Fs_Slot{})
  fs_table.slots[0] = Fs_Slot {
    used   = true,
    is_dir = true,
    handle = windows.INVALID_HANDLE_VALUE, // the cwd is a path, not something held open
    path   = own_path(current_directory_path_temp()),
  }
}

@(private = "file")
alloc_slot :: proc(slot: Fs_Slot) -> Fs_Fd {
  sync.lock(&fs_table.mutex)
  defer sync.unlock(&fs_table.mutex)
  ensure_cwd_slot()
  for i in 1 ..< len(fs_table.slots) {
    if !fs_table.slots[i].used {
      fs_table.slots[i] = slot
      return Fs_Fd(i)
    }
  }
  append(&fs_table.slots, slot)
  return Fs_Fd(len(fs_table.slots) - 1)
}

@(private = "file")
get_slot :: proc(fd: Fs_Fd) -> (Fs_Slot, bool) {
  sync.lock(&fs_table.mutex)
  defer sync.unlock(&fs_table.mutex)
  ensure_cwd_slot()
  i := int(fd)
  if i < 0 || i >= len(fs_table.slots) do return {}, false
  if !fs_table.slots[i].used do return {}, false
  return fs_table.slots[i], true
}

// The directory a descriptor stands for, as the path children get joined onto.
@(private = "file")
dir_path_of :: proc(fd: Fs_Fd) -> (string, bool) {
  slot, ok := get_slot(fd)
  if !ok || !slot.is_dir do return "", false
  return slot.path, true
}

// ---- Win32 paths ------------------------------------------------------------

// Paths travel through the interpreter '/'-separated (§3, and clean_path in
// builtins_fs.odin), so the conversion to a Win32 path happens here and
// nowhere else.
//
// An absolute path gets the \\?\ prefix, which lifts the 260-character
// MAX_PATH limit - a build system nests directories deeply enough to hit it.
// That prefix also switches off Win32's own path normalisation, which is safe
// precisely because everything reaching here has already been through
// clean_path: no "." or ".." segments, no doubled separators.
@(private = "file")
to_win_path :: proc(path: string) -> windows.wstring {
  // Since \\?\ switches off normalisation, the path has to arrive already
  // normalised. A display path has been through clean_path; a path a program
  // wrote has not, and an unsandboxed call hands one of those straight down.
  p := path
  if is_absolute_path(p) do p = clean_path(p, context.temp_allocator)

  b := strings.builder_make(context.temp_allocator)
  switch {
  case strings.has_prefix(p, "//"):
    // UNC: //server/share -> \\?\UNC\server\share
    strings.write_string(&b, "\\\\?\\UNC\\")
    write_backslashed(&b, p[2:])
  case is_drive_absolute(p):
    strings.write_string(&b, "\\\\?\\")
    write_backslashed(&b, p)
  case:
    // Relative, or rooted on the current drive ("/x"): left to Win32's
    // ordinary resolution, which the \\?\ form cannot express.
    write_backslashed(&b, p)
  }
  return windows.utf8_to_wstring(strings.to_string(b), context.temp_allocator)
}

// Byte-wise on purpose, and safe for UTF-8: every byte of a multi-byte
// sequence is >= 0x80, so none of them can be mistaken for a separator.
@(private = "file")
write_backslashed :: proc(b: ^strings.Builder, s: string) {
  for i in 0 ..< len(s) {
    c := s[i]
    if c == '/' do c = '\\'
    strings.write_byte(b, c)
  }
}

// The inverse, for paths coming back out of Win32.
@(private = "file")
to_slash :: proc(s: string, allocator := context.temp_allocator) -> string {
  b := strings.builder_make(allocator)
  for i in 0 ..< len(s) {
    c := s[i]
    if c == '\\' do c = '/'
    strings.write_byte(&b, c)
  }
  return strings.to_string(b)
}

@(private = "file")
join_child :: proc(dir: string, name: string) -> string {
  // An absolute name replaces the directory outright, exactly as openat()
  // ignores its dirfd when handed an absolute path. resolve_parent_beneath
  // never produces one - it rejects them - but an *unsandboxed* call passes
  // the program's own path straight through, and §16 lets that be absolute.
  if is_absolute_path(name) do return name
  if dir == "" do return name
  if strings.has_suffix(dir, "/") do return strings.concatenate({dir, name}, context.temp_allocator)
  return strings.concatenate({dir, "/", name}, context.temp_allocator)
}

// The process's working directory, '/'-separated, for slot 0.
@(private = "file")
current_directory_path_temp :: proc() -> string {
  n := windows.GetCurrentDirectoryW(0, nil)
  if n == 0 do return "."
  buf := make([]u16, int(n), context.temp_allocator)
  got := windows.GetCurrentDirectoryW(n, raw_data(buf))
  if got == 0 do return "."
  utf8, err := windows.utf16_to_utf8(buf[:got], context.temp_allocator)
  if err != nil do return "."
  return clean_path(utf8, context.temp_allocator) // clean_path folds '\' to '/' on this target
}

// ---- error mapping ----------------------------------------------------------

// core:sys/windows doesn't spell these three.
@(private = "file")
ERROR_DIRECTORY :: 267
@(private = "file")
ERROR_PRIVILEGE_NOT_HELD :: 1314
@(private = "file")
ERROR_NOT_A_REPARSE_POINT :: 4390

// Windows error codes onto fs.odin's deliberately coarse set - the same
// judgement the Linux side makes about errno: "wasn't there", "already
// there", "not allowed", "not a directory", and .Io for everything else.
@(private = "file")
win_error_to_fs_error :: proc(code: u32) -> Fs_Error {
  switch code {
  case 0:
    return .None
  case windows.ERROR_FILE_NOT_FOUND, windows.ERROR_PATH_NOT_FOUND, windows.ERROR_INVALID_NAME:
    // ERROR_INVALID_NAME is a name Windows cannot represent at all - a
    // reserved device name, a stray colon. There is no such entry, which is
    // what .Not_Found says.
    return .Not_Found
  case windows.ERROR_FILE_EXISTS, windows.ERROR_ALREADY_EXISTS:
    return .Exists
  case windows.ERROR_ACCESS_DENIED, ERROR_PRIVILEGE_NOT_HELD:
    return .Access
  case ERROR_DIRECTORY:
    return .Not_Directory
  }
  return .Io
}

@(private = "file")
last_error :: proc() -> Fs_Error {
  return win_error_to_fs_error(u32(windows.GetLastError()))
}

// ---- opening ----------------------------------------------------------------

// The one place a handle is actually opened. `no_follow` adds
// FILE_FLAG_OPEN_REPARSE_POINT so the call lands on the link itself rather
// than its target, and the handle is then asked what it is - a check after
// the fact, but on the very object that was opened, which is what makes this
// equivalent to O_NOFOLLOW rather than a check-then-open race.
@(private = "file")
open_path :: proc(
  path: string,
  want_dir: bool,
  no_follow: bool,
  access: u32 = windows.FILE_GENERIC_READ,
) -> (windows.HANDLE, Fs_Error) {
  flags: u32 = windows.FILE_ATTRIBUTE_NORMAL
  if want_dir do flags |= windows.FILE_FLAG_BACKUP_SEMANTICS // required to open a directory at all
  if no_follow do flags |= windows.FILE_FLAG_OPEN_REPARSE_POINT

  h := windows.CreateFileW(
    to_win_path(path),
    access,
    windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
    nil,
    windows.OPEN_EXISTING,
    flags,
    nil,
  )
  if h == windows.INVALID_HANDLE_VALUE do return h, last_error()

  info: windows.BY_HANDLE_FILE_INFORMATION
  if !windows.GetFileInformationByHandle(h, &info) {
    err := last_error()
    windows.CloseHandle(h)
    return windows.INVALID_HANDLE_VALUE, err
  }
  if no_follow && (info.dwFileAttributes & windows.FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
    // A symlink or junction where the caller said not to follow one. Linux's
    // O_NOFOLLOW reports ELOOP, which fs.odin's mapping folds into .Io;
    // .Access is the honest answer here - the entry exists, and this is a
    // refusal rather than a device failure.
    windows.CloseHandle(h)
    return windows.INVALID_HANDLE_VALUE, .Access
  }
  if want_dir && (info.dwFileAttributes & windows.FILE_ATTRIBUTE_DIRECTORY) == 0 {
    windows.CloseHandle(h)
    return windows.INVALID_HANDLE_VALUE, .Not_Directory
  }
  return h, .None
}

// ---- fs.odin's operations ---------------------------------------------------

fs_cwd_dir :: proc() -> Fs_Fd {
  sync.lock(&fs_table.mutex)
  defer sync.unlock(&fs_table.mutex)
  ensure_cwd_slot()
  return FS_CWD
}

fs_open_dir_at :: proc(parent: Fs_Fd, name: string, no_follow: bool) -> (Fs_Fd, Fs_Error) {
  dir, ok := dir_path_of(parent)
  if !ok do return FS_INVALID_FD, .Not_Directory
  child := join_child(dir, name)
  h, err := open_path(child, true, no_follow)
  if err != .None do return FS_INVALID_FD, err
  return alloc_slot(Fs_Slot{used = true, is_dir = true, handle = h, path = own_path(clean_path(child, context.temp_allocator))}), .None
}

fs_open_read_at :: proc(parent: Fs_Fd, name: string, no_follow: bool) -> (Fs_Fd, Fs_Error) {
  dir, ok := dir_path_of(parent)
  if !ok do return FS_INVALID_FD, .Not_Directory
  h, err := open_path(join_child(dir, name), false, no_follow)
  if err != .None do return FS_INVALID_FD, err
  return alloc_slot(Fs_Slot{used = true, is_dir = false, handle = h}), .None
}

// CREATE_NEW is exactly O_CREAT|O_EXCL: it fails with ERROR_FILE_EXISTS when
// the name is taken, which is what §16's exclusive create and the cache's
// dedup both rely on.
fs_create_exclusive_at :: proc(parent: Fs_Fd, name: string) -> (Fs_Fd, Fs_Error) {
  dir, ok := dir_path_of(parent)
  if !ok do return FS_INVALID_FD, .Not_Directory
  h := windows.CreateFileW(
    to_win_path(join_child(dir, name)),
    windows.FILE_GENERIC_WRITE,
    windows.FILE_SHARE_READ,
    nil,
    windows.CREATE_NEW,
    windows.FILE_ATTRIBUTE_NORMAL,
    nil,
  )
  if h == windows.INVALID_HANDLE_VALUE do return FS_INVALID_FD, last_error()
  return alloc_slot(Fs_Slot{used = true, is_dir = false, handle = h}), .None
}

// Asked before opening, so a directory is never opened as if it were a file -
// see the note in fs.odin. Attributes rather than an open, because this is
// only ever a question about the name.
fs_stat_is_dir_at :: proc(parent: Fs_Fd, name: string, no_follow: bool) -> (bool, Fs_Error) {
  dir, ok := dir_path_of(parent)
  if !ok do return false, .Not_Directory
  attrs := windows.GetFileAttributesW(to_win_path(join_child(dir, name)))
  if attrs == windows.INVALID_FILE_ATTRIBUTES do return false, last_error()
  if no_follow && (attrs & windows.FILE_ATTRIBUTE_REPARSE_POINT) != 0 do return false, .Access
  return (attrs & windows.FILE_ATTRIBUTE_DIRECTORY) != 0, .None
}

fs_is_directory :: proc(fd: Fs_Fd) -> (bool, Fs_Error) {
  slot, ok := get_slot(fd)
  if !ok do return false, .Io
  return slot.is_dir, .None
}

fs_read_all :: proc(fd: Fs_Fd) -> ([]u8, Fs_Error) {
  slot, ok := get_slot(fd)
  if !ok || slot.is_dir do return nil, .Io

  size: windows.LARGE_INTEGER
  if !windows.GetFileSizeEx(slot.handle, &size) do return nil, last_error()

  // The size is a starting point, not a promise - the loop is what decides,
  // the same reasoning as the Linux side's short-read loop.
  total := int(i64(size))
  buf := make([]u8, total)
  read := 0
  for read < total {
    // ReadFile counts bytes in a DWORD, so a file over 4GB needs more than
    // one call however cooperative the OS is being.
    want := total - read
    if want > int(max(u32)) do want = int(max(u32))
    n: windows.DWORD
    if !windows.ReadFile(slot.handle, raw_data(buf[read:]), windows.DWORD(want), &n, nil) {
      err := last_error()
      delete(buf)
      return nil, err
    }
    if n == 0 do break // EOF early: the file shrank since the size call
    read += int(n)
  }
  return buf[:read], .None
}

fs_write_all :: proc(fd: Fs_Fd, data: []u8) -> Fs_Error {
  slot, ok := get_slot(fd)
  if !ok || slot.is_dir do return .Io
  written := 0
  for written < len(data) {
    want := len(data) - written
    if want > int(max(u32)) do want = int(max(u32))
    n: windows.DWORD
    if !windows.WriteFile(slot.handle, raw_data(data[written:]), windows.DWORD(want), &n, nil) {
      return last_error()
    }
    if n == 0 do break
    written += int(n)
  }
  return .None
}

fs_close :: proc(fd: Fs_Fd) {
  if fd == FS_CWD do return // slot 0 is the working directory, and outlives everything
  sync.lock(&fs_table.mutex)
  defer sync.unlock(&fs_table.mutex)
  i := int(fd)
  if i < 1 || i >= len(fs_table.slots) do return
  slot := fs_table.slots[i]
  if !slot.used do return
  if slot.handle != windows.INVALID_HANDLE_VALUE do windows.CloseHandle(slot.handle)
  if slot.is_dir do delete(slot.path, fs_allocator())
  fs_table.slots[i] = Fs_Slot{}
}

// ---- symlinks ---------------------------------------------------------------

// Windows needs a privilege for this that an ordinary process does not have:
// either Developer Mode is on (which is what
// SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE asks for) or the process is
// elevated. When neither holds the refusal arrives as
// ERROR_PRIVILEGE_NOT_HELD and maps to .Access - "not allowed", which is
// exactly what happened. readlink needs no privilege either way.
//
// Windows also distinguishes file symlinks from directory symlinks at
// creation time, where POSIX does not: the flag has to match the target, and
// the target need not exist yet. Resolving it against the link's own
// directory is the best available guess; a dangling target gets a file
// symlink, which is the commoner case.
fs_symlink_at :: proc(parent: Fs_Fd, name: string, target: string) -> Fs_Error {
  dir, ok := dir_path_of(parent)
  if !ok do return .Not_Directory

  flags: u32 = windows.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
  probe := target
  if !is_drive_absolute(target) && !(len(target) > 0 && (target[0] == '/' || target[0] == '\\')) {
    probe = join_child(dir, target)
  }
  if attrs := windows.GetFileAttributesW(to_win_path(probe)); attrs != windows.INVALID_FILE_ATTRIBUTES {
    if (attrs & windows.FILE_ATTRIBUTE_DIRECTORY) != 0 do flags |= windows.SYMBOLIC_LINK_FLAG_DIRECTORY
  }

  // The target is stored as the program wrote it (§3 treats it as directory
  // metadata, not something to resolve) - only the separators are translated,
  // since a Windows symlink target has to be backslash-separated for anything
  // else to follow it.
  tb := strings.builder_make(context.temp_allocator)
  write_backslashed(&tb, target)

  if !windows.CreateSymbolicLinkW(
    to_win_path(join_child(dir, name)),
    windows.utf8_to_wstring(strings.to_string(tb), context.temp_allocator),
    flags,
  ) {
    return last_error()
  }
  return .None
}

// Windows has no readlink(): the target lives in the reparse point's data
// buffer, fetched with FSCTL_GET_REPARSE_POINT and decoded by hand below.
// Junctions are read as well as symlinks, since either is what a program
// could have found there.

@(private = "file")
REPARSE_HEADER :: struct {
  ReparseTag:        u32,
  ReparseDataLength: u16,
  Reserved:          u16,
}

// Symlink and mount-point buffers differ only by the symlink's trailing
// Flags field, and the name offsets are measured from the start of the path
// buffer that follows each.
@(private = "file")
SYMLINK_REPARSE :: struct {
  using header:         REPARSE_HEADER,
  SubstituteNameOffset: u16,
  SubstituteNameLength: u16,
  PrintNameOffset:      u16,
  PrintNameLength:      u16,
  Flags:                u32,
}

@(private = "file")
MOUNT_POINT_REPARSE :: struct {
  using header:         REPARSE_HEADER,
  SubstituteNameOffset: u16,
  SubstituteNameLength: u16,
  PrintNameOffset:      u16,
  PrintNameLength:      u16,
}

fs_readlink_at :: proc(parent: Fs_Fd, name: string) -> (string, Fs_Error) {
  dir, ok := dir_path_of(parent)
  if !ok do return "", .Not_Directory

  // No-follow on purpose: the link itself is wanted, not what it points at.
  // No read access is requested - FSCTL_GET_REPARSE_POINT is metadata.
  h := windows.CreateFileW(
    to_win_path(join_child(dir, name)),
    0,
    windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
    nil,
    windows.OPEN_EXISTING,
    windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OPEN_REPARSE_POINT,
    nil,
  )
  if h == windows.INVALID_HANDLE_VALUE do return "", last_error()
  defer windows.CloseHandle(h)

  buf := make([]u8, windows.MAXIMUM_REPARSE_DATA_BUFFER_SIZE, context.temp_allocator)
  returned: windows.DWORD
  if !windows.DeviceIoControl(
    h,
    windows.FSCTL_GET_REPARSE_POINT,
    nil,
    0,
    raw_data(buf),
    windows.DWORD(len(buf)),
    &returned,
    nil,
  ) {
    code := u32(windows.GetLastError())
    // Not a link at all. readlink(2) reports EINVAL here, which fs.odin's
    // mapping folds into .Io along with everything outside its named cases.
    if code == ERROR_NOT_A_REPARSE_POINT do return "", .Io
    return "", win_error_to_fs_error(code)
  }
  if int(returned) < size_of(REPARSE_HEADER) do return "", .Io

  header := (^REPARSE_HEADER)(raw_data(buf))
  offset, length, path_start: int
  switch header.ReparseTag {
  case windows.IO_REPARSE_TAG_SYMLINK:
    if int(returned) < size_of(SYMLINK_REPARSE) do return "", .Io
    r := (^SYMLINK_REPARSE)(raw_data(buf))
    offset, length = int(r.SubstituteNameOffset), int(r.SubstituteNameLength)
    path_start = size_of(SYMLINK_REPARSE)
  case windows.IO_REPARSE_TAG_MOUNT_POINT:
    if int(returned) < size_of(MOUNT_POINT_REPARSE) do return "", .Io
    r := (^MOUNT_POINT_REPARSE)(raw_data(buf))
    offset, length = int(r.SubstituteNameOffset), int(r.SubstituteNameLength)
    path_start = size_of(MOUNT_POINT_REPARSE)
  case:
    return "", .Io // some other reparse point - not a link this can describe
  }

  start := path_start + offset
  if length <= 0 || start + length > int(returned) do return "", .Io
  wide := (transmute([^]u16)raw_data(buf[start:]))[:length / 2]

  target, err := windows.utf16_to_utf8(wide, context.temp_allocator)
  if err != nil do return "", .Io
  // An absolute target carries the \??\ device prefix Windows resolves it
  // through, which is how it is stored rather than part of the target.
  target = strings.trim_prefix(target, "\\??\\")
  return strings.clone(to_slash(target)), .None
}

// ---- the two path-taking operations, for ctx.cache (§9) ---------------------

fs_open_dir_path :: proc(path: string) -> (Fs_Fd, Fs_Error) {
  abs := absolute_dir_path(path)
  defer delete(abs)
  h, err := open_path(abs, true, false)
  if err != .None do return FS_INVALID_FD, err
  return alloc_slot(Fs_Slot{used = true, is_dir = true, handle = h, path = own_path(abs)}), .None
}

// mkdir -p: every missing ancestor, tolerating those that already exist. The
// walk starts past the root - a drive letter or a UNC share is not a
// directory anyone creates.
fs_make_dirs :: proc(path: string) -> Fs_Error {
  abs := absolute_dir_path(path)
  defer delete(abs)
  start := path_root_len(abs)
  if start == 0 do start = 1
  for i := start; i <= len(abs); i += 1 {
    if i < len(abs) && abs[i] != '/' do continue
    if i == 0 do continue
    windows.CreateDirectoryW(to_win_path(abs[:i]), nil)
  }
  return .None
}

// The editor's file pickers. FindFirstFileW wants a wildcard rather than a
// directory, and always reports "." and ".." first, which no caller wants.
fs_list_dir :: proc(path: string, allocator := context.allocator) -> ([]Fs_Entry, Fs_Error) {
  abs := absolute_dir_path(path)
  defer delete(abs)
  data: windows.WIN32_FIND_DATAW
  h := windows.FindFirstFileW(to_win_path(join_child(abs, "*")), &data)
  if h == windows.INVALID_HANDLE_VALUE do return nil, last_error()
  defer windows.FindClose(h)

  entries := make([dynamic]Fs_Entry, 0, 16, allocator)
  for {
    name, err := windows.utf16_to_utf8(data.cFileName[:name_length(data.cFileName[:])], context.temp_allocator)
    if err == nil && name != "." && name != ".." {
      append(&entries, Fs_Entry {
        name   = strings.clone(name, allocator),
        is_dir = (data.dwFileAttributes & windows.FILE_ATTRIBUTE_DIRECTORY) != 0,
      })
    }
    if !windows.FindNextFileW(h, &data) do break
  }
  return entries[:], .None
}

@(private = "file")
name_length :: proc(buf: []u16) -> int {
  for c, i in buf do if c == 0 do return i
  return len(buf)
}
