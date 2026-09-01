package hashedbuild

import "core:fmt"
import "core:strconv"
import "core:strings"

// Tree-walking evaluator for the pure-expression core of SPEC.md. Deliberately
// scoped out for this pass (each needs real design/OS decisions this project
// hasn't made yet): `import`, `#context`, and the static-vs-runtime
// distinction for `check`/`static_check` (both just run as runtime checks
// here).
//
// The two mechanisms that make omission work:
//   - A bare Hole makes its *enclosing hard-boundary slot* (§7) become a
//     Function value - a closure over that slot's AST subtree, deferred rather
//     than evaluated immediately. `eval_slot` is the one place that decides
//     this, via `contains_hole_shallow`, which recurses through ordinary
//     structure but stops at boundary children (and/or/pipe/call operands,
//     Table entries, let-bind's sides, then/else's condition/branches).
//   - `#arg`/`#argN` (and a Hole once actually evaluated - it means the same
//     thing) is a genuine *dynamic* lookup into `Interpreter.arg_stack`, which
//     function calls push onto - this is what lets it "reach through"
//     boundaries the way §9 describes, unlike a Hole's static, per-slot effect.

// How deep the evaluator may nest before a program is stopped with an ordinary
// fatal failure (§8) instead of running the host stack into the ground. It
// counts *native recursion steps* - one per `eval`, one more per user-level
// call - rather than HashedBuild-level calls alone, because the stack cost of
// one call depends entirely on the shape of the body being evaluated. That is
// also why SPEC.md §8 promises programs no particular recursion depth, only
// that exceeding it is diagnosable.
//
// Counting both halves is what makes one constant cover shapes that sit at
// opposite extremes, and counting only one does not: an earlier version of
// this charged `eval` alone, which a body as small as a single self-call
// (`(func #self 0) 5` - one eval and one call_function per level, nothing
// else) walked straight past into a segfault, because almost none of the
// stack it was burning was eval frames.
//
// The budget is per *stack size*, which is what the targets actually differ
// in - the language does not. Measured the same way for each: run a spread of
// recursive body shapes, find the budget at which the worst of them first
// crashes, keep about a third of it in hand.
//
//   8 MiB - Linux/macOS, the default thread stack. Worst shape crashes near
//           2700, so 1800.
//   1 MiB - Windows, where it is the PE header's default stack reserve, used
//           by the main thread and (via CreateThread with dwStackSize 0) by
//           the thread pool `odin test` runs tests on; and WASI, where it is
//           wasm-ld's reserve for the main stack, which task_wasi.odin then
//           matches for each spawned thread. Worst shape crashes near 300, so
//           200.
//
// The 1 MiB figure was measured natively under `ulimit -s 1024`, so it is
// exact for Windows and an over-estimate of the cost for WASI, where a wasm
// frame is smaller than a native one. Erring that way is deliberate: a budget
// too high traps the module or overflows the stack instead of reporting a
// failure. The deepest example in examples/ needs about 60, so every target
// keeps real headroom.
when ODIN_OS == .Windows || ODIN_OS == .WASI {
  MAX_NEST_DEPTH :: #config(HB_MAX_NEST_DEPTH, 200)
} else {
  MAX_NEST_DEPTH :: #config(HB_MAX_NEST_DEPTH, 1800)
}

Interpreter :: struct {
  ast:           ^ast_t,
  src:           string,
  arg_stack:     [dynamic]Value,
  // The function each active call is *executing*, for `#self`/`#selfN` (§9).
  // Parallel to arg_stack but deliberately not the same depth: `|>` pushes an
  // argument without entering a function, and a native builtin enters without
  // pushing either - so the two are independent addressing schemes, exactly as
  // §9 says ("per implicit-value kind, each with its own addressing scheme").
  self_stack:    [dynamic]Value,
  // Native recursion steps currently outstanding, against MAX_NEST_DEPTH -
  // bumped by `eval` and by each user-level call (see call_function).
  nest_depth:    int,
  error_message: string,

  // The current implicit context (SPEC.md §9's `ctx`) - read live by native
  // builtins (so `withctx` can restrict them from outside), but captured into
  // a Function_Value at closure-creation time and restored around each call
  // (see call_function) so a user-defined closure can never be handed *more*
  // authority than it had when it was made, regardless of who calls it later.
  // Zero value (nil) until a caller sets one up - callers that never touch
  // `ctx`/`withctx` don't need to care.
  current_ctx: Value,

  // Base directory for the *unsandboxed* forms of loadfile/createfile (§16 -
  // no .dir given): relative paths there resolve against this directory
  // instead of the process's actual cwd, so a program's own relative paths
  // stay correct regardless of where `hb` was invoked from. Zero value
  // (has_base_dir == false) means "just use the process's cwd" (AT_FDCWD) -
  // what the REPL wants, since there's no source file to be relative to.
  base_dir_fd:  Fs_Fd,
  has_base_dir: bool,
  // The same directory as a path, kept alongside the handle because a File
  // displays the path it was reached by (SPEC.md §3) and an fd can't be
  // turned back into one portably - Linux could ask /proc/self/fd, WASI has
  // no equivalent at all. Empty means "use the process's cwd", matching
  // has_base_dir == false.
  base_dir_path: string,

  // The `let rec` Table literals currently being built, innermost last
  // (rec_build.odin). Empty for every program that doesn't write a cyclic
  // `let rec`, which is what keeps table_access's check to a length test.
  rec_builds: [dynamic]^Rec_Build,

  // Every `async` task this run has started (eval_async.odin). Shared with
  // each task's own Interpreter so that one run's tasks are all drained
  // together before it ends, however it ends.
  async_registry: ^Async_Registry,

  // Step-by-step trace (off by default - zero-cost for every caller that
  // doesn't set enable_trace, e.g. all the existing tests and the REPL).
  // `trace_depth` is bookkeeping for `eval`'s own instrumentation, not meant
  // to be read by callers.
  enable_trace: bool,
  trace:        [dynamic]Trace_Step,
  trace_depth:  int,

  // If set, `eval` (see its defer, below) pauses after completing each node,
  // waiting for the controlling side to grant one more step before handing
  // the result back to its caller - see debugger.odin. This is what makes
  // the live editor's debugger panel genuinely step-by-step rather than a
  // replay of a trace computed all at once. nil for every other caller
  // (REPL, file mode, tests, the Result/Steps panels) - no cost for them.
  debugger: ^Debugger_Run,

  // >0 while evaluating a then/else or and/or side that's only being walked
  // because §2 requires an untaken branch's async work to still be started
  // and awaited even though its value is discarded (see eval_then_or_else,
  // eval_guard_chain) - lets the debugger mark those steps distinctly rather
  // than showing them as if they were part of the real, kept result.
  // Depth (not a bool) since a discarded branch can itself contain further
  // then/else or and/or nesting.
  discard_depth: int,
}

// One recorded step: node's own source span evaluated to `value` (if `ok`) or
// failed with `error_message` (owned - cloned at the moment of failure, since
// `Interpreter.error_message` itself gets overwritten by whatever fails next).
Trace_Step :: struct {
  node:          Node_Idx,
  depth:         int,
  ok:            bool,
  value:         Value,
  error_message: string,
}

node_text :: proc(interp: ^Interpreter, node: Node_Idx) -> string {
  span := interp.ast.nodes[node].span
  return interp.src[span.start:span.end]
}

