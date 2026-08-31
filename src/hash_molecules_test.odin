// Tests run natively, never in a WASI build - see eval_test.odin.
#+build linux, windows
package hashedbuild

import "core:strings"
import "core:testing"

// Cyclic hashing (hash_cyclic.odin), exercised on the recursive structure it
// was actually designed for rather than on the two-node toys in
// rec_build_test.odin: molecules.
//
// A ring of atoms is a cycle in the literal sense - benzene is six carbons
// each bonded to the next until the sixth closes back onto the first - so
// `let rec` builds one directly, and hashing one is exactly the problem the
// canonical form solves. The molecules below range from a perfectly symmetric
// ring (every atom interchangeable, one bisimulation class) through
// substituted rings that break that symmetry, to a fused bicyclic where two
// cycles interlock inside a single strongly connected component. Between them
// they cover the refinement machinery far harder than a self-referential
// two-entry Table does.
//
// **The model.** An atom is a Table: its element, how many hydrogens hang off
// it, and `.ring`, the bond to the next atom around the ring. `.substituent`
// hangs a group off a ring atom, `.fused` is a cross-bond closing a second
// ring. Bonds are therefore *directed*, and that is not a stylistic choice: a
// Table's keys have to be hashable before its entries can be ordered, so a
// cyclic value cannot be a key (hash_cyclic.odin), which rules out the
// unordered set of neighbours a chemist would draw. Two consequences are
// tested below rather than glossed over - rotating the numbering is invisible
// (which is the point), but *reflecting* it is not.

@(private = "file")
eval_molecule :: proc(t: ^testing.T, parts: ..string) -> Value {
  src := strings.concatenate(parts)
  defer delete(src)
  ast := parse(source_t{name = "test", n_bytes = u64(len(src)), data = raw_data(src)}, ast_t{})
  interp := Interpreter{ast = &ast, src = src}
  val, ok := eval(&interp, ast.root, env_make_child(nil))
  testing.expect(t, ok, interp.error_message)
  return val
}

// The digest of whatever `expr` selects, as the language itself computes it.
@(private = "file")
digest :: proc(t: ^testing.T, defs: string, expr: string) -> string {
  val := eval_molecule(t, defs, "sha256 ", expr)
  s, is_str := val.(string)
  testing.expect(t, is_str, "expected a Utf8 digest")
  return s
}

@(private = "file")
truth :: proc(t: ^testing.T, defs: string, expr: string) -> bool {
  val := eval_molecule(t, defs, expr)
  b, is_bool := val.(bool)
  testing.expect(t, is_bool, "expected a Boolean")
  return b
}

// ---- the molecules -------------------------------------------------------------

// Benzene: six aromatic CH units in a ring. Every carbon is like every other,
// so the whole ring is one bisimulation class.
@(private = "file")
BENZENE :: `let rec benzene {
  .c1 = { .element = "C", .h = 1, .bond = "aromatic", .ring = benzene.c2 },
  .c2 = { .element = "C", .h = 1, .bond = "aromatic", .ring = benzene.c3 },
  .c3 = { .element = "C", .h = 1, .bond = "aromatic", .ring = benzene.c4 },
  .c4 = { .element = "C", .h = 1, .bond = "aromatic", .ring = benzene.c5 },
  .c5 = { .element = "C", .h = 1, .bond = "aromatic", .ring = benzene.c6 },
  .c6 = { .element = "C", .h = 1, .bond = "aromatic", .ring = benzene.c1 },
};`

// Cyclohexane: the same six-carbon ring, saturated - two hydrogens per carbon
// and single bonds throughout.
@(private = "file")
CYCLOHEXANE :: `let rec cyclohexane {
  .c1 = { .element = "C", .h = 2, .bond = "single", .ring = cyclohexane.c2 },
  .c2 = { .element = "C", .h = 2, .bond = "single", .ring = cyclohexane.c3 },
  .c3 = { .element = "C", .h = 2, .bond = "single", .ring = cyclohexane.c4 },
  .c4 = { .element = "C", .h = 2, .bond = "single", .ring = cyclohexane.c5 },
  .c5 = { .element = "C", .h = 2, .bond = "single", .ring = cyclohexane.c6 },
  .c6 = { .element = "C", .h = 2, .bond = "single", .ring = cyclohexane.c1 },
};`

