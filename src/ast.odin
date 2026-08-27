package hashedbuild

Node_Idx :: distinct u32

Node_Kind :: enum u16 {
  // Structural / Composite
  Root,
  Binary_Expr,       // children: [left, op_leaf, right] - op_leaf.kind picks the operator, including
                      // postfix-shaped ones reused here: Op_Dot, Op_Bracket, Op_Call, Op_Pipe, Op_Is,
                      // Op_CheckColon, Op_CheckDot
  Unary_Expr,         // children: [op_leaf, operand] - currently only Op_Minus
  Table_Construct,    // children: zero or more Table_Entry (map-style) XOR bare exprs (sequence-style) -
                      // never mixed. Also what `empty` desugars to (zero children).
  Table_Entry,        // children: [key, value] - key is an expr ([expr] form) or an Identifier (.field form)
  As_Bind,            // children: [bound_expr_or_Hole, name_leaf, body] - `<expr> as <name> <body>`
  With_Ctx_Expr,      // children: [expr_or_Hole, new_ctx] - `<expr> withctx <new_ctx>` (SPEC.md §7/§9)
  ChCtx_Expr,         // children: [expr_or_Hole, fn] - `<expr> chctx <fn>` == `<expr> withctx (<fn> ctx)` (SPEC.md §7/§9)
  Func_Expr,          // children: [body] - `func <body>`
  AsFunc_Expr,        // children: [expr] - `asfunc <expr>`
  AsFuncStatic_Expr,  // children: [expr] - `asfuncstatic <expr>`
  Then_Expr,          // children: [condition, happy_path]
  Else_Expr,          // children: [then_expr, bad_path] - left child is always, structurally, a Then_Expr
  Variant_Construct,  // children: [key, value] - key is Tag_Name (`:.name`) or an arbitrary expr (`::key`).
                      // Also reused for pattern context, where `value` is a pattern instead of an expr.
                      // `present <value>` desugars to this with key = Tag_Name("present").
  Check_Expr,         // children: [condition, body] or [condition, error_msg, body] - `check(cond,[msg]) body`
  StaticCheck_Expr,   // same shape as Check_Expr - `static_check(cond,[msg]) body`
  Error_Expr,         // children: [] or [msg] - `error [msg]`
  Import_Expr,        // children: [expr]
  Serialize_Expr,     // children: [expr]
  SerializeFile_Expr, // children: [expr]
  Sha256_Expr,        // children: [expr]
  Cached_Expr,        // children: [expr]
  Async_Expr,         // children: [expr]

  // Pattern-only nodes (right side of `is`, §8)
  Pattern_Bind,          // children: [pattern, name_leaf] - `<pattern> as <name>`
  Table_Pattern,          // children: pattern selectors, in source order
  Table_Pattern_Field,    // children: [name_leaf] - a bare `.field`/`.5` selector (Identifier or Number_Literal)
  Table_Pattern_Index,    // children: [key_expr] - a bare `[expr]` selector
  Table_Pattern_Sequence, // children: [n_literal, selector...] - `{N}` or `{N}: selector, ...`

  // Tokens / Terminal Leaves
  Identifier,
  Number_Literal,
  String_Literal,
  Tag_Name,          // the `name` in `:.name`/`!.name`/`present` - a literal tag spelling, not a variable reference
  Implicit_Name,     // `#arg`, `#arg2`, `#context`, ...
  Nothing_Literal,   // `nothing`
  Ctx_Expr,          // `ctx` (SPEC.md §9) - the current implicit context, context-sensitive keyword like `present`
  Op_Plus,
  Op_Minus,
  Op_Star,
  Op_Slash,
  Op_Percent,
  Op_EqEq,
  Op_Gt,
  Op_GtEq,
  Op_Lt,
  Op_LtEq,
  Op_And,        // `and` keyword
  Op_Or,         // `or` keyword
  Op_Concat,     // `concat` keyword
  Op_Is,         // `is` keyword
  Op_Pipe,       // `|>`
  Op_Dot,        // `.field` / `.5` - reused as a Binary_Expr operator, right child is Identifier/Number_Literal
  Op_Bracket,    // `[expr]` - reused as a Binary_Expr operator, right child is the index expression
  Op_Call,       // `f x` (juxtaposition) - reused as a Binary_Expr operator, right child is the single argument
  Op_CheckColon, // `subject !: key_expr` - check-or-throw, dynamic key
  Op_CheckDot,   // `subject !.name` - check-or-throw, static tag name
  Op_Eq,         // `=` inside a Table_Entry only - never a standalone expression operator
  Sigil_ColonColon, // `::`
  Sigil_ColonDot,   // `:.`

  // Pure punctuation / structural keywords - consumed structurally by the parser,
  // not retained as tree nodes (kept in this enum, alongside the leaf/operator
  // kinds above, for one uniform token stream)
  Left_Paren,
  Right_Paren,
  Left_Bracket,
  Right_Bracket,
  Left_Brace,
  Right_Brace,
  Comma,
  Colon,     // bare `:` - only meaningful in `{N}: selector, ...` (§8 sequence patterns)
  Kw_Then,
  Kw_Else,
  Kw_As,
  Kw_WithCtx,
  Kw_ChCtx,
  End_Of_File,

  // Deliberately-blank operand (SPEC.md §7 omission), NOT an error - zero-width, no source text.
  // Distinct from MISSING_TOKEN, which specifically marks error recovery.
  Hole,

  // Recovery Specific Nodes
  ERROR_UNRECOGNIZED, // Unexpected tokens / garbage text
  MISSING_TOKEN,      // Expected token synthesized by parser recovery
}

Node_Flags :: bit_set[enum {
  Has_Error,    // True if this node OR any descendant contains an error
  Is_Missing,   // Synthesized node (zero length in source text)
  // Set on a Table_Entry written as `[expr] = value` rather than
  // `.name = value` (SPEC.md §5). Both forms hold [key, value] children, and
  // a bare `[name]` key parses to the same Identifier leaf a `.name` key
  // does - so without this flag the evaluator can't tell "the key is the
  // literal text `name`" from "the key is whatever the variable `name`
  // holds", and silently picks the former.
  Computed_Key,
}]

Span :: struct {
  start: u32, // Byte offset in source
  end:   u32, // Byte offset in source
}

// Fixed 16-byte node structure for cache friendliness
Node :: struct {
  kind:           Node_Kind,
  flags:          Node_Flags,
  span:           Span,
  children_start: u32, // Index into ast_t.extra_children array
  children_count: u16,
}

ast_t :: struct {
  nodes:          [dynamic]Node,
  extra_children: [dynamic]Node_Idx,
  errors:         [dynamic]Parse_Error,
  root:           Node_Idx,
}

Parse_Error :: struct {
  span:    Span,
  message: string,
}

ast_destroy :: proc(ast: ^ast_t) {
  delete(ast.nodes)
  delete(ast.extra_children)
  delete(ast.errors)
}
