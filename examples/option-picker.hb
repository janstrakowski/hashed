// Reads choice.txt (relative to this file, not to wherever `hb` was invoked
// from), then branches on its exact content: "option A" writes output.txt
// starting with "Option A:" followed by optiona.txt's content; "option B"
// does the analogous thing with optionb.txt; anything else is an
// unrecoverable runtime error (§11's `error` - fatal even to an enclosing
// `else`, unlike a failed `then`).
loadfile "choice.txt" |> filetext as choice
  choice == "option A" then
    createfile {
      .path = "output.txt",
      .content = "Option A:\n" concat filetext (loadfile "optiona.txt"),
    }
  else choice == "option B" then
    createfile {
      .path = "output.txt",
      .content = "Option B:\n" concat filetext (loadfile "optionb.txt"),
    }
  else
    error "choice.txt must contain exactly \"option A\" or \"option B\""
