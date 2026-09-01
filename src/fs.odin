package hashedbuild

// The filesystem operations §16's builtins are built from, named once here
// and implemented per target: fs_linux.odin against core:sys/linux's *at()
// syscalls, fs_wasi.odin against WASI preview1, fs_windows.odin against
// Win32.
//
// The split exists because the interpreter has to run in a browser, and it is
// deliberately thin: everything portable stays in builtins_fs.odin - the
// component-by-component containment walk (§16), the display-path
// construction (§3), the cache's naming and dedup (§9) - and only the calls
// that actually enter the OS live behind these names.
//
// The shape is WASI's as much as Linux's, which is no accident: preview1 is
// entirely descriptor-relative (`path_open` against a base fd, no absolute
// paths, no cwd), which is the same capability model §16's `.dir` handles
// already describe. Every operation below therefore takes a directory
// handle plus a name within it, never a bare path - except the three the
// runtime itself needs (fs_open_dir_path, fs_make_dirs, fs_cwd_dir), which
// are where `ctx.dirs` and the cache come from (§9): the only paths in the
// system that arrive from outside a program.
//
// Windows is the one target that has no descriptor-relative open at all, so
// fs_windows.odin keeps a numbered table of handles and reaches a child by
// joining onto its parent's path. That file's header says what that costs and
// what it does not: containment still holds for every path a program can
// write.

// A directory or file descriptor. Every target numbers its own as i32 - Linux
// and WASI because that is what the OS hands back, Windows because a HANDLE
// is a pointer and has to be indexed into a table to fit here. No target
// interprets another's, and nothing outside the fs_* files should do
// arithmetic on one.
Fs_Fd :: distinct i32

FS_INVALID_FD :: Fs_Fd(-1)

// Operations, all implemented per target:
//
//   fs_cwd_dir              the process's working directory, as a descriptor
//   fs_stat_is_dir_at       is this name a directory? - asked before opening,
//                           because WASI refuses a file-shaped open on a
//                           directory (its rights model distinguishes them)
//   fs_open_dir_at          open a name as a traversable directory handle
//   fs_open_read_at         open a name for reading
//   fs_create_exclusive_at  create a name, failing if it exists (§16)
//   fs_read_all             read a descriptor to EOF
//   fs_write_all            write a buffer in full
//   fs_close
//   fs_symlink_at           create a symlink; fs_readlink_at reads its target
//   fs_open_dir_path        open a directory by path - ctx.cache only (§9)
//   fs_make_dirs            mkdir -p by path - ctx.cache only (§9)
//   fs_list_dir             names in a directory - the editor's file pickers
//
// The five below were added for §15's `cached` (see cache_store.odin), which is
// the first thing here that has to write a whole directory back out again.
// Reading one is `fs_list_entries_at`, further down.
//
//   fs_mkdir_at             create one directory, failing if it exists
//   fs_rename_at            rename within one directory - the atomic commit
//   fs_unlink_at            remove one non-directory name
//   fs_rmdir_at             remove one empty directory
//   fs_set_executable_at    set the owner-execute bit, where the target has one

// One entry of a directory listing. Deliberately minimal: the editor wants
// names, and whether to descend.
Fs_Entry :: struct {
  name:   string,
  is_dir: bool,
}

// One entry of a directory in the detail SPEC.md §3's directory hash needs:
// which of the three shapes it is - plus, for a regular file, whether it is
// executable, which §3 does not hash but §15's cache preserves. Distinct from
// Fs_Entry above, which answers the editor's much smaller question (a name,
// and whether to descend into it).
//
// `kind` is decided **without following symlinks**: §3 hashes a link entry as
// its target string rather than resolving through it, so a link *to* a
// directory is .Symlink here, never .Directory.
Fs_Node_Kind :: enum {
  Regular,
  Directory,
  Symlink,
  Other, // a fifo, socket, or device node - §3 describes no hash for one
}

Fs_Dir_Entry :: struct {
  name:          string,
  kind:          Fs_Node_Kind,
  // .Regular only, and **not part of any hash**: §3 carries no permission bit
  // (see hash.odin's directory section), precisely because this is the one
  // field a target can be unable to answer - WASI's filestat has no permission
  // bits at all and Windows has no POSIX exec bit, so on those two it is always
  // false. It exists for cache_store.odin, which puts the bit back when it
  // copies a tree, so that caching a build output does not strip it. Anything
  // asking what a directory *is* should ignore this field.
  is_executable: bool,
}

//   fs_list_entries_at      the above, for every name in an open directory
//
// Named here rather than in the list above because it is the one operation
// added for hashing, and a directory's digest is its only caller. It takes a
// descriptor, not a path, because §16's containment is descriptor-relative and
// the walk must not be able to step outside the handle it was handed.

// What went wrong, in terms both targets can express. Deliberately coarse:
// these become the parenthesised detail in a §16 failure message, where the
// distinctions that matter are "wasn't there", "already there", "not allowed"
// and "the OS said no for some other reason". A Linux errno or a WASI errno
// that doesn't map onto the first four becomes .Io.
Fs_Error :: enum {
  None,
  Not_Found,
  Exists,
  Access,
  Not_Directory,
  Io,
  Unsupported, // the target has no such operation - WASI, mostly
}
