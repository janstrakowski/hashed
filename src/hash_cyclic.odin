package hashed

import "core:slice"

// Hashing a value that reaches itself (SPEC.md §10's cyclic `let rec`).
//
// hash.odin's encoding is a Merkle fold: a composite's digest is built from
// its children's. A cycle has no bottom to start that fold from, so this file
// supplies the other half of the answer §6 asks for - "some arbitrary total
// order... such that any value can be compared with any other" - by giving
// each node in a cycle a digest that depends only on *what it is*, never on
// where a walk entered it.
//
// The requirement is sharper than it sounds. `values_equal` (value.odin)
// already compares cyclic values by bisimulation: two separately built cycles
// of the same shape are equal, and a 2-cycle whose halves are identical is
// equal to a 1-cycle, because unrolling them gives the same infinite tree. A
// digest that disagreed with that would break the one property a content-
// addressed language cannot do without - equal values hashing alike. So the
// digest here is not merely deterministic; it is canonical **under
// bisimulation**, which is exactly the equality that already exists.
//
// Three steps:
//
//  1. **Build the graph.** Tables and Functions are the nodes - the only two
//     kinds that hold other values - and everything else is a leaf whose
//     digest the ordinary fold gives. Each node's out-edges carry a *slot* -
//     a Table's key digest, a closure's captured name - and are in the order
//     hash.odin's fold would put them in, which is what lets the two paths
//     encode the same node the same way.
//
//  2. **Fold what can be folded.** Tarjan's algorithm splits the graph into
//     strongly connected components and hands them back successors-first, so
//     every component is reached only once everything it points at has a
//     digest. A component of one node with no self-edge is not a cycle at all,
//     and gets the plain Merkle encoding - byte for byte the one hash.odin
//     computes, which is what keeps `sha256 t` the same answer whether or not
//     some unrelated corner of the value turned out to be cyclic.
//
//  3. **Canonicalise the rest.** Within a genuine component, partition
//     refinement finds the bisimulation classes, and each node's digest is
//     then a canonical encoding of the quotient graph reachable from its own
//     class - classes numbered in the order a deterministic walk from that
//     class first meets them. Two bisimilar nodes reach isomorphic quotients
//     in the same order, so they encode identically; two that are not
//     bisimilar differ in the first round of refinement that told them apart.

// An out-edge. `slot` is what names this child within its parent - a key's
// digest for a Table entry, a name's for a capture - and is part of the
// encoding, not just a sort key. `target` indexes into the node list, or is
// NOT_A_NODE for a child that is an ordinary value.
@(private = "file")
NOT_A_NODE :: -1

@(private = "file")
Graph_Edge :: struct {
  slot:     Value_Digest,
  has_slot: bool, // false for a builtin's carried closure, which has no name
  target:   int,
  leaf:     Value_Digest, // valid when target == NOT_A_NODE
}

@(private = "file")
Graph_Node :: struct {
  ptr:    rawptr,
  tag:    u8,
  // What the node is before its children are looked at: nothing for a Table
  // (its identity is entirely its entries), the body's shape for a closure,
  // the operation's name for a builtin.
  prefix: []u8,
  edges:  []Graph_Edge,
  digest: Value_Digest,
  done:   bool,

  // Tarjan's bookkeeping.
  index:    int,
  lowlink:  int,
  on_stack: bool,
  visited:  bool,
}

@(private = "file")
Graph :: struct {
  interp: ^Interpreter,
  nodes:  [dynamic]Graph_Node,
  by_ptr: map[rawptr]int,
  fail:   Hash_Fail,
}

