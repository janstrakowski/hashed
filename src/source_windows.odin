package hashedbuild

import "core:path/filepath"
import "core:strings"
import "core:sys/windows"

// The Windows counterpart to source_linux.odin. Like source_wasi.odin it
// reads the file rather than mapping it: Windows does have file mapping
// (CreateFileMapping/MapViewOfFile), but a source file is read once, in full,
// and then never touched again - the mapping would buy nothing and would owe
// an UnmapViewOfFile plus a second handle to close.
load_source_file :: proc(path_str: string) -> (res: source_t, err: Fs_Error) {
  assert(len(path_str) != 0, "path must not be empty")

  wide := windows.utf8_to_wstring(win_source_path(path_str), context.temp_allocator)
  h := windows.CreateFileW(
    wide,
    windows.FILE_GENERIC_READ,
    windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
    nil,
    windows.OPEN_EXISTING,
    windows.FILE_ATTRIBUTE_NORMAL,
    nil,
  )
  if h == windows.INVALID_HANDLE_VALUE {
    return res, source_last_error()
  }
  defer windows.CloseHandle(h)

  size: windows.LARGE_INTEGER
  if !windows.GetFileSizeEx(h, &size) do return res, source_last_error()

  total := int(i64(size))
  data := make([]u8, total)
  read := 0
  for read < total {
    want := total - read
    if want > int(max(u32)) do want = int(max(u32))
    n: windows.DWORD
    if !windows.ReadFile(h, raw_data(data[read:]), windows.DWORD(want), &n, nil) {
      e := source_last_error()
      delete(data)
      return res, e
    }
    if n == 0 do break
    read += int(n)
  }

  res = source_t {
    name    = filepath.base(path_str),
    n_bytes = u64(read),
    data    = raw_data(data),
  }
  return res, .None
}

// Mirrors free_source_file's Linux contract (there: munmap; here, as on WASI:
// the read buffer goes back to the allocator).
free_source_file :: proc(source: source_t) {
  if source.data == nil do return
  delete(source.data[:source.n_bytes])
}

// The path as Win32 wants it: backslash-separated, since the argument arrives
// however the user typed it on the command line. No \\?\ prefix here - this
// path comes straight from argv and has not been through clean_path, so the
// normalisation that prefix switches off is still wanted.
@(private = "file")
win_source_path :: proc(path: string) -> string {
  b := strings.builder_make(context.temp_allocator)
  for i in 0 ..< len(path) {
    c := path[i]
    if c == '/' do c = '\\'
    strings.write_byte(&b, c)
  }
  return strings.to_string(b)
}

// The same coarse mapping fs_windows.odin makes, kept here because that one
// is file-private and this path never goes through the builtins.
@(private = "file")
source_last_error :: proc() -> Fs_Error {
  switch u32(windows.GetLastError()) {
  case windows.ERROR_FILE_NOT_FOUND, windows.ERROR_PATH_NOT_FOUND, windows.ERROR_INVALID_NAME:
    return .Not_Found
  case windows.ERROR_ACCESS_DENIED:
    return .Access
  }
  return .Io
}
