// A fixture for dap-tests: one user-level call, so a stack trace has
// something in it. adapter.test.js breaks on line 6 - the function's body
// itself, so the stop happens with the call still in flight and the frame
// for it still on the stack.
let square func (
  #arg * #arg
);
  square 5
