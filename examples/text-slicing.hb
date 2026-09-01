// `textlen` and `textslice` (SPEC.md §16): measuring and cutting `Utf8`.
//
// Both count **codepoints, not bytes**, because the type is Utf8 (§3) - a byte
// index could land inside a multi-byte character and hand back something that
// is not text at all. `.start` is 1-based, matching `[i]`'s element access
// (§5), and asking for anything past the end is a fatal failure rather than a
// silently short answer.
//
// They are deliberately the primitives rather than a set of ready-made
// predicates: `endswith` below is the whole of what a build needs to pick the
// C files out of a directory listing, and it is four lines of ordinary
// HashedBuild. Evaluates to
// { length: 7, bytes_would_say: 5, extension: ".c", stem: "cJSON",
//   is_c: true, is_not_h: false, too_short_is_false: false }.

let endswith (let a;
  let t a.text; let s a.suffix;
  (textlen t) >= (textlen s)
    and (textslice { .text = t, .start = (textlen t) - (textlen s) + 1, .count = textlen s }) == s);

let name "cJSON.c";
{
  .length = textlen name,
  .bytes_would_say = textlen "héllo",   // 5 codepoints, 6 bytes
  .extension = textslice { .text = name, .start = (textlen name) - 1, .count = 2 },
  .stem = textslice { .text = name, .start = 1, .count = (textlen name) - 2 },
  .is_c = endswith { .text = name, .suffix = ".c" },
  .is_not_h = endswith { .text = name, .suffix = ".h" },
  .too_short_is_false = endswith { .text = "c", .suffix = ".c" },
}