@(private = "file")
record_step :: proc(interp: ^Interpreter, node: Node_Idx, depth: int, val: Value, ok: bool) {
  step := Trace_Step{node = node, depth = depth, ok = ok}
  if ok {
    step.value = val
  } else {
    step.error_message = strings.clone(interp.error_message)
  }
  append(&interp.trace, step)
}

fail :: proc(interp: ^Interpreter, msg: string) -> (Value, bool) {
  interp.error_message = msg
  return nil, false
}

@(private = "file")
new_function :: proc(interp: ^Interpreter, body: Node_Idx, env: ^Env) -> Value {
  f := new(Function_Value)
  f.body = body
  f.env = env
  f.ctx = interp.current_ctx // captured now, restored around every call - see Interpreter.current_ctx
  return f
}

// ---- literal parsing --------------------------------------------------------

@(private = "file")
strip_underscores :: proc(s: string) -> string {
  if !strings.contains(s, "_") do return s
  b: strings.Builder
  strings.builder_init(&b, context.temp_allocator)
  for c in s do if c != '_' do strings.write_rune(&b, c)
  return strings.to_string(b)
}

parse_number_literal :: proc(text: string) -> Value {
  t := strip_underscores(text)
  if len(t) > 1 && t[0] == '0' && (t[1] == 'x' || t[1] == 'X') {
    v, _ := strconv.parse_i64_of_base(t[2:], 16)
    return v
  }
  if len(t) > 1 && t[0] == '0' && (t[1] == 'o' || t[1] == 'O') {
    v, _ := strconv.parse_i64_of_base(t[2:], 8)
    return v
  }
  if len(t) > 1 && t[0] == '0' && (t[1] == 'b' || t[1] == 'B') {
    v, _ := strconv.parse_i64_of_base(t[2:], 2)
    return v
  }
  if strings.contains(t, ".") || strings.contains(t, "e") || strings.contains(t, "E") {
    v, _ := strconv.parse_f64(t)
    return v
  }
  v, _ := strconv.parse_i64(t)
  return v
}

parse_string_literal :: proc(text: string) -> string {
  // An unterminated string literal (e.g. a lone `"` at EOF) reaches here as a
  // 1-byte token - just the opening quote, no closing one - since the lexer
  // defers validation to the parser (see lex_string), which doesn't actually
  // check this yet. Treat it as empty rather than slicing out of bounds; a
  // real diagnostic belongs in the parser, not here.
  if len(text) < 2 do return ""
  inner := text[1:len(text) - 1] // strip surrounding quotes
  if !strings.contains(inner, "\\") do return strings.clone(inner)
  b: strings.Builder
  strings.builder_init(&b)
  i := 0
  for i < len(inner) {
    c := inner[i]
    if c == '\\' && i + 1 < len(inner) {
      i += 1
      switch inner[i] {
      case 'n': strings.write_byte(&b, '\n')
      case 't': strings.write_byte(&b, '\t')
      case 'r': strings.write_byte(&b, '\r')
      case '"': strings.write_byte(&b, '"')
      case '\\': strings.write_byte(&b, '\\')
      case: strings.write_byte(&b, inner[i]) // unknown escape - keep the literal char
      }
      i += 1
    } else {
      strings.write_byte(&b, c)
      i += 1
    }
  }
  return strings.to_string(b)
}

// ---- hole/boundary detection (§7) ------------------------------------------

@(private = "file")
is_boundary_op :: proc(op_kind: Node_Kind) -> bool {
  #partial switch op_kind {
  case .Op_And, .Op_Or, .Op_Pipe, .Op_Call:
    return true
  }
  return false
}

contains_hole_shallow :: proc(ast: ^ast_t, node: Node_Idx) -> bool {
  n := ast.nodes[node]
  #partial switch n.kind {
  case .Hole:
    return true
  case .Binary_Expr:
    op := ast.nodes[ast.extra_children[n.children_start + 1]].kind
    left := ast.extra_children[n.children_start + 0]
    if op == .Op_Pipe && ast.nodes[left].kind == .Hole {
      // Same "entirely omitted" rule as Let_Bind: "|> f" with a bare, direct
      // Hole on the left is a function of the omitted piped value (SPEC.md
      // §7's own example), not a pipe whose left side is a trivial identity
      // closure - so the escape happens here rather than being independently
      // curried like a non-trivial hole-containing left side would be.
      return true
    }
    if is_boundary_op(op) do return false
    right := ast.extra_children[n.children_start + 2]
    return contains_hole_shallow(ast, left) || contains_hole_shallow(ast, right)
  case .Unary_Expr:
    operand := ast.extra_children[n.children_start + 1]
    return contains_hole_shallow(ast, operand)
  case .Let_Bind, .With_Ctx_Expr, .ChCtx_Expr:
    // §7 rule 2 (Let_Bind's bound value, or With_Ctx_Expr's left expr) applies
    // identically to both: entirely omitting the slot ("let name; body" /
    // "withctx new_ctx") makes the WHOLE construct a function - the slot's
    // hole-ness escapes outward. A value that merely *contains* a hole inside
    // a larger expression ("let name (*2); body") does NOT escape - per rule 1
    // that's its own independent slot, curried separately by eval_let_bind /
    // eval_with_ctx.
    bound := ast.extra_children[n.children_start]
    return ast.nodes[bound].kind == .Hole
  }
  // Table_Construct, Then_Expr, Else_Expr, Func_Expr and friends,
  // Variant_Construct, Check_Expr, leaves, etc. all either have only boundary
  // children or are leaves - never themselves hole-containing from outside.
  return false
}

// The one entry point for evaluating any hard-boundary slot: defers (returns
// a Function) if the slot contains an unresolved Hole, otherwise evaluates now.
eval_slot :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> (Value, bool) {
  if contains_hole_shallow(interp.ast, node) {
    val := new_function(interp, node, env)
    if interp.enable_trace do record_step(interp, node, interp.trace_depth, val, true)
    return val, true
  }
  return eval(interp, node, env)
}

// ---- main dispatch -----------------------------------------------------------