// The Kekule drawing of benzene: alternating double and single bonds rather
// than six equivalent aromatic ones. Same atoms, different bonds.
@(private = "file")
KEKULE :: `let rec kekule {
  .c1 = { .element = "C", .h = 1, .bond = "double", .ring = kekule.c2 },
  .c2 = { .element = "C", .h = 1, .bond = "single", .ring = kekule.c3 },
  .c3 = { .element = "C", .h = 1, .bond = "double", .ring = kekule.c4 },
  .c4 = { .element = "C", .h = 1, .bond = "single", .ring = kekule.c5 },
  .c5 = { .element = "C", .h = 1, .bond = "double", .ring = kekule.c6 },
  .c6 = { .element = "C", .h = 1, .bond = "single", .ring = kekule.c1 },
};`

// Two smaller rings built from exactly the same repeating unit as the two
// above - three aromatic CH, and four carbons alternating double/single.
@(private = "file")
SMALL_RINGS :: `let rec cyclopropenyl {
  .c1 = { .element = "C", .h = 1, .bond = "aromatic", .ring = cyclopropenyl.c2 },
  .c2 = { .element = "C", .h = 1, .bond = "aromatic", .ring = cyclopropenyl.c3 },
  .c3 = { .element = "C", .h = 1, .bond = "aromatic", .ring = cyclopropenyl.c1 },
};
let rec cyclobutadiene {
  .c1 = { .element = "C", .h = 1, .bond = "double", .ring = cyclobutadiene.c2 },
  .c2 = { .element = "C", .h = 1, .bond = "single", .ring = cyclobutadiene.c3 },
  .c3 = { .element = "C", .h = 1, .bond = "double", .ring = cyclobutadiene.c4 },
  .c4 = { .element = "C", .h = 1, .bond = "single", .ring = cyclobutadiene.c1 },
};`

// Toluene, and the same substitution on a five-membered ring.
@(private = "file")
TOLUENE :: `let methyl { .element = "C", .h = 3 };
let rec toluene {
  .c1 = { .element = "C", .h = 0, .substituent = methyl, .ring = toluene.c2 },
  .c2 = { .element = "C", .h = 1, .ring = toluene.c3 },
  .c3 = { .element = "C", .h = 1, .ring = toluene.c4 },
  .c4 = { .element = "C", .h = 1, .ring = toluene.c5 },
  .c5 = { .element = "C", .h = 1, .ring = toluene.c6 },
  .c6 = { .element = "C", .h = 1, .ring = toluene.c1 },
};
let rec methylcyclopentadienyl {
  .c1 = { .element = "C", .h = 0, .substituent = methyl, .ring = methylcyclopentadienyl.c2 },
  .c2 = { .element = "C", .h = 1, .ring = methylcyclopentadienyl.c3 },
  .c3 = { .element = "C", .h = 1, .ring = methylcyclopentadienyl.c4 },
  .c4 = { .element = "C", .h = 1, .ring = methylcyclopentadienyl.c5 },
  .c5 = { .element = "C", .h = 1, .ring = methylcyclopentadienyl.c1 },
};`

// The three xylenes: C8H10 each, two methyls 1,2- / 1,3- / 1,4- around the
// ring. Same atoms, three different molecules.
@(private = "file")
XYLENES :: `let me { .element = "C", .h = 3 };
let rec ortho {
  .c1 = { .element = "C", .h = 0, .substituent = me, .ring = ortho.c2 },
  .c2 = { .element = "C", .h = 0, .substituent = me, .ring = ortho.c3 },
  .c3 = { .element = "C", .h = 1, .ring = ortho.c4 },
  .c4 = { .element = "C", .h = 1, .ring = ortho.c5 },
  .c5 = { .element = "C", .h = 1, .ring = ortho.c6 },
  .c6 = { .element = "C", .h = 1, .ring = ortho.c1 },
};
let rec meta {
  .c1 = { .element = "C", .h = 0, .substituent = me, .ring = meta.c2 },
  .c2 = { .element = "C", .h = 1, .ring = meta.c3 },
  .c3 = { .element = "C", .h = 0, .substituent = me, .ring = meta.c4 },
  .c4 = { .element = "C", .h = 1, .ring = meta.c5 },
  .c5 = { .element = "C", .h = 1, .ring = meta.c6 },
  .c6 = { .element = "C", .h = 1, .ring = meta.c1 },
};
let rec para {
  .c1 = { .element = "C", .h = 0, .substituent = me, .ring = para.c2 },
  .c2 = { .element = "C", .h = 1, .ring = para.c3 },
  .c3 = { .element = "C", .h = 1, .ring = para.c4 },
  .c4 = { .element = "C", .h = 0, .substituent = me, .ring = para.c5 },
  .c5 = { .element = "C", .h = 1, .ring = para.c6 },
  .c6 = { .element = "C", .h = 1, .ring = para.c1 },
};`

