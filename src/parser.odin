package hashedbuild

// Recursive-descent parser covering the whole of SPEC.md's expression grammar
// (CST/AST only - no evaluation). Read this file top-down: `parse_expr` is the
// single entry point every "hard boundary slot" (§7) - a happy_path, a bad_path,
// an `as`-body, a Table entry's value, a parenthesized group, a keyword-prefix's
// operand - recurses back into, giving each of those slots the full grammar.
//
// Precedence, loosest to tightest (the spec never wrote one down; these are the
// choices this parser makes, informed by the one concrete example the spec does
// give - `object |> (c1 and is p1 and c2) then happy else bad` needs those parens,
// which only makes sense if `|>` binds tighter than `and`):
//
//   let-bind  >  then/else  >  or  >  and  >  |>  >  concat  >
//   comparison (incl. `is`)  >  +/-  >  * / %  >  unary -  >  application  >
//   postfix (. [] !: !.)  >  primary
//
// Omission (§7): a *hole* - a deliberately blank operand - is a normal, valid
// parse result (Node_Kind.Hole), not an error. It shows up anywhere a primary
// is expected but the token there is actually an operator or a closing/
// terminating token instead (see `is_hole_signal`). This is completely separate
// from `error`/`check`'s *optional* trailing arguments, which are a different
// concept (an omitted optional parameter, not an omitted function argument) and
// are handled by explicitly peeking for `starts_primary` rather than by falling
// into the hole path.

Parser :: struct {
  lexer: Lexer,
  ast:   ^ast_t,
  cur:   Token,
}

parse :: proc(source: source_t, ref: ast_t) -> (res: ast_t) {
  p := Parser{lexer = lexer_make(source)}
  p.ast = &res
  p.cur = next_token(&p.lexer)

  root_expr, ok := parse_expr(&p)
  if !ok {
    root_expr = push_missing(&p, p.cur.span, "expected an expression")
  }
  if p.cur.kind != .End_Of_File {
    add_error(&p, p.cur.span, "unexpected trailing input")
    for p.cur.kind != .End_Of_File do advance(&p)
  }

  start, count := push_children(&res, []Node_Idx{root_expr})
  res.root = push_node(&res, Node{
    kind = .Root,
    flags = node_flags(&res, root_expr),
    span = res.nodes[root_expr].span,
    children_start = start,
    children_count = count,
  })
  return
}

// ---- token stream helpers -------------------------------------------------

@(private = "file")
advance :: proc(p: ^Parser) -> Token {
  t := p.cur
  p.cur = next_token(&p.lexer)
  return t
}

// One-token lookahead, needed only to tell `let rec <name> ...` from a `let`
// binding an ordinary name spelled "rec" (SPEC.md §10's contextual-keyword
// rule). Lexing is pure and the Lexer is a plain {source, pos} value, so a
// copy re-lexes the next token without disturbing the real stream.
@(private = "file")
peek_kind :: proc(p: ^Parser) -> Node_Kind {
  lookahead := p.lexer
  return next_token(&lookahead).kind
}

@(private = "file")
expect :: proc(p: ^Parser, kind: Node_Kind, what: string) -> (span: Span, ok: bool) {
  if p.cur.kind == kind {
    t := advance(p)
    return t.span, true
  }
  add_error(p, p.cur.span, what)
  return Span{p.cur.span.start, p.cur.span.start}, false
}

// Tokens that can open a fresh primary expression - gates function-application
// (juxtaposition) lookahead.
@(private = "file")
starts_primary :: proc(kind: Node_Kind) -> bool {
  #partial switch kind {
  case .Identifier, .Number_Literal, .String_Literal, .Nothing_Literal, .Implicit_Name, .Ctx_Expr,
       .Left_Paren, .Left_Brace, .Table_Construct, .Variant_Construct,
       .Sigil_ColonColon, .Sigil_ColonDot,
       .Func_Expr, .AsFunc_Expr, .AsFuncStatic_Expr, .Check_Expr, .StaticCheck_Expr,
       .Error_Expr, .Import_Expr, .Sha256_Expr, .Cached_Expr,
       .Async_Expr:
    return true
  }
  return false
}

// Tokens that mean "leave this operand blank" (§7) rather than "syntax error" -
// every binary/postfix operator (a hole can sit on either side of any of them),
// `as` (the bound expression in `<expr> as <name> <body>` can be omitted), and
// anything that closes/terminates the enclosing construct. `Op_Minus` is
// deliberately absent - it's consumed by parse_unary before parse_primary ever
// sees it, per SPEC.md §4's already-resolved unary-minus-vs-omission rule.
@(private = "file")
is_hole_signal :: proc(kind: Node_Kind) -> bool {
  #partial switch kind {
  case .Op_Plus, .Op_Star, .Op_Slash, .Op_Percent,
       .Op_EqEq, .Op_Gt, .Op_GtEq, .Op_Lt, .Op_LtEq,
       .Op_And, .Op_Or, .Op_Concat, .Op_Is, .Op_Pipe,
       .Op_Dot, .Op_Bracket, .Op_CheckColon, .Op_CheckDot,
       .Kw_As, .Kw_WithCtx, .Kw_ChCtx,
       .Right_Paren, .Right_Bracket, .Right_Brace, .Comma, .Semicolon, .End_Of_File:
    return true
  }
  return false
}

