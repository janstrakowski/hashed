package hashedbuild

import "core:encoding/base64"
import "core:fmt"
import "core:slice"
import "core:strings"

// SPEC.md §15's `cached`, on disk. The key mechanism lives in
// hash_function.odin (a cached expression hashes as the closure it is); the
// text format lives in cache_format.odin; this file is the layout and the two
// operations over it, lookup and store.
//
// ---- the layout -------------------------------------------------------------
//
// One entry per key, in the same directory ctx.cache writes its blobs to (§16
// - `--cache-dir`, else $XDG_CACHE_HOME/hashedbuild, else the per-user
// fallback). Two shapes, decided by what the cached value *is*:
//
//   <cache>/sha256-<key>              the value is a File - stored as itself
//   <cache>/sha256-<key>.hb/          anything else - a directory holding
//   <cache>/sha256-<key>.hb/value.hb    the value, written as HashedBuild text
//   <cache>/sha256-<key>.hb/sha256-<h>  one entry per File inside that value
//
// A File value is kept as a file, and a directory value as a directory, so
// that what a build produced is still a thing you can open, `cat`, `diff` or
// copy out - the point of a content-addressed store is lost if everything in
// it is an opaque blob. Anything that is not a File has no such natural form,
// so it becomes text; and since text cannot hold a file, any File *inside* it
// is written out beside it and referenced by name, systematically, however
// deep it is nested.
//
// `<key>` is the cache key - the hash of the expression as a closure - because
// that is the only thing a lookup has to go on. `<h>` on a nested entry is
// that File's own content hash (§3), which is what makes two entries that
// contain the same file share one copy of it inside their own directories.
// Both are base64url without padding, so they are legal filenames on every
// target. The separator is `-`, where ctx.cache's own blobs use `_`
// (builtins_fs.odin): the two kinds of entry live in one directory, and the
// separator is what tells them apart at a glance.
//
// ---- committing -------------------------------------------------------------
//
// An entry is built under a temporary name and renamed into place, so a run
// that is interrupted mid-write leaves a `.tmp` behind rather than a truncated
// entry that the next run would read as a hit. The rename is also how the race
// between two runs computing the same key is settled: the loser's rename
// fails, it removes its own temporary, and both go on to read the winner's
// entry. Nothing is ever overwritten, and nothing has to be locked.
//
// ---- what a hit returns -----------------------------------------------------
//
// A store reads the entry back rather than returning the value it just
// computed. It costs a re-read, and it buys the property that matters: the
// first run and the second return the *same* value, Files included - pointing
// at the cache, displaying the cache's paths - instead of a value whose Files
// happen to point wherever this particular run built them.

// The prefix and alphabet an entry name is built with. Never change either:
// both are baked into the name of every entry already on disk.
@(private = "file")
ENTRY_PREFIX :: "sha256-"
@(private = "file")
VALUE_FILE :: "value.hb"
@(private = "file")
HB_SUFFIX :: ".hb"

cache_entry_name_for :: proc(d: Value_Digest) -> string {
  d := d
  encoded, _ := base64.encode(d[:], base64.ENC_URL_TABLE, context.temp_allocator)
  return strings.concatenate({ENTRY_PREFIX, strings.trim_right(encoded, "=")})
}

// ---- lookup -----------------------------------------------------------------

// Whether `key_name` has an entry, and if so the value it holds. A missing
// entry is (nil, false, "") - an ordinary miss, not a failure. A *present*
// entry that cannot be read is a failure with a message, deliberately rather
// than a miss: silently recomputing over a corrupt cache would hide the
// corruption for as long as the cache lived.
cache_lookup :: proc(cache: ^Cache_Value, key_name: string) -> (val: Value, found: bool, err_msg: string) {
  if errno := ensure_cache_dir_open(cache); errno != .None {
    return nil, false, fmt.tprintf("could not open cache directory %s (%v)", cache.dir_path, errno)
  }

  // The File shape first: a bare `sha256-<key>`, stored as itself.
  if is_dir, stat_err := fs_stat_is_dir_at(cache.dir_fd, key_name, true); stat_err == .None {
    v, ok, msg := load_file_entry(cache, key_name, is_dir)
    return v, ok, msg
  }

  text_name := strings.concatenate({key_name, HB_SUFFIX}, context.temp_allocator)
  if is_dir, stat_err := fs_stat_is_dir_at(cache.dir_fd, text_name, true); stat_err != .None || !is_dir {
    return nil, false, "" // a miss
  }
  return load_text_entry(cache, text_name)
}

