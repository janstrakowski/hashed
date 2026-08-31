package hashedbuild

import "core:slice"

// SPEC.md §3's directory hash - the other half of the rule hash.odin
// implements for a regular file:
//
//   dir_entry_hash(name, entry) =
//     hash(name, "file",    content_hash, is_executable)
//     hash(name, "dir",     child_dir_hash)
//     hash(name, "symlink", target_path_string)
//   dir_hash = hash(sorted [dir_entry_hash(name, entry) for each entry])
//
// Sorted by *name*, as §3 says, so the digest does not depend on the order
// the filesystem happened to hand the entries back in. Every piece mixed in
// is a fixed-width digest (plus the single exec byte), per hash.odin's Merkle
// rule - a name and a symlink target both hash as the Utf8 leaves they are,
// and a file's content keeps the untagged hash(content_bytes) it has as a
// value, so a file's digest doesn't change with whether you reached it
// directly or as a directory entry.
//
// Three things to have in front of you before changing anything here:
//
//   * **It does I/O.** Hashing a directory reads the whole tree, recursively.
//     That makes value_digest - and so values_equal, and so `==` between two
//     directory Files - a filesystem walk. There is no way around it: §3
//     defines the identity over the entries, and a directory File value holds
//     an open descriptor, not a snapshot of what was under it.
//   * **The exec bit is only readable on Linux.** WASI's filestat carries no
//     permission bits and Windows has no POSIX execute bit, so both report
//     every entry as non-executable (fs.odin's Fs_Entry). A tree containing
//     an executable therefore hashes differently there than on Linux. §3 says
//     so explicitly; it is the resolution of the question that used to be the
//     stated reason directory hashing was unbuilt.
//   * **Symlinks are never followed.** Not for classification (Fs_Entry is
//     no-follow), not for the digest (the target string is hashed as-is), and
//     not for the recursion (a link to a directory is a symlink entry, not a
//     subtree to descend into). That last one is also what keeps a cycle of
//     links from making this run forever.

directory_digest :: proc(dir_fd: Fs_Fd) -> (Value_Digest, Hash_Error) {
  entries, list_err := fs_list_dir_at(dir_fd, context.temp_allocator)
  if list_err != .None do return {}, .Directory_Read

  slice.sort_by(entries, proc(a, b: Fs_Entry) -> bool { return a.name < b.name })

  buf := make([]u8, len(entries) * DIGEST_SIZE, context.temp_allocator)
  for entry, i in entries {
    d, err := dir_entry_digest(dir_fd, entry)
    if err != .None do return {}, err
    copy(buf[i * DIGEST_SIZE:], d[:])
  }
  return sha256_tagged(TAG_DIRECTORY, buf), .None
}

@(private = "file")
dir_entry_digest :: proc(dir_fd: Fs_Fd, entry: Fs_Entry) -> (Value_Digest, Hash_Error) {
  name_d := sha256_tagged(TAG_UTF8, transmute([]u8)entry.name)

  switch {
  case entry.is_symlink:
    target, err := fs_readlink_at(dir_fd, entry.name)
    if err != .None do return {}, .Directory_Read
    return mix_digests(TAG_DIR_ENTRY_SYMLINK, name_d, sha256_tagged(TAG_UTF8, transmute([]u8)target), nil), .None

  case entry.is_dir:
    child, open_err := fs_open_dir_at(dir_fd, entry.name, true)
    if open_err != .None do return {}, .Directory_Read
    defer fs_close(child)
    child_d, child_err := directory_digest(child)
    if child_err != .None do return {}, child_err
    return mix_digests(TAG_DIR_ENTRY_DIR, name_d, child_d, nil), .None

  case:
    fd, open_err := fs_open_read_at(dir_fd, entry.name, true)
    if open_err != .None do return {}, .Directory_Read
    defer fs_close(fd)
    content, read_err := fs_read_all(fd)
    if read_err != .None do return {}, .Directory_Read
    defer delete(content)
    exec: [1]u8 = {entry.is_executable ? 1 : 0}
    return mix_digests(TAG_DIR_ENTRY_FILE, name_d, sha256_of(content), exec[:]), .None
  }
}

// tag || a || b || trailing - the one composite shape this file and
// hash_function.odin are both built from, so neither open-codes the buffer
// arithmetic. Fixed-width inputs only, per hash.odin's Merkle rule; the
// trailing bytes are always a fixed count decided by the tag.
mix_digests :: proc(tag: u8, a: Value_Digest, b: Value_Digest, trailing: []u8) -> Value_Digest {
  // Shadowed into locals because a `proc` parameter isn't addressable in Odin,
  // so it can't be sliced - the same reason digest_less (hash.odin) is written
  // as an explicit loop.
  a, b := a, b
  buf := make([]u8, 2 * DIGEST_SIZE + len(trailing), context.temp_allocator)
  copy(buf[:], a[:])
  copy(buf[DIGEST_SIZE:], b[:])
  if len(trailing) > 0 do copy(buf[2 * DIGEST_SIZE:], trailing)
  return sha256_tagged(tag, buf)
}