// Every keyword this parser recognizes is a *contextual* one (SPEC.md has no
// notion of reserving words globally): each is special only in the specific
// syntactic position that looks for it (an infix `and`, a primary-starting
// `func`, ...). Anywhere the grammar just wants a bare name - a `.field`, a
// `:.tag`/`!.tag`, an `as <name>` target - any of these tokens is just as valid
// a name as a plain Identifier, since lexically it *is* one; only the parser's
// own position-specific checks give it special meaning elsewhere.
@(private = "file")
is_name_token :: proc(kind: Node_Kind) -> bool {
  #partial switch kind {
  case .Identifier,
       .Op_And, .Op_Or, .Op_Concat, .Op_Is,
       .Kw_Then, .Kw_Else, .Kw_As, .Kw_Let, .Kw_Rec, .Kw_WithCtx, .Kw_ChCtx,
       .Func_Expr, .AsFunc_Expr, .AsFuncStatic_Expr, .Check_Expr, .StaticCheck_Expr,
       .Error_Expr, .Import_Expr, .Sha256_Expr, .Cached_Expr,
       .Async_Expr, .Nothing_Literal, .Table_Construct, .Variant_Construct, .Ctx_Expr:
    return true
  }
  return false
}

// Consumes the current token as a plain name, regardless of which keyword (if
// any) it would otherwise mean - used for `.field`/`as <name>` positions.
@(private = "file")
push_name_leaf :: proc(p: ^Parser) -> Node_Idx {
  t := advance(p)
  return push_node(p.ast, Node{kind = .Identifier, span = t.span})
}

// Same, but tagged `Tag_Name` - used for `:.name`/`!.name` positions, where the
// name is a literal tag spelling rather than a variable reference.
@(private = "file")
push_tag_name_leaf :: proc(p: ^Parser) -> Node_Idx {
  t := advance(p)
  return push_node(p.ast, Node{kind = .Tag_Name, span = t.span})
}

// ---- ast construction helpers ----------------------------------------------

@(private = "file")
push_node :: proc(ast: ^ast_t, node: Node) -> Node_Idx {
  idx := Node_Idx(len(ast.nodes))
  append(&ast.nodes, node)
  return idx
}

@(private = "file")
push_children :: proc(ast: ^ast_t, children: []Node_Idx) -> (start: u32, count: u16) {
  start = u32(len(ast.extra_children))
  for c in children do append(&ast.extra_children, c)
  count = u16(len(children))
  return
}

@(private = "file")
node_flags :: proc(ast: ^ast_t, children: ..Node_Idx) -> (flags: Node_Flags) {
  for c in children {
    if .Has_Error in ast.nodes[c].flags do flags += {.Has_Error}
  }
  return
}

@(private = "file")
push_leaf :: proc(p: ^Parser, t: Token) -> Node_Idx {
  return push_node(p.ast, Node{kind = t.kind, span = t.span})
}

@(private = "file")
push_binary :: proc(p: ^Parser, left: Node_Idx, op: Node_Idx, right: Node_Idx) -> Node_Idx {
  span := Span{p.ast.nodes[left].span.start, p.ast.nodes[right].span.end}
  start, count := push_children(p.ast, []Node_Idx{left, op, right})
  return push_node(p.ast, Node{
    kind = .Binary_Expr,
    flags = node_flags(p.ast, left, op, right),
    span = span,
    children_start = start,
    children_count = count,
  })
}

// Wraps one child under `kind`, spanning from `kw_span`'s start to the child's end -
// the shape shared by func/asfunc/asfuncstatic/import/sha256/cached/async.
@(private = "file")
push_wrapped :: proc(p: ^Parser, kind: Node_Kind, kw_span: Span, child: Node_Idx) -> Node_Idx {
  start, count := push_children(p.ast, []Node_Idx{child})
  span := Span{kw_span.start, p.ast.nodes[child].span.end}
  return push_node(p.ast, Node{kind = kind, flags = node_flags(p.ast, child), span = span, children_start = start, children_count = count})
}

@(private = "file")
add_error :: proc(p: ^Parser, span: Span, message: string) {
  append(&p.ast.errors, Parse_Error{span = span, message = message})
}

@(private = "file")
push_error_node :: proc(p: ^Parser, span: Span, message: string) -> Node_Idx {
  add_error(p, span, message)
  return push_node(p.ast, Node{kind = .ERROR_UNRECOGNIZED, flags = {.Has_Error}, span = span})
}

@(private = "file")
push_missing :: proc(p: ^Parser, span: Span, message: string) -> Node_Idx {
  add_error(p, span, message)
  pos := span.start
  return push_node(p.ast, Node{kind = .MISSING_TOKEN, flags = {.Has_Error, .Is_Missing}, span = Span{pos, pos}})
}

@(private = "file")
push_hole :: proc(p: ^Parser) -> Node_Idx {
  pos := p.cur.span.start
  return push_node(p.ast, Node{kind = .Hole, span = Span{pos, pos}})
}

// ---- expression grammar, loosest to tightest -------------------------------

parse_expr :: proc(p: ^Parser) -> (Node_Idx, bool) {
  return parse_context_ops(p)
}

