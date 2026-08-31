// Hashing a value that reaches itself (SPEC.md §6/§10). `let rec` can build a
// Table that contains itself (see examples/cyclic-data.hb), and every value is
// hashable - including that one.
//
// It cannot be hashed the way everything else is. An ordinary digest is a fold
// from the leaves upward, and a cycle has no leaves to start from. So a cyclic
// value's digest is instead a canonical form of the cycle itself: the shape is
// reduced to what genuinely differs, and the digest is read off that. The
// point of "canonical" is the two properties below - it does not matter which
// node you started from, and it does not matter how the cycle was written.
//
// That second one is the same rule equality already follows. `g` below is a
// one-node cycle and `h.a` is one node of a two-node cycle, and they are
// *equal*, because unrolling either gives the same infinite tree. A digest
// that disagreed with that would be a language where two equal values have two
// different content addresses.
//
// There are no boolean literals, so "false" is spelled `1 > 2`.
//
// Evaluates to { a_cycle_hashes: true, equal_cycles_hash_alike: true,
//                shape_still_matters: true, either_end_agrees: true }.
let rec g { .n = 1, .next = g };
let rec h { .a = { .n = 1, .next = h.b }, .b = { .n = 1, .next = h.a } };
let rec differs { .n = 2, .next = differs };
{
  // It terminates and produces a digest, which is the first thing to want.
  .a_cycle_hashes = (sha256 g) == (sha256 g),

  // A 1-cycle and a 2-cycle that unroll the same way are one value, and hash
  // as one value.
  .equal_cycles_hash_alike = ((g == h.a) and ((sha256 g) == (sha256 h.a))),

  // Canonical is not constant: cycles that unroll differently still differ.
  .shape_still_matters = ((sha256 g) == (sha256 differs)) == (1 > 2),

  // The same node reached two ways is one digest - the walk's entry point is
  // not part of the answer.
  .either_end_agrees = (sha256 g) == (sha256 g.next.next.next),
}