// Named returns so the trace-recording defer below can see the final
// (val, ok) without touching any of the dispatch's own `return` statements.
// Named returns are `ret_val`/`ret_ok`, not `val`/`ok`, only to avoid
// shadowing errors against the many internal `val, ok := ...` locals already
// used throughout the switch body below - functionally they're the same
// "final result" a plain (Value, bool) return would give the caller.
eval :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> (ret_val: Value, ret_ok: bool) {
  // Checked before any of the trace/debugger bookkeeping below, so the early
  // return leaves none of it half-set-up.
  interp.nest_depth += 1
  defer interp.nest_depth -= 1
  if interp.nest_depth > MAX_NEST_DEPTH {
    return fail(interp, "evaluation nested too deeply (runaway recursion?)")
  }

  tracing := interp.enable_trace
  depth := interp.trace_depth
  if tracing do interp.trace_depth += 1
  // One `defer` block (not `defer if`, since both conditions below need to be
  // checked independently) so this runs at eval's return, not at the end of
  // some inner block scope.
  defer {
    if tracing {
      interp.trace_depth -= 1
      record_step(interp, node, depth, ret_val, ret_ok)
    }
    if interp.debugger != nil {
      debugger_wait_and_publish(interp, node, &ret_val, &ret_ok)
    }
  }
  n := interp.ast.nodes[node]
  #partial switch n.kind {
  case .Root:
    return eval_slot(interp, interp.ast.extra_children[n.children_start], env)

  case .Number_Literal:
    return parse_number_literal(node_text(interp, node)), true

  case .String_Literal:
    return parse_string_literal(node_text(interp, node)), true

  case .Nothing_Literal:
    return Nothing_Value{}, true

  case .Ctx_Expr:
    return interp.current_ctx, true

  case .Identifier:
    name := node_text(interp, node)
    if v, ok := env_lookup(env, name); ok do return v, true
    return fail(interp, fmt.tprintf("undefined name: %s", name))

  case .Implicit_Name:
    return eval_implicit_name(interp, node)

  case .Hole:
    if len(interp.arg_stack) == 0 do return fail(interp, "omitted value referenced with no active function call")
    return interp.arg_stack[len(interp.arg_stack) - 1], true

  case .Unary_Expr:
    return eval_unary(interp, node, env)

  case .Binary_Expr:
    return eval_binary(interp, node, env)

  case .Table_Construct:
    return eval_table_construct(interp, node, env)

  case .Variant_Construct:
    return eval_variant_construct(interp, node, env)

  case .Let_Bind:
    return eval_let_bind(interp, node, env)

  case .With_Ctx_Expr:
    return eval_with_ctx(interp, node, env)

  case .ChCtx_Expr:
    return eval_chctx(interp, node, env)

  case .Func_Expr:
    return new_function(interp, interp.ast.extra_children[n.children_start], env), true

  case .AsFunc_Expr, .AsFuncStatic_Expr:
    inner := interp.ast.extra_children[n.children_start]
    val, ok := eval_slot(interp, inner, env)
    if !ok do return nil, false
    if _, is_fn := val.(^Function_Value); !is_fn do return fail(interp, "asserted value is not a function")
    return val, true

  case .Then_Expr, .Else_Expr:
    return eval_then_or_else(interp, node, env)

  case .Check_Expr, .StaticCheck_Expr:
    return eval_check(interp, node, env)

  case .Error_Expr:
    if n.children_count > 0 {
      msg_val, ok := eval_slot(interp, interp.ast.extra_children[n.children_start], env)
      if ok {
        msg_val, ok = concrete_value(interp, msg_val)
      }
      if ok {
        if s, is_str := msg_val.(string); is_str do return fail(interp, s)
      }
    }
    return fail(interp, "error")

  case .MISSING_TOKEN, .ERROR_UNRECOGNIZED:
    return fail(interp, "cannot evaluate a syntax error")

  case .Async_Expr:
    inner := interp.ast.extra_children[n.children_start]
    h, spawned := spawn_async(interp, inner, env)
    if !spawned {
      return fail(interp, "async: could not start a thread - no thread support here (see LANGUAGE.md on the WASI flavours)")
    }
    return h, true

  case .Sha256_Expr:
    return eval_sha256(interp, node, env)

  case .Cached_Expr:
    return eval_cached(interp, node, env)

  case .Import_Expr:
    return fail(interp, fmt.tprintf("%v is not implemented by this evaluator yet", n.kind))
  }
  return fail(interp, fmt.tprintf("evaluation not implemented for %v", n.kind))
}

@(private = "file")
eval_unary :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> (Value, bool) {
  n := interp.ast.nodes[node]
  op := interp.ast.nodes[interp.ast.extra_children[n.children_start]].kind
  val, ok := eval(interp, interp.ast.extra_children[n.children_start + 1], env)
  if !ok do return nil, false
  val, ok = concrete_value(interp, val)
  if !ok do return nil, false
  #partial switch op {
  case .Op_Minus:
    #partial switch v in val {
    case i64: return -v, true
    case f64: return -v, true
    }
    return fail(interp, "unary '-' requires a number")
  }
  return fail(interp, "unknown unary operator")
}

// `#arg`/`#argN` (the enclosing call's argument) and `#self`/`#selfN` (the
// function that call is executing, §9). Both are dynamic lookups into their own
// stack, N levels out - which is what lets either reach through a hard boundary
// (§7) the way a Hole cannot. `#self` is what makes an *anonymous* function
// recursive: `let rec` (§10) only helps one that has a name to refer to.
@(private = "file")
eval_implicit_name :: proc(interp: ^Interpreter, node: Node_Idx) -> (Value, bool) {
  text := node_text(interp, node) // "#arg", "#arg2", "#self", "#context", ...
  rest := text[1:]
  if rest == "context" do return fail(interp, "#context is not supported by this evaluator yet")

  stack: ^[dynamic]Value
  prefix: string
  switch {
  case strings.has_prefix(rest, "arg"):  stack, prefix = &interp.arg_stack, "arg"
  case strings.has_prefix(rest, "self"): stack, prefix = &interp.self_stack, "self"
  case: return fail(interp, fmt.tprintf("unknown implicit name: %s", text))
  }

  level := 1
  num_part := rest[len(prefix):]
  if len(num_part) > 0 {
    v, ok := strconv.parse_int(num_part)
    if !ok do return fail(interp, fmt.tprintf("malformed implicit name: %s", text))
    level = v
  }
  idx := len(stack) - level
  if idx < 0 do return fail(interp, fmt.tprintf("%s: no such enclosing function", text))
  return stack[idx], true
}

// ---- binary operators --------------------------------------------------------

