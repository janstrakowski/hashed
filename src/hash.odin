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
@(private = "file")
TAG_NOTHING :: 0x00
@(private = "file")
TAG_BOOLEAN :: 0x01
@(private = "file")
TAG_INTEGER :: 0x02
@(private = "file")
TAG_FLOAT :: 0x03
@(private = "file")
TAG_UTF8 :: 0x04
@(private = "file")
TAG_BYTES :: 0x05
@(private = "file")
TAG_TABLE :: 0x07

// Byte-lexicographic order on digests. Written as an explicit loop rather than
// slice.cmp because a `proc` parameter isn't addressable, so it can't be sliced.
@(private = "file")
digest_less :: proc(a, b: Value_Digest) -> bool {
  for i in 0 ..< DIGEST_SIZE {
    if a[i] != b[i] do return a[i] < b[i]
  }
  return false
}

@(private = "file")
sha256_of :: proc(data: []u8) -> Value_Digest {
  digest: Value_Digest
  hash.hash_bytes_to_buffer(.SHA256, data, digest[:])
  return digest
}

@(private = "file")
sha256_tagged :: proc(tag: u8, payload: []u8) -> Value_Digest {
  buf := make([]u8, 1 + len(payload), context.temp_allocator)
  buf[0] = tag
  copy(buf[1:], payload)
  return sha256_of(buf)
}

// Why a value has no digest, so the caller can say which value and why rather
// than emitting one "not hashable" for every case.
Hash_Error :: enum {
  None,
  Directory_File, // §3's directory hash needs an executable bit WASI cannot report
  Function,       // §15 needs it for `cached`, but never specifies the encoding
  Cache,          // §9's ctx.cache is write-only and has no identity to hash
  Async,          // an un-awaited handle - callers await before hashing
}

hash_error_message :: proc(e: Hash_Error) -> string {
  switch e {
  case .None:
    return ""
  case .Directory_File:
    return "a directory File has no hash yet (see LANGUAGE.md on what isn't built yet)"
  case .Function:
    return "a Function has no hash yet (see LANGUAGE.md on what isn't built yet)"
  case .Cache:
    return "ctx.cache has no hash - it is write-only and has no identity (SPEC.md §9)"
  case .Async:
    return "an un-awaited async handle has no hash"
  }
  return ""
}

// The digest of a value, per the encoding described at the top of this file.
// Fails (rather than inventing a digest) for the kinds §3/§15 leave open -
// see Hash_Error.
value_digest :: proc(v: Value) -> (Value_Digest, Hash_Error) {
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
    // untagged, so it matches what sha256sum reports for the same bytes.
    if av.kind == .Directory do return {}, .Directory_File
    return sha256_of(av.content), .None

  case ^Table_Value:
    // §5/§6: a Table's hash is key-sorted, so it does not depend on the order
    // the entries were written in - which is exactly the equality values_equal
    // already implements (it matches entries by key, ignoring position).
    // Sorting by key digest gives a deterministic order without needing §6's
    // cross-type value ordering, which isn't built.
    pairs := make([][2]Value_Digest, len(av.entries), context.temp_allocator)
    for entry, i in av.entries {
      kd, kerr := value_digest(entry.key)
      if kerr != .None do return {}, kerr
      vd, verr := value_digest(entry.value)
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
    return {}, .Function

  case ^Cache_Value:
    return {}, .Cache

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
