package hashedbuild

import "core:crypto/hash"
import "core:encoding/base64"
import "core:fmt"
import "core:slice"

// SPEC.md §6's "every value is hashable", and the §15 `sha256` builtin built
// on top of it. One mechanism, not two: the digest computed here is the same
// one §3 defines a `File`'s identity as, which is why values_equal (value.odin)
// compares Files through it rather than by pointer.
//
// The encoding is a Merkle construction, and it has to be, because §3 pins a
// regular File's digest to `hash(content_bytes)` exactly - untagged, so that
// `sha256 (loadfile "pkg.tar.gz")` is the same digest `sha256sum` prints for
// that file, which is the whole point of having it in a build language. An
// untagged variable-length encoding can't be safely *inlined* into a larger
// one (the boundary between a File's bytes and whatever follows it would be
// ambiguous), so composites never inline a child's encoding - they hash the
// child to a fixed 32 bytes and concatenate those. Every composite therefore
// mixes fixed-width pieces only, and distinct values cannot collide by
// re-parsing the same byte stream a different way.
//
// Leaves are domain-separated by a tag byte so that values of different types
// with the same payload stay distinct - Integer 5 and Float 5.0 are not equal
// (value.odin), so they must not hash alike either.
//
// The three kinds a Merkle fold does not reach on its own live in this file
// and its two companions:
//
//   * a **directory File**, below - its children are on the disk rather than
//     in the value, so it is the one digest that does I/O;
//   * a **Function** (hash_function.odin) - a closure is its body's shape plus
//     the values it captures, so hashing one is a static analysis and a fold;
//   * a **cyclic value** (hash_cyclic.odin) - a fold has no bottom to start
//     from, so those nodes are hashed by a canonical form instead.
//
// Everything else is the fold, and the fold is the fast path: value_digest
// tries it first, allocates nothing for an acyclic value that holds no
// directory, and only reaches for the graph machinery when it meets a cycle.

DIGEST_SIZE :: 32

Value_Digest :: [DIGEST_SIZE]u8

// Tag bytes. Never renumber these: a digest that changes meaning silently
// invalidates every cache entry and every recorded hash a user has written
// down. Appending a new tag for a new type is fine.
//
// 0x06 is unused - it was the regular File's, before §3 pinned that digest to
// the untagged content hash. It stays unused rather than being recycled, for
// the same reason the rest are never renumbered.
TAG_NOTHING :: 0x00
TAG_BOOLEAN :: 0x01
TAG_INTEGER :: 0x02
TAG_FLOAT :: 0x03
TAG_UTF8 :: 0x04
TAG_BYTES :: 0x05
TAG_TABLE :: 0x07
TAG_DIRECTORY :: 0x08
TAG_DIR_ENTRY_FILE :: 0x09
TAG_DIR_ENTRY_DIR :: 0x0a
TAG_DIR_ENTRY_LINK :: 0x0b
TAG_CACHE :: 0x0c
TAG_FUNCTION :: 0x0d
TAG_NATIVE :: 0x0e
TAG_AST :: 0x0f
TAG_CYCLIC :: 0x10
TAG_CYCLIC_NODE :: 0x11
// Not a value's digest at all: §15's cache key, which is a closure's digest
// plus what the expression can read out of the dynamic `#arg`/`#self` stacks.
// It lives here so the tag space stays in one place. See hash_implicit.odin.
TAG_IMPLICIT_REACH :: 0x12
TAG_WORKDIR :: 0x13

// Byte-lexicographic order on digests. Written as an explicit loop rather than
// slice.cmp because a `proc` parameter isn't addressable, so it can't be sliced.
digest_less :: proc(a, b: Value_Digest) -> bool {
  for i in 0 ..< DIGEST_SIZE {
    if a[i] != b[i] do return a[i] < b[i]
  }
  return false
}

sha256_of :: proc(data: []u8) -> Value_Digest {
  digest: Value_Digest
  hash.hash_bytes_to_buffer(.SHA256, data, digest[:])
  return digest
}

