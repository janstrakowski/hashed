package hashedbuild

import "core:strings"

// Program attributes (SPEC.md §17): a prologue of directives that say how a
// program is *run*, as opposed to what it computes.
//
//   #Directory here .
//   #Directory src ../src
//   #Cache-Dir ./.hbcache
//
//   let choice loadfile { .dir = ctx.dirs.here, ... } |> filetext;
//     ...
//
// A directive is `#` then a name, then space-separated arguments, ending at a
// line break or a `;`. They may only appear before the program's expression -
// which is the whole point: a program's inputs are declared where anyone
// reading it will see them, not inferred from the command line that happened
// to start it.
//
// **Why the name must begin with a capital.** `#` already introduces §9's
// implicit names, and `#arg` is a perfectly good program all by itself. A
// lower-case `#name` is therefore always an expression, and an upper-case one
// is always an attribute - the two can never be confused, by the lexer or by
// a reader.
//
// Paths in a directive are relative to **the source file**, not to whoever
// invoked it (§9/§16). That is what lets `hb examples/hashing.hb` work from
// anywhere, which is exactly what the `// run:` comment this replaces was
// trying to achieve by convention.

Attribute_Kind :: enum {
  Directory, // #Directory <name> <path>  -> one entry of ctx.dirs
  Cache_Dir, // #Cache-Dir <path>         -> where ctx.cache and `cached` write
}

Attribute :: struct {
  kind: Attribute_Kind,
  args: []string, // slices of the source; no allocation, no ownership
  span: Span,
}

Attribute_Error :: struct {
  span:    Span,
  message: string,
}

// What a prologue scan produced. `consumed` is how many bytes of the source
// the prologue occupied, so the parser can start the program's expression
// after it.
Attributes :: struct {
  list:     [dynamic]Attribute,
  errors:   [dynamic]Attribute_Error,
  consumed: int,
}

attributes_destroy :: proc(a: ^Attributes) {
  for attr in a.list do delete(attr.args)
  delete(a.list)
  delete(a.errors)
}

@(private = "file")
Spec :: struct {
  name:  string,
  kind:  Attribute_Kind,
  arity: int,
  usage: string,
}

// Every attribute there is. Adding one is a line here plus whatever reads it;
// deliberately not open-ended, so a typo is an error rather than a directive
// that silently does nothing.
@(private = "file")
SPECS := []Spec{
  {"Directory", .Directory, 2, "#Directory <name> <path>"},
  {"Cache-Dir", .Cache_Dir, 1, "#Cache-Dir <path>"},
}

// Reads the prologue at the start of `src`. Used by the parser, which reports
// the errors and skips past what this consumed, and by the runtime, which
// reads the directives themselves (main.odin, dap.odin) - one implementation,
// so the two can never disagree about what a file declares.
scan_attributes :: proc(src: string, allocator := context.allocator) -> (a: Attributes) {
  a.list = make([dynamic]Attribute, 0, 4, allocator)
  a.errors = make([dynamic]Attribute_Error, 0, 0, allocator)

  i := 0
  for {
    line_start := skip_prologue_space(src, i)
    if line_start >= len(src) {
      a.consumed = line_start
      return
    }
    if !starts_attribute(src, line_start) {
      a.consumed = i // the program begins here; leave the whitespace to the lexer
      return
    }
    i = scan_one_attribute(&a, src, line_start, allocator)
  }
}

// Whitespace and comments, which may sit between directives and before the
// program - a prologue is allowed to be commented like anything else.
@(private = "file")
skip_prologue_space :: proc(src: string, from: int) -> int {
  i := from
  for i < len(src) {
    c := src[i]
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == ';' {
      i += 1
      continue
    }
    if c == '/' && i + 1 < len(src) && src[i + 1] == '/' {
      for i < len(src) && src[i] != '\n' do i += 1
      continue
    }
    break
  }
  return i
}

// `#` followed by a capital: an attribute. `#arg` and `#self` (§9) begin with
// a lower-case letter and are expressions, so the two never collide.
@(private = "file")
starts_attribute :: proc(src: string, at: int) -> bool {
  if at >= len(src) || src[at] != '#' do return false
  if at + 1 >= len(src) do return false
  c := src[at + 1]
  return c >= 'A' && c <= 'Z'
}

@(private = "file")
scan_one_attribute :: proc(a: ^Attributes, src: string, start: int, allocator := context.allocator) -> int {
  i := start + 1 // past '#'
  name_start := i
  for i < len(src) && (is_name_byte(src[i])) do i += 1
  name := src[name_start:i]

  args := make([dynamic]string, 0, 2, allocator)
  for {
    // Arguments run to the end of the line, or to a `;` - so a directive can
    // share a line with the next one if anybody wants that.
    for i < len(src) && (src[i] == ' ' || src[i] == '\t') do i += 1
    if i >= len(src) || src[i] == '\n' || src[i] == '\r' || src[i] == ';' do break
    arg_start := i
    for i < len(src) && src[i] != ' ' && src[i] != '\t' && src[i] != '\n' && src[i] != '\r' && src[i] != ';' {
      i += 1
    }
    append(&args, src[arg_start:i])
  }
  if i < len(src) && src[i] == ';' do i += 1

  span := Span{start = u32(start), end = u32(i)}
  spec, known := find_spec(name)
  if !known {
    append(&a.errors, Attribute_Error{
      span    = span,
      message = strings.concatenate({"unknown program attribute #", name, " - see SPEC.md §17"}, allocator),
    })
    delete(args)
    return i
  }
  if len(args) != spec.arity {
    append(&a.errors, Attribute_Error{
      span    = span,
      message = strings.concatenate({"#", name, " takes ", spec.usage}, allocator),
    })
    delete(args)
    return i
  }
  append(&a.list, Attribute{kind = spec.kind, args = args[:], span = span})
  return i
}