@(private = "file")
load_file_entry :: proc(cache: ^Cache_Value, name: string, is_dir: bool) -> (Value, bool, string) {
  display := strings.concatenate({cache.dir_path, "/", name})
  fv, msg := open_as_file_value(cache.dir_fd, name, is_dir, display)
  if msg != "" do return nil, false, msg
  return fv, true, ""
}

@(private = "file")
load_text_entry :: proc(cache: ^Cache_Value, dir_name: string) -> (Value, bool, string) {
  entry_fd, open_err := fs_open_dir_at(cache.dir_fd, dir_name, true)
  if open_err != .None {
    return nil, false, fmt.tprintf("could not open %s (%v)", dir_name, open_err)
  }
  defer fs_close(entry_fd)

  text_fd, text_err := fs_open_read_at(entry_fd, VALUE_FILE, true)
  if text_err != .None {
    return nil, false, fmt.tprintf("cache entry %s has no %s (%v)", dir_name, VALUE_FILE, text_err)
  }
  text, read_err := fs_read_all(text_fd)
  fs_close(text_fd)
  if read_err != .None {
    return nil, false, fmt.tprintf("could not read %s/%s (%v)", dir_name, VALUE_FILE, read_err)
  }

  ctx := Load_Ctx{
    entry_fd     = entry_fd,
    display_base = strings.concatenate({cache.dir_path, "/", dir_name}, context.temp_allocator),
  }
  v, ok := cache_format_read(string(text), resolve_entry_file, &ctx)
  if !ok {
    return nil, false, fmt.tprintf("cache entry %s/%s is not readable as a value", dir_name, VALUE_FILE)
  }
  if ctx.failure != "" do return nil, false, ctx.failure
  return v, true, ""
}

@(private = "file")
Load_Ctx :: struct {
  entry_fd:     Fs_Fd,
  display_base: string,
  failure:      string, // set by the resolver, which can only report a bool
}

@(private = "file")
resolve_entry_file :: proc(entry_name: string, is_dir: bool, userdata: rawptr) -> (Value, bool) {
  ctx := (^Load_Ctx)(userdata)
  // The name comes out of the entry's own text, so it is contained the same
  // way §16's `.dir` sub-paths are: a separator in it would mean the entry was
  // hand-edited, and there is nothing legitimate it could name.
  if entry_name == "" || index_path_sep(entry_name) >= 0 || strings.contains(entry_name, "..") {
    ctx.failure = fmt.tprintf("cache entry names %q, which is not a name this store writes", entry_name)
    return nil, false
  }
  display := strings.concatenate({ctx.display_base, "/", entry_name})
  fv, msg := open_as_file_value(ctx.entry_fd, entry_name, is_dir, display)
  if msg != "" {
    ctx.failure = msg
    return nil, false
  }
  return fv, true
}

// One File value for a name inside the store, of the kind the text said it
// was. A mismatch is reported rather than followed: it means the entry and
// what is on disk have drifted apart.
open_as_file_value :: proc(dir_fd: Fs_Fd, name: string, is_dir: bool, display: string) -> (^File_Value, string) {
  actually_dir, stat_err := fs_stat_is_dir_at(dir_fd, name, true)
  if stat_err != .None do return nil, fmt.tprintf("could not read %s (%v)", name, stat_err)
  if actually_dir != is_dir {
    return nil, fmt.tprintf("%s is not the kind of File it was expected to be", name)
  }

  fv := new(File_Value)
  fv.display_path = display
  if is_dir {
    fd, err := fs_open_dir_at(dir_fd, name, true)
    if err != .None do return nil, fmt.tprintf("could not open %s (%v)", name, err)
    fv.kind = .Directory
    fv.dir_fd = fd
    return fv, ""
  }

  fd, err := fs_open_read_at(dir_fd, name, true)
  if err != .None do return nil, fmt.tprintf("could not open %s (%v)", name, err)
  defer fs_close(fd)
  content, read_err := fs_read_all(fd)
  if read_err != .None do return nil, fmt.tprintf("could not read %s (%v)", name, read_err)
  fv.kind = .Regular
  fv.content = content
  fv.is_executable = is_executable_at(dir_fd, name)
  return fv, ""
}

