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
// handle plus a name within it, never a bare path - except the two the cache
// needs (§9), which are the one place a path arrives from outside the
// program.
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
//   fs_cwd_dir              the directory unsandboxed calls resolve against
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

// One entry of a directory listing. Deliberately minimal: the editor wants
// names, and whether to descend.
Fs_Entry :: struct {
  name:   string,
  is_dir: bool,
}

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