// `<expr> withctx <new_ctx>` / `<expr> chctx <fn>` (§7/§9) - the loosest
// operators in the grammar, chaining left-associatively with each other:
// `x withctx c1 chctx c2` is `(x withctx c1) chctx c2`. `<expr>` is the
// hard-boundary slot (may be a Hole, making the whole thing a function
// evaluated under the new context). The right side of each parses one level
// tighter (`parse_let_bind`, not `parse_expr`) so it doesn't re-enter this
// same loop and swallow a *sibling* withctx/chctx suffix meant for the
// growing left side instead - same greedy-tail hazard as a let-bind's body
// (which still recurses through the full grammar, and so still absorbs a
// *trailing* context-op the way the gotcha in SPEC.md §7 describes).
@(private = "file")
parse_context_ops :: proc(p: ^Parser) -> (Node_Idx, bool) {
  left, ok := parse_let_bind(p)
  if !ok do return left, false

  for {
    kw: Node_Kind
    #partial switch p.cur.kind {
    case .Kw_WithCtx: kw = .With_Ctx_Expr
    case .Kw_ChCtx: kw = .ChCtx_Expr
    case: return left, true
    }

    advance(p)
    right, rok := parse_let_bind(p)
    if !rok {
      msg := "expected a context expression after 'withctx'" if kw == .With_Ctx_Expr else "expected a context-change function after 'chctx'"
      right = push_missing(p, p.cur.span, msg)
    }

    start, count := push_children(p.ast, []Node_Idx{left, right})
    span := Span{p.ast.nodes[left].span.start, p.ast.nodes[right].span.end}
    left = push_node(p.ast, Node{
      kind = kw, flags = node_flags(p.ast, left, right),
      span = span, children_start = start, children_count = count,
    })
  }
}

// `let [rec] <name> <expr>; <body>` (§7/§10) - the language's one binding
// form. Unlike the `as`-bind it replaced, this is a *prefix* construct: it
// takes no left operand, so it starts an expression rather than continuing
// one, and the `;` hard-terminates `<expr>`.
//
// That terminator is the whole reason the bound value parses at `parse_expr`
// (the top of the grammar) rather than one level tighter the way the old
// `as`-bind's did: with a `;` to stop at, a `withctx`/`chctx` on the bound
// side can no longer escape past the binding, so `let a 9 withctx c; a`
// means what it reads as, with no parens needed. The body is still a greedy
// tail through the full grammar, so a *trailing* context op is still absorbed
// into it - see SPEC.md §7's gotcha, and parse_context_ops above.
//
// The cost of that terminator: a `let` nested directly in the *bound-value*
// position steals the outer `;` for itself, so it needs parens -
// `let a (let b 1; b + 1); a`. A `let` in *body* position needs none, which
// is the case that actually comes up (`let a 1; let b 2; a + b`).
//
// `rec` is contextual like every other keyword here (§10): it only reads as
// the recursion marker when a name follows it, so `let rec 5; 42` still binds
// an ordinary name spelled "rec". (Reading such a name back is a separate
// matter and still doesn't work - a bare `rec` in value position is a
// keyword, exactly as a bare `then` is.)
@(private = "file")
parse_let_bind :: proc(p: ^Parser) -> (Node_Idx, bool) {
  if p.cur.kind != .Kw_Let do return parse_then_chain(p)
  start_pos := p.cur.span.start
  advance(p)

  is_rec := false
  if p.cur.kind == .Kw_Rec && is_name_token(peek_kind(p)) {
    is_rec = true
    advance(p)
  }

  name: Node_Idx
  if is_name_token(p.cur.kind) {
    name = push_name_leaf(p)
  } else {
    name = push_missing(p, p.cur.span, "expected a name after 'let'")
  }

  // A bare `;` here is an omitted bound value, not an error: `is_hole_signal`
  // lists Semicolon, so parse_expr hands back a zero-width Hole and §7 rule 2
  // turns the whole Let_Bind into a function of it.
  bound, bound_ok := parse_expr(p)
  if !bound_ok do bound = push_missing(p, p.cur.span, "expected a bound value after 'let <name>'")
  expect(p, .Semicolon, "expected ';' after the bound value in 'let <name> <value>;'")

  body, body_ok := parse_expr(p)
  if !body_ok do body = push_missing(p, p.cur.span, "expected a body after 'let <name> <value>;'")

  flags := node_flags(p.ast, bound, name, body)
  if is_rec do flags += {.Is_Rec}
  start, count := push_children(p.ast, []Node_Idx{bound, name, body})
  return push_node(p.ast, Node{
    kind = .Let_Bind, flags = flags,
    span = Span{start_pos, p.ast.nodes[body].span.end}, children_start = start, children_count = count,
  }), true
}

// `<condition> then <happy_path>` optionally followed immediately by
// `else <bad_path>` (§8) - `else` only ever attaches to a `then` it directly follows.
@(private = "file")
parse_then_chain :: proc(p: ^Parser) -> (Node_Idx, bool) {
  cond, ok := parse_or(p)
  if !ok do return cond, false
  if p.cur.kind != .Kw_Then do return cond, true

  advance(p)
  happy, hok := parse_expr(p)
  if !hok do happy = push_missing(p, p.cur.span, "expected a happy path after 'then'")
  start, count := push_children(p.ast, []Node_Idx{cond, happy})
  span := Span{p.ast.nodes[cond].span.start, p.ast.nodes[happy].span.end}
  node := push_node(p.ast, Node{
    kind = .Then_Expr, flags = node_flags(p.ast, cond, happy),
    span = span, children_start = start, children_count = count,
  })

  if p.cur.kind == .Kw_Else {
    advance(p)
    bad, bok := parse_expr(p)
    if !bok do bad = push_missing(p, p.cur.span, "expected a bad path after 'else'")
    start2, count2 := push_children(p.ast, []Node_Idx{node, bad})
    span2 := Span{p.ast.nodes[node].span.start, p.ast.nodes[bad].span.end}
    node = push_node(p.ast, Node{
      kind = .Else_Expr, flags = node_flags(p.ast, node, bad),
      span = span2, children_start = start2, children_count = count2,
    })
  }
  return node, true
}