// Whether a name in an open directory is executable. Read off the directory
// listing, which is the one place the fs layer reports the bit (Fs_Dir_Entry);
// there is no single-name stat for it. §3 hashes no permission bit, so this
// changes no digest - it is carried so that a program does not stop being one
// by passing through the cache, or through `exec`'s scratch directory.
is_executable_at :: proc(dir_fd: Fs_Fd, name: string) -> bool {
  entries, err := fs_list_entries_at(dir_fd, context.temp_allocator)
  if err != .None do return false
  for entry in entries {
    if entry.name == name do return entry.is_executable
  }
  return false
}

// ---- store ------------------------------------------------------------------

// Writes `v` under `key_name` and returns what a lookup of that key now
// yields. Losing the race to another run is not a failure: the entry that
// won holds the same value, since the key is the same.
// `interp` is what hashing a nested File needs (§3's directory digest reads
// the tree, and that read is gated on `io` like any other).
cache_store :: proc(cache: ^Cache_Value, key_name: string, v: Value, interp: ^Interpreter) -> (Value, bool, string) {
  if errno := ensure_cache_dir_open(cache); errno != .None {
    return nil, false, fmt.tprintf("could not open cache directory %s (%v)", cache.dir_path, errno)
  }

  final_name := key_name
  if _, is_file := v.(^File_Value); !is_file {
    final_name = strings.concatenate({key_name, HB_SUFFIX})
  }

  temp_name, temp_ok := make_temp_dir(cache.dir_fd, final_name)
  if !temp_ok {
    return nil, false, "could not create a temporary directory in the cache"
  }
  temp_fd, temp_err := fs_open_dir_at(cache.dir_fd, temp_name, true)
  if temp_err != .None {
    remove_tree_at(cache.dir_fd, temp_name)
    return nil, false, fmt.tprintf("could not open the temporary cache entry (%v)", temp_err)
  }

  // A File value is written *as* the entry, so it is built one level down and
  // that inner name is what gets renamed into place; everything else fills the
  // temporary directory itself.
  published := temp_name
  if fv, is_file := v.(^File_Value); is_file {
    if msg := write_file_value(temp_fd, "entry", fv); msg != "" {
      fs_close(temp_fd)
      remove_tree_at(cache.dir_fd, temp_name)
      return nil, false, msg
    }
    published = strings.concatenate({temp_name, "/entry"}, context.temp_allocator)
  } else if msg := write_text_entry(temp_fd, v, interp); msg != "" {
    fs_close(temp_fd)
    remove_tree_at(cache.dir_fd, temp_name)
    return nil, false, msg
  }
  fs_close(temp_fd)

  rename_err := fs_rename_at(cache.dir_fd, published, final_name)
  // A File entry was built one level down, so the wrapper directory is still
  // there to clear away after a successful rename; a text entry *is* the
  // temporary, so there is only something to remove when the rename failed.
  if rename_err != .None || published != temp_name {
    remove_tree_at(cache.dir_fd, temp_name)
  }

  if rename_err != .None {
    // Either another run published this key first - the ordinary case, and not
    // a failure, since the key determines the value - or the store is broken.
    // The lookup below is what tells the two apart.
    if stored, found, msg := cache_lookup(cache, key_name); msg == "" && found {
      return stored, true, ""
    }
    return nil, false, fmt.tprintf("could not publish cache entry %s (%v)", final_name, rename_err)
  }

  stored, found, msg := cache_lookup(cache, key_name)
  if msg != "" do return nil, false, msg
  if !found do return nil, false, fmt.tprintf("cache entry %s vanished immediately after being written", final_name)
  return stored, true, ""
}

