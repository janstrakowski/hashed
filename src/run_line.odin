package hashedbuild

import "core:strings"

// A program's directories come from `--dir` and nowhere else (SPEC.md
// §9/§16), which makes the command line part of what a program *is* rather
// than incidental to running it. An example that reads or writes anything
// therefore carries its own command line, on a `run:` line in its header
// comment:
//
//   // run: hb --dir here=. option-picker.hb
//
// so that a reader copies one line to run it, and the suite runs it the same
// way (examples_test.odin). The two cannot drift, because the suite has no
// other source for the flags - and an example that touches the filesystem
// without such a line fails the suite rather than failing to run.
//
// **The line is the command as run from the example's own directory**, which
// is why "." is the usual path in it. Callers pass that directory as
// `base_dir` and get paths already resolved against it.

Run_Line :: struct {
  found:      bool,
  named_dirs: []Named_Dir, // --dir <name>=<path>, paths joined onto base_dir
  // The last bare word on the line, which should be the example's own
  // filename. Kept so a harness can check that a copied-and-edited run line
  // still names the file it sits in.
  file:       string,
}

// Reads the first `// run:` line out of `src`. Everything on it is taken as a
// command line: `--dir <name>=<path>` entries become handles (their paths
// resolved against `base_dir`), the trailing bare word becomes `file`, and any
// other flag is ignored rather than rejected - a harness that supplies its own
// `--cache-dir`, say, should not have to care that the line mentions one.
parse_run_line :: proc(src: string, base_dir: string, allocator := context.allocator) -> (r: Run_Line) {
  line, has_line := find_run_line(src)
  if !has_line do return r
  r.found = true

  dirs := make([dynamic]Named_Dir, 0, 2, allocator)
  words := strings.fields(line, context.temp_allocator)
  for i := 0; i < len(words); i += 1 {
    word := words[i]
    if word == "--dir" {
      i += 1
      if i >= len(words) do break
      eq := strings.index_byte(words[i], '=')
      if eq <= 0 do continue // not <name>=<path>: nothing to open
      name := words[i][:eq]
      path := words[i][eq + 1:]
      if path == "" do continue
      append(&dirs, Named_Dir{
        name = strings.clone(name, allocator),
        path = resolve_against(base_dir, path, allocator),
      })
      continue
    }
    // Some other flag with an argument the loop would otherwise read as the
    // filename. Only the ones a run line can plausibly carry need naming.
    if word == "--cache-dir" || word == "-e" || word == "--eval" {
      i += 1
      continue
    }
    if strings.has_prefix(word, "-") do continue
    if word == "hb" || word == "./hb" || word == "hb.exe" || word == "./hb.exe" do continue
    r.file = strings.clone(word, allocator)
  }
  r.named_dirs = dirs[:]
  return r
}

run_line_destroy :: proc(r: Run_Line, allocator := context.allocator) {
  for d in r.named_dirs {
    delete(d.name, allocator)
    delete(d.path, allocator)
  }
  delete(r.named_dirs, allocator)
  delete(r.file, allocator)
}

// The text after `// run:` on the first line that has it. Only a comment line
// counts, so nothing in a program's body can be mistaken for one.
@(private = "file")
find_run_line :: proc(src: string) -> (string, bool) {
  rest := src
  for len(rest) > 0 {
    end := strings.index_byte(rest, '\n')
    line := rest
    if end >= 0 {
      line = rest[:end]
      rest = rest[end + 1:]
    } else {
      rest = ""
    }
    trimmed := strings.trim_space(line)
    if !strings.has_prefix(trimmed, "//") do continue
    body := strings.trim_space(trimmed[2:])
    if !strings.has_prefix(body, "run:") do continue
    return strings.trim_space(body[len("run:"):]), true
  }
  return "", false
}

// A run line's paths are relative to the example's own directory (see above);
// an absolute one is left alone, since it names a place rather than a
// neighbour.
@(private = "file")
resolve_against :: proc(base_dir: string, path: string, allocator := context.allocator) -> string {
  if base_dir == "" || is_absolute_path(path) do return strings.clone(path, allocator)
  joined := display_join(base_dir, path)
  defer delete(joined)
  return strings.clone(joined, allocator)
}