@(private = "file")
parse_or :: proc(p: ^Parser) -> (Node_Idx, bool) {
  left, ok := parse_and(p)
  if !ok do return left, false
  for p.cur.kind == .Op_Or {
    op := push_leaf(p, advance(p))
    right, rok := parse_and(p)
    if !rok do right = push_missing(p, p.cur.span, "expected an operand after 'or'")
    left = push_binary(p, left, op, right)
  }
  return left, true
}

@(private = "file")
parse_and :: proc(p: ^Parser) -> (Node_Idx, bool) {
  left, ok := parse_pipe(p)
  if !ok do return left, false
  for p.cur.kind == .Op_And {
    op := push_leaf(p, advance(p))
    right, rok := parse_pipe(p)
    if !rok do right = push_missing(p, p.cur.span, "expected an operand after 'and'")
    left = push_binary(p, left, op, right)
  }
  return left, true
}

// `<value> |> <function>` (§7/§8). Binds tighter than and/or so that piping
// into a multi-term guard chain needs explicit parens, matching the spec's own
// canonical example: `object |> (c1 and is p1 and c2) then happy else bad`.
@(private = "file")
parse_pipe :: proc(p: ^Parser) -> (Node_Idx, bool) {
  left, ok := parse_concat(p)
  if !ok do return left, false
  for p.cur.kind == .Op_Pipe {
    op := push_leaf(p, advance(p))
    right, rok := parse_concat(p)
    if !rok do right = push_missing(p, p.cur.span, "expected a function after '|>'")
    left = push_binary(p, left, op, right)
  }
  return left, true
}

@(private = "file")
parse_concat :: proc(p: ^Parser) -> (Node_Idx, bool) {
  left, ok := parse_comparison(p)
  if !ok do return left, false
  for p.cur.kind == .Op_Concat {
    op := push_leaf(p, advance(p))
    right, rok := parse_comparison(p)
    if !rok do right = push_missing(p, p.cur.span, "expected an operand after 'concat'")
    left = push_binary(p, left, op, right)
  }
  return left, true
}

@(private = "file")
is_comparison_op :: proc(kind: Node_Kind) -> bool {
  #partial switch kind {
  case .Op_EqEq, .Op_Gt, .Op_GtEq, .Op_Lt, .Op_LtEq:
    return true
  }
  return false
}

// `is` (§8) sits alongside the comparison operators, but its right side is a
// *pattern* (§8's resolved pattern grammar), not an ordinary expression.
@(private = "file")
parse_comparison :: proc(p: ^Parser) -> (Node_Idx, bool) {
  left, ok := parse_additive(p)
  if !ok do return left, false
  for is_comparison_op(p.cur.kind) || p.cur.kind == .Op_Is {
    is_pattern := p.cur.kind == .Op_Is
    op := push_leaf(p, advance(p))
    right: Node_Idx
    rok: bool
    if is_pattern {
      right, rok = parse_pattern(p)
    } else {
      right, rok = parse_additive(p)
    }
    if !rok do right = push_missing(p, p.cur.span, "expected an operand")
    left = push_binary(p, left, op, right)
  }
  return left, true
}

@(private = "file")
parse_additive :: proc(p: ^Parser) -> (Node_Idx, bool) {
  left, ok := parse_multiplicative(p)
  if !ok do return left, false
  for p.cur.kind == .Op_Plus || p.cur.kind == .Op_Minus {
    op := push_leaf(p, advance(p))
    right, rok := parse_multiplicative(p)
    if !rok do right = push_missing(p, p.cur.span, "expected an operand")
    left = push_binary(p, left, op, right)
  }
  return left, true
}

@(private = "file")
parse_multiplicative :: proc(p: ^Parser) -> (Node_Idx, bool) {
  left, ok := parse_unary(p)
  if !ok do return left, false
  for p.cur.kind == .Op_Star || p.cur.kind == .Op_Slash || p.cur.kind == .Op_Percent {
    op := push_leaf(p, advance(p))
    right, rok := parse_unary(p)
    if !rok do right = push_missing(p, p.cur.span, "expected an operand")
    left = push_binary(p, left, op, right)
  }
  return left, true
}

// SPEC.md §4: unary minus reads exactly as in ordinary math, binding tighter
// than every binary operator - but looser than application (`-f x` = `-(f x)`).
@(private = "file")
parse_unary :: proc(p: ^Parser) -> (Node_Idx, bool) {
  if p.cur.kind == .Op_Minus {
    op := push_leaf(p, advance(p))
    operand, ok := parse_unary(p)
    if !ok do operand = push_missing(p, p.cur.span, "expected an operand after unary '-'")
    start, count := push_children(p.ast, []Node_Idx{op, operand})
    span := Span{p.ast.nodes[op].span.start, p.ast.nodes[operand].span.end}
    return push_node(p.ast, Node{
      kind = .Unary_Expr,
      flags = node_flags(p.ast, op, operand),
      span = span,
      children_start = start,
      children_count = count,
    }), true
  }
  return parse_application(p)
}