// The tag byte and the payload, fed to one digest without joining them first.
// Streamed rather than concatenated because the payload is sometimes the whole
// value - a Bytes leaf, a directory's entry digests - and a hash that copied
// what it hashes would double the cost of every large value in a build.
sha256_tagged :: proc(tag: u8, payload: []u8) -> Value_Digest {
  s: Digest_Stream
  digest_stream_begin(&s, tag)
  digest_stream_bytes(&s, payload)
  return digest_stream_end(&s)
}

// A digest built a piece at a time, for a composite whose payload is a
// sequence of children rather than one buffer. Same bytes as assembling the
// payload and hashing it in one go - SHA-256 is a streaming construction, so
// this is the identity, not an approximation.
Digest_Stream :: struct {
  ctx: hash.Context,
}

digest_stream_begin :: proc(s: ^Digest_Stream, tag: u8) {
  hash.init(&s.ctx, .SHA256)
  tag_byte := [1]u8{tag}
  hash.update(&s.ctx, tag_byte[:])
}

digest_stream_bytes :: proc(s: ^Digest_Stream, data: []u8) {
  hash.update(&s.ctx, data)
}

digest_stream_digest :: proc(s: ^Digest_Stream, d: Value_Digest) {
  child := d // a parameter isn't addressable, and hashing one needs a slice
  hash.update(&s.ctx, child[:])
}

digest_stream_end :: proc(s: ^Digest_Stream) -> Value_Digest {
  d: Value_Digest
  hash.final(&s.ctx, d[:])
  return d
}

// A digest of a Utf8 payload, which several composites need for a name: an
// entry's filename (§3), a captured variable's spelling (hash_function.odin).
// It is the same digest the Utf8 *value* has, deliberately - there is one
// encoding per type, not one per use site.
sha256_text :: proc(s: string) -> Value_Digest {
  return sha256_tagged(TAG_UTF8, transmute([]u8)s)
}

// ---- failures ----------------------------------------------------------------

// Why a value has no digest. Every one of these is either a refusal the OS
// made or a shape §3 describes no encoding for - the kinds that used to sit
// here for "not built yet" are gone, because they are built.
Hash_Error :: enum {
  None,
  Io_Denied,        // a directory's first read, in a context without `io` (§9)
  Directory_Read,   // the OS refused somewhere in the tree
  Unhashable_Entry, // a fifo/socket/device in a tree - §3 encodes three shapes
  Directory_Unread, // a cold directory digest, asked for where no read is possible
  No_Program,       // a closure's shape is its AST's, and there is no AST here
  Async,            // an un-awaited handle - callers await before hashing
  Cyclic,           // internal: the fold met a cycle. Never escapes value_digest.
}

// The failure, plus the entry or reason the kind alone doesn't carry. `detail`
// is temp-allocated, so it lives exactly as long as the failure is being
// reported - which is the same turn, in every caller.
Hash_Fail :: struct {
  kind:   Hash_Error,
  detail: string,
}

HASH_OK :: Hash_Fail{}

@(private = "file")
fail_kind :: proc(kind: Hash_Error) -> Hash_Fail {
  return Hash_Fail{kind = kind}
}

@(private = "file")
fail_detail :: proc(kind: Hash_Error, detail: string) -> Hash_Fail {
  return Hash_Fail{kind = kind, detail = detail}
}

hash_error_message :: proc(f: Hash_Fail) -> string {
  switch f.kind {
  case .None:
    return ""
  case .Io_Denied:
    return "reading a directory File's entries needs the io permission, and the current context does not grant it"
  case .Directory_Read:
    return f.detail
  case .Unhashable_Entry:
    return f.detail
  case .Directory_Unread:
    return "a directory File's entries have not been read yet, and cannot be read from here"
  case .No_Program:
    return "a Function's hash is its body's shape, which needs the program it was written in"
  case .Async:
    return "an un-awaited async handle has no hash"
  case .Cyclic:
    return "a cyclic value could not be hashed"
  }
  return ""
}

// ---- the walk ----------------------------------------------------------------

