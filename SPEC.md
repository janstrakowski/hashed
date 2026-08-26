# HashedBuild Language Spec (draft)

This is a **living draft**, not a finalized specification — mirrors the README's own framing of this project as a "faked proof-of-concept." Sections below capture design decisions as discussed so far. Anything unresolved is marked inline with `> TODO:`. Expect this document to keep growing and changing.

---

## 1. Overview / philosophy

HashedBuild is a **functional language for build systems**. Its central idea: filesystem entities (files, directories) are first-class values, on equal footing with integers, strings, and other primitives. Building something that touches the filesystem is just producing a result value that happens to incorporate `File` values — not a side-effecting action distinct from ordinary computation.

Design goals (from the README): output reproducibility, incremental updates, standards compliance, extensibility, a standard library of common operations.

## 2. Program / execution model

A **program** is a function that accepts an explicit argument (from the CLI or an API) and an implicit context (composed of builtins and dependencies supplied by the runtime internals), and produces — again — an explicit result and an implicit context. This explicit-argument / implicit-context pairing is the calling convention for **every** function in the language, not just top-level programs (see [§7 Functions](#7-functions)).

**Concurrency.** Execution is sequential by default, in the order established by operator precedence and control-flow structure. Concurrency is opt-in via an `async` directive wrapping an expression. There is no separate upfront pass to detect whether async work exists anywhere — detection is a side effect of the first real execution pass:

- **Pass 1** walks the expression tree in evaluation order, actually executing every synchronous sub-expression as it goes. When it directly encounters an expression wrapped in `async`, it **starts that operation immediately** (fired off, running concurrently in the background) but does not wait for it — evaluation of the `async` expression itself is left for pass 2. An `async` nested further down inside otherwise-sync structure is still found without special-casing, since pass 1's ordinary recursion into sync sub-expressions reaches it regardless of depth.
- If pass 1 finds no `async` anywhere, **pass 2 is skipped entirely.**
- Otherwise, **pass 2** walks the same route again, awaiting every async operation encountered along the way, in order — each is likely already in flight (or done) by the time pass 2 reaches it, which is what makes the sequential in-order awaiting actually concurrent in practice. Once pass 2's walk reaches the end, the work is done.

**Branching interacts with this specially.** Ordinarily a conditional (`if`/`else`, `matches`/`else`, §8) only evaluates whichever branch is actually taken. When async is involved, this changes: *all* branches must still be walked, not just the taken one — because an async operation started inside an untaken branch still has to be awaited to completion; only its resulting *value* is discarded once it resolves. (The build-system framing in §1 suggests why: an async operation likely represents a real side effect — a download, a write — that can't be safely abandoned mid-flight just because its result turns out to be unneeded.)

A condition (of `if` or `matches`) can itself be, or contain, an async expression too — conditions are ordinary expressions, no special restriction. Combined with the rule above, this means pass 1 doesn't need a condition resolved to decide which branch to walk when async is present anywhere: it starts whatever async work exists in the condition and in every branch, and pass 2 resolves everything — condition included — before the correct branch's value is settled on.

**Errors are not scoped per-branch.** If *any* async operation anywhere fails — including one in a branch whose value would have been discarded — the failure "poisons the whole well": the entire evaluation fails, not just the branch that errored.

**No separate dependency graph exists between async operations, because none is needed.** All values are immutable (§6) and there's no mutable handle/promise/channel type in the language — the only way one expression can use another's result is by syntactically containing it. If some expression needs an async sub-expression's value, that sub-expression is, by construction, nested inside it, and since pass 2 walks the exact same route as pass 1 in the same order, it necessarily resolves an inner async value before evaluating anything outside it that consumes it. Ordinary nested-expression evaluation order *is* the dependency graph.

## 3. Primitive types

- **`Integer`** — 64-bit signed
- **`Float`** — 64-bit floating point
- **`Boolean`** — no additional notes
- **`Utf8`** — UTF-8 encoded string, length-based internally (not null-terminated)
- **`File`** — Immutable (from HashedBuild's side) handle to a filesystem entity — file or directory only. Symlink handling exists but is tied to the directories that hold the symlinks.

> TODO: How is `File` hashed / totally ordered / compared for equality (§6 requires *all* values to support this) — by path, by content hash, by inode, some combination? This matters a lot given the reproducibility goal.

> TODO: Numeric literal forms (hex/octal/binary, underscores as digit separators, float exponent syntax) not yet specified.

## 4. Operators

- Standard arithmetic
- Standard comparison
- Standard logical
- **Concatenation** — an infix `concat` literal (i.e. written as a keyword between operands, e.g. `a concat b`)

> TODO: Confirm `concat`'s exact spelling/keyword status and which types support it — `Utf8` only, or also `Array`/`Map`/`File` paths?

> TODO: Unary minus — semantics not yet settled, in particular how it interacts with operand-omission sections (§9). Does `(-2-1)` mean "negate 2, then subtract 1," or "omitted-operand, minus 2, minus 1"?

## 5. Complex types

- **Map** — associative array. Supports access both by arbitrary-type key, `<map>[<expr>]`, and by field-style string key, `<map>.field`.
- **Array** — ordered array of values. Access via `<array>[<expr>]` or `<array>.<non-negative integer>`.
- **Variant** — sum type. Construct via `::<expr>` or `:.name`. Check-or-throw via `!:<expr>` or `!.name`.

All complex types are subject to pattern matching (see [§8](#8-control-flow)).

> TODO: Is `.field` on a `Map` sugar for `["field"]` (only when the key looks like an identifier)? Is `.0` on an `Array` sugar for `[0]`?

> TODO: What's the actual difference between the expr-form and dotted-name form for `Variant` construction (`::<expr>` vs `:.name`) and checking (`!:<expr>` vs `!.name`)? What does "check or throw" mean operationally — assert a value matches a given variant tag and extract its payload, else raise an error?

> TODO: Since all values are immutable (§6), what does a "functional update" of a `Map`/`Array` look like syntactically?

## 6. Value semantics

- All values are **hashable** and have some arbitrary total order defined by HashedBuild, such that any value can be compared with any other value.
- All values are **serializable** — see §15 for the `serialize`/`serialize_file`/`sha256`/`cached` builtins that operationalize this.
- All values are **immutable**.
- Complex types **reference** their subtypes rather than copying them — cycles are possible.
- There is **no type system** in the conventional sense (as in most other languages) — instead there is static analysis (§11).

## 7. Functions

Per the program model (§2), every function threads an explicit argument and an implicit context in, and produces an explicit result and an implicit context out. There are three ways to write one:

1. **Omission.** Any expression with its first (leading) value left out is itself a function — the omitted value becomes the function's argument. `(*3+4)` is a function: "multiply the (omitted) argument by 3, add 4." This applies generally, not just to arithmetic sections — see §9.
2. **A bind-expression with its bound value omitted.** The binding form introduced in §10, `<expr> as <name> <body>`, itself becomes a function when `<expr>` is omitted: `as my_arg my_arg + 1` is a function that binds its (omitted) argument to `my_arg` and evaluates `my_arg + 1`. This is the primary way to declare a function with a named argument — it directly answers the earlier open question of how something like `containerbuild` (README) gets *defined*, not just called.
3. **The explicit `function` directive.** `function <body>` wraps an expression as a function explicitly; the argument is accessed via `#arg` inside `<body>`, with no named binding. E.g. `function #arg + 1`.

> TODO: Can omission (1) and `function` (3) combine — does `function *2+1` make sense, or is `#arg` mandatory once inside `function`? Is there any real semantic difference between an implicitly-created function (bare omission) and an explicit `function ...`, or is `function` purely a disambiguation aid for when omission would otherwise be unclear?

## 8. Control flow

Two constructs, sharing the `else` keyword:

- **Plain conditional**: `<expr> if <condition> else <expr>` — a value-first (postfix) ternary, e.g. `"yes" if x > 0 else "no"`. Confirms plain boolean branching exists alongside pattern matching, not replaced by it.
- **Pattern-based branching**: `<scrutinee> matches <pattern> <expr>` evaluates `<expr>` if `<scrutinee>` matches `<pattern>`. If it does **not** match, this *fails* (propagates a failure) rather than producing a value. `else` recovers from that failure with a fallback, and chains:

  ```
  arg matches pattern1 result1 else matches pattern2 result2 else ... else default
  ```

  (This previously used a dedicated `or` keyword — now unified under `else`, the same keyword `if` uses.)

Per the omission rule (§7 / §9), leaving out the scrutinee makes a `matches`/`else` chain a function.

> TODO: Is `else` a genuinely shared failure-recovery mechanism between `if` (no real "failure," just branching on a boolean) and `matches` (a real match failure being recovered from) — or two constructs that just happen to reuse the same keyword? I.e. does `if`'s `else` share any actual mechanism with `matches`' `else`?

> TODO: What does "fails" mean precisely for an unmatched `matches` with no `else` — propagate like a runtime `check` failure (§11), unwind some other way, or something distinct?

> TODO: Exact pattern syntax — literal values, destructuring of `Map`/`Array`/`Variant`, wildcards? Do pattern variables bind new names into scope for the matched `<expr>` (tying into §10)? Presumably yes — matching without binding the matched parts would be of limited use — but not yet confirmed.

> TODO: An example given alongside this design combines `matches`, `if`, and an implicit name not otherwise described:
>
> ```
> matches pattern if #matches > 0 "its foo" else "its bar"
> ```
>
> Needs clarification: what does `#matches` refer to (the matched value itself? a count of something the pattern captured? the nearest enclosing `matches`, by analogy to `#arg`/`#context`)? And how does this compound expression actually group — is it `matches pattern (if #matches > 0 "its foo" else "its bar")`, or something else?

## 9. Implicit names

A system for deriving values from context instead of explicit names:

- Per §7, any expression (including an `as` bind-expression) with its first value omitted becomes a function; the omitted value is that function's argument.
- `#arg` refers to the nearest enclosing function's argument; `#arg2`, `#arg3`, ... jump *n* levels further out (to enclosing/outer functions).
- `#context` refers to the **current** (nearest enclosing) implicit context (§2). Unlike `#arg`/`#arg2`/..., there is **no way to reach an outer/previous context** from within a function — a called function (including imported code, §13) can only ever see its own immediate context, never anything from its caller's or definer's broader context chain. This is a deliberate security boundary, not an oversight.
- This numbered-jump pattern was earlier said to generalize beyond function arguments — e.g. `#ifn` for `if` expressions. A `#matches` name has also come up (see §8's open question on what it refers to) — presumably the same generalization applies to `matches` too.

> TODO: What's the general rule behind `#<construct><n>`? Does *every* binding-introducing construct get its own addressing scheme, or is this one unified implicit-value stack indexed by nesting level regardless of construct kind?

> TODO: Can more than one leading value be omitted within a single expression/section (e.g. a two-argument omission)?

## 10. Name scopes / bindings

Name scopes are introduced by bindings, which occur in:

1. **The bind-expression**: `<expr> as <name> <body>` — evaluates `<expr>`, binds its result to `<name>`, and evaluates `<body>` with `<name>` in scope. (Replaces an earlier `let <name> = <expr>; <expr>` sketch, and an intermediate `=:` symbol that read oddly as "reversed `:=`".) When `<expr>` is omitted, this becomes a function declaration (§7).
2. **Function definitions** via the explicit `function` directive (§7) — argument accessed through `#arg`, no named binding.
3. **Pattern matching** (`matches`, §8) — pattern variables presumably bind into the scope of the matched expression (see §8's open question on pattern syntax).

Each scope establishes its own names. Child scopes overlay (shadow into) parent scopes.

## 11. Static analysis

- `static_check(<expr>, [error_msg]) <expr>` — enforces a static check. If the check can be statically determined using HashedBuild's static-analysis methods, it's checked at that stage; otherwise it fails, describing why static analysis wasn't possible.
- `check(<expr>, [error_msg]) <expr>` — checks the condition at runtime. If a full static check is available for the same condition, it's checked statically instead, and should never fail at runtime if the static check succeeded.

## 12. Documentation system

A documentation system is planned, intended to be based on the static-analysis mechanism (§11) rather than a conventional type system. No implementation approach has been decided yet.

## 13. Imports

Any `Utf8` value or `File` can be imported, which turns it into a function. Syntax: `import <expr>`. Permissions for imported code are restricted through argument and context restriction — see §9's `#context` security boundary, which presumably underlies this: an imported function's context can only ever be its own, never reaching back into whatever imported it.

> TODO: How does a plain `Utf8` (as opposed to a `File`) "become a function" via `import` — is it treated as inline HashedBuild source text? Beyond context inaccessibility (§9), is there additional, finer-grained permission restriction expressed at the import site (e.g. restricting *which* builtins are reachable, not just which context)?

## 14. Comments

- Line comments: `//`
- Block comments: `/* ... */`

## 15. Serialization, hashing & caching

Four builtins operationalizing §6's "every value is hashable and serializable" claims. Like `import` and `function`, each is a bare keyword prefix taking one trailing expression — no parentheses:

- **`serialize <expr>`** — serializes a value to its canonical binary representation, then base64-encodes that as a `Utf8` string.
- **`serialize_file <expr>`** — the same underlying serialization as `serialize`, but writes the raw binary bytes directly to a file rather than base64-encoding them as text.
- **`sha256 <expr>`** — hashes a value, returning the digest base64-encoded as `Utf8`.
- **`cached <expr>`** — caches a value, or loads it from cache if already present.

(`check`/`static_check` (§11) are the odd ones out, needing parens — plausibly because they take two comma-separated arguments, one optional, and parens are what make multiple arguments unambiguous; a single trailing expression needs no such grouping. Not confirmed as a general rule, just the pattern so far.)

> TODO: `serialize`/`serialize_file`/`sha256` presumably all operate on the same underlying canonical binary serialization of a value — is there one fixed, documented format? This matters for `sha256` to be a meaningful reproducibility guarantee: two structurally-equal values must serialize identically for their hashes to match.

> TODO: Is `sha256`'s hash the same mechanism as §6's "every value is hashable" (used there for the arbitrary total order over all values), or two distinct hashing mechanisms serving different purposes — one for ordering/comparison, one cryptographic for content-addressing?

> TODO: `serialize_file`'s return value — presumably a `File` (§3) pointing at the newly written file? Not stated.

> TODO: `cached` is central to the project's stated reproducibility/incremental-build goals (§1), but its mechanism is wide open: what determines the cache key — a hash of the expression's own structure, of its resolved inputs, something else? Where does the cache live? Does a cache lookup/store count as `async` work under §2's execution model?
