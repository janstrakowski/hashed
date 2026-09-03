// Table construction (map-style, SPEC.md §5) and `concat` as the functional-
// update mechanism: overriding one field of an existing table by merging in a
// table that just has the new value for that field. Evaluates to
// { archive: "https://example.com/x.tar.gz", sha256: "def456" }.
{ .archive = "https://example.com/x.tar.gz", .sha256 = "abc123" }
  concat { .sha256 = "def456" }