// State threaded through the fold. `interp` is what makes a directory's first
// read possible - and permitted; it is nil wherever hashing is asked for
// outside the evaluator (values_hash_equal, reached from table_find), and
// there a cold directory is a failure rather than a silent read.
Hash_Walk :: struct {
  interp: ^Interpreter,
  open:   [dynamic]rawptr, // the composite nodes currently being folded
}

// The digest of a value, per the encoding described at the top of this file.
//
// Two passes, and the second one almost never runs: the fold is tried first,
// and only a value that turns out to contain a cycle falls through to the
// graph algorithm in hash_cyclic.odin. That ordering is what keeps an ordinary
// Table's digest - the overwhelmingly common case - a plain recursive hash
// with no graph analysis behind it.
value_digest :: proc(v: Value, interp: ^Interpreter = nil) -> (Value_Digest, Hash_Fail) {
  w := Hash_Walk{interp = interp, open = make([dynamic]rawptr, 0, 8, context.temp_allocator)}
  d, f := value_digest_walk(v, &w)
  if f.kind != .Cyclic do return d, f
  return value_digest_cyclic(v, interp)
}

value_digest_walk :: proc(v: Value, w: ^Hash_Walk) -> (Value_Digest, Hash_Fail) {
  resolved, rok := resolve_forward(v)
  if !rok do return {}, fail_kind(.Cyclic)
  switch av in resolved {
  case Nothing_Value:
    return sha256_tagged(TAG_NOTHING, nil), HASH_OK

  case bool:
    return sha256_tagged(TAG_BOOLEAN, {1 if av else 0}), HASH_OK

  case i64:
    // Little-endian two's complement, fixed 8 bytes - Integer is exactly one
    // width (§3), so there is nothing else to encode.
    buf: [8]u8
    u := transmute(u64)av
    for i in 0 ..< 8 do buf[i] = u8((u >> (8 * uint(i))) & 0xff)
    return sha256_tagged(TAG_INTEGER, buf[:]), HASH_OK

  case f64:
    // IEEE-754 bits, little-endian. Two normalisations keep this consistent
    // with values_equal, which compares f64 with `==`: negative zero equals
    // positive zero there, so both must hash alike; and every NaN bit pattern
    // collapses to one, so a NaN at least hashes stably (it still compares
    // unequal to itself, as IEEE requires - that mismatch is IEEE's, not ours).
    f := av
    if f == 0 do f = 0 // -0.0 -> 0.0
    u := transmute(u64)f
    if f != f do u = 0x7ff8_0000_0000_0000 // any NaN -> one canonical quiet NaN
    buf: [8]u8
    for i in 0 ..< 8 do buf[i] = u8((u >> (8 * uint(i))) & 0xff)
    return sha256_tagged(TAG_FLOAT, buf[:]), HASH_OK

  case string:
    return sha256_tagged(TAG_UTF8, transmute([]u8)av), HASH_OK

  case []u8:
    return sha256_tagged(TAG_BYTES, av), HASH_OK

  case ^File_Value:
    // §3: "a regular file's hash is just hash(content_bytes)" - deliberately
    // untagged, so it matches what sha256sum reports for the same bytes.
    if av.kind == .Directory do return file_directory_digest(av, w.interp)
    return sha256_of(av.content), HASH_OK

  case ^Table_Value:
    // §5/§6: a Table's hash is key-sorted, so it does not depend on the order
    // the entries were written in - which is exactly the equality values_equal
    // already implements (it matches entries by key, ignoring position).
    // Sorting by key digest gives a deterministic order without needing §6's
    // cross-type value ordering, which isn't built.
    for open in w.open {
      if open == rawptr(av) do return {}, fail_kind(.Cyclic)
    }
    append(&w.open, rawptr(av))
    defer pop(&w.open)
    pairs := make([][2]Value_Digest, len(av.entries), context.temp_allocator)
    for entry, i in av.entries {
      kd, kerr := value_digest_walk(entry.key, w)
      if kerr.kind != .None do return {}, kerr
      vd, verr := value_digest_walk(entry.value, w)
      if verr.kind != .None do return {}, verr
      pairs[i] = {kd, vd}
    }
    slice.sort_by(pairs, proc(a, b: [2]Value_Digest) -> bool {
      return digest_less(a[0], b[0])
    })
    s: Digest_Stream
    digest_stream_begin(&s, TAG_TABLE)
    for pair in pairs {
      digest_stream_digest(&s, pair[0])
      digest_stream_digest(&s, pair[1])
    }
    return digest_stream_end(&s), HASH_OK

  case ^Function_Value:
    return function_digest(av, w)

  case ^Cache_Value:
    // §9's ctx.cache. A bare tag and nothing else: there is exactly one per
    // context, it has no content a program can observe, and the one thing that
    // *would* tell two of them apart - the directory it is rooted at - is the
    // path §9 spends its last paragraph keeping out of the language. Hashing
    // it to the path would hand that back through a side door.
    return sha256_tagged(TAG_CACHE, nil), HASH_OK

  case ^Workdir_Value:
    // §9's ctx.dir, and the same reasoning as ctx.cache above with one more
    // reason on top. Hashing it as the directory's *contents* (which is what
    // a directory File hashes as, §3) would put the whole project tree into
    // every `cached` key, so editing any one file would invalidate every
    // entry - the exact opposite of what a content-addressed build wants.
    // Hashing it as its *path* would bake the checkout location in. A bare
    // tag is what is left, and it loses nothing: what a program reads through
    // this handle are ordinary Files, and those still hash by content.
    return sha256_tagged(TAG_WORKDIR, nil), HASH_OK

  case ^Async_Handle:
    return {}, fail_kind(.Async)

  case ^Forward_Ref_Value:
    // Unreachable: resolve_forward above returned either a non-forward value
    // or .Cyclic. Present so the switch stays exhaustive.
    return {}, fail_kind(.Cyclic)
  }
  return sha256_tagged(TAG_NOTHING, nil), HASH_OK
}

