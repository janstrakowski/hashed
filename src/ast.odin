package hashedbuild

Node_Idx :: distinct u32

Node_Kind :: enum u16 {
  // Structural / Composite
  Root,
  Binary_Expr,
  Unary_Expr,
  Array_Construct,
  Map_Construct,
  Variant_Construct,

  // Tokens / Terminal Leaves
  Identifier,
  Number_Literal,
  String_Literal,
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
  Op_PipePipe,
  Op_AmpersandAmpersand,
  Op_ColonColon,
  Op_Dot,
  Op_Bracket,
  Op_DoubleArrow,
  Op_DoubleDot,

  // Recovery Specific Nodes
  ERROR_UNRECOGNIZED, // Unexpected tokens / garbage text
  MISSING_TOKEN,      // Expected token synthesized by parser recovery
}

Node_Flags :: bit_set[enum {
  Has_Error,   // True if this node OR any descendant contains an error
  Is_Missing,  // Synthesized node (zero length in source text)
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
