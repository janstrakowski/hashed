#Directory here .

// Reads choice.txt out of `ctx.dirs.here` - the directory the run named with
// `--dir here=.`, since a program reaches nothing it was not handed (§9/§16) -
// then branches on its exact content: "option A" writes the result
// starting with "Option A:" followed by optiona.txt's content; "option B"
// does the analogous thing with optionb.txt; anything else is an
// unrecoverable runtime error (§11's `error` - fatal even to an enclosing
// `else`, unlike a failed `then`). The result is written into ctx.cache
// (§9/§16) rather than a named path - `.dir = ctx.cache` with no `.path`
// content-addresses it under the XDG cache dir (or --cache-dir) instead of
// landing next to this source file.
let choice loadfile { .dir = ctx.dirs.here, .path = "choice.txt" } |> filetext;
  choice == "option A" then
    createfile {
      .dir = ctx.cache,
      .content = "Option A:\n" concat filetext (loadfile { .dir = ctx.dirs.here, .path = "optiona.txt" }),
    }
  else choice == "option B" then
    createfile {
      .dir = ctx.cache,
      .content = "Option B:\n" concat filetext (loadfile { .dir = ctx.dirs.here, .path = "optionb.txt" }),
    }
  else
    error "choice.txt must contain exactly \"option A\" or \"option B\""