// ---- directories (SPEC.md §3) -------------------------------------------------

// §3 spells the directory hash out:
//
//   dir_entry_hash(name, entry) =
//     hash(name, "file",    content_hash)
//     hash(name, "dir",     child_dir_hash)
//     hash(name, "symlink", target_path_string)
//   dir_hash = hash(sorted [dir_entry_hash(name, entry) for each entry])
//
// with the three spelled-out tags becoming the three TAG_DIR_ENTRY_* bytes,
// and "sorted" meaning by name, byte-wise - so the digest is the tree's, not
// the order readdir happened to hand it back in. The directory's own digest is
// tagged, which §3 leaves open: only a *regular* file's digest is pinned
// untagged (so it matches sha256sum), and without a tag here a directory could
// in principle collide with a regular file whose content happened to be its
// entry digests laid end to end.
//
// **No permission bit is hashed** (§3, resolved 2026-08-31). An earlier form of
// §3 kept the owner-execute bit here, false on the targets that cannot see one.
// The trouble is that this makes a tree's identity depend on where it was
// checked out, and git shows why that is not hypothetical: it records exactly
// this one bit (100644 vs 100755) and sets core.fileMode=false on Windows, so
// the bit round-trips through a repository without ever existing in the working
// tree. The same commit is executable on Linux and not on Windows - this
// repository's own scripts/ would have hashed two ways.
//
// git escapes that by *remembering* the bit rather than re-deriving it, which
// is not available here: a File is a handle onto a live directory, with no
// index beside it to consult. Between a digest that disagrees across targets
// and one that ignores a bit two of the three cannot see, §3 takes the second.
// Fs_Dir_Entry still reports it and cache_store.odin still restores it when
// copying a tree, so caching a build output does not silently strip it - that
// is fidelity in the store, not identity in the language.
//
// A symlink is hashed as its target *string*, never resolved (§3), which is
// also what keeps this recursion finite: nothing here follows a link, so the
// walk is bounded by the tree's real depth and a link loop is just a string.
@(private = "file")
file_directory_digest :: proc(fv: ^File_Value, interp: ^Interpreter) -> (Value_Digest, Hash_Fail) {
  if fv.dir_digest_known do return fv.dir_digest, HASH_OK
  // No evaluator to ask, so no permission to check and no read to make. This
  // is values_hash_equal's path (value.odin) - see the note there on why the
  // evaluator warms the digest before a comparison rather than doing it here.
  if interp == nil do return {}, fail_kind(.Directory_Unread)
  if !ctx_allows_io(interp) do return {}, fail_kind(.Io_Denied)

  d, f := directory_digest_at(fv.dir_fd)
  if f.kind != .None do return {}, f
  fv.dir_digest = d
  fv.dir_digest_known = true
  return d, HASH_OK
}

