// Cyclic data (SPEC.md §10). Friendship is mutual, so a social graph has to
// close: Alice's friends hold Bob, and Bob's hold Alice. `let rec` builds the
// Table before its entries run, so an entry can name the Table it is part of;
// entries are then evaluated on demand rather than in source order, so
// reaching `people.bob` while `.alice` is still being built simply evaluates
// `.bob` there and then. Only the reference that closes the loop - `.bob`
// reaching back into `.alice`, which is still in progress - is left to be
// filled in when `.alice` finishes.
//
// `.reordered` shows the same machinery with no cycle in it at all: `.a` is
// written first but needs `.b`, and demand alone sorts that out.
//
// `.same_shape` compares two rings built by separate bindings that share no
// entry between them. Equality is about content (§6), so walking one against
// the other says they are the same value - which needs a walk that assumes a
// pair equal on first meeting it, since a plain structural comparison would
// follow the loop forever.
//
// Evaluates to { round_trip: "Alice", mutual: true, second_hop: "Carol",
// reordered: 3, same_shape: true }.
let rec people {
  .alice = { .name = "Alice", .friends = { people.bob, people.carol } },
  .bob   = { .name = "Bob",   .friends = { people.alice } },
  .carol = { .name = "Carol", .friends = { people.alice, people.bob } },
};
let rec reordered { .a = reordered.b + 1, .b = 2 };
let rec ring { .x = { .tag = "x", .next = ring.y }, .y = { .tag = "y", .next = ring.x } };
let rec other { .x = { .tag = "x", .next = other.y }, .y = { .tag = "y", .next = other.x } };
{
  .round_trip = people.alice.friends[1].friends[1].name,
  .mutual = people.alice.friends[1].friends[1] == people.alice,
  .second_hop = people.alice.friends[2].name,
  .reordered = reordered.a,
  .same_shape = ring.x == other.x,
}