@(private = "file")
eval_binary :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> (Value, bool) {
  n := interp.ast.nodes[node]
  left_idx := interp.ast.extra_children[n.children_start]
  op := interp.ast.nodes[interp.ast.extra_children[n.children_start + 1]].kind
  right_idx := interp.ast.extra_children[n.children_start + 2]

  #partial switch op {
  case .Op_And, .Op_Or, .Op_Is:
    result, _, ok := eval_guard_chain(interp, node, env)
    return result, ok

  case .Op_Pipe:
    // Push the piped value before evaluating the right side (rather than
    // eval_slot-ing it and calling separately) so any hole/#arg reference
    // inside a guard-chain right side (§9's "applied to the value most
    // recently piped in via |>") resolves immediately, without needing an
    // intermediate closure. If the right side turns out to be an ordinary,
    // as-yet-uncalled Function value instead (the plain `x |> f` case), call
    // it explicitly with the piped value.
    // Evaluate (firing, not yet awaiting, any `async`) before awaiting - see
    // eval_async.odin - so an async left side and an async right side, or two
    // async table/arithmetic operands elsewhere below, actually run
    // concurrently with each other rather than being serialized by an eager
    // await right after each one is computed.
    left_val, lok := eval_pipe_left(interp, left_idx, env)
    if !lok do return nil, false
    append(&interp.arg_stack, left_val)
    defer pop(&interp.arg_stack)
    right_val, rok := eval(interp, right_idx, env)
    if !rok do return nil, false
    right_val, rok = concrete_value(interp, right_val) // need its concrete type to know whether to call it
    if !rok do return nil, false
    if fn, is_fn := right_val.(^Function_Value); is_fn {
      return call_function(interp, fn, left_val)
    }
    return right_val, true

  case .Op_Call:
    fn_val, fok := eval_slot(interp, left_idx, env)
    if !fok do return nil, false
    fn_val, fok = concrete_value(interp, fn_val) // need its concrete type before the is_fn check below
    if !fok do return nil, false
    arg_val, aok := eval_slot(interp, right_idx, env)
    if !aok do return nil, false
    fn, is_fn := fn_val.(^Function_Value)
    if !is_fn do return fail(interp, "cannot apply a non-function value")
    return call_function(interp, fn, arg_val)

  case .Op_Dot:
    base, bok := eval(interp, left_idx, env)
    if !bok do return nil, false
    base, bok = concrete_value(interp, base)
    if !bok do return nil, false
    right_node := interp.ast.nodes[right_idx]
    key: Value = node_text(interp, right_idx)
    if right_node.kind == .Number_Literal do key = parse_number_literal(node_text(interp, right_idx))
    return table_access(interp, base, key)

  case .Op_Bracket:
    base, bok := eval(interp, left_idx, env)
    if !bok do return nil, false
    key, kok := eval(interp, right_idx, env)
    if !kok do return nil, false
    base, bok = concrete_value(interp, base)
    if !bok do return nil, false
    key, kok = concrete_value(interp, key)
    if !kok do return nil, false
    return table_access(interp, base, key)

  case .Op_CheckColon, .Op_CheckDot:
    base, bok := eval(interp, left_idx, env)
    if !bok do return nil, false
    key: Value
    if op == .Op_CheckDot {
      key = node_text(interp, right_idx)
    } else {
      k, kok := eval(interp, right_idx, env)
      if !kok do return nil, false
      key = k
    }
    base, bok = concrete_value(interp, base)
    if !bok do return nil, false
    awaited_key, kok := concrete_value(interp, key)
    if !kok do return nil, false
    key = awaited_key
    t, is_table := base.(^Table_Value)
    if !is_table do return fail(interp, "check-or-throw requires a Table")
    val, found := table_find(t, key)
    if !found do return fail(interp, "check-or-throw: no matching entry")
    return val, true

  case .Op_Concat:
    l, lok := eval(interp, left_idx, env)
    if !lok do return nil, false
    r, rok := eval(interp, right_idx, env)
    if !rok do return nil, false
    l, lok = concrete_value(interp, l)
    if !lok do return nil, false
    r, rok = concrete_value(interp, r)
    if !rok do return nil, false
    if ls, lis := l.(string); lis {
      rs, ris := r.(string)
      if !ris do return fail(interp, "concat requires two operands of the same type")
      return strings.concatenate({ls, rs}), true
    }
    if lt, lit := l.(^Table_Value); lit {
      rt, rit := r.(^Table_Value)
      if !rit do return fail(interp, "concat requires two operands of the same type")
      return table_concat(lt, rt), true
    }
    return fail(interp, "concat requires two Utf8, Bytes, or Table values")

  case .Op_EqEq, .Op_Gt, .Op_GtEq, .Op_Lt, .Op_LtEq:
    l, lok := eval(interp, left_idx, env)
    if !lok do return nil, false
    r, rok := eval(interp, right_idx, env)
    if !rok do return nil, false
    l, lok = concrete_value(interp, l)
    if !lok do return nil, false
    r, rok = concrete_value(interp, r)
    if !rok do return nil, false
    // Comparing a directory File means comparing what is inside it (§3), so
    // the comparison is a read - and a read is where `io` is checked (§9).
    // values_equal itself is reached from table_find on the hot path of every
    // field access and can do no I/O, so the operands are warmed here, while
    // there is still a context to ask. See hash.odin's hash_materialize.
    if f := hash_materialize(interp, l); f.kind != .None {
      return fail(interp, hash_error_message(f))
    }
    if f := hash_materialize(interp, r); f.kind != .None {
      return fail(interp, hash_error_message(f))
    }
    if op == .Op_EqEq do return values_equal(l, r), true
    return compare_ordered(interp, op, l, r)

  case .Op_Plus, .Op_Minus, .Op_Star, .Op_Slash, .Op_Percent:
    l, lok := eval(interp, left_idx, env)
    if !lok do return nil, false
    r, rok := eval(interp, right_idx, env)
    if !rok do return nil, false
    l, lok = concrete_value(interp, l)
    if !lok do return nil, false
    r, rok = concrete_value(interp, r)
    if !rok do return nil, false
    return arithmetic(interp, op, l, r)
  }
  return fail(interp, "unknown binary operator")
}

@(private = "file")
as_f64 :: proc(v: Value) -> (f64, bool) {
  #partial switch x in v {
  case i64: return f64(x), true
  case f64: return x, true
  }
  return 0, false
}

@(private = "file")
compare_ordered :: proc(interp: ^Interpreter, op: Node_Kind, l: Value, r: Value) -> (Value, bool) {
  lf, lok := as_f64(l)
  rf, rok := as_f64(r)
  if !lok || !rok do return fail(interp, "comparison requires numbers")
  #partial switch op {
  case .Op_Gt: return lf > rf, true
  case .Op_GtEq: return lf >= rf, true
  case .Op_Lt: return lf < rf, true
  case .Op_LtEq: return lf <= rf, true
  }
  return fail(interp, "unknown comparison operator")
}

@(private = "file")
arithmetic :: proc(interp: ^Interpreter, op: Node_Kind, l: Value, r: Value) -> (Value, bool) {
  li, l_is_int := l.(i64)
  ri, r_is_int := r.(i64)
  if l_is_int && r_is_int {
    #partial switch op {
    case .Op_Plus: return li + ri, true
    case .Op_Minus: return li - ri, true
    case .Op_Star: return li * ri, true
    case .Op_Slash:
      if ri == 0 do return fail(interp, "division by zero")
      return li / ri, true
    case .Op_Percent:
      if ri == 0 do return fail(interp, "modulo by zero")
      return li % ri, true
    }
  }
  lf, lok := as_f64(l)
  rf, rok := as_f64(r)
  if !lok || !rok do return fail(interp, "arithmetic requires numbers")
  #partial switch op {
  case .Op_Plus: return lf + rf, true
  case .Op_Minus: return lf - rf, true
  case .Op_Star: return lf * rf, true
  case .Op_Slash:
    if rf == 0 do return fail(interp, "division by zero")
    return lf / rf, true
  case .Op_Percent:
    return fail(interp, "modulo requires Integer operands")
  }
  return fail(interp, "unknown arithmetic operator")
}

// Resolves |>'s left operand, honoring the same "bare, direct Hole" special
// case as contains_hole_shallow: when this Pipe node was itself the deferred
// slot (we're now running as the body of a call), the omitted piped value
// must resolve straight from the argument stack rather than being re-deferred
// into a pointless identity-function.
@(private = "file")
eval_pipe_left :: proc(interp: ^Interpreter, left_idx: Node_Idx, env: ^Env) -> (Value, bool) {
  if interp.ast.nodes[left_idx].kind == .Hole {
    return eval(interp, left_idx, env)
  }
  return eval_slot(interp, left_idx, env)
}

// `Table concat Table` (SPEC.md §4/§5): a merge where the right side's entries
// win on key collision - this doubles as Table's functional-update mechanism
// (`original concat { .field = new_value }`).
@(private = "file")
table_concat :: proc(a: ^Table_Value, b: ^Table_Value) -> ^Table_Value {
  result := new(Table_Value)
  result.entries = make([dynamic]Table_Entry_Value, 0, len(a.entries) + len(b.entries))
  for entry in a.entries {
    if _, overridden := table_find(b, entry.key); !overridden {
      append(&result.entries, entry)
    }
  }
  for entry in b.entries {
    append(&result.entries, entry)
  }
  return result
}