// Naphthalene and azulene: both C10H8, both a ten-carbon perimeter closed by
// one cross-bond. Only the chord's position differs - naphthalene splits the
// perimeter into two six-rings, azulene into a five-ring fused to a seven.
// Two interlocking cycles in one strongly connected component, which is the
// hardest shape in this file.
@(private = "file")
FUSED :: `let rec naphthalene {
  .c1  = { .element = "C", .h = 1, .ring = naphthalene.c2 },
  .c2  = { .element = "C", .h = 1, .ring = naphthalene.c3 },
  .c3  = { .element = "C", .h = 1, .ring = naphthalene.c4 },
  .c4  = { .element = "C", .h = 1, .ring = naphthalene.c4a },
  .c4a = { .element = "C", .h = 0, .ring = naphthalene.c5, .fused = naphthalene.c8a },
  .c5  = { .element = "C", .h = 1, .ring = naphthalene.c6 },
  .c6  = { .element = "C", .h = 1, .ring = naphthalene.c7 },
  .c7  = { .element = "C", .h = 1, .ring = naphthalene.c8 },
  .c8  = { .element = "C", .h = 1, .ring = naphthalene.c8a },
  .c8a = { .element = "C", .h = 0, .ring = naphthalene.c1, .fused = naphthalene.c4a },
};
let rec azulene {
  .c1  = { .element = "C", .h = 1, .ring = azulene.c2 },
  .c2  = { .element = "C", .h = 1, .ring = azulene.c3 },
  .c3  = { .element = "C", .h = 1, .ring = azulene.c3a },
  .c3a = { .element = "C", .h = 0, .ring = azulene.c4, .fused = azulene.c8a },
  .c4  = { .element = "C", .h = 1, .ring = azulene.c5 },
  .c5  = { .element = "C", .h = 1, .ring = azulene.c6 },
  .c6  = { .element = "C", .h = 1, .ring = azulene.c7 },
  .c7  = { .element = "C", .h = 1, .ring = azulene.c8 },
  .c8  = { .element = "C", .h = 1, .ring = azulene.c8a },
  .c8a = { .element = "C", .h = 0, .ring = azulene.c1, .fused = azulene.c3a },
};`

// ---- 1. benzene: the perfectly symmetric ring ----------------------------------

@(test)
test_benzene_every_carbon_is_the_same_carbon :: proc(t: ^testing.T) {
  // Six atoms, one bisimulation class. This is entry-point independence at its
  // starkest: which carbon you name is not part of the answer, so all six
  // digests coincide - and so does the digest of the carbon you arrive at
  // after walking the ring any number of times.
  from_c1 := digest(t, BENZENE, "benzene.c1")
  for start in ([]string{"benzene.c2", "benzene.c3", "benzene.c4", "benzene.c5", "benzene.c6"}) {
    testing.expect_value(t, digest(t, BENZENE, start), from_c1)
  }
  testing.expect_value(t, digest(t, BENZENE, "benzene.c1.ring.ring.ring"), from_c1)
  testing.expect_value(t, digest(t, BENZENE, "benzene.c1.ring.ring.ring.ring.ring.ring"), from_c1)

  // The ring is genuinely traversable, not just hashable.
  testing.expect(t, truth(t, BENZENE, `benzene.c1.ring.ring.ring.ring.ring.ring.element == "C"`))
}

// ---- 2. the same skeleton, different chemistry ---------------------------------

