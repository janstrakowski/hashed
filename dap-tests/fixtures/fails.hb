// A fixture for dap-tests: every failure in this language is fatal (SPEC.md
// §8), which is what DAP calls an exception - so a run stops at the node that
// failed instead of unwinding quietly to the end.
error "boom"