@(private = "file")
directory_digest_at :: proc(dir: Fs_Fd) -> (Value_Digest, Hash_Fail) {
  entries, err := fs_list_entries_at(dir, context.temp_allocator)
  if err != .None {
    return {}, fail_detail(.Directory_Read, fmt.tprintf("could not read a directory's entries (%v)", err))
  }
  slice.sort_by(entries, proc(a, b: Fs_Dir_Entry) -> bool { return a.name < b.name })

  s: Digest_Stream
  digest_stream_begin(&s, TAG_DIRECTORY)
  for entry in entries {
    ed, f := dir_entry_digest(dir, entry)
    if f.kind != .None do return {}, f
    digest_stream_digest(&s, ed)
  }
  return digest_stream_end(&s), HASH_OK
}

@(private = "file")
dir_entry_digest :: proc(dir: Fs_Fd, entry: Fs_Dir_Entry) -> (Value_Digest, Hash_Fail) {
  name := sha256_text(entry.name)

  switch entry.kind {
  case .Regular:
    // no_follow throughout: the listing already decided this is a regular
    // file rather than a link, and opening it must not be able to disagree.
    fd, oerr := fs_open_read_at(dir, entry.name, true)
    if oerr != .None {
      return {}, fail_detail(.Directory_Read, fmt.tprintf("could not open %s while hashing a directory (%v)", entry.name, oerr))
    }
    content, rerr := fs_read_all(fd)
    fs_close(fd)
    if rerr != .None {
      return {}, fail_detail(.Directory_Read, fmt.tprintf("could not read %s while hashing a directory (%v)", entry.name, rerr))
    }
    defer delete(content)

    // Name and content, and nothing else - see the note on permission bits
    // above. entry.is_executable is deliberately not read here.
    payload: [2 * DIGEST_SIZE]u8
    ch := sha256_of(content)
    copy(payload[0:], name[:])
    copy(payload[DIGEST_SIZE:], ch[:])
    return sha256_tagged(TAG_DIR_ENTRY_FILE, payload[:]), HASH_OK

  case .Directory:
    child, oerr := fs_open_dir_at(dir, entry.name, true)
    if oerr != .None {
      return {}, fail_detail(.Directory_Read, fmt.tprintf("could not open %s while hashing a directory (%v)", entry.name, oerr))
    }
    cd, f := directory_digest_at(child)
    fs_close(child)
    if f.kind != .None do return {}, f

    payload: [2 * DIGEST_SIZE]u8
    copy(payload[0:], name[:])
    copy(payload[DIGEST_SIZE:], cd[:])
    return sha256_tagged(TAG_DIR_ENTRY_DIR, payload[:]), HASH_OK

  case .Symlink:
    target, rerr := fs_readlink_at(dir, entry.name)
    if rerr != .None {
      return {}, fail_detail(.Directory_Read, fmt.tprintf("could not read the link %s while hashing a directory (%v)", entry.name, rerr))
    }
    defer delete(target)

    payload: [2 * DIGEST_SIZE]u8
    td := sha256_text(target)
    copy(payload[0:], name[:])
    copy(payload[DIGEST_SIZE:], td[:])
    return sha256_tagged(TAG_DIR_ENTRY_LINK, payload[:]), HASH_OK

  case .Other:
    // §3 encodes three shapes, and this is none of them. Refused rather than
    // skipped: a digest that quietly ignored part of a tree would claim two
    // different trees were the same value.
    return {}, fail_detail(
      .Unhashable_Entry,
      fmt.tprintf("%s is neither a file, a directory, nor a symlink, and SPEC.md §3 gives no hash for one", entry.name),
    )
  }
  return {}, fail_kind(.Directory_Read)
}