@(private = "file")
table_access :: proc(interp: ^Interpreter, base: Value, key: Value) -> (Value, bool) {
  t, is_table := base.(^Table_Value)
  if !is_table do return fail(interp, "cannot index a non-Table value")
  // A Table still being built by a `let rec` (§10) answers through
  // rec_build.odin instead: the entry asked for may not have run yet, and
  // reading it is exactly the demand that makes it run. Ordinary Tables -
  // every Table in a program that has no cyclic `let rec` - skip this on a
  // length check.
  if len(interp.rec_builds) > 0 {
    if rb := rec_build_for(interp, t); rb != nil do return rec_access(interp, rb, key)
  }
  val, found := table_find(t, key)
  if !found do return fail(interp, "no such key in Table")
  return val, true
}

// ---- Table / Variant construction --------------------------------------------

@(private = "file")
eval_table_construct :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> (Value, bool) {
  n := interp.ast.nodes[node]
  start := int(n.children_start)
  count := int(n.children_count)

  // Evaluate every entry's key/value first (firing, not yet awaiting, any
  // `async` among them) into `pending`, then await them all in a second
  // pass below - this is what makes several async entries in one Table
  // literal actually run concurrently with each other, rather than each
  // being awaited (blocking) before the next one is even started.
  // await_value is a no-op for a non-async Value, so a plain positional
  // entry's already-concrete i64 key just passes through unchanged.
  pending := make([dynamic]Table_Entry_Value, 0, count, context.temp_allocator)
  for i in 0 ..< count {
    child_idx := interp.ast.extra_children[start + i]
    child := interp.ast.nodes[child_idx]
    if child.kind == .Table_Entry {
      key_idx := interp.ast.extra_children[child.children_start]
      value_idx := interp.ast.extra_children[child.children_start + 1]
      key_node := interp.ast.nodes[key_idx]
      key: Value
      // `.name = v` uses the identifier's own spelling as the key; `[name]
      // = v` (Computed_Key, §5) evaluates it like any other expression.
      if key_node.kind == .Identifier && .Computed_Key not_in child.flags {
        key = node_text(interp, key_idx)
      } else {
        k, kok := eval_slot(interp, key_idx, env)
        if !kok do return nil, false
        key = k
      }
      val, vok := eval_slot(interp, value_idx, env)
      if !vok do return nil, false
      append(&pending, Table_Entry_Value{key = key, value = val})
    } else {
      val, vok := eval_slot(interp, child_idx, env)
      if !vok do return nil, false
      append(&pending, Table_Entry_Value{key = i64(i + 1), value = val}) // 1-indexed, §5
    }
  }

  t := new(Table_Value)
  t.entries = make([dynamic]Table_Entry_Value, 0, count)
  for entry in pending {
    key, kok := await_value(interp, entry.key)
    if !kok do return nil, false
    val, vok := await_value(interp, entry.value)
    if !vok do return nil, false
    append(&t.entries, Table_Entry_Value{key = key, value = val})
  }
  return t, true
}

@(private = "file")
eval_variant_construct :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> (Value, bool) {
  n := interp.ast.nodes[node]
  key_idx := interp.ast.extra_children[n.children_start]
  value_idx := interp.ast.extra_children[n.children_start + 1]
  key_node := interp.ast.nodes[key_idx]
  key: Value
  if key_node.kind == .Tag_Name {
    key = node_text(interp, key_idx)
  } else {
    k, kok := eval_slot(interp, key_idx, env)
    if !kok do return nil, false
    key = k
  }
  val, vok := eval_slot(interp, value_idx, env)
  if !vok do return nil, false
  awaited_key, kok := await_value(interp, key)
  if !kok do return nil, false
  key = awaited_key
  val, vok = await_value(interp, val)
  if !vok do return nil, false
  t := new(Table_Value)
  t.entries = make([dynamic]Table_Entry_Value, 0, 1)
  append(&t.entries, Table_Entry_Value{key = key, value = val})
  return t, true
}

@(private = "file")
eval_let_bind :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> (Value, bool) {
  n := interp.ast.nodes[node]
  bound_idx := interp.ast.extra_children[n.children_start]
  name_idx := interp.ast.extra_children[n.children_start + 1]
  body_idx := interp.ast.extra_children[n.children_start + 2]

  // `let rec` (§10) evaluates the bound value in the child scope the name is
  // about to land in, rather than in the parent. Nothing else changes: a
  // closure made while evaluating it captures that same ^Env by pointer, so
  // binding the name afterwards is visible to it when it is eventually
  // called - which is the whole of recursion. A *non*-function that reads its
  // own name (`let rec x x + 1; x`) instead hits the window before the bind
  // and fails with the ordinary "undefined name" - the right answer, and one
  // that falls out rather than needing a sentinel value to detect.
  child_env := env_make_child(env)
  bound_env := env if .Is_Rec not_in n.flags else child_env

  // `let rec <name> <table literal>;` is the one shape whose entries can be
  // reordered, so it gets §10's demand-driven construction (rec_build.odin) -
  // which is what lets one entry reach another, and lets the Table reach
  // itself. Every other shape, `let rec` over a function included, keeps the
  // ordinary path below unchanged.
  if .Is_Rec in n.flags && interp.ast.nodes[bound_idx].kind == .Table_Construct {
    if _, rok := eval_rec_table(interp, bound_idx, node_text(interp, name_idx), child_env); !rok {
      return nil, false
    }
    return eval_slot(interp, body_idx, child_env)
  }

  bound_val: Value
  bok: bool
  if interp.ast.nodes[bound_idx].kind == .Hole {
    // The whole Let_Bind was the deferred slot (§7 rule 2, "named function") -
    // this is reached via call_function's plain `eval` on its own body, so the
    // omitted value resolves straight from the argument stack, same as any
    // other bare Hole - it must NOT be re-deferred into its own function.
    bound_val, bok = eval(interp, bound_idx, bound_env)
  } else {
    bound_val, bok = eval_slot(interp, bound_idx, bound_env)
  }
  if !bok do return nil, false

  env_bind(child_env, node_text(interp, name_idx), bound_val)
  return eval_slot(interp, body_idx, child_env)
}

// `<expr> withctx <new_ctx>` (§7/§9). `<new_ctx>` is evaluated under the
// *outer* context (the new one doesn't exist yet), then swapped in only for
// the extent of `<expr>`, restored unconditionally afterward. `<expr>`
// follows the exact same bare-Hole-vs-embedded-Hole distinction as Let_Bind's
// bound value and |>'s left side (see contains_hole_shallow) - an entirely
// omitted `<expr>` makes the whole With_Ctx_Expr the deferred slot, so its
// Hole must resolve from the argument stack directly, not re-defer.
@(private = "file")
eval_with_ctx :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> (Value, bool) {
  n := interp.ast.nodes[node]
  expr_idx := interp.ast.extra_children[n.children_start]
  new_ctx_idx := interp.ast.extra_children[n.children_start + 1]

  new_ctx_val, cok := eval_slot(interp, new_ctx_idx, env)
  if !cok do return nil, false
  new_ctx_val, cok = concrete_value(interp, new_ctx_val) // ctx.permissions reads need a concrete Table
  if !cok do return nil, false

  old_ctx := interp.current_ctx
  interp.current_ctx = new_ctx_val
  defer interp.current_ctx = old_ctx

  if interp.ast.nodes[expr_idx].kind == .Hole {
    return eval(interp, expr_idx, env)
  }
  return eval_slot(interp, expr_idx, env)
}