// Juxtaposition: `f x y` = `(f x) y`. A bare `-` never starts a new argument
// here - it always falls through to parse_additive as binary minus instead, so
// `f -x` is `f - x`, not `f (-x)`.
@(private = "file")
parse_application :: proc(p: ^Parser) -> (Node_Idx, bool) {
  left, ok := parse_postfix(p)
  if !ok do return left, false
  for starts_primary(p.cur.kind) {
    call_span := p.cur.span // synthetic operator leaf marking the application site
    op := push_node(p.ast, Node{kind = .Op_Call, span = Span{call_span.start, call_span.start}})
    right, rok := parse_postfix(p)
    if !rok do break // shouldn't happen given the starts_primary guard, but stay safe
    left = push_binary(p, left, op, right)
  }
  return left, true
}

@(private = "file")
parse_postfix :: proc(p: ^Parser) -> (Node_Idx, bool) {
  left, ok := parse_primary(p)
  if !ok do return left, false
  for {
    #partial switch p.cur.kind {
    case .Op_Dot:
      op := push_leaf(p, advance(p))
      if p.cur.kind == .Number_Literal {
        right := push_leaf(p, advance(p))
        left = push_binary(p, left, op, right)
      } else if is_name_token(p.cur.kind) {
        right := push_name_leaf(p)
        left = push_binary(p, left, op, right)
      } else {
        right := push_missing(p, p.cur.span, "expected a field name or index after '.'")
        left = push_binary(p, left, op, right)
      }
    case .Left_Bracket:
      open := advance(p)
      op := push_node(p.ast, Node{kind = .Op_Bracket, span = open.span})
      index, iok := parse_expr(p)
      if !iok do index = push_missing(p, p.cur.span, "expected an index expression")
      expect(p, .Right_Bracket, "expected ']'")
      left = push_binary(p, left, op, index)
    case .Op_CheckColon: // `subject !: key_expr` (§5) - dynamic-key check-or-throw
      op := push_leaf(p, advance(p))
      key, kok := parse_postfix(p)
      if !kok do key = push_missing(p, p.cur.span, "expected a key expression after '!:'")
      left = push_binary(p, left, op, key)
    case .Op_CheckDot: // `subject !.name` (§5) - static-tag check-or-throw
      op := push_leaf(p, advance(p))
      name: Node_Idx
      if is_name_token(p.cur.kind) {
        name = push_tag_name_leaf(p)
      } else {
        name = push_missing(p, p.cur.span, "expected a tag name after '!.'")
      }
      left = push_binary(p, left, op, name)
    case:
      return left, true
    }
  }
}

@(private = "file")
parse_primary :: proc(p: ^Parser) -> (Node_Idx, bool) {
  #partial switch p.cur.kind {
  case .Identifier, .Number_Literal, .String_Literal, .Nothing_Literal, .Implicit_Name, .Ctx_Expr:
    return push_leaf(p, advance(p)), true

  case .Left_Paren:
    advance(p)
    inner, ok := parse_expr(p)
    if !ok do inner = push_missing(p, p.cur.span, "expected an expression inside '(...)'")
    expect(p, .Right_Paren, "expected ')'")
    return inner, true

  case .Left_Brace:
    return parse_table(p)

  case .Table_Construct: // the `empty` keyword (§5) - desugars to a zero-entry Table_Construct
    t := advance(p)
    return push_node(p.ast, Node{kind = .Table_Construct, span = t.span}), true

  case .Variant_Construct: // the `present` keyword (§5) - desugars to `:.present <value>`
    return parse_present_construct(p), true

  case .Sigil_ColonColon, .Sigil_ColonDot: // `::key value` / `:.name value` (§5)
    return parse_variant_construct(p), true

  case .Func_Expr:
    kw := advance(p)
    body, bok := parse_expr(p)
    if !bok do body = push_missing(p, p.cur.span, "expected a function body after 'func'")
    return push_wrapped(p, .Func_Expr, kw.span, body), true

  case .AsFunc_Expr, .AsFuncStatic_Expr, .Import_Expr, .Sha256_Expr, .Cached_Expr,
       .Async_Expr:
    kw := advance(p)
    body, bok := parse_expr(p)
    if !bok do body = push_missing(p, p.cur.span, "expected an expression")
    return push_wrapped(p, kw.kind, kw.span, body), true

  case .Error_Expr: // `error [msg]` (§11) - msg is a genuinely optional argument,
                     // not an omission-hole, so peek for a real expression start first.
    kw := advance(p)
    if starts_primary(p.cur.kind) || p.cur.kind == .Op_Minus {
      msg, mok := parse_expr(p)
      if mok do return push_wrapped(p, .Error_Expr, kw.span, msg), true
    }
    return push_node(p.ast, Node{kind = .Error_Expr, span = kw.span}), true

  case .Check_Expr, .StaticCheck_Expr:
    return parse_check(p), true
  }

  if is_hole_signal(p.cur.kind) do return push_hole(p), true
  return push_error_node(p, p.cur.span, "unexpected token"), false
}