// The entry point hash.odin falls through to when its fold meets a cycle.
value_digest_cyclic :: proc(v: Value, interp: ^Interpreter) -> (Value_Digest, Hash_Fail) {
  g := Graph {
    interp = interp,
    nodes  = make([dynamic]Graph_Node, 0, 16, context.temp_allocator),
    by_ptr = make(map[rawptr]int, 16, context.temp_allocator),
  }

  root, is_node := graph_add(&g, v)
  if g.fail.kind != .None do return {}, g.fail
  // Not a node, so it holds nothing and cannot have been what was cyclic.
  // Reachable only if a caller asks about a value the fold already answered.
  if !is_node {
    w := Hash_Walk{interp = interp, open = make([dynamic]rawptr, 0, 4, context.temp_allocator)}
    return value_digest_walk(v, &w)
  }

  if f := solve(&g); f.kind != .None do return {}, f
  return g.nodes[root].digest, HASH_OK
}

// ---- building the graph --------------------------------------------------------

// Adds `v` and everything below it, returning its node index. `is_node` is
// false for a value that is not a Table or a Function, which is a leaf: it
// holds no other values, so the ordinary fold answers it outright.
@(private = "file")
graph_add :: proc(g: ^Graph, v: Value) -> (index: int, is_node: bool) {
  resolved, rok := resolve_forward(v)
  if !rok {
    g.fail = Hash_Fail{kind = .Cyclic}
    return NOT_A_NODE, false
  }

  #partial switch av in resolved {
  case ^Table_Value:
    return graph_add_table(g, av), true
  case ^Function_Value:
    return graph_add_function(g, av), true
  }
  return NOT_A_NODE, false
}

// The digest of a value that is not a graph node. Its own fold cannot reach a
// node - only Tables and Functions hold values - so this cannot recurse back
// into the cycle.
@(private = "file")
graph_leaf_digest :: proc(g: ^Graph, v: Value) -> Value_Digest {
  w := Hash_Walk{interp = g.interp, open = make([dynamic]rawptr, 0, 4, context.temp_allocator)}
  d, f := value_digest_walk(v, &w)
  if f.kind != .None && g.fail.kind == .None do g.fail = f
  return d
}

// A child, as an edge: a node reference if it is one, its digest if it is not.
@(private = "file")
graph_edge_to :: proc(g: ^Graph, slot: Value_Digest, has_slot: bool, child: Value) -> Graph_Edge {
  if index, is_node := graph_add(g, child); is_node {
    return Graph_Edge{slot = slot, has_slot = has_slot, target = index}
  }
  return Graph_Edge{slot = slot, has_slot = has_slot, target = NOT_A_NODE, leaf = graph_leaf_digest(g, child)}
}

@(private = "file")
graph_add_table :: proc(g: ^Graph, t: ^Table_Value) -> int {
  if existing, found := g.by_ptr[rawptr(t)]; found do return existing

  index := len(g.nodes)
  g.by_ptr[rawptr(t)] = index
  append(&g.nodes, Graph_Node{ptr = rawptr(t), tag = TAG_TABLE, index = NOT_A_NODE})

  edges := make([dynamic]Graph_Edge, 0, len(t.entries), context.temp_allocator)
  for entry in t.entries {
    // A key goes through the ordinary fold rather than becoming a node of its
    // own, because a key has to have a digest *now*: it is what puts this
    // node's children in an order, and an order is what the whole encoding
    // below rests on. A cyclic key would therefore have nowhere to go - but it
    // is also not a shape a program can build, since making one means
    // inspecting an unresolved forward reference and that fails while the
    // `let rec` is still running (rec_build.odin). If one ever arrived, the
    // fold reports it here instead of being quietly mis-ordered.
    append(&edges, graph_edge_to(g, graph_leaf_digest(g, entry.key), true, entry.value))
  }
  sort_edges(edges[:])
  g.nodes[index].edges = edges[:]
  return index
}

