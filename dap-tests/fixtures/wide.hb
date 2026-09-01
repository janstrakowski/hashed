// A fixture for dap-tests: one line holding many expressions, which is
// ordinary here and is what a line breakpoint has to cope with. Line 5 below
// is eight nodes - four names, three operators, and the whole of it - and a
// breakpoint on it must stop once, not eight times. The value is 24.
let a 2; let b 3; let c 4;
  a * b * c