// ---- keyword-prefix constructs with unusual shapes -------------------------

// `::<key-expr> <value>` (dynamic key) / `:.<name> <value>` (static tag), §5.
@(private = "file")
parse_variant_construct :: proc(p: ^Parser) -> Node_Idx {
  sigil := advance(p)
  key: Node_Idx
  if sigil.kind == .Sigil_ColonDot {
    if is_name_token(p.cur.kind) {
      key = push_tag_name_leaf(p)
    } else {
      key = push_missing(p, p.cur.span, "expected a tag name after ':.'")
    }
  } else {
    k, kok := parse_postfix(p)
    if !kok do k = push_missing(p, p.cur.span, "expected a key expression after '::'")
    key = k
  }
  value, vok := parse_expr(p)
  if !vok do value = push_missing(p, p.cur.span, "expected a payload value")
  start, count := push_children(p.ast, []Node_Idx{key, value})
  span := Span{sigil.span.start, p.ast.nodes[value].span.end}
  return push_node(p.ast, Node{
    kind = .Variant_Construct, flags = node_flags(p.ast, key, value),
    span = span, children_start = start, children_count = count,
  })
}

// `present <value>` - sugar for `:.present <value>` (§5).
@(private = "file")
parse_present_construct :: proc(p: ^Parser) -> Node_Idx {
  kw := advance(p)
  key := push_node(p.ast, Node{kind = .Tag_Name, span = kw.span})
  value, vok := parse_expr(p)
  if !vok do value = push_missing(p, p.cur.span, "expected a payload value after 'present'")
  start, count := push_children(p.ast, []Node_Idx{key, value})
  span := Span{kw.span.start, p.ast.nodes[value].span.end}
  return push_node(p.ast, Node{
    kind = .Variant_Construct, flags = node_flags(p.ast, key, value),
    span = span, children_start = start, children_count = count,
  })
}

// `check(cond, [error_msg]) body` / `static_check(cond, [error_msg]) body` (§11).
@(private = "file")
parse_check :: proc(p: ^Parser) -> Node_Idx {
  kw := advance(p)
  expect(p, .Left_Paren, "expected '(' after 'check'/'static_check'")

  cond, cok := parse_expr(p)
  if !cok do cond = push_missing(p, p.cur.span, "expected a condition")

  children := make([dynamic]Node_Idx, 0, 3)
  defer delete(children)
  append(&children, cond)
  if p.cur.kind == .Comma {
    advance(p)
    msg, mok := parse_expr(p)
    if !mok do msg = push_missing(p, p.cur.span, "expected an error message")
    append(&children, msg)
  }
  expect(p, .Right_Paren, "expected ')'")

  body, bok := parse_expr(p)
  if !bok do body = push_missing(p, p.cur.span, "expected a body after 'check(...)'")
  append(&children, body)

  start, count := push_children(p.ast, children[:])
  flags := node_flags(p.ast, ..children[:])
  span := Span{kw.span.start, p.ast.nodes[body].span.end}
  return push_node(p.ast, Node{kind = kw.kind, flags = flags, span = span, children_start = start, children_count = count})
}

// ---- Table construction (SPEC.md §5) ---------------------------------------
//
// `{ .field = value, [expr] = value, ... }` (map-style) or `{ value1, value2, ... }`
// (sequence-style). Mixing the two in one literal is an error - the spec leaves
// open whether that must be a syntax-level error, so this pilot treats it as one
// for simplicity (a single Parse_Error, parsing continues either way).

@(private = "file")
Table_Shape :: enum { Unknown, Map, Sequence }

@(private = "file")
parse_table :: proc(p: ^Parser) -> (Node_Idx, bool) {
  open := advance(p) // Left_Brace
  entries := make([dynamic]Node_Idx, 0, 4)
  defer delete(entries)
  shape := Table_Shape.Unknown
  has_error := false

  for p.cur.kind != .Right_Brace && p.cur.kind != .End_Of_File {
    entry, this_shape := parse_table_element(p)
    if shape == .Unknown {
      shape = this_shape
    } else if shape != this_shape {
      add_error(p, p.ast.nodes[entry].span, "cannot mix key/value and bare-value entries in one Table literal")
      has_error = true
    }
    append(&entries, entry)
    if p.cur.kind == .Comma {
      advance(p)
    } else {
      break
    }
  }

  close_span, close_ok := expect(p, .Right_Brace, "expected '}'")
  if !close_ok do has_error = true

  end := close_span.end
  if len(entries) > 0 && end < p.ast.nodes[entries[len(entries) - 1]].span.end {
    end = p.ast.nodes[entries[len(entries) - 1]].span.end
  }

  start, count := push_children(p.ast, entries[:])
  flags := node_flags(p.ast, ..entries[:])
  if has_error do flags += {.Has_Error}
  return push_node(p.ast, Node{
    kind = .Table_Construct,
    flags = flags,
    span = Span{open.span.start, end},
    children_start = start,
    children_count = count,
  }), true
}