@(private = "file")
graph_add_function :: proc(g: ^Graph, fv: ^Function_Value) -> int {
  if existing, found := g.by_ptr[rawptr(fv)]; found do return existing

  index := len(g.nodes)
  g.by_ptr[rawptr(fv)] = index
  append(&g.nodes, Graph_Node{ptr = rawptr(fv), index = NOT_A_NODE})

  if fv.native != nil {
    name := sha256_text(fv.name)
    prefix := make([]u8, DIGEST_SIZE, context.temp_allocator)
    copy(prefix, name[:])
    edges := make([]Graph_Edge, 1, context.temp_allocator)
    edges[0] = graph_edge_to(g, {}, false, fv.native_closure)
    g.nodes[index].tag = TAG_NATIVE
    g.nodes[index].prefix = prefix
    g.nodes[index].edges = edges
    return index
  }

  if g.interp == nil {
    if g.fail.kind == .None do g.fail = Hash_Fail{kind = .No_Program}
    g.nodes[index].tag = TAG_FUNCTION
    return index
  }

  shape := function_shape_digest(g.interp, fv)
  prefix := make([]u8, DIGEST_SIZE, context.temp_allocator)
  copy(prefix, shape[:])

  // Deliberately NOT sort_edges: function_captures already returns them sorted
  // by name, and that order is part of the encoding hash_function.odin writes.
  // Re-sorting by the name's *digest* would put them in a different order and
  // give the same closure two digests depending on which path reached it.
  captures := function_captures(g.interp, fv)
  edges := make([dynamic]Graph_Edge, 0, len(captures), context.temp_allocator)
  for capture in captures {
    append(&edges, graph_edge_to(g, sha256_text(capture.name), true, capture.value))
  }
  g.nodes[index].tag = TAG_FUNCTION
  g.nodes[index].prefix = prefix
  g.nodes[index].edges = edges[:]
  return index
}

@(private = "file")
sort_edges :: proc(edges: []Graph_Edge) {
  slice.sort_by(edges, proc(a, b: Graph_Edge) -> bool { return digest_less(a.slot, b.slot) })
}

// ---- the Merkle half -----------------------------------------------------------

// Byte for byte what hash.odin's fold produces for the same node. This is not
// a convenience: a value hashed here and the same value hashed there have to
// agree, or a Table's digest would depend on whether something else in the
// value it was reached through happened to be cyclic.
@(private = "file")
merkle_digest :: proc(g: ^Graph, node: ^Graph_Node) -> Value_Digest {
  buf := make([dynamic]u8, 0, len(node.prefix) + len(node.edges) * 2 * DIGEST_SIZE, context.temp_allocator)
  append(&buf, ..node.prefix)
  for edge in node.edges {
    slot := edge.slot
    if edge.has_slot do append(&buf, ..slot[:])
    child := edge.leaf
    if edge.target != NOT_A_NODE do child = g.nodes[edge.target].digest
    append(&buf, ..child[:])
  }
  return sha256_tagged(node.tag, buf[:])
}

// ---- components ----------------------------------------------------------------

@(private = "file")
Tarjan :: struct {
  next:  int,
  stack: [dynamic]int,
}

// Tarjan's algorithm, iterative rather than recursive because the graph is a
// user's data structure and its depth is theirs to choose - the evaluator has
// a depth budget (§12) but a value that is already built does not.
@(private = "file")
solve :: proc(g: ^Graph) -> Hash_Fail {
  if g.fail.kind != .None do return g.fail

  t := Tarjan{stack = make([dynamic]int, 0, len(g.nodes), context.temp_allocator)}
  for i in 0 ..< len(g.nodes) {
    if !g.nodes[i].visited do strongconnect(g, &t, i)
  }
  return g.fail
}

@(private = "file")
Frame :: struct {
  node: int,
  edge: int,
}

