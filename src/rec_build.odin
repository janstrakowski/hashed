package hashed

import "core:fmt"

// SPEC.md §10's cyclic `let rec`: how a Table can reach itself.
//
// An ordinary `let rec` evaluates its bound value in the scope the name is
// about to land in, which is enough for a *function* to recurse - a closure
// captures the scope by pointer, so the name is bound by the time anything
// calls it (see eval.odin's eval_let_bind). It is not enough for data. A Table
// entry that reads `people.bob` needs that entry's value now, during
// construction, and until this file existed there was nothing to give it: the
// name resolved to nothing and the program failed with "undefined name".
//
// The fix is to stop evaluating the entries in source order. The Table is
// created empty and bound to the name *first*, so the name always resolves to
// the object being built; entries are then evaluated **on demand**, in
// whatever order the dependencies between them actually require. Reaching
// `people.bob` while `.alice` is mid-flight simply evaluates `.bob` there and
// then. That dissolves every dependency which has a topological order at all.
//
// What survives is the residual true cycle: `.bob` reaching back into `.alice`,
// which is still in progress and so has no value to give. That, and only that,
// yields a Forward_Ref_Value (value.odin) - a cell filled in the moment
// `.alice` completes. Storing one is fine and is what makes the back-edge;
// inspecting one before it is filled is a genuinely circular definition and
// fails. Since every entry completes before the `let rec` returns, every cell
// is filled by then, and no finished value ever holds an unresolved one.
//
// The scope of all this is deliberately narrow: it applies to a Table literal
// written directly as a `let rec`'s bound value, because that is the only
// shape whose entries there are to reorder. `let rec p (build_it p);` has no
// entries and still fails exactly as it did before.

@(private = "file")
Rec_Entry_State :: enum {
  Pending,     // not started
  In_Progress, // being evaluated right now - reaching it yields its forward reference
  Done,        // its value is in place
}

// One `let rec` Table literal, mid-construction. Lives on Interpreter.rec_builds
// for exactly as long as the binding is being evaluated.
Rec_Build :: struct {
  table: ^Table_Value,
  env:   ^Env,    // the child scope the name is bound in - entries evaluate here
  name:  string,  // the bound name, for failure messages
  nodes: []Node_Idx,           // each entry's value expression
  state: []Rec_Entry_State,
  fwd:   []^Forward_Ref_Value, // one per entry; `table.entries[i].value` until it is Done
}

// The build for `t`, if it is currently being constructed. The stack is empty
// for every program that never writes a cyclic `let rec`, so this is a length
// check on the hot path of every field access.
rec_build_for :: proc(interp: ^Interpreter, t: ^Table_Value) -> ^Rec_Build {
  #reverse for rb in interp.rec_builds {
    if rb.table == t do return rb
  }
  return nil
}

// `<name>.<key>` / `<name>[<key>]`, for a failure message that names the entry
// a program actually wrote rather than an internal index.
@(private = "file")
rec_entry_label :: proc(name: string, key: Value) -> string {
  if s, is_str := key.(string); is_str do return fmt.tprintf("%s.%s", name, s)
  return fmt.tprintf("%s[%s]", name, format_value(key))
}

// Reading `<name>.<key>` while `<name>` is still being built - the demand that
// drives the whole scheme. Routed here by table_access (eval.odin) instead of
// the ordinary lookup, because the ordinary lookup would find the entry's
// unfilled forward reference rather than evaluating it.
rec_access :: proc(interp: ^Interpreter, rb: ^Rec_Build, key: Value) -> (Value, bool) {
  for entry, i in rb.table.entries {
    if !values_equal(entry.key, key) do continue
    switch rb.state[i] {
    case .Done:
      return rb.table.entries[i].value, true
    case .Pending:
      // Evaluate it now, out of source order. This is the reordering that
      // makes a mutual reference between two entries work without either of
      // them needing a placeholder at all.
      if !rec_force(interp, rb, i) do return nil, false
      return rb.table.entries[i].value, true
    case .In_Progress:
      // The real cycle: this entry is somewhere up our own call stack. Hand
      // back the cell it will be filled into.
      return rb.fwd[i], true
    }
  }
  return fail(interp, "no such key in Table")
}