// One `.field = value` / `[expr] = value` / bare `value` entry.
@(private = "file")
parse_table_element :: proc(p: ^Parser) -> (Node_Idx, Table_Shape) {
  if p.cur.kind == .Op_Dot {
    dot := advance(p)
    key: Node_Idx
    if is_name_token(p.cur.kind) {
      key = push_name_leaf(p)
    } else {
      key = push_missing(p, p.cur.span, "expected a field name after '.'")
    }
    _, eq_ok := expect(p, .Op_Eq, "expected '=' after '.field'")
    value, vok := parse_expr(p)
    if !vok do value = push_missing(p, p.cur.span, "expected a value after '='")
    span := Span{dot.span.start, p.ast.nodes[value].span.end}
    start, count := push_children(p.ast, []Node_Idx{key, value})
    flags := node_flags(p.ast, key, value)
    if !eq_ok do flags += {.Has_Error}
    return push_node(p.ast, Node{kind = .Table_Entry, flags = flags, span = span, children_start = start, children_count = count}), .Map
  }

  if p.cur.kind == .Left_Bracket {
    open := advance(p)
    key, kok := parse_expr(p)
    if !kok do key = push_missing(p, p.cur.span, "expected a key expression inside '[...]'")
    expect(p, .Right_Bracket, "expected ']'")
    _, eq_ok := expect(p, .Op_Eq, "expected '=' after '[expr]'")
    value, vok := parse_expr(p)
    if !vok do value = push_missing(p, p.cur.span, "expected a value after '='")
    span := Span{open.span.start, p.ast.nodes[value].span.end}
    start, count := push_children(p.ast, []Node_Idx{key, value})
    // Computed_Key marks this as the `[expr]` form: `[name]` and `.name`
    // both leave an Identifier in the key slot, and only the flag tells the
    // evaluator to look the name up instead of using its spelling (§5).
    flags := node_flags(p.ast, key, value) + {.Computed_Key}
    if !eq_ok do flags += {.Has_Error}
    return push_node(p.ast, Node{kind = .Table_Entry, flags = flags, span = span, children_start = start, children_count = count}), .Map
  }

  value, vok := parse_expr(p)
  if !vok do value = push_missing(p, p.cur.span, "expected a value")
  return value, .Sequence
}

// ---- Pattern grammar for `is` (SPEC.md §8) ---------------------------------

// Any pattern can be bound via a trailing `as <name>` (§8) - the general rule,
// applied here once rather than duplicated in every pattern-producing branch.
@(private = "file")
parse_pattern :: proc(p: ^Parser) -> (Node_Idx, bool) {
  base, ok := parse_pattern_base(p)
  if !ok do return base, false
  return wrap_pattern_as(p, base)
}

@(private = "file")
wrap_pattern_as :: proc(p: ^Parser, base: Node_Idx) -> (Node_Idx, bool) {
  if p.cur.kind != .Kw_As do return base, true
  advance(p)
  name: Node_Idx
  if is_name_token(p.cur.kind) {
    name = push_name_leaf(p)
  } else {
    name = push_missing(p, p.cur.span, "expected a name after 'as'")
  }
  start, count := push_children(p.ast, []Node_Idx{base, name})
  span := Span{p.ast.nodes[base].span.start, p.ast.nodes[name].span.end}
  return push_node(p.ast, Node{
    kind = .Pattern_Bind, flags = node_flags(p.ast, base, name),
    span = span, children_start = start, children_count = count,
  }), true
}

@(private = "file")
parse_pattern_base :: proc(p: ^Parser) -> (Node_Idx, bool) {
  #partial switch p.cur.kind {
  case .Left_Brace:
    return parse_table_pattern(p)
  case .Table_Construct: // `empty` (§5) as a pattern - matches a zero-entry Table
    t := advance(p)
    return push_node(p.ast, Node{kind = .Table_Construct, span = t.span}), true
  case .Variant_Construct: // `present [as name]` (§8)
    return parse_present_pattern(p), true
  case .Sigil_ColonColon, .Sigil_ColonDot:
    return parse_variant_pattern(p), true
  }
  // Fallback: an ordinary (tight) expression, matched by structural equality -
  // not explicitly enumerated in §8's resolution, but needed for plain literal
  // patterns (`is 5`, `is "ok"`) to be expressible at all.
  return parse_postfix(p)
}

// `present [as name]` - unlike the general Variant pattern below, there's no
// separate payload sub-pattern: the tag alone is 1 child, `present as name`
// wraps it via the generic `as` handling in `parse_pattern`.
@(private = "file")
parse_present_pattern :: proc(p: ^Parser) -> Node_Idx {
  kw := advance(p)
  key := push_node(p.ast, Node{kind = .Tag_Name, span = kw.span})
  start, count := push_children(p.ast, []Node_Idx{key})
  return push_node(p.ast, Node{kind = .Variant_Construct, span = kw.span, children_start = start, children_count = count})
}

// `:.name <subpattern>` / `::key-expr <subpattern>` (§8) - the construction
// syntax doubling as a pattern; here the payload position is a pattern, not a
// plain expression.
@(private = "file")
parse_variant_pattern :: proc(p: ^Parser) -> Node_Idx {
  sigil := advance(p)
  key: Node_Idx
  if sigil.kind == .Sigil_ColonDot {
    if is_name_token(p.cur.kind) {
      key = push_tag_name_leaf(p)
    } else {
      key = push_missing(p, p.cur.span, "expected a tag name after ':.'")
    }
  } else {
    k, kok := parse_postfix(p)
    if !kok do k = push_missing(p, p.cur.span, "expected a key expression after '::'")
    key = k
  }
  subpattern, spok := parse_pattern(p)
  if !spok do subpattern = push_missing(p, p.cur.span, "expected a payload pattern")
  start, count := push_children(p.ast, []Node_Idx{key, subpattern})
  span := Span{sigil.span.start, p.ast.nodes[subpattern].span.end}
  return push_node(p.ast, Node{
    kind = .Variant_Construct, flags = node_flags(p.ast, key, subpattern),
    span = span, children_start = start, children_count = count,
  })
}

