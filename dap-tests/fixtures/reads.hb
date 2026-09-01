#Directory here .

// A fixture for dap-tests: reads its neighbour through the directory the
// launch configuration named (SPEC.md §9/§16). Launched without `dirs`, it
// fails instead - which is a test of its own.
filetext (loadfile { .dir = ctx.dirs.here, .path = "payload.txt" })
