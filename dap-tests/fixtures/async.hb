// A fixture for dap-tests: `async` (SPEC.md §2) runs on real OS threads, so a
// session has more than one thread to report. Both are spawned before line 6,
// which is where adapter.test.js breaks.
let a async (1 + 1);
let b async (2 + 2);
  a + b