@(private = "file")
strongconnect :: proc(g: ^Graph, t: ^Tarjan, start: int) {
  frames := make([dynamic]Frame, 0, 16, context.temp_allocator)
  open_node(g, t, start)
  append(&frames, Frame{node = start})

  for len(frames) > 0 {
    frame := &frames[len(frames) - 1]
    node := &g.nodes[frame.node]

    if frame.edge < len(node.edges) {
      edge := node.edges[frame.edge]
      frame.edge += 1
      if edge.target == NOT_A_NODE do continue

      child := &g.nodes[edge.target]
      if !child.visited {
        open_node(g, t, edge.target)
        append(&frames, Frame{node = edge.target})
      } else if child.on_stack {
        node.lowlink = min(node.lowlink, child.index)
      }
      continue
    }

    // Every edge walked: this node's component is settled if it is the root.
    if node.lowlink == node.index do close_component(g, t, frame.node)
    finished := frame.node
    pop(&frames)
    if len(frames) > 0 {
      parent := &g.nodes[frames[len(frames) - 1].node]
      parent.lowlink = min(parent.lowlink, g.nodes[finished].lowlink)
    }
  }
}

@(private = "file")
open_node :: proc(g: ^Graph, t: ^Tarjan, i: int) {
  node := &g.nodes[i]
  node.visited = true
  node.index = t.next
  node.lowlink = t.next
  t.next += 1
  node.on_stack = true
  append(&t.stack, i)
}

// Pops one component and gives every node in it a digest. Successors are
// already done - that is what makes the Merkle case below possible at all.
@(private = "file")
close_component :: proc(g: ^Graph, t: ^Tarjan, root: int) {
  members := make([dynamic]int, 0, 4, context.temp_allocator)
  for {
    i := pop(&t.stack)
    g.nodes[i].on_stack = false
    append(&members, i)
    if i == root do break
  }

  if len(members) == 1 && !has_self_edge(g, members[0]) {
    node := &g.nodes[members[0]]
    node.digest = merkle_digest(g, node)
    node.done = true
    return
  }
  canonicalise(g, members[:])
}

@(private = "file")
has_self_edge :: proc(g: ^Graph, i: int) -> bool {
  for edge in g.nodes[i].edges do if edge.target == i do return true
  return false
}

// ---- canonical digests for a component -----------------------------------------

// Partition refinement, then one canonical encoding per bisimulation class.
//
// Refinement starts with every node in the component in one class and splits
// on each round: a node's signature is what it is, plus - for each child in
// slot order - either that child's finished digest (it is outside the
// component) or the class its child currently sits in. Two nodes stay together
// only while nothing has told them apart, which is precisely the greatest
// fixed point bisimulation is defined as. n rounds suffice for n nodes: every
// round that changes anything splits at least one class, and there are at most
// n classes.
@(private = "file")
canonicalise :: proc(g: ^Graph, members: []int) {
  class := make(map[int]int, len(members), context.temp_allocator)
  for m in members do class[m] = 0
  class_count := 1

  for _ in 0 ..< len(members) {
    sigs := make([]Value_Digest, len(members), context.temp_allocator)
    for m, i in members do sigs[i] = refine_signature(g, m, class)

    ordered := make([]Value_Digest, len(members), context.temp_allocator)
    copy(ordered, sigs)
    slice.sort_by(ordered, proc(a, b: Value_Digest) -> bool { return digest_less(a, b) })

    // Distinct signatures, in byte order: that ordering is a property of the
    // signatures themselves, so the numbering does not depend on the order
    // the component's members were popped in.
    next_id := 0
    ids := make(map[Value_Digest]int, len(members), context.temp_allocator)
    for sig, i in ordered {
      if i > 0 && ordered[i - 1] == sig do continue
      ids[sig] = next_id
      next_id += 1
    }
    for m, i in members do class[m] = ids[sigs[i]]

    if next_id == class_count do break // nothing split; the partition is stable
    class_count = next_id
  }

  // One encoding per class, shared by every node in it - which is what makes
  // two bisimilar nodes hash alike even when they are different objects.
  encoded := make(map[int]Value_Digest, class_count, context.temp_allocator)
  for m in members {
    c := class[m]
    if _, done := encoded[c]; !done do encoded[c] = class_digest(g, members, class, c)
    g.nodes[m].digest = encoded[c]
    g.nodes[m].done = true
  }
}

