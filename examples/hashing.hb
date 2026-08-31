// `sha256` (SPEC.md §15), and the value identity underneath it (§6). It takes
// one trailing expression, like `func` or `async`, and returns the digest
// base64-encoded as `Utf8`.
//
// Two properties are worth more than the digests themselves. A regular
// `File`'s hash is the hash of its content bytes and nothing else (§3), so
// `sha256 loadfile "optiona.txt"` is exactly what `sha256sum` reports for
// that file - a digest you can check against the one upstream published. And
// a `Table`'s hash is computed over its entries sorted by key, so it does not
// depend on the order they were written in, which is the same rule that makes
// two such tables compare equal.
//
// That identity is why the two `loadfile`s below are one value: a `File` is
// its content, not the path it was reached by.
//
// The last three entries are the kinds that have no obvious "content" to hash
// and get one anyway, which is what `cached` (§15) is built on:
//
//   - A **function** hashes as its code plus everything it captures. The code
//     is hashed structurally, so whitespace and comments are not part of it -
//     but the values of the names it uses are, which is exactly what stops
//     `cached` handing one argument's answer to another.
//   - A **directory** hashes over its entries: each name, each file's content,
//     each subdirectory's own hash, each symlink's target string unresolved.
//     No permission bits, on any target (§3) - so a tree hashes the same
//     wherever it was checked out.
//
// Evaluates to
// { text: "Ar9oHTBiuRDqs+ZdbYD2daaU7RcvIDTJNB3UICNP92A=",
//   file: "ZT6vBQgoXEojRYd890EDlZWhUF/uGfXa+C9BNGBykI0=",
//   key_order_is_irrelevant: true, same_content_same_file: true,
//   integer_is_not_float: false, layout_is_not_part_of_a_function: true,
//   captured_values_are: false, directory_is_not_a_file: false }.
{
  .text = sha256 "hello",
  .file = sha256 loadfile "optiona.txt",
  .key_order_is_irrelevant = (sha256 { .a = 1, .b = 2 }) == (sha256 { .b = 2, .a = 1 }),
  .same_content_same_file = (loadfile "optiona.txt") == (loadfile "optiona.txt"),
  .integer_is_not_float = (sha256 5) == (sha256 5.0),

  // Same function, written two ways.
  .layout_is_not_part_of_a_function = (sha256 func (1 + 2)) == (sha256 func ( 1 /* two */ + 2 )),
  // Same code, two different captured values - so two different functions.
  .captured_values_are = (let x 1; sha256 func (x + 1)) == (let x 2; sha256 func (x + 1)),
  // A directory is its own kind of value, not its contents run together.
  .directory_is_not_a_file = (sha256 loadfile ".") == (sha256 loadfile "optiona.txt"),
}