// ---- what the evaluator calls ------------------------------------------------

// §15: the digest, base64-encoded as Utf8. Standard alphabet with padding -
// the form README.md's worked example writes a package hash in, and what
// `sha256sum ... | xxd -r -p | base64` prints. (ctx.cache's entry names use
// the URL alphabet instead, because those become filenames; see builtins_fs.odin.)
value_digest_base64 :: proc(v: Value, interp: ^Interpreter = nil, allocator := context.allocator) -> (string, Hash_Fail) {
  d, f := value_digest(v, interp)
  if f.kind != .None do return "", f
  encoded, _ := base64.encode(d[:], base64.ENC_TABLE, allocator)
  return encoded, HASH_OK
}

// Whether two values hash alike. Used for §3's File identity, where equality
// *is* the content hash - two Files with the same bytes are the same value
// however they were reached.
//
// No interpreter, on purpose: this is reached from table_find, which is the
// hot path of every field access and has no business opening files. A
// directory File whose digest has not been read yet therefore compares as
// "not equal to anything but itself" here, and the evaluator warms it first -
// see hash_materialize below.
values_hash_equal :: proc(a: Value, b: Value) -> bool {
  da, af := value_digest(a)
  if af.kind != .None do return false
  db, bf := value_digest(b)
  if bf.kind != .None do return false
  return da == db
}

// Read the entries of every directory File reachable from `v`, so that a
// later comparison - which cannot do I/O - finds the digests already there.
//
// This is what makes "the first read is the read" observable at the right
// moment. Comparing a directory File means comparing its contents (§3), so
// the comparison *is* a read, and a read needs `io` (§9); but the comparison
// itself happens deep inside values_equal with no context to ask. So the
// evaluator warms the operands here, where it still has one, and fails
// honestly if the permission is missing rather than quietly answering "not
// equal" - which is what an un-warmed comparison would otherwise say.
//
// Cheap for everything else: a value holding no File and no Table returns at
// the first switch, and one that has already been hashed re-walks a value it
// has, without touching the disk.
hash_materialize :: proc(interp: ^Interpreter, v: Value) -> Hash_Fail {
  // Every `==` in every program comes through here, and almost none of them
  // involve a File. Nothing but the three kinds that can hold one is worth
  // allocating a visited set for.
  #partial switch av in v {
  case ^File_Value:
    if av.kind != .Directory || av.dir_digest_known do return HASH_OK
  case ^Table_Value, ^Function_Value, ^Forward_Ref_Value:
  case:
    return HASH_OK
  }
  seen := make([dynamic]rawptr, 0, 8, context.temp_allocator)
  return materialize_walk(interp, v, &seen)
}

@(private = "file")
materialize_walk :: proc(interp: ^Interpreter, v: Value, seen: ^[dynamic]rawptr) -> Hash_Fail {
  resolved, rok := resolve_forward(v)
  if !rok do return HASH_OK // mid-construction; nothing a program can compare yet

  #partial switch av in resolved {
  case ^File_Value:
    if av.kind != .Directory || av.dir_digest_known do return HASH_OK
    _, f := file_directory_digest(av, interp)
    return f

  case ^Table_Value:
    for s in seen^ do if s == rawptr(av) do return HASH_OK
    append(seen, rawptr(av))
    for entry in av.entries {
      if f := materialize_walk(interp, entry.key, seen); f.kind != .None do return f
      if f := materialize_walk(interp, entry.value, seen); f.kind != .None do return f
    }

  case ^Function_Value:
    // A closure holds its captures, and one of them can be a directory. The
    // captured values are what function_digest mixes in, so they are exactly
    // what has to be warm before a comparison reaches for a digest.
    for s in seen^ do if s == rawptr(av) do return HASH_OK
    append(seen, rawptr(av))
    if av.native != nil do return materialize_walk(interp, av.native_closure, seen)
    for captured in function_captures(interp, av) {
      if f := materialize_walk(interp, captured.value, seen); f.kind != .None do return f
    }
  }
  return HASH_OK
}