// Evaluates entry `i` to completion and fills both its slot and its forward
// reference cell.
@(private = "file")
rec_force :: proc(interp: ^Interpreter, rb: ^Rec_Build, i: int) -> bool {
  rb.state[i] = .In_Progress
  val, ok := eval_slot(interp, rb.nodes[i], rb.env)
  if !ok do return false
  // await, not concrete: an `async` entry still has to be resolved before it
  // is stored, but a forward reference *stored* inside this value is the
  // back-edge itself and must pass through untouched.
  val, ok = await_value(interp, val)
  if !ok do return false

  // A bare forward reference as the whole value means this entry is defined as
  // some other entry which is in turn defined as this one - `{ .a = p.b,
  // .b = p.a }`. No ordering and no cell can produce a value for that; it is
  // circular in the sense that genuinely has no answer.
  resolved, rok := resolve_forward(val)
  if !rok {
    interp.error_message = fmt.tprintf(
      "circular definition: %s is defined as itself, through %s",
      rec_entry_label(rb.name, rb.table.entries[i].key),
      rec_entry_label(rb.name, val.(^Forward_Ref_Value).key))
    return false
  }

  rb.table.entries[i].value = resolved
  rb.state[i] = .Done
  // Storing the resolved value (never another cell) keeps every chain at most
  // one link long, so resolve_forward can never loop.
  rb.fwd[i].target = resolved
  rb.fwd[i].resolved = true
  return true
}

// `let rec <name> <table literal>; <body>` (§10). Called by eval_let_bind for
// that one shape; everything else keeps the ordinary path.
eval_rec_table :: proc(
  interp: ^Interpreter,
  table_node: Node_Idx,
  name: string,
  child_env: ^Env,
) -> (Value, bool) {
  n := interp.ast.nodes[table_node]
  start := int(n.children_start)
  count := int(n.children_count)

  t := new(Table_Value)
  t.entries = make([dynamic]Table_Entry_Value, 0, count)
  // Bound before a single entry runs - this is the whole point, and what lets
  // an entry mention the Table it is part of.
  env_bind(child_env, name, t)

  rb := new(Rec_Build)
  rb.table = t
  rb.env = child_env
  rb.name = name
  rb.nodes = make([]Node_Idx, count)
  rb.state = make([]Rec_Entry_State, count)
  rb.fwd = make([]^Forward_Ref_Value, count)

  // Keys first, all of them, in source order. They have to be known before any
  // value runs, since a demand for `.bob` is a lookup by key - and it keeps the
  // entries in the order they were written whatever order they end up being
  // evaluated in, which §5 requires and the printer's sequence-shape test
  // depends on. A computed key `[expr] =` that reads the name being bound
  // finds no entry it can answer with and fails, which is the honest outcome:
  // the key would have to exist before it could be looked up.
  for i in 0 ..< count {
    child_idx := interp.ast.extra_children[start + i]
    child := interp.ast.nodes[child_idx]
    key: Value
    value_idx: Node_Idx
    if child.kind == .Table_Entry {
      key_idx := interp.ast.extra_children[child.children_start]
      value_idx = interp.ast.extra_children[child.children_start + 1]
      key_node := interp.ast.nodes[key_idx]
      if key_node.kind == .Identifier && .Computed_Key not_in child.flags {
        key = node_text(interp, key_idx)
      } else {
        k, kok := eval_slot(interp, key_idx, child_env)
        if !kok do return nil, false
        kk, kok2 := concrete_value(interp, k)
        if !kok2 do return nil, false
        key = kk
      }
    } else {
      key = i64(i + 1) // 1-indexed, §5
      value_idx = child_idx
    }
    fr := new(Forward_Ref_Value)
    fr.name = name
    fr.key = key
    rb.nodes[i] = value_idx
    rb.fwd[i] = fr
    // Every entry starts as its own unfilled cell rather than a nil, so
    // anything that reaches a not-yet-evaluated entry by a route other than
    // field access - a pattern match against the half-built Table, say - meets
    // a forward reference and fails with the circular-definition message,
    // rather than reading a hole.
    append(&t.entries, Table_Entry_Value{key = key, value = fr})
  }

  append(&interp.rec_builds, rb)
  defer pop(&interp.rec_builds)

  for i in 0 ..< count {
    if rb.state[i] == .Pending {
      if !rec_force(interp, rb, i) do return nil, false
    }
  }
  return t, true
}

// Resolves `v` into something that can actually be looked at: awaits an
// `async` handle (eval_async.odin) and follows a §10 forward reference to the
// value it stands for. The two are the same idea at different scales - a value
// that is not ready yet - which is why they resolve at the same places, the
// small set of points that genuinely need a concrete value.
//
// The difference is what "not ready" means. An async handle always becomes
// ready if you wait. A forward reference is ready only once the `let rec` entry
// it points at has finished, and reaching one that has not is a program that
// asked for a value before there was one to give.
concrete_value :: proc(interp: ^Interpreter, v: Value) -> (Value, bool) {
  awaited, aok := await_value(interp, v)
  if !aok do return nil, false
  resolved, rok := resolve_forward(awaited)
  if rok do return resolved, true
  fr := resolved.(^Forward_Ref_Value)
  return fail(interp, fmt.tprintf(
    "circular definition: %s is needed before it has a value",
    rec_entry_label(fr.name, fr.key)))
}
