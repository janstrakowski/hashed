// A fixture for dap-tests: two `let` bindings, so the Locals scope holds
// something that is not a builtin. adapter.test.js breaks on line 6 and
// expects `width` to be 4 there.
let width 4;
let height 3;
  width * height
