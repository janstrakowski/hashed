// A fixture for dap-tests: a Table bound to a name, so a variables pane has
// something to expand. adapter.test.js breaks on line 6.
let point { .x = 1, .y = 2 };
// (this comment keeps the expression below on line 6, where the test
//  expects it)
  point.x + point.y