@(private = "file")
refine_signature :: proc(g: ^Graph, i: int, class: map[int]int) -> Value_Digest {
  node := &g.nodes[i]
  buf := make([dynamic]u8, 0, 64, context.temp_allocator)
  append(&buf, node.tag)
  append(&buf, ..node.prefix)
  for edge in node.edges {
    slot := edge.slot
    if edge.has_slot do append(&buf, ..slot[:])
    if edge.target == NOT_A_NODE || edge.target not_in class {
      // Outside the component, so already final.
      append(&buf, 0x00)
      child := edge.leaf
      if edge.target != NOT_A_NODE do child = g.nodes[edge.target].digest
      append(&buf, ..child[:])
    } else {
      append(&buf, 0x01)
      append(&buf, ..u32_bytes(u32(class[edge.target])))
    }
  }
  return sha256_of(buf[:])
}

// The canonical encoding of the quotient graph reachable from class `c`.
//
// A deterministic walk numbers the classes it meets - `c` is 0, and each new
// class takes the next number in the order the walk first reaches it - and
// then every class is written out in that numbering, with intra-component
// children written as numbers rather than digests. Because the walk visits
// children in slot order and bisimilar nodes have identical slots, two
// bisimilar classes produce the same numbering and therefore the same bytes.
@(private = "file")
class_digest :: proc(g: ^Graph, members: []int, class: map[int]int, c: int) -> Value_Digest {
  representative := make(map[int]int, len(members), context.temp_allocator)
  for m in members {
    if _, seen := representative[class[m]]; !seen do representative[class[m]] = m
  }

  order := make(map[int]int, len(members), context.temp_allocator)
  visit_order := make([dynamic]int, 0, len(members), context.temp_allocator)

  // Breadth-first from `c`, taking each node's children in slot order and
  // numbering a class the first time it is reached. Breadth-first rather than
  // depth-first for no deeper reason than that it is the one whose numbering
  // is obvious from the code: `visit_order` is the queue and the numbering at
  // once, so "the order the walk first meets them" is literally what it holds.
  order[c] = 0
  append(&visit_order, c)
  for at := 0; at < len(visit_order); at += 1 {
    node := &g.nodes[representative[visit_order[at]]]
    for edge in node.edges {
      if edge.target == NOT_A_NODE || edge.target not_in class do continue
      child := class[edge.target]
      if _, seen := order[child]; seen do continue
      order[child] = len(visit_order)
      append(&visit_order, child)
    }
  }

  buf := make([dynamic]u8, 0, 256, context.temp_allocator)
  for visited in visit_order {
    node := &g.nodes[representative[visited]]
    append(&buf, TAG_CYCLIC_NODE)
    append(&buf, node.tag)
    prefix := sha256_of(node.prefix)
    append(&buf, ..prefix[:])
    append(&buf, ..u32_bytes(u32(len(node.edges))))
    for edge in node.edges {
      slot := edge.slot
      append(&buf, 0x01 if edge.has_slot else 0x00)
      append(&buf, ..slot[:])
      if edge.target == NOT_A_NODE || edge.target not_in class {
        append(&buf, 0x00)
        child := edge.leaf
        if edge.target != NOT_A_NODE do child = g.nodes[edge.target].digest
        append(&buf, ..child[:])
      } else {
        append(&buf, 0x01)
        ref: Value_Digest
        copy(ref[:], u32_bytes(u32(order[class[edge.target]])))
        append(&buf, ..ref[:])
      }
    }
  }
  return sha256_tagged(TAG_CYCLIC, buf[:])
}

@(private = "file")
u32_bytes :: proc(v: u32) -> []u8 {
  buf := make([]u8, 4, context.temp_allocator)
  for i in 0 ..< 4 do buf[i] = u8((v >> (8 * uint(i))) & 0xff)
  return buf
}