// `<final>.tmpN`, first N that doesn't already exist. Uniqueness comes from
// the exclusive mkdir itself rather than from a random name, which needs no
// source of randomness and no process id - neither of which every target here
// has. The cap only has to exceed the number of runs racing on one key at
// once; anything near it means something else is wrong.
make_temp_dir :: proc(dir_fd: Fs_Fd, final_name: string) -> (string, bool) {
  for i in 0 ..< 64 {
    name := fmt.tprintf("%s.tmp%d", final_name, i)
    if fs_mkdir_at(dir_fd, name) == .None do return strings.clone(name), true
  }
  return "", false
}

@(private = "file")
write_text_entry :: proc(entry_fd: Fs_Fd, v: Value, interp: ^Interpreter) -> string {
  // Every File in the value, written out first, so the text can refer to each
  // by the name it landed under.
  files := make([dynamic]^File_Value, 0, 4, context.temp_allocator)
  seen := make(map[^Table_Value]bool)
  defer delete(seen)
  collect_files(v, &files, &seen)

  // Not the temp allocator, unlike almost everything else here: this map has
  // to survive every write below, and writing a File hashes it - which for a
  // directory value walks a whole tree, allocating temporary buffers the whole
  // way down. A map living in that same arena does not reliably come out the
  // other side.
  names := make(map[^File_Value]string, len(files))
  defer delete(names)
  for fv in files {
    if _, already := names[fv]; already do continue
    d, herr := value_digest(fv, interp)
    if herr.kind != .None do return fmt.tprintf("cannot cache this value: %s", hash_error_message(herr))
    name := cache_entry_name_for(d)
    if msg := write_file_value(entry_fd, name, fv); msg != "" do return msg
    names[fv] = name
  }

  text, ok, why := cache_format_write(v, names)
  if !ok do return fmt.tprintf("cannot cache this value: %s", why)
  return write_bytes(entry_fd, VALUE_FILE, transmute([]u8)text, false)
}

// Every File reachable in `v`, in a deterministic order. Tables are the only
// thing that can hold one; a Function's environment is not part of a value's
// content, and nothing else nests.
//
// `seen` is not an optimisation: `let rec` can build a Table that reaches
// itself (§10), and without it this walks a cycle forever.
@(private = "file")
collect_files :: proc(v: Value, out: ^[dynamic]^File_Value, seen: ^map[^Table_Value]bool) {
  resolved, ok := resolve_forward(v)
  if !ok do return // still under construction; write_value reports it

  #partial switch av in resolved {
  case ^File_Value:
    append(out, av)
  case ^Table_Value:
    if seen[av] do return
    seen[av] = true
    for entry in av.entries {
      collect_files(entry.key, out, seen)
      collect_files(entry.value, out, seen)
    }
  }
}

// ---- writing a File out -----------------------------------------------------
//
// The four procs below (write_file_value, open_as_file_value, make_temp_dir,
// remove_tree_at, copy_tree and write_bytes) are package-visible rather than file-private because `exec`
// (builtins_build.odin) needs exactly the same four operations: it materialises
// input Files into a scratch directory, reads the declared outputs back out as
// Files, and removes the scratch afterwards. Sharing them is what keeps a File
// round-tripping identically through a build step and through the cache.

write_file_value :: proc(dir_fd: Fs_Fd, name: string, fv: ^File_Value) -> string {
  if fv.kind == .Regular do return write_bytes(dir_fd, name, fv.content, fv.is_executable)

  if err := fs_mkdir_at(dir_fd, name); err != .None {
    return fmt.tprintf("could not create %s (%v)", name, err)
  }
  dst, open_err := fs_open_dir_at(dir_fd, name, true)
  if open_err != .None do return fmt.tprintf("could not open %s (%v)", name, open_err)
  defer fs_close(dst)
  return copy_tree(fv.dir_fd, dst)
}