// `<expr> chctx <fn>` (§7/§9) - exactly like eval_with_ctx, except the new
// context is computed by calling `<fn>` with the *old* context (the one
// active before `<expr>` starts), rather than being supplied directly.
@(private = "file")
eval_chctx :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> (Value, bool) {
  n := interp.ast.nodes[node]
  expr_idx := interp.ast.extra_children[n.children_start]
  fn_idx := interp.ast.extra_children[n.children_start + 1]

  fn_val, fok := eval_slot(interp, fn_idx, env)
  if !fok do return nil, false
  fn_val, fok = concrete_value(interp, fn_val)
  if !fok do return nil, false
  fn, is_fn := fn_val.(^Function_Value)
  if !is_fn do return fail(interp, "chctx's right side must be a function")

  new_ctx_val, cok := call_function(interp, fn, interp.current_ctx)
  if !cok do return nil, false
  new_ctx_val, cok = concrete_value(interp, new_ctx_val)
  if !cok do return nil, false

  old_ctx := interp.current_ctx
  interp.current_ctx = new_ctx_val
  defer interp.current_ctx = old_ctx

  if interp.ast.nodes[expr_idx].kind == .Hole {
    return eval(interp, expr_idx, env)
  }
  return eval_slot(interp, expr_idx, env)
}

// ---- function calls -----------------------------------------------------------

call_function :: proc(interp: ^Interpreter, fn: ^Function_Value, arg: Value) -> (Value, bool) {
  // Natives (§16's filesystem builtins) read `ctx` live off the call site -
  // no arg_stack/self_stack push (they evaluate no HashedBuild body, so neither
  // #arg nor #self can be observed inside one) and no context swap (the whole
  // point is that a wrapping `withctx` can restrict what they do from
  // outside; see SPEC.md §9's "Context & permissions").
  if fn.native != nil {
    return fn.native(interp, fn.native_closure, arg)
  }

  // A call costs native stack of its own, on top of the `eval` frames its body
  // spends - and a body can be as small as a single call, in which case those
  // frames alone badly under-count what the stack is actually doing. Charging
  // the call itself is what keeps one budget honest across body shapes; see
  // MAX_NEST_DEPTH.
  interp.nest_depth += 1
  defer interp.nest_depth -= 1
  if interp.nest_depth > MAX_NEST_DEPTH {
    return fail(interp, "evaluation nested too deeply (runaway recursion?)")
  }

  append(&interp.arg_stack, arg)
  defer pop(&interp.arg_stack)
  append(&interp.self_stack, Value(fn))
  defer pop(&interp.self_stack)
  // Restore the closure's own captured context for the call, then put back
  // whatever was active at the call site - see Interpreter.current_ctx.
  old_ctx := interp.current_ctx
  interp.current_ctx = fn.ctx
  defer interp.current_ctx = old_ctx
  return eval(interp, fn.body, fn.env)
}

// ---- guard chains: and/or/is (§8) ---------------------------------------------

// Returns (result, the scope accumulated so far, ok). `and`'s right side
// inherits the left's scope; `or`'s sides are independent, each inheriting
// from `env` (the parent), not from each other.
eval_guard_chain :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> (result: bool, out_env: ^Env, ok: bool) {
  n := interp.ast.nodes[node]
  if n.kind == .Binary_Expr {
    op := interp.ast.nodes[interp.ast.extra_children[n.children_start + 1]].kind
    left_idx := interp.ast.extra_children[n.children_start]
    right_idx := interp.ast.extra_children[n.children_start + 2]

    #partial switch op {
    case .Op_And:
      left_result, left_env, ok1 := eval_guard_chain(interp, left_idx, env)
      if !ok1 do return false, env, false
      if !left_result {
        // §2: and/or short-circuit ordinarily, but an async op on the side
        // that gets skipped must still be started and awaited to completion
        // (only its Boolean *result* is discarded) - only pay for the check
        // (and the extra walk) when that side actually contains async.
        if contains_async_anywhere(interp.ast, right_idx) {
          interp.discard_depth += 1
          _, _, rok := eval_guard_chain(interp, right_idx, left_env)
          interp.discard_depth -= 1
          if !rok do return false, env, false
        }
        return false, env, true
      }
      return eval_guard_chain(interp, right_idx, left_env)
    case .Op_Or:
      left_result, left_env, ok1 := eval_guard_chain(interp, left_idx, env)
      if !ok1 do return false, env, false
      if left_result {
        if contains_async_anywhere(interp.ast, right_idx) {
          interp.discard_depth += 1
          _, _, rok := eval_guard_chain(interp, right_idx, env)
          interp.discard_depth -= 1
          if !rok do return false, env, false
        }
        return true, left_env, true
      }
      return eval_guard_chain(interp, right_idx, env)
    case .Op_Is:
      subject_val, sok := eval(interp, left_idx, env)
      if !sok do return false, env, false
      subject_val, sok = concrete_value(interp, subject_val)
      if !sok do return false, env, false
      matched, new_env, mok := match_pattern(interp, right_idx, subject_val, env)
      if !mok do return false, env, false
      if matched do return true, new_env, true
      return false, env, true
    case .Op_Pipe:
      // Recurse into eval_guard_chain (not a plain eval) so that bindings
      // made by an `is` nested inside the piped-to guard chain still thread
      // through to whatever inherits from this condition (§8: "happy" is a
      // scope-child of the whole condition chain, pipe included).
      left_val, lok := eval_pipe_left(interp, left_idx, env)
      if !lok do return false, env, false
      append(&interp.arg_stack, left_val)
      defer pop(&interp.arg_stack)
      return eval_guard_chain(interp, right_idx, env)
    }
  }

  // A plain guard (a Boolean expression, or a function to auto-apply to the
  // current #arg per §8's "implicit function application in a guard position").
  val, ok1 := eval_slot(interp, node, env)
  if !ok1 do return false, env, false
  val, ok1 = concrete_value(interp, val)
  if !ok1 do return false, env, false
  if fn, is_fn := val.(^Function_Value); is_fn {
    if len(interp.arg_stack) == 0 {
      interp.error_message = "guard function has no piped value to apply to"
      return false, env, false
    }
    applied, aok := call_function(interp, fn, interp.arg_stack[len(interp.arg_stack) - 1])
    if !aok do return false, env, false
    applied, aok = concrete_value(interp, applied)
    if !aok do return false, env, false
    val = applied
  }
  b, is_bool := val.(bool)
  if !is_bool {
    interp.error_message = "guard must evaluate to a Boolean"
    return false, env, false
  }
  return b, env, true
}

// ---- then/else (§8) ------------------------------------------------------------