@(test)
test_the_ring_skeleton_alone_is_not_the_molecule :: proc(t: ^testing.T) {
  // Three six-membered carbon rings that differ only in what hangs off each
  // carbon and how the bonds are drawn. If the digest saw only the cycle's
  // shape these would collide; it sees the atoms too, so they do not.
  aromatic := digest(t, BENZENE, "benzene.c1")
  saturated := digest(t, CYCLOHEXANE, "cyclohexane.c1")
  alternating := digest(t, KEKULE, "kekule.c1")

  testing.expect(t, aromatic != saturated, "benzene is not cyclohexane")
  testing.expect(t, aromatic != alternating, "aromatic bonds are not alternating ones")
  testing.expect(t, saturated != alternating, "cyclohexane is not the Kekule drawing")
}

// ---- 3. toluene: one substituent breaks the symmetry ---------------------------

@(test)
test_a_substituent_splits_the_ring_into_positions :: proc(t: ^testing.T) {
  // Benzene's six carbons were one class. Hang a methyl off one of them and
  // every carbon becomes distinguishable by how far it sits from the methyl,
  // so the refinement has to find six classes instead of one.
  positions := []string {
    "toluene.c1", "toluene.c2", "toluene.c3", "toluene.c4", "toluene.c5", "toluene.c6",
  }
  seen := make([dynamic]string, 0, len(positions), context.temp_allocator)
  for p in positions {
    d := digest(t, TOLUENE, p)
    for previous in seen do testing.expect(t, previous != d, "each ring position is its own class")
    append(&seen, d)
  }

  // And walking the whole way round still lands on the same carbon.
  testing.expect_value(
    t,
    digest(t, TOLUENE, "toluene.c1.ring.ring.ring.ring.ring.ring"),
    digest(t, TOLUENE, "toluene.c1"),
  )
}

@(test)
test_a_substituent_makes_the_ring_size_visible :: proc(t: ^testing.T) {
  // The counterpart to test_a_symmetric_ring_cannot_count_itself below. Once
  // one atom stands out, distance from it distinguishes every other atom, and
  // a five-ring simply has fewer distances than a six-ring - so the two hash
  // apart even though their repeating unit is identical.
  testing.expect(
    t,
    digest(t, TOLUENE, "toluene.c1") != digest(t, TOLUENE, "methylcyclopentadienyl.c1"),
    "a substituted six-ring is not a substituted five-ring",
  )
}

// ---- 4. the xylenes: positional isomers ----------------------------------------

@(test)
test_the_three_xylenes_are_three_values :: proc(t: ^testing.T) {
  // Same formula, same atoms, methyls in three different arrangements. This is
  // the "canonical is not constant" case with real stakes: a build keyed on
  // these digests would confuse three different compounds if they collided.
  o := digest(t, XYLENES, "ortho.c1")
  m := digest(t, XYLENES, "meta.c1")
  p := digest(t, XYLENES, "para.c1")

  testing.expect(t, o != m, "ortho is not meta")
  testing.expect(t, o != p, "ortho is not para")
  testing.expect(t, m != p, "meta is not para")
}

@(test)
test_para_xylene_finds_its_own_symmetry :: proc(t: ^testing.T) {
  // p-xylene's two methylated carbons sit directly across the ring, so
  // rotating the numbering by three maps one onto the other. That is a
  // rotation, which the canonical form does see - and the two hash alike.
  testing.expect_value(t, digest(t, XYLENES, "para.c4"), digest(t, XYLENES, "para.c1"))
  // Its unsubstituted carbons pair up the same way.
  testing.expect_value(t, digest(t, XYLENES, "para.c5"), digest(t, XYLENES, "para.c2"))
}

// ---- 5. naphthalene and azulene: two cycles in one component -------------------

@(test)
test_a_fused_bicyclic_hashes_and_finds_its_rotation :: proc(t: ^testing.T) {
  // Ten atoms, eleven bonds, two rings sharing an edge: one strongly connected
  // component that no single walk can linearise. Naphthalene has a two-fold
  // rotation, so the carbons pair up across it - the bridgeheads with each
  // other, and each perimeter carbon with the one five positions away.
  testing.expect_value(
    t,
    digest(t, FUSED, "naphthalene.c8a"),
    digest(t, FUSED, "naphthalene.c4a"),
  )
  pairs := [][2]string {
    {"naphthalene.c1", "naphthalene.c5"},
    {"naphthalene.c2", "naphthalene.c6"},
    {"naphthalene.c3", "naphthalene.c7"},
    {"naphthalene.c4", "naphthalene.c8"},
  }
  for pair in pairs do testing.expect_value(t, digest(t, FUSED, pair[0]), digest(t, FUSED, pair[1]))

  // Neighbours are not interchangeable, though - the refinement stops in the
  // right place rather than collapsing everything.
  testing.expect(
    t,
    digest(t, FUSED, "naphthalene.c1") != digest(t, FUSED, "naphthalene.c2"),
    "adjacent carbons are not equivalent",
  )
  testing.expect(
    t,
    digest(t, FUSED, "naphthalene.c1") != digest(t, FUSED, "naphthalene.c4a"),
    "a bridgehead is not a perimeter carbon",
  )
}

