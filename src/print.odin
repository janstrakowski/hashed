package hashedbuild

import "core:fmt"
import "core:strings"

// Indented dump of the AST, for eyeballing what the pilot parser produced.
print_ast :: proc(ast: ^ast_t, src: string) {
  lines := ast_lines(ast, src)
  defer {
    for line in lines do delete(line)
    delete(lines)
  }
  for line in lines do fmt.println(line)
  for err in ast.errors {
    fmt.printfln("error at [%d:%d): %s", err.span.start, err.span.end, err.message)
  }
}

// Same content as `print_ast`, but as an owned slice of lines (one per node) -
// used by the live editor to lay the tree out side-by-side with the source.
// Caller owns every string in the result and the result itself.
ast_lines :: proc(ast: ^ast_t, src: string) -> [dynamic]string {
  lines := make([dynamic]string, 0, 32)
  collect_node_lines(ast, src, ast.root, 0, &lines)
  return lines
}

@(private = "file")
collect_node_lines :: proc(ast: ^ast_t, src: string, n: Node_Idx, depth: int, out: ^[dynamic]string) {
  node := ast.nodes[n]

  text := ""
  if node.span.end > node.span.start && int(node.span.end) <= len(src) {
    text = src[node.span.start:node.span.end]
  }
  err_marker := " [ERROR]" if .Has_Error in node.flags else ""
  missing_marker := " [MISSING]" if .Is_Missing in node.flags else ""

  indent, _ := strings.repeat("  ", depth)
  defer delete(indent)

  line: string
  // Leaves (no children) with real source text get it printed inline; composite
  // nodes and zero-width markers (Hole, MISSING_TOKEN, the synthetic Op_Call) don't.
  if node.children_count == 0 && text != "" {
    line = fmt.aprintf("%s%v %q%s%s", indent, node.kind, text, err_marker, missing_marker)
  } else {
    line = fmt.aprintf("%s%v%s%s", indent, node.kind, err_marker, missing_marker)
  }
  append(out, line)

  start := int(node.children_start)
  for i in 0 ..< int(node.children_count) {
    collect_node_lines(ast, src, ast.extra_children[start + i], depth + 1, out)
  }
}