@(private = "file")
eval_then_or_else :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> (Value, bool) {
  n := interp.ast.nodes[node]
  if n.kind == .Then_Expr {
    cond_idx := interp.ast.extra_children[n.children_start]
    happy_idx := interp.ast.extra_children[n.children_start + 1]
    result, guard_env, ok := eval_guard_chain(interp, cond_idx, env)
    if !ok do return nil, false
    if !result do return fail(interp, "condition failed")
    return eval_slot(interp, happy_idx, guard_env)
  }

  // Else_Expr: children = [then_expr, bad_path]. Reach into the Then_Expr
  // directly (rather than treating it as an opaque sub-evaluation) so a guard
  // failure's partial scope is still available to bad_path, per §8.
  then_idx := interp.ast.extra_children[n.children_start]
  bad_idx := interp.ast.extra_children[n.children_start + 1]
  then_node := interp.ast.nodes[then_idx]
  cond_idx := interp.ast.extra_children[then_node.children_start]
  happy_idx := interp.ast.extra_children[then_node.children_start + 1]

  result, guard_env, ok := eval_guard_chain(interp, cond_idx, env)
  if !ok do return nil, false

  // §2: only the taken branch's *value* is used, but an async op inside the
  // untaken one still has to be started and awaited to completion (the
  // build-system framing: a download/write can't be abandoned mid-flight
  // just because its result turns out unneeded) - and if it fails, that
  // poisons the whole evaluation even though its value was never going to be
  // used. Only pay for this when the untaken branch actually contains async
  // anywhere; ordinary then/else stays exactly as short-circuiting as before.
  discarded_idx := bad_idx if result else happy_idx
  if contains_async_anywhere(interp.ast, discarded_idx) {
    interp.discard_depth += 1
    discarded_val, dok := eval_slot(interp, discarded_idx, guard_env)
    interp.discard_depth -= 1
    if !dok do return nil, false
    _, aok := concrete_value(interp, discarded_val)
    if !aok do return nil, false
  }

  if result do return eval_slot(interp, happy_idx, guard_env)
  return eval_slot(interp, bad_idx, guard_env)
}

// ---- sha256 (§15) ----------------------------------------------------------------

// §15: hashes a value, returning the digest base64-encoded as Utf8. This is
// §6's "every value is hashable" mechanism itself (hash.odin), not a second
// hash living alongside it - the same digest File equality is defined by (§3).
@(private = "file")
eval_sha256 :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> (Value, bool) {
  n := interp.ast.nodes[node]
  val, ok := eval_slot(interp, interp.ast.extra_children[n.children_start], env)
  if !ok do return nil, false
  // An operand that is still an async handle gets awaited first, exactly as
  // every other operator does - `sha256 async <expr>` hashes the result, not
  // the handle.
  val, ok = concrete_value(interp, val)
  if !ok do return nil, false

  // The interpreter goes along: a directory File's digest is read off the disk
  // the first time anything asks (§3), and that read needs this context's `io`
  // permission (§9). It is also what a Function's shape is read from.
  encoded, herr := value_digest_base64(val, interp)
  if herr.kind != .None {
    return fail(interp, fmt.tprintf("sha256: %s", hash_error_message(herr)))
  }
  return encoded, true
}

// §15: evaluates an expression once and remembers the answer, or hands back
// the answer an earlier run already stored. The cache lives on disk, in the
// directory `ctx.cache` writes to - see cache_store.odin for the layout,
// hash_function.odin for what a closure hashes as, and hash_implicit.odin
// for the part of the key a closure's digest cannot carry.
//
// **The key is computed before the expression runs**, which is the whole point:
// a hit must not have to evaluate anything. §15 pins what it is - the cached
// expression treated as a function, hashed as one - so that is exactly what is
// built here, a closure over the operand in the current environment and
// `ctx`. Its digest covers the code, the captured `ctx`, and the values of the
// names the code uses, so `cached (x + 1)` is a different entry for each `x`.
//
// **Gated by `ctx.permissions.io`** (§9), like §16's builtins and for the same
// reason: this reads and writes files. A denied `io` is a failure rather than a
// quiet fall-through to evaluating uncached, because the two differ in what
// gets written to disk, and silently doing the other one is not something a
// program should have to guess at.
//
// **Async is positional**, as §15 says. `cached async <expr>` is this
// procedure wrapped around an operand that evaluates on another thread: the
// await below is the "caching wrapper around it synchronous" half. `async
// cached <expr>` is the other placement, and needs nothing here - it is an
// Async_Expr whose body happens to be this one.
@(private = "file")
eval_cached :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> (Value, bool) {
  n := interp.ast.nodes[node]
  operand := interp.ast.extra_children[n.children_start]

  if !ctx_allows_io(interp) do return fail(interp, "cached: io permission not granted in the current context")

  cache, has_cache := cache_of_ctx(interp.current_ctx)
  if !has_cache {
    return fail(interp, "cached: the current context has no .cache (SPEC.md §9 - a hand-built ctx has to carry it over)")
  }

  key, herr := value_digest(new_function(interp, operand, env), interp)
  if herr.kind != .None do return fail(interp, fmt.tprintf("cached: %s", hash_error_message(herr)))
  key, herr = mix_implicit_reach(interp, operand, key)
  if herr.kind != .None do return fail(interp, fmt.tprintf("cached: %s", hash_error_message(herr)))
  key_name := cache_entry_name_for(key)

  if stored, found, msg := cache_lookup(cache, key_name); msg != "" {
    return fail(interp, fmt.tprintf("cached: %s", msg))
  } else if found {
    return stored, true
  }

  val, ok := eval_slot(interp, operand, env)
  if !ok do return nil, false
  val, ok = await_value(interp, val)
  if !ok do return nil, false

  stored, stored_ok, msg := cache_store(cache, key_name, val, interp)
  if !stored_ok do return fail(interp, fmt.tprintf("cached: %s", msg))
  return stored, true
}

// A closure captures its environment and its `ctx`, but `#arg`/`#self` (§9) are
// dynamic lookups into the interpreter's own stacks and are captured by
// neither - so the closure digest cannot see them, and the key has to. Without
// this, `let f func (cached (#arg + 1)); f 1` and `f 10` would be one entry.
//
// Only the levels the expression can actually reach are mixed in, and only when
// it reaches any at all: an expression that mentions no implicit name gets the
// closure digest untouched. See hash_implicit.odin for why a static bound on
// the reach is sound.
@(private = "file")
mix_implicit_reach :: proc(interp: ^Interpreter, operand: Node_Idx, key: Value_Digest) -> (Value_Digest, Hash_Fail) {
  max_arg, max_self := 0, 0
  implicit_reach(interp, operand, &max_arg, &max_self)
  if max_arg == 0 && max_self == 0 do return key, HASH_OK

  return implicit_reach_digest(
    key,
    top_of(interp.arg_stack[:], max_arg),
    top_of(interp.self_stack[:], max_self),
    interp,
  )
}

// The top `count` entries, innermost first, padded with `nothing` where the
// stack is shorter than the reach - so the shape of what gets mixed in depends
// only on the expression, never on how deep the program happens to be.
@(private = "file")
top_of :: proc(stack: []Value, count: int) -> []Value {
  out := make([]Value, count, context.temp_allocator)
  for i in 0 ..< count {
    idx := len(stack) - 1 - i
    out[i] = idx >= 0 ? stack[idx] : Nothing_Value{}
  }
  return out
}

// `ctx.cache`, if this context has one. §9 lets a program build a context by
// hand, and one built without carrying `.cache` over simply hasn't got a cache
// to use - so this is a question, not an assertion.
//
// Package-visible because `exec` (builtins_build.odin) asks the same question:
// its scratch directory lives under the cache's, so a run with no cache has
// nowhere to put one.
cache_of_ctx :: proc(ctx: Value) -> (^Cache_Value, bool) {
  t, is_table := ctx.(^Table_Value)
  if !is_table do return nil, false
  val, found := table_find(t, "cache")
  if !found do return nil, false
  cache, is_cache := val.(^Cache_Value)
  return cache, is_cache
}

// ---- check / static_check / error (§11) ----------------------------------------