@(test)
test_azulene_is_not_naphthalene :: proc(t: ^testing.T) {
  // Both are C10H8, both a ten-carbon perimeter plus one chord. Only where the
  // chord lands differs, and that is enough.
  testing.expect(
    t,
    digest(t, FUSED, "azulene.c1") != digest(t, FUSED, "naphthalene.c1"),
    "5+7 fusion is not 6+6 fusion",
  )
  // Azulene's fusion is lopsided, so unlike naphthalene's its two bridgeheads
  // are *not* interchangeable: one carries a five-ring on the short side.
  testing.expect(
    t,
    digest(t, FUSED, "azulene.c3a") != digest(t, FUSED, "azulene.c8a"),
    "an asymmetric fusion has no rotation to find",
  )
}

// ---- what this model cannot see ------------------------------------------------

@(test)
test_a_symmetric_ring_cannot_count_itself :: proc(t: ^testing.T) {
  // Benzene and the cyclopropenyl cation are built from the same repeating
  // unit - an aromatic CH bonded to the next - and differ only in how many
  // times it repeats. Under bisimulation that difference does not exist:
  // unrolling either gives the same infinite chain, so they are the same
  // value and hash alike. Kekule benzene and cyclobutadiene collide for the
  // same reason at period two.
  //
  // This is not the hash disagreeing with equality - the second half of each
  // pair below is the point. `values_equal` calls them equal too, and a digest
  // that separated them would be the bug. The loss is in the model: a ring
  // with nothing to distinguish any atom carries no record of its own length,
  // and the containers available cannot express an unordered bond set that
  // would (see this file's header). Every substituted ring above recovers it.
  testing.expect_value(
    t,
    digest(t, strings.concatenate({BENZENE, SMALL_RINGS}, context.temp_allocator), "cyclopropenyl.c1"),
    digest(t, strings.concatenate({BENZENE, SMALL_RINGS}, context.temp_allocator), "benzene.c1"),
  )
  testing.expect(t, truth(
    t,
    strings.concatenate({BENZENE, SMALL_RINGS}, context.temp_allocator),
    "benzene.c1 == cyclopropenyl.c1",
  ), "the hash agrees with equality here, which is what makes it correct")

  testing.expect_value(
    t,
    digest(t, strings.concatenate({KEKULE, SMALL_RINGS}, context.temp_allocator), "cyclobutadiene.c1"),
    digest(t, strings.concatenate({KEKULE, SMALL_RINGS}, context.temp_allocator), "kekule.c1"),
  )
}

@(test)
test_reflection_is_invisible_but_rotation_is_not :: proc(t: ^testing.T) {
  // m-xylene's two methylated carbons are equivalent to a chemist: reflect the
  // ring through them and the molecule is unchanged. The digest disagrees, and
  // the reason is structural rather than incidental. Bisimulation matches
  // Table entries **by key**, and a reflection maps one atom's `.ring` onto
  // another's *incoming* bond - a different key, or in this model no key at
  // all. No amount of listing more neighbours fixes it; naming both directions
  // would just give reflection two keys to swap, which matching by key can
  // never do.
  //
  // Rotation, by contrast, maps `.ring` onto `.ring`, which is exactly why
  // para above works and why every benzene carbon agrees. So: this model
  // hashes an *oriented* drawing of a molecule. That is a property of the
  // model, and pinned here so a future change to the encoding has to argue
  // with it rather than silently alter it.
  testing.expect(
    t,
    digest(t, XYLENES, "meta.c1") != digest(t, XYLENES, "meta.c3"),
    "reflection is not visible to a walk that only goes one way round",
  )
}