// A recursive copy of everything SPEC.md §3's directory hash reads - names,
// file contents, and symlink targets stored without being followed - so a
// restored directory hashes as the one it was copied from, which is what makes
// a hit and a miss return the same value.
//
// Plus one thing §3 does *not* read: the executable bit, where the target has
// one. It is not part of a directory's identity (§3 hashes no permission bit),
// so copying it changes no digest; it is copied because caching a build output
// and getting back something you can no longer run would be a poor trade for a
// build system. Nothing else about a directory is copied.
copy_tree :: proc(src_fd: Fs_Fd, dst_fd: Fs_Fd) -> string {
  entries, list_err := fs_list_entries_at(src_fd, context.temp_allocator)
  if list_err != .None do return fmt.tprintf("could not read a directory being cached (%v)", list_err)
  slice.sort_by(entries, proc(a, b: Fs_Dir_Entry) -> bool { return a.name < b.name })

  for entry in entries {
    switch entry.kind {
    case .Symlink:
      target, err := fs_readlink_at(src_fd, entry.name)
      if err != .None do return fmt.tprintf("could not read the symlink %s (%v)", entry.name, err)
      if serr := fs_symlink_at(dst_fd, entry.name, target); serr != .None {
        return fmt.tprintf("could not recreate the symlink %s in the cache (%v)", entry.name, serr)
      }

    case .Directory:
      if err := fs_mkdir_at(dst_fd, entry.name); err != .None {
        return fmt.tprintf("could not create %s (%v)", entry.name, err)
      }
      child_src, src_err := fs_open_dir_at(src_fd, entry.name, true)
      if src_err != .None do return fmt.tprintf("could not open %s (%v)", entry.name, src_err)
      defer fs_close(child_src)
      child_dst, dst_err := fs_open_dir_at(dst_fd, entry.name, true)
      if dst_err != .None do return fmt.tprintf("could not open %s (%v)", entry.name, dst_err)
      defer fs_close(child_dst)
      if msg := copy_tree(child_src, child_dst); msg != "" do return msg

    case .Regular:
      fd, open_err := fs_open_read_at(src_fd, entry.name, true)
      if open_err != .None do return fmt.tprintf("could not open %s (%v)", entry.name, open_err)
      content, read_err := fs_read_all(fd)
      fs_close(fd)
      if read_err != .None do return fmt.tprintf("could not read %s (%v)", entry.name, read_err)
      defer delete(content)
      if msg := write_bytes(dst_fd, entry.name, content, entry.is_executable); msg != "" do return msg

    case .Other:
      // §3 encodes three shapes and this is none of them, so the directory has
      // no digest either (hash.odin says the same). Refusing here rather than
      // skipping keeps the copy and the hash agreeing about what a tree is.
      return fmt.tprintf("%s is not a file, directory or symlink, and cannot be cached", entry.name)
    }
  }
  return ""
}

write_bytes :: proc(dir_fd: Fs_Fd, name: string, data: []u8, executable: bool) -> string {
  fd, err := fs_create_exclusive_at(dir_fd, name)
  if err != .None do return fmt.tprintf("could not create %s (%v)", name, err)
  werr := fs_write_all(fd, data)
  fs_close(fd)
  if werr != .None do return fmt.tprintf("could not write %s in the cache (%v)", name, werr)
  if executable do fs_set_executable_at(dir_fd, name)
  return ""
}

// ---- removing a temporary ---------------------------------------------------

// Best-effort: this only ever runs on a temporary the caller just built, and
// the caller is already on its way to reporting something else (or to using
// the entry another run published). Leaving a `.tmpN` behind is untidy, not
// wrong - the next run picks a different N.
remove_tree_at :: proc(parent: Fs_Fd, name: string) {
  if fs_unlink_at(parent, name) == .None do return
  if fd, err := fs_open_dir_at(parent, name, true); err == .None {
    if entries, lerr := fs_list_entries_at(fd, context.temp_allocator); lerr == .None {
      for entry in entries {
        if entry.kind == .Directory {
          remove_tree_at(fd, entry.name)
        } else {
          fs_unlink_at(fd, entry.name)
        }
      }
    }
    fs_close(fd)
  }
  fs_rmdir_at(parent, name)
}
