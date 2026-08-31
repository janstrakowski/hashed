package hashedbuild

import "core:crypto/hash"
import "core:encoding/base64"
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

DIGEST_SIZE :: 32

Value_Digest :: [DIGEST_SIZE]u8

// Tag bytes. Never renumber these: a digest that changes meaning silently
// invalidates every cache entry and every recorded hash a user has written
// down. Appending a new tag for a new type is fine.
TAG_NOTHING :: 0x00
TAG_BOOLEAN :: 0x01
TAG_INTEGER :: 0x02
TAG_FLOAT :: 0x03
TAG_UTF8 :: 0x04
TAG_BYTES :: 0x05
TAG_TABLE :: 0x07
// A *directory* File. A regular one stays untagged (below); a directory has
// no sha256sum to agree with, so it is domain-separated like everything else.
TAG_DIRECTORY :: 0x08
// SPEC.md §3's three kinds of directory entry, one tag each - which is what
// keeps a file named "x" from hashing like a symlink named "x" whose target
// happens to be that file's content. See hash_directory.odin.
TAG_DIR_ENTRY_FILE :: 0x09
TAG_DIR_ENTRY_DIR :: 0x0a
TAG_DIR_ENTRY_SYMLINK :: 0x0b
// ctx.cache. It is write-only and content-addressed, with no name, no listing
// and no identity of its own to tell one from another, so every cache hashes
// to this tag over an empty payload. Deliberately *not* its directory path:
// §15's cache key mixes in the whole ctx, and hashing the path there would
// mean a cache directory that gets moved or copied missed on every entry in
// it, because the old path was baked into every key.
TAG_CACHE :: 0x0c
// A Function, and the pieces its encoding is built from - see
// hash_function.odin, which is where all four are actually used.
TAG_FUNCTION :: 0x0d
TAG_NATIVE :: 0x0e
TAG_AST_NODE :: 0x0f
TAG_FREE_NAMES :: 0x10
// What a cached expression can read out of the *dynamic* stacks `#arg`/`#self`
// address (§9) - not part of a closure, and mixed in by `cached` on top of the
// closure digest. See implicit_reach_digest.
TAG_IMPLICIT_REACH :: 0x11

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

sha256_tagged :: proc(tag: u8, payload: []u8) -> Value_Digest {
  buf := make([]u8, 1 + len(payload), context.temp_allocator)
  buf[0] = tag
  copy(buf[1:], payload)
  return sha256_of(buf)
}

// Why a value has no digest, so the caller can say which value and why rather
// than emitting one "not hashable" for every case. Every remaining case is a
// failure to *compute* a digest that exists - as of the `cached` work there is
// no longer a kind of value the encoding simply does not cover.
Hash_Error :: enum {
  None,
  Directory_Read, // §3 hashes a directory over its entries, and reading them failed
  Function_Ast,   // a closure with no syntax tree to encode - see hash_function.odin
  Async,          // an un-awaited handle - callers await before hashing
}

hash_error_message :: proc(e: Hash_Error) -> string {
  switch e {
  case .None:
    return ""
  case .Directory_Read:
    return "a directory File could not be read to hash it (SPEC.md §3 hashes a directory over its entries)"
  case .Function_Ast:
    return "a Function with no syntax tree cannot be hashed"
  case .Async:
    return "an un-awaited async handle has no hash"
  }
  return ""
}

// The digest of a value, per the encoding described at the top of this file.
// Fails (rather than inventing a digest) only where the digest exists but
// could not be computed - see Hash_Error.
//
// `seen` is the closure stack hash_function.odin threads through so that a
// recursive function terminates; every caller outside this file leaves it nil.
value_digest :: proc(v: Value, seen: ^Seen_Stack = nil) -> (Value_Digest, Hash_Error) {
  switch av in v {
  case Nothing_Value:
    return sha256_tagged(TAG_NOTHING, nil), .None

  case bool:
    return sha256_tagged(TAG_BOOLEAN, {1 if av else 0}), .None

  case i64:
    // Little-endian two's complement, fixed 8 bytes - Integer is exactly one
    // width (§3), so there is nothing else to encode.
    buf: [8]u8
    u := transmute(u64)av
    for i in 0 ..< 8 do buf[i] = u8((u >> (8 * uint(i))) & 0xff)
    return sha256_tagged(TAG_INTEGER, buf[:]), .None

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
    return sha256_tagged(TAG_FLOAT, buf[:]), .None

  case string:
    return sha256_tagged(TAG_UTF8, transmute([]u8)av), .None

  case []u8:
    return sha256_tagged(TAG_BYTES, av), .None

  case ^File_Value:
    // §3: "a regular file's hash is just hash(content_bytes)" - deliberately
    // untagged, so it matches what sha256sum reports for the same bytes. A
    // directory is the other half of §3's rule, and reads its whole tree to
    // answer - see hash_directory.odin.
    if av.kind == .Directory do return directory_digest(av.dir_fd)
    return sha256_of(av.content), .None

  case ^Table_Value:
    // §5/§6: a Table's hash is key-sorted, so it does not depend on the order
    // the entries were written in - which is exactly the equality values_equal
    // already implements (it matches entries by key, ignoring position).
    // Sorting by key digest gives a deterministic order without needing §6's
    // cross-type value ordering, which isn't built.
    pairs := make([][2]Value_Digest, len(av.entries), context.temp_allocator)
    for entry, i in av.entries {
      kd, kerr := value_digest(entry.key, seen)
      if kerr != .None do return {}, kerr
      vd, verr := value_digest(entry.value, seen)
      if verr != .None do return {}, verr
      pairs[i] = {kd, vd}
    }
    slice.sort_by(pairs, proc(a, b: [2]Value_Digest) -> bool {
      return digest_less(a[0], b[0])
    })
    buf := make([]u8, len(pairs) * 2 * DIGEST_SIZE, context.temp_allocator)
    for i in 0 ..< len(pairs) {
      copy(buf[i * 2 * DIGEST_SIZE:], pairs[i][0][:])
      copy(buf[(i * 2 + 1) * DIGEST_SIZE:], pairs[i][1][:])
    }
    return sha256_tagged(TAG_TABLE, buf), .None

  case ^Function_Value:
    // §15's cache key is the hash of an expression *as a function*, so this
    // is the case `cached` is built on - see hash_function.odin.
    return function_digest(av, seen)

  case ^Cache_Value:
    return sha256_tagged(TAG_CACHE, nil), .None

  case ^Async_Handle:
    return {}, .Async
  }
  return sha256_tagged(TAG_NOTHING, nil), .None
}

// §15: the digest, base64-encoded as Utf8. Standard alphabet with padding -
// the form README.md's worked example writes a package hash in, and what
// `sha256sum ... | xxd -r -p | base64` prints. (ctx.cache's entry names use
// the URL alphabet instead, because those become filenames; see builtins_fs.odin.)
value_digest_base64 :: proc(v: Value, allocator := context.allocator) -> (string, Hash_Error) {
  d, err := value_digest(v)
  if err != .None do return "", err
  return base64.encode(d[:], base64.ENC_TABLE, allocator), .None
}

// Whether two values hash alike. Used for §3's File identity, where equality
// *is* the content hash - two Files with the same bytes are the same value
// however they were reached.
values_hash_equal :: proc(a: Value, b: Value) -> bool {
  da, aerr := value_digest(a)
  if aerr != .None do return false
  db, berr := value_digest(b)
  if berr != .None do return false
  return da == db
}
