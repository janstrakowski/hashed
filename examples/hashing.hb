// run: hb --dir here=. hashing.hb
//
// `sha256` (SPEC.md §15), and the value identity underneath it (§6). It takes
// one trailing expression, like `func` or `async`, and returns the digest
// base64-encoded as `Utf8`.
//
// Two properties are worth more than the digests themselves. A regular
// `File`'s hash is the hash of its content bytes and nothing else (§3), so
// `sha256 loadfile { .dir = …, .path = "optiona.txt" }` is exactly what
// `sha256sum` reports for
// that file - a digest you can check against the one upstream published. And
// a `Table`'s hash is computed over its entries sorted by key, so it does not
// depend on the order they were written in, which is the same rule that makes
// two such tables compare equal.
//
// That identity is why the two `loadfile`s below are one value: a `File` is
// its content, not the path it was reached by. Evaluates to
// { text: "Ar9oHTBiuRDqs+ZdbYD2daaU7RcvIDTJNB3UICNP92A=",
//   file: "ZT6vBQgoXEojRYd890EDlZWhUF/uGfXa+C9BNGBykI0=",
//   key_order_is_irrelevant: true, same_content_same_file: true,
//   integer_is_not_float: false }.
{
  .text = sha256 "hello",
  .file = sha256 loadfile { .dir = ctx.dirs.here, .path = "optiona.txt" },
  .key_order_is_irrelevant = (sha256 { .a = 1, .b = 2 }) == (sha256 { .b = 2, .a = 1 }),
  .same_content_same_file =
    (loadfile { .dir = ctx.dirs.here, .path = "optiona.txt" })
      == (loadfile { .dir = ctx.dirs.here, .path = "optiona.txt" }),
  .integer_is_not_float = (sha256 5) == (sha256 5.0),
}