@(private = "file")
eval_check :: proc(interp: ^Interpreter, node: Node_Idx, env: ^Env) -> (Value, bool) {
  n := interp.ast.nodes[node]
  cond_idx := interp.ast.extra_children[n.children_start]
  cond_val, cok := eval_slot(interp, cond_idx, env)
  if !cok do return nil, false
  cond_val, cok = concrete_value(interp, cond_val)
  if !cok do return nil, false
  cond_bool, is_bool := cond_val.(bool)
  if !is_bool do return fail(interp, "check condition must be a Boolean")

  has_msg := n.children_count == 3
  body_idx := interp.ast.extra_children[n.children_start + (2 if has_msg else 1)]

  if !cond_bool {
    if has_msg {
      msg_val, mok := eval_slot(interp, interp.ast.extra_children[n.children_start + 1], env)
      if mok do msg_val, mok = concrete_value(interp, msg_val)
      if mok {
        if s, is_str := msg_val.(string); is_str do return fail(interp, s)
      }
    }
    return fail(interp, "check failed")
  }
  return eval_slot(interp, body_idx, env)
}

// ---- pattern matching (§8) -------------------------------------------------------

match_pattern :: proc(interp: ^Interpreter, pattern_node: Node_Idx, value: Value, env: ^Env) -> (matched: bool, new_env: ^Env, ok: bool) {
  n := interp.ast.nodes[pattern_node]
  #partial switch n.kind {
  case .Pattern_Bind:
    sub_idx := interp.ast.extra_children[n.children_start]
    name_idx := interp.ast.extra_children[n.children_start + 1]
    m, sub_env, sok := match_pattern(interp, sub_idx, value, env)
    if !sok do return false, env, false
    if !m do return false, env, true
    // Ordinarily "<pattern> as <name>" binds the whole matched value. The one
    // exception is SPEC.md §8's "present [as <name>]" idiom - a tag-only
    // variant/optional pattern - which explicitly binds the *payload*, not
    // the enclosing one-entry Table.
    bind_val := value
    sub_node := interp.ast.nodes[sub_idx]
    if sub_node.kind == .Variant_Construct && sub_node.children_count == 1 {
      if t, is_table := value.(^Table_Value); is_table && len(t.entries) == 1 {
        bind_val = t.entries[0].value
      }
    }
    bound_env := env_make_child(sub_env)
    env_bind(bound_env, node_text(interp, name_idx), bind_val)
    return true, bound_env, true

  case .Hole:
    // An omitted pattern - §7's blank operand, in pattern position. It shows
    // up as the payload slot of `:.ok as v`, which parses as the variant
    // pattern `:.ok` with `<nothing> as v` inside it (`present as v` takes
    // the other shape, binding on the outside, which is why only the
    // explicit-tag spelling reached here). Matches anything and binds
    // nothing; the enclosing Pattern_Bind does the binding.
    return true, env, true

  case .Identifier:
    // A bare name in pattern position is a fresh binder: it matches any
    // value unconditionally and binds it to that name (standard destructuring
    // convention - not literally spelled out by §8, but needed for the
    // pattern grammar's own worked example, "y as z", to bind anything at all).
    bound_env := env_make_child(env)
    env_bind(bound_env, node_text(interp, pattern_node), value)
    return true, bound_env, true

  case .Table_Construct: // `empty` (§5) as a pattern - matches a zero-entry Table
    t, is_table := value.(^Table_Value)
    return is_table && len(t.entries) == 0, env, true

  case .Variant_Construct:
    t, is_table := value.(^Table_Value)
    if !is_table || len(t.entries) != 1 do return false, env, true
    key_idx := interp.ast.extra_children[n.children_start]
    key_node := interp.ast.nodes[key_idx]
    want_key: Value
    if key_node.kind == .Tag_Name {
      want_key = node_text(interp, key_idx)
    } else {
      k, kok := eval(interp, key_idx, env)
      if !kok do return false, env, false
      want_key = k
    }
    if !values_equal(t.entries[0].key, want_key) do return false, env, true
    if n.children_count < 2 do return true, env, true // tag-only, e.g. bare `present`
    return match_pattern(interp, interp.ast.extra_children[n.children_start + 1], t.entries[0].value, env)

  case .Table_Pattern:
    cur_env := env
    start := int(n.children_start)
    for i in 0 ..< int(n.children_count) {
      m, next_env, sok := match_table_selector(interp, interp.ast.extra_children[start + i], value, cur_env)
      if !sok do return false, env, false
      if !m do return false, env, true
      cur_env = next_env
    }
    return true, cur_env, true

  case .Table_Pattern_Sequence:
    t, is_table := value.(^Table_Value)
    if !is_table do return false, env, true
    n_val := parse_number_literal(node_text(interp, interp.ast.extra_children[n.children_start]))
    want_n, is_int := n_val.(i64)
    if !is_int do return false, env, false
    if i64(len(t.entries)) != want_n do return false, env, true
    for i in 1 ..= int(want_n) {
      if _, found := table_find(t, i64(i)); !found do return false, env, true
    }
    cur_env := env
    for i in 1 ..< int(n.children_count) {
      sel_idx := interp.ast.extra_children[int(n.children_start) + i]
      m, next_env, sok := match_table_selector(interp, sel_idx, value, cur_env)
      if !sok do return false, env, false
      if !m do return false, env, true
      cur_env = next_env
    }
    return true, cur_env, true

  case .MISSING_TOKEN, .ERROR_UNRECOGNIZED:
    return false, env, false
  }

  // Fallback: a literal-value pattern - evaluate as an ordinary expression and
  // compare structurally. Not explicitly re-confirmed by §8's resolution, but
  // needed for `is 5`/`is "ok"` to mean anything at all.
  pat_val, pok := eval(interp, pattern_node, env)
  if !pok do return false, env, false
  return values_equal(pat_val, value), env, true
}

@(private = "file")
match_table_selector :: proc(interp: ^Interpreter, sel_node: Node_Idx, subject: Value, env: ^Env) -> (matched: bool, new_env: ^Env, ok: bool) {
  n := interp.ast.nodes[sel_node]
  #partial switch n.kind {
  case .Pattern_Bind:
    base_idx := interp.ast.extra_children[n.children_start]
    name_idx := interp.ast.extra_children[n.children_start + 1]
    matched_val, mok := select_table_value(interp, base_idx, subject, env)
    if !mok do return false, env, true
    bound_env := env_make_child(env)
    env_bind(bound_env, node_text(interp, name_idx), matched_val)
    return true, bound_env, true
  case .Table_Pattern_Field, .Table_Pattern_Index:
    _, mok := select_table_value(interp, sel_node, subject, env)
    return mok, env, true
  }
  return false, env, false
}

// The value a `.field`/`[expr]` selector refers to within `subject`, if present.
@(private = "file")
select_table_value :: proc(interp: ^Interpreter, sel_node: Node_Idx, subject: Value, env: ^Env) -> (Value, bool) {
  n := interp.ast.nodes[sel_node]
  t, is_table := subject.(^Table_Value)
  if !is_table do return nil, false
  #partial switch n.kind {
  case .Table_Pattern_Field:
    name_idx := interp.ast.extra_children[n.children_start]
    name_node := interp.ast.nodes[name_idx]
    key: Value = node_text(interp, name_idx)
    if name_node.kind == .Number_Literal do key = parse_number_literal(node_text(interp, name_idx))
    return table_find(t, key)
  case .Table_Pattern_Index:
    key, kok := eval(interp, interp.ast.extra_children[n.children_start], env)
    if !kok do return nil, false
    return table_find(t, key)
  }
  return nil, false
}