@(private = "file")
is_name_byte :: proc(c: u8) -> bool {
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
}

@(private = "file")
find_spec :: proc(name: string) -> (Spec, bool) {
  for s in SPECS do if s.name == name do return s, true
  return {}, false
}

// The directories a file declares, as the runtime wants them: names paired
// with paths already resolved against the source file's own directory.
//
// `base_dir` is that directory (dir_of_source, source.odin). Callers own the
// result and the strings in it.
attribute_dirs :: proc(a: Attributes, base_dir: string, allocator := context.allocator) -> []Named_Dir {
  out := make([dynamic]Named_Dir, 0, len(a.list), allocator)
  for attr in a.list {
    if attr.kind != .Directory do continue
    append(&out, Named_Dir{
      name = strings.clone(attr.args[0], allocator),
      path = resolve_from_source(base_dir, attr.args[1], allocator),
    })
  }
  return out[:]
}

// The cache directory a file declares, or "" for none.
attribute_cache_dir :: proc(a: Attributes, base_dir: string, allocator := context.allocator) -> string {
  for attr in a.list {
    if attr.kind == .Cache_Dir do return resolve_from_source(base_dir, attr.args[0], allocator)
  }
  return ""
}

@(private = "file")
resolve_from_source :: proc(base_dir: string, path: string, allocator := context.allocator) -> string {
  if base_dir == "" || is_absolute_path(path) do return strings.clone(path, allocator)
  joined := display_join(base_dir, path)
  defer delete(joined)
  return strings.clone(joined, allocator)
}

// ---- combining a file's attributes with a run's own arguments (§17) -------------

// What a run's inputs come to once the file and the command line have been
// reconciled. Owns its strings.
Run_Inputs :: struct {
  named_dirs: []Named_Dir,
  cache_dir:  string,
}

run_inputs_destroy :: proc(r: Run_Inputs) {
  for d in r.named_dirs {
    delete(d.name)
    delete(d.path)
  }
  delete(r.named_dirs)
  delete(r.cache_dir)
}

// The rule, in full (SPEC.md §17):
//
//   - A file's attributes are its inputs. Run it and they apply; nothing on
//     the command line is needed, which is the point.
//   - If the command line *also* sets inputs and the file declares any, that
//     is refused. Not per-name: the two disagree about who decides, and
//     picking one silently would mean debugging or running a program against
//     directories its own text says it does not use.
//   - `--override` settles it in the command line's favour. The attributes are
//     read, then the command line is applied on top, name by name. An empty
//     path (`--dir here=`) removes that name, which is the only way to take
//     away something a file declares.
//   - Without `--override` an empty path is simply ignored - there is nothing
//     for it to remove.
//
// `base_dir` is the source file's own directory: a file's paths are relative
// to it (attribute_dirs), while the command line's are relative to wherever
// the shell was, and so are left alone.
resolve_run_inputs :: proc(
  attrs: Attributes,
  base_dir: string,
  cli_dirs: []Named_Dir,
  cli_cache_dir: string,
  override: bool,
  allocator := context.allocator,
) -> (inputs: Run_Inputs, err_msg: string, ok: bool) {
  has_attrs := len(attrs.list) > 0
  cli_sets_inputs := len(cli_dirs) > 0 || cli_cache_dir != ""

  if has_attrs && cli_sets_inputs && !override {
    return {}, "this program declares its own inputs (see its # attributes), and the command line sets them too - pass --override to let the command line win", false
  }

  dirs := make([dynamic]Named_Dir, 0, 4, allocator)
  cache := ""

  if has_attrs {
    for d in attribute_dirs(attrs, base_dir, allocator) do append(&dirs, d)
    cache = attribute_cache_dir(attrs, base_dir, allocator)
  }

  if !has_attrs || override {
    for cli in cli_dirs {
      existing := -1
      for d, i in dirs do if d.name == cli.name do existing = i
      if cli.path == "" {
        // Removes what the file declared; means nothing otherwise.
        if existing >= 0 {
          delete(dirs[existing].name)
          delete(dirs[existing].path)
          ordered_remove(&dirs, existing)
        }
        continue
      }
      entry := Named_Dir{name = strings.clone(cli.name, allocator), path = strings.clone(cli.path, allocator)}
      if existing >= 0 {
        delete(dirs[existing].name)
        delete(dirs[existing].path)
        dirs[existing] = entry
      } else {
        append(&dirs, entry)
      }
    }
    if cli_cache_dir != "" {
      delete(cache)
      cache = strings.clone(cli_cache_dir, allocator)
    }
  }

  return Run_Inputs{named_dirs = dirs[:], cache_dir = cache}, "", true
}