// `{ .field, .field2 as f, [expr] }` or `{ {N} }` / `{ {N}: selector, ... }` (§8).
@(private = "file")
parse_table_pattern :: proc(p: ^Parser) -> (Node_Idx, bool) {
  open := advance(p) // outer Left_Brace
  if p.cur.kind == .Left_Brace {
    // `{{N}}` / `{{N}: sel, ...}` - the nested {N} governs the WHOLE outer
    // content; there is no separate outer comma-list in this form.
    return parse_sequence_pattern_body(p, open)
  }

  selectors := make([dynamic]Node_Idx, 0, 4)
  defer delete(selectors)
  has_error := false
  for p.cur.kind != .Right_Brace && p.cur.kind != .End_Of_File {
    sel, sok := parse_table_pattern_selector(p)
    if !sok do has_error = true
    append(&selectors, sel)
    if p.cur.kind == .Comma {
      advance(p)
    } else {
      break
    }
  }
  close_span, close_ok := expect(p, .Right_Brace, "expected '}'")
  if !close_ok do has_error = true
  end := close_span.end
  if len(selectors) > 0 && end < p.ast.nodes[selectors[len(selectors) - 1]].span.end {
    end = p.ast.nodes[selectors[len(selectors) - 1]].span.end
  }
  start, count := push_children(p.ast, selectors[:])
  flags := node_flags(p.ast, ..selectors[:])
  if has_error do flags += {.Has_Error}
  return push_node(p.ast, Node{
    kind = .Table_Pattern, flags = flags,
    span = Span{open.span.start, end}, children_start = start, children_count = count,
  }), true
}

@(private = "file")
parse_table_pattern_selector :: proc(p: ^Parser) -> (Node_Idx, bool) {
  #partial switch p.cur.kind {
  case .Op_Dot:
    dot := advance(p)
    name: Node_Idx
    if p.cur.kind == .Number_Literal {
      name = push_leaf(p, advance(p))
    } else if is_name_token(p.cur.kind) {
      name = push_name_leaf(p)
    } else {
      return push_missing(p, p.cur.span, "expected a field name or index after '.'"), false
    }
    span := Span{dot.span.start, p.ast.nodes[name].span.end}
    start, count := push_children(p.ast, []Node_Idx{name})
    field := push_node(p.ast, Node{kind = .Table_Pattern_Field, span = span, children_start = start, children_count = count})
    return wrap_pattern_as(p, field)
  case .Left_Bracket:
    open := advance(p)
    key, kok := parse_expr(p)
    if !kok do key = push_missing(p, p.cur.span, "expected a key expression")
    expect(p, .Right_Bracket, "expected ']'")
    start, count := push_children(p.ast, []Node_Idx{key})
    span := Span{open.span.start, p.ast.nodes[key].span.end}
    idx := push_node(p.ast, Node{kind = .Table_Pattern_Index, flags = node_flags(p.ast, key), span = span, children_start = start, children_count = count})
    return wrap_pattern_as(p, idx)
  }
  return push_error_node(p, p.cur.span, "expected a Table pattern selector ('.field' or '[expr]')"), false
}

// `outer_open` is the already-consumed outer `{`; this consumes the inner
// `{N}`, the optional `: selector, ...`, and the outer closing `}`.
@(private = "file")
parse_sequence_pattern_body :: proc(p: ^Parser, outer_open: Token) -> (Node_Idx, bool) {
  advance(p) // inner Left_Brace
  n: Node_Idx
  if p.cur.kind == .Number_Literal {
    n = push_leaf(p, advance(p))
  } else {
    n = push_missing(p, p.cur.span, "expected a sequence length")
  }
  _, inner_close_ok := expect(p, .Right_Brace, "expected '}' to close the sequence length")
  has_error := !inner_close_ok

  children := make([dynamic]Node_Idx, 0, 4)
  defer delete(children)
  append(&children, n)

  if p.cur.kind == .Colon {
    advance(p)
    for p.cur.kind != .Right_Brace && p.cur.kind != .End_Of_File {
      sel, sok := parse_table_pattern_selector(p)
      if !sok do has_error = true
      append(&children, sel)
      if p.cur.kind == .Comma {
        advance(p)
      } else {
        break
      }
    }
  }

  outer_close_span, outer_close_ok := expect(p, .Right_Brace, "expected '}'")
  if !outer_close_ok do has_error = true

  start, count := push_children(p.ast, children[:])
  flags := node_flags(p.ast, ..children[:])
  if has_error do flags += {.Has_Error}
  span := Span{outer_open.span.start, outer_close_span.end}
  return push_node(p.ast, Node{
    kind = .Table_Pattern_Sequence, flags = flags,
    span = span, children_start = start, children_count = count,
  }), true
}
