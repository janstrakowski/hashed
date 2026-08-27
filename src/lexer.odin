package hashedbuild

// Hand-written tokenizer covering the whole of SPEC.md's syntax. Several
// keyword tokens reuse a *composite* Node_Kind directly (e.g. `func` lexes as
// a bare Func_Expr token) rather than a separate raw-keyword kind - the parser
// fills in that same node's children once it's parsed the keyword's operand(s),
// so the token and the eventual tree node share one enum value throughout.

Token :: struct {
  kind: Node_Kind,
  span: Span,
}

Lexer :: struct {
  source: source_t,
  pos:    u32,
}

lexer_make :: proc(source: source_t) -> Lexer {
  return Lexer{source = source, pos = 0}
}

@(private = "file")
byte_at :: proc(l: ^Lexer, offset: u32 = 0) -> u8 {
  idx := u64(l.pos) + u64(offset)
  if idx >= l.source.n_bytes do return 0
  return l.source.data[idx]
}

@(private = "file")
is_ident_start :: proc(b: u8) -> bool {
  return b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

@(private = "file")
is_ident_continue :: proc(b: u8) -> bool {
  return is_ident_start(b) || (b >= '0' && b <= '9')
}

@(private = "file")
is_digit :: proc(b: u8) -> bool { return b >= '0' && b <= '9' }

@(private = "file")
is_hex_digit :: proc(b: u8) -> bool {
  return is_digit(b) || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F')
}

@(private = "file")
is_octal_digit :: proc(b: u8) -> bool { return b >= '0' && b <= '7' }

@(private = "file")
is_binary_digit :: proc(b: u8) -> bool { return b == '0' || b == '1' }

@(private = "file")
skip_trivia :: proc(l: ^Lexer) {
  for {
    switch byte_at(l) {
    case ' ', '\t', '\r', '\n':
      l.pos += 1
    case '/':
      if byte_at(l, 1) == '/' {
        for byte_at(l) != 0 && byte_at(l) != '\n' do l.pos += 1
      } else if byte_at(l, 1) == '*' {
        l.pos += 2
        for byte_at(l) != 0 && !(byte_at(l) == '*' && byte_at(l, 1) == '/') do l.pos += 1
        if byte_at(l) != 0 do l.pos += 2 // consume closing "*/"; unterminated block comments just run to EOF
      } else {
        return
      }
    case:
      return
    }
  }
}

// Consumes a run of digits (per `is_digit_kind`) with SPEC.md §3's `_` separator
// allowed between them. Best-effort for the pilot: malformed separator placement
// (leading/trailing/doubled underscores) is accepted rather than rejected.
@(private = "file")
consume_digit_run :: proc(l: ^Lexer, is_digit_kind: proc(u8) -> bool) {
  for is_digit_kind(byte_at(l)) || byte_at(l) == '_' do l.pos += 1
}

@(private = "file")
lex_number :: proc(l: ^Lexer) -> Token {
  start := l.pos
  if byte_at(l) == '0' && (byte_at(l, 1) == 'x' || byte_at(l, 1) == 'X') {
    l.pos += 2
    consume_digit_run(l, is_hex_digit)
  } else if byte_at(l) == '0' && (byte_at(l, 1) == 'o' || byte_at(l, 1) == 'O') {
    l.pos += 2
    consume_digit_run(l, is_octal_digit)
  } else if byte_at(l) == '0' && (byte_at(l, 1) == 'b' || byte_at(l, 1) == 'B') {
    l.pos += 2
    consume_digit_run(l, is_binary_digit)
  } else {
    consume_digit_run(l, is_digit)
    // SPEC.md §3: a Float requires a digit on both sides of `.` - `0.5`, not `.5` -
    // so only consume the dot here if it's actually followed by another digit.
    if byte_at(l) == '.' && is_digit(byte_at(l, 1)) {
      l.pos += 1
      consume_digit_run(l, is_digit)
    }
    if byte_at(l) == 'e' || byte_at(l) == 'E' {
      save := l.pos
      l.pos += 1
      if byte_at(l) == '+' || byte_at(l) == '-' do l.pos += 1
      if is_digit(byte_at(l)) {
        consume_digit_run(l, is_digit)
      } else {
        l.pos = save // not actually an exponent (e.g. a trailing identifier char) - back off
      }
    }
  }
  return Token{kind = .Number_Literal, span = Span{start, l.pos}}
}

@(private = "file")
lex_string :: proc(l: ^Lexer) -> Token {
  start := l.pos
  l.pos += 1 // opening quote
  for {
    b := byte_at(l)
    if b == 0 || b == '\n' do break // unterminated - let the parser flag it via span
    l.pos += 1
    if b == '\\' {
      if byte_at(l) != 0 do l.pos += 1 // consume the escaped byte, whatever it is
      continue
    }
    if b == '"' do break
  }
  return Token{kind = .String_Literal, span = Span{start, l.pos}}
}

next_token :: proc(l: ^Lexer) -> Token {
  skip_trivia(l)
  start := l.pos
  b := byte_at(l)

  if b == 0 {
    return Token{kind = .End_Of_File, span = Span{start, start}}
  }
  if is_ident_start(b) {
    for is_ident_continue(byte_at(l)) do l.pos += 1
    text := string(l.source.data[start:l.pos])
    switch text {
    case "and":           return Token{kind = .Op_And, span = Span{start, l.pos}}
    case "or":            return Token{kind = .Op_Or, span = Span{start, l.pos}}
    case "concat":        return Token{kind = .Op_Concat, span = Span{start, l.pos}}
    case "is":            return Token{kind = .Op_Is, span = Span{start, l.pos}}
    case "then":          return Token{kind = .Kw_Then, span = Span{start, l.pos}}
    case "else":          return Token{kind = .Kw_Else, span = Span{start, l.pos}}
    case "as":            return Token{kind = .Kw_As, span = Span{start, l.pos}}
    case "withctx":       return Token{kind = .Kw_WithCtx, span = Span{start, l.pos}}
    case "chctx":         return Token{kind = .Kw_ChCtx, span = Span{start, l.pos}}
    case "ctx":           return Token{kind = .Ctx_Expr, span = Span{start, l.pos}}
    case "func":          return Token{kind = .Func_Expr, span = Span{start, l.pos}}
    case "asfunc":        return Token{kind = .AsFunc_Expr, span = Span{start, l.pos}}
    case "asfuncstatic":  return Token{kind = .AsFuncStatic_Expr, span = Span{start, l.pos}}
    case "check":         return Token{kind = .Check_Expr, span = Span{start, l.pos}}
    case "static_check":  return Token{kind = .StaticCheck_Expr, span = Span{start, l.pos}}
    case "error":         return Token{kind = .Error_Expr, span = Span{start, l.pos}}
    case "import":        return Token{kind = .Import_Expr, span = Span{start, l.pos}}
    case "serialize":     return Token{kind = .Serialize_Expr, span = Span{start, l.pos}}
    case "serialize_file":return Token{kind = .SerializeFile_Expr, span = Span{start, l.pos}}
    case "sha256":        return Token{kind = .Sha256_Expr, span = Span{start, l.pos}}
    case "cached":        return Token{kind = .Cached_Expr, span = Span{start, l.pos}}
    case "async":         return Token{kind = .Async_Expr, span = Span{start, l.pos}}
    case "nothing":       return Token{kind = .Nothing_Literal, span = Span{start, l.pos}}
    case "empty":         return Token{kind = .Table_Construct, span = Span{start, l.pos}}
    case "present":       return Token{kind = .Variant_Construct, span = Span{start, l.pos}}
    case:                 return Token{kind = .Identifier, span = Span{start, l.pos}}
    }
  }
  if is_digit(b) do return lex_number(l)
  if b == '"' do return lex_string(l)
  if b == '#' {
    l.pos += 1
    for is_ident_continue(byte_at(l)) do l.pos += 1
    return Token{kind = .Implicit_Name, span = Span{start, l.pos}}
  }

  switch b {
  case '+': l.pos += 1; return Token{.Op_Plus, Span{start, l.pos}}
  case '-': l.pos += 1; return Token{.Op_Minus, Span{start, l.pos}}
  case '*': l.pos += 1; return Token{.Op_Star, Span{start, l.pos}}
  case '/': l.pos += 1; return Token{.Op_Slash, Span{start, l.pos}}
  case '%': l.pos += 1; return Token{.Op_Percent, Span{start, l.pos}}
  case '.': l.pos += 1; return Token{.Op_Dot, Span{start, l.pos}}
  case '=':
    l.pos += 1
    if byte_at(l) == '=' { l.pos += 1; return Token{.Op_EqEq, Span{start, l.pos}} }
    return Token{.Op_Eq, Span{start, l.pos}}
  case '>':
    l.pos += 1
    if byte_at(l) == '=' { l.pos += 1; return Token{.Op_GtEq, Span{start, l.pos}} }
    return Token{.Op_Gt, Span{start, l.pos}}
  case '<':
    l.pos += 1
    if byte_at(l) == '=' { l.pos += 1; return Token{.Op_LtEq, Span{start, l.pos}} }
    return Token{.Op_Lt, Span{start, l.pos}}
  case '|':
    l.pos += 1
    if byte_at(l) == '>' { l.pos += 1; return Token{.Op_Pipe, Span{start, l.pos}} }
    // no bare `|` in the language yet
  case ':':
    l.pos += 1
    if byte_at(l) == ':' { l.pos += 1; return Token{.Sigil_ColonColon, Span{start, l.pos}} }
    if byte_at(l) == '.' { l.pos += 1; return Token{.Sigil_ColonDot, Span{start, l.pos}} }
    return Token{.Colon, Span{start, l.pos}}
  case '!':
    l.pos += 1
    if byte_at(l) == ':' { l.pos += 1; return Token{.Op_CheckColon, Span{start, l.pos}} }
    if byte_at(l) == '.' { l.pos += 1; return Token{.Op_CheckDot, Span{start, l.pos}} }
    // no bare `!` in the language yet
  case '(': l.pos += 1; return Token{.Left_Paren, Span{start, l.pos}}
  case ')': l.pos += 1; return Token{.Right_Paren, Span{start, l.pos}}
  case '[': l.pos += 1; return Token{.Left_Bracket, Span{start, l.pos}}
  case ']': l.pos += 1; return Token{.Right_Bracket, Span{start, l.pos}}
  case '{': l.pos += 1; return Token{.Left_Brace, Span{start, l.pos}}
  case '}': l.pos += 1; return Token{.Right_Brace, Span{start, l.pos}}
  case ',': l.pos += 1; return Token{.Comma, Span{start, l.pos}}
  }

  return Token{kind = .ERROR_UNRECOGNIZED, span = Span{start, l.pos}}
}
