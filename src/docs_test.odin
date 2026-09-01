// Tests run natively, never in a WASI build: core:testing pulls in
// core:log and core:terminal, neither of which compiles for wasm32.
#+build linux, windows
package hashedbuild

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// README.md shows examples/option-picker.hb inline as the "this actually
// runs" sample. It had already drifted once (it still wrote to output.txt
// after the example moved to ctx.cache), so the two are compared here rather
// than trusted: the code lines must match, comments and prose aside.
@(test)
test_readme_sample_matches_the_example_it_quotes :: proc(t: ^testing.T) {
  readme := read_repo_file(t, "README.md")
  example := read_repo_file(t, "examples/option-picker.hb")
  if readme == "" || example == "" do return

  // The block now opens with the example's own `#Directory` attribute (§17),
  // which is part of the program rather than a comment about it.
  quoted, found := fenced_block(readme, "```hashedbuild\n#Directory here .")
  if !testing.expect(t, found, "README.md no longer quotes examples/option-picker.hb in a hashedbuild block") do return

  testing.expect_value(t, code_lines(quoted), code_lines(example))
}

// The language tour promises that everything it documents runs today, so the
// examples it points at have to exist.
@(test)
test_language_doc_links_to_examples_that_exist :: proc(t: ^testing.T) {
  doc := read_repo_file(t, "LANGUAGE.md")
  if doc == "" do return

  rest := doc
  checked := 0
  for {
    idx := strings.index(rest, "`examples/")
    if idx < 0 do break
    rest = rest[idx + len("`examples/"):]
    end := strings.index_byte(rest, '`')
    if end < 0 do break
    name := rest[:end]
    rest = rest[end:]
    if !strings.has_suffix(name, ".hb") do continue // e.g. `examples/` itself
    checked += 1
    path := fmt.tprintf("%s/examples/%s", repo_root(), name)
    testing.expect(t, os.exists(path), fmt.tprintf("LANGUAGE.md points at examples/%s, which doesn't exist", name))
  }
  testing.expect(t, checked > 0, "LANGUAGE.md stopped pointing at any example")
}

@(private = "file")
read_repo_file :: proc(t: ^testing.T, rel_path: string) -> string {
  data, err := os.read_entire_file(fmt.tprintf("%s/%s", repo_root(), rel_path), context.temp_allocator)
  if !testing.expect(t, err == nil, fmt.tprintf("could not read %s", rel_path)) do return ""
  return string(data)
}

// The body of the first fenced block that starts with `opening`, excluding
// the fences themselves.
@(private = "file")
fenced_block :: proc(text: string, opening: string) -> (body: string, found: bool) {
  start := strings.index(text, opening)
  if start < 0 do return "", false
  after_fence := start + len("```hashedbuild\n")
  rest := text[after_fence:]
  end := strings.index(rest, "\n```")
  if end < 0 do return "", false
  return rest[:end], true
}

// Comment and blank lines dropped, so the two copies can explain themselves
// differently while still being the same program.
@(private = "file")
code_lines :: proc(source: string) -> string {
  kept := make([dynamic]string, context.temp_allocator)
  for line in strings.split_lines(source, context.temp_allocator) {
    trimmed := strings.trim_space(line)
    if trimmed == "" || strings.has_prefix(trimmed, "//") do continue
    append(&kept, trimmed)
  }
  return strings.join(kept[:], "\n", context.temp_allocator)
}
