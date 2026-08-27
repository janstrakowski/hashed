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

**Branching interacts with this specially.** Ordinarily a conditional (`then`, `else`, §8) only evaluates whichever branch is actually taken. When async is involved, this changes: *all* branches must still be walked, not just the taken one — because an async operation started inside an untaken branch still has to be awaited to completion; only its resulting *value* is discarded once it resolves. (The build-system framing in §1 suggests why: an async operation likely represents a real side effect — a download, a write — that can't be safely abandoned mid-flight just because its result turns out to be unneeded.)

A condition (of `then`, `and`, `or`, `is`) can itself be, or contain, an async expression too — these are ordinary expressions, no special restriction. Combined with the rule above, this means pass 1 doesn't need a condition resolved to decide which branch to walk when async is present anywhere: it starts whatever async work exists in the condition and in every branch, and pass 2 resolves everything — condition included — before the correct branch's value is settled on.

**Errors are not scoped per-branch.** If *any* async operation anywhere fails — including one in a branch whose value would have been discarded — the failure "poisons the whole well": the entire evaluation fails, not just the branch that errored.

**No separate dependency graph exists between async operations, because none is needed.** All values are immutable (§6) and there's no mutable handle/promise/channel type in the language — the only way one expression can use another's result is by syntactically containing it. If some expression needs an async sub-expression's value, that sub-expression is, by construction, nested inside it, and since pass 2 walks the exact same route as pass 1 in the same order, it necessarily resolves an inner async value before evaluating anything outside it that consumes it. Ordinary nested-expression evaluation order *is* the dependency graph.

**Implementation note (2026-08-27):** the evaluator (`src/eval_async.odin`) doesn't literally run two tree walks. `async <expr>` spawns `<expr>` on a real OS thread and returns an opaque handle immediately (that alone *is* "pass 1: start it"); a generic `await_value` resolves a handle (joining its thread, or propagating its failure) and is inserted at the small set of places that genuinely need a concrete value — arithmetic/comparison/concat/table-access operands, a call target, a ctx swap, a guard's condition, `Table`/`Variant` entries. Since `await_value` is a no-op for any other kind of `Value`, this reproduces "pass 2 is skipped entirely when there's no async" for free, at zero cost to programs that never use it. `then`/`else` and `and`/`or` additionally do a purely structural scan (`contains_async_anywhere`, deliberately ignoring §7's hole-boundary rules) to decide whether their untaken side must still be force-evaluated-and-awaited for its side effects — ordinary (non-async) branching is completely unaffected. Firing several sibling `async`s before awaiting any of them (as `Table`/`Variant` construction does) is what makes them actually run concurrently with each other. Known simplifications: an `async` sub-evaluation doesn't participate in the step-trace or interactive-debugger mechanisms (its own `Interpreter` never sets either), and if a *sibling*, already-fired async is abandoned because another entry in the same `Table`/call fails synchronously first, its background thread is left to finish unjoined rather than being explicitly cleaned up — consistent with this evaluator's existing "runtime values are never freed" stance, not a new gap.

## 3. Primitive types

- **`Integer`** — 64-bit signed
- **`Float`** — 64-bit floating point
- **`Boolean`** — no additional notes
- **`Utf8`** — UTF-8 encoded string, length-based internally (not null-terminated)
- **`Bytes`** — raw binary data, length-based like `Utf8` (not null-terminated) but with no UTF-8 (or any other) validity constraint — arbitrary bytes. Hashing/equality/ordering are byte-wise, per §6's generic total order.
- **`File`** — Immutable (from HashedBuild's side) handle to a filesystem entity — file or directory only. Symlink handling exists but is tied to the directories that hold the symlinks.
- **`Nothing`** — a unit type with exactly one value, the literal `nothing`. A generic "no meaningful value" result — e.g. for a function whose point is its effect on the returned context (§2) rather than its explicit result. Participates in §6's value semantics like everything else (hashable, ordered, serializable) with no special-cased behavior. Also the payload the `absent` sugar carries — see [§5's "Optional values"](#5-complex-types).

**Hashing / equality / ordering.** A `File`'s identity is **pure content, independent of path.** Where it was read from is how the value was obtained, not part of the value itself — two `File`s built from different paths are equal whenever their content matches. Ordering follows the same generic total-order mechanism as every other value (§6), keyed off this hash.

- A **regular file**'s hash is just `hash(content_bytes)`. Its own permission bits (e.g. executable) are *not* part of a bare `File` value's identity — permissions only become relevant as metadata about how the file sits inside a directory (next point).
- A **directory**'s hash is computed over its entries, sorted by name for determinism (independent of filesystem readdir order):
  ```
  dir_entry_hash(name, entry) =
    hash(name, "file",    content_hash, is_executable)   // executable flag only — not full POSIX mode
    hash(name, "dir",     child_dir_hash)                 // directories carry no exec bit
    hash(name, "symlink", target_path_string)             // target is NOT followed/resolved
  dir_hash = hash(sorted [dir_entry_hash(name, entry) for each entry])
  ```
  A symlink entry hashes the link itself (its target path string) rather than resolving through it — consistent with symlink handling being a property of the containing directory, not a standalone `File` value in its own right.

> TODO: full POSIX mode bits (owner/group/other rwx) are deliberately excluded as noise — confirm this holds up in practice, or whether some other bit besides "executable" ever needs to round-trip through a build.

**Numeric literals** (proposed 2026-08-26, loosely modeled on C but simplified — no type-width suffixes needed, since there's exactly one `Integer` width and one `Float` width):

- **`Integer`**: decimal (`42`), hex (`0x2A`/`0X2a`), octal (`0o52` — an explicit prefix, unlike C's ambiguous bare-leading-zero form), binary (`0b101010`).
- **`Float`**: decimal with a mandatory digit on both sides of the `.` (`0.5`, not `.5` — a readability choice, not a grammar necessity: dotted-suffix `Table` access, §5, doesn't actually collide, since an omitted operand there is blank, not spelled with a leading `.`), plus an optional decimal exponent (`1.5e10`, `1.5E-3`). No hex-float form (C99's `0x1.8p3`) — left out as unneeded for a build-system language, revisitable later.
- **Digit separator**: `_`, freely between digits in either form, including within an exponent (`1_000_000`, `0xFF_FF_FF`, `1_000.5e1_0`) — not leading, trailing, doubled, or adjacent to a base prefix or the decimal point.
- A literal is `Float` iff it contains a `.` or an exponent; otherwise it's `Integer` — no suffix needed to disambiguate.

> TODO: Is there a conversion between `Bytes` and `Utf8` (encode/decode, presumably fallible one way since not all `Bytes` are valid UTF-8)? Also unclear whether `serialize`'s (§15) "canonical binary representation" is itself conceptually a `Bytes` value before being base64-encoded into the `Utf8` it actually returns.

## 4. Operators

- Standard arithmetic
- Standard comparison
- Standard logical — spelled `and`/`or` (words, not `&&`/`||`); see §8 for their scope-threading rules (`and` threads scope left-to-right, `or` doesn't)
- **Concatenation** — an infix `concat` literal (i.e. written as a keyword between operands, e.g. `a concat b`)

**Type coverage** (resolved 2026-08-26, revised same day to add `Table`): `concat` supports `Utf8`, `Bytes`, and `Table` (§5) — same-type only, no mixing `Utf8` with `Bytes` in one call. `Table concat Table` merges two tables, with the right-hand side's entries overriding the left's on key collision — this doubles as `Table`'s functional-update mechanism (§5). `File` doesn't support `concat`.

**Unary minus** (resolved 2026-08-26): reads exactly as in ordinary mathematics. `-2-1` means "negate 2, then subtract 1" (`(-2) - 1 = -3`), binding tighter than any binary operator, applied to whatever primary/operand immediately follows it (a literal, a name, a parenthesized expression, ...). Consequently, a leading `-` at the start of an expression is **never** read as an omitted left operand of binary minus (§7) — that specific ambiguity resolves permanently in favor of unary minus, since "blank, then `-`" and "unary minus" are indistinguishable at that position and unary minus wins outright. There's still no bare-omission-section spelling for "subtract N from the omitted argument" as a result — `func #arg - 1` or `asfunc` remain the way to write that function explicitly.

## 5. Complex types

Revised 2026-08-26: `Map`, `Array`, and `Variant` are retired as separate types, unified into one Lua-style associative structure:

- **`Table`** — maps arbitrary hashable keys (§6) to values. There's no structural distinction between "array-like" and "map-like" usage anymore — a sequence is just a `Table` whose keys happen to be sequential integers **starting at 1** (revised 2026-08-26: the language is 1-indexed, retroactively — a sequence's first element is `t[1]`/`t.1`, not `t[0]`/`t.0`).
  - **Access**: `<table>[<expr>]` for an arbitrary key, or dotted-suffix sugar: `<table>.field` for an identifier-shaped suffix (sugar for `<table>["field"]`, an `Utf8` key), `<table>.5` for a numeral-shaped suffix (sugar for `<table>[5]`, an `Integer` key). One rule now covers what used to be two separate types' access sugar — the suffix's own shape (identifier vs. numeral) picks the key's type.
  - **General dot sugar** (resolved 2026-08-26): `.<identifier>` is this exact same sugar — "the identifier's own spelling, as a `Utf8` string, substituted wherever a bracketed key/expression would go" — everywhere a dot-form like this appears in the language, not just plain access: the `:.`/`!.` variant forms (below) and `{.field}` pattern selectors (§8) are all the identical rule applied in different contexts, not separate mechanisms that happen to share a symbol.
  - **Hashing/equality/ordering**: `hash(Table) = hash(sorted [(key, value) for each entry], ordered by key per §6's generic total order)` — the same sort-then-hash pattern §3 already uses for `File` directory hashing.
  - **`empty`** — a bare keyword that, in an ordinary expression context, constructs an empty `Table` (zero entries) — the first concrete answer to this section's "is there `Table` literal syntax" question, at least for the trivial case; a nonempty literal form is still unspecified. `empty` also doubles as a pattern (§8) matching a `Table` with zero entries.

Subject to pattern matching via `is` (see [§8](#8-control-flow)).

### Variants, as a `Table` convention

There's no separate `Variant` type anymore — a "variant" is just the idiom of a **one-entry `Table`**, where the key is the tag and the value is the payload:

- **Construct**: `::<key-expr> <value>` builds `{ <key-expr>: <value> }`, where `<key-expr>` is any expression computing the key. `:.<name> <value>` is the dot-sugar special case (above) for a static, literal tag: `:.<name> <value>` ≡ `::"<name>" <value>`. Both take the same trailing payload — the two forms differ only in how the key is spelled, not in arity. (This resolves the earlier open question here: it's hypothesis (a), a static/dynamic key distinction — not (b), a payload/no-payload one. Earlier examples in this doc that wrote a bare identifier straight after `::`, e.g. `::present <value>`, were technically imprecise — a literal tag like `present` should use the `:.` form: `:.present <value>`.)
- **Check-or-throw**: `!:<expr>` / `!.<name>` — asserts the table has a matching entry and extracts its value, else raises a failure (§11). Same relationship: `!:<expr>` checks an arbitrary computed key, `!.<name>` is dot-sugar for `!:"<name>"`.

### Optional values

Revised 2026-08-26: `absent` is retired. A present optional is still a one-entry `Table`, but an absent one is now represented directly by `empty` (an empty `Table`, above) rather than a second tag (`::absent nothing`) — presence is signaled by whether the table has *any* entries at all, not by which of two tags it carries:

- **`present <value>`** — sugar for `:.present <value>` (i.e. `::"present" <value>`), a `Table` tagged `present` carrying `<value>` as its payload.
- **`ispresent <value>`** — `Boolean`, true iff `<value>` is a `present`-tagged `Table`. Unaffected by this revision — it only ever tested for the `present` tag specifically.
- **`isnothing <value>`** — `Boolean`, true iff `<value> == nothing` (plain equality against the `Nothing` singleton, §3) — a separate, still-useful check unrelated to the `Table`-based optional idiom.
- **`isthere <value>`** — one check spanning both optional representations: `ispresent <value>` if `<value>` is a `Table` at all, else `isnothing <value>`. Also unaffected — `ispresent(empty)` is already `false`, so an absent optional correctly reads as "not there" either way.

**Table literals** (resolved 2026-08-26): two forms, sharing the outer `{ ... }` syntax already used for `empty` and for patterns (§8):

- **Map-style**: `{ .field = value, [expr] = value, ... }` — explicit key/value pairs, reusing the same `.field`/`[expr]` key-selector syntax as access and patterns, now followed by `= value`.
- **Sequence-style**: `{ value1, value2, ... }` — bare comma-separated values, implicitly keyed `1, 2, 3, ...` (§5's 1-indexing).

Mixing the two forms in one literal is an error — not necessarily a *syntax*-level one; it could equally be something static analysis (§11) catches rather than the parser.

**Functional update** (resolved 2026-08-26): achieved via `concat` (§4), not dedicated syntax — `original concat { .field = new_value }` produces an updated table, since `Table concat Table` already has the right override-on-collision semantics.

## 6. Value semantics

- All values are **hashable** and have some arbitrary total order defined by HashedBuild, such that any value can be compared with any other value.
- All values are **serializable** — see §15 for the `serialize`/`serialize_file`/`sha256`/`cached` builtins that operationalize this.
- All values are **immutable**.
- Complex types **reference** their subtypes rather than copying them — cycles are possible.
- There is **no type system** in the conventional sense (as in most other languages) — instead there is static analysis (§11).

## 7. Functions

Per the program model (§2), every function threads an explicit argument and an implicit context in, and produces an explicit result and an implicit context out. There are three ways to write one:

1. **Omission.** A *hole* — a blank left where a value is grammatically expected, anywhere in an expression, not just its leading operand — makes its enclosing expression a function; whatever value is ultimately supplied fills every hole in that expression via `#arg`. `(*3+4)` is a function: "multiply the (omitted) argument by 3, add 4."

   Since HashedBuild functions map exactly one explicit argument to one explicit result (§2) — there are no positional parameters — multiple holes in the same expression don't create a multi-argument function. They just **duplicate the one argument**: `(* )` (a hole on each side of `*`) is `func (#arg * #arg)`, a squaring function.

   **Hard boundaries.** A hole's function-ness bubbles outward through ordinary expression structure — operators, parens, unary prefixes — but stops at the edge of whichever grammatically distinct *slot* it sits inside. A slot is anywhere the grammar expects exactly one concrete value, or one function applied to some object, standing on its own: each individual function-call argument, each individual `Table` literal element, either side of an `as` bind-expression (§10), either side of `and`/`or`/`then`/`|>`/`withctx` (below, §8/§9), and `else`'s right side (§8) — `else`'s left side isn't a free slot at all, since it must be, syntactically, the `then` it's immediately attached to. A hole never crosses from one such slot into a sibling slot or out into whatever contains the whole construct — it only turns *that slot* into a function. So `(*1-2) or b`, written as one complete slot (a bare statement, one call argument, one array element, ...), bubbles across the entire `or` expression — `func (#arg*1-2 or b)` — because operators and parens aren't slot boundaries by themselves. But a hole written inside just the `happy_path` of a `then` doesn't turn the whole `|>`/`then`/`else` chain into a function, only `happy_path` itself does.
2. **A bind-expression with its bound value omitted.** The binding form introduced in §10, `<expr> as <name> <body>`, itself becomes a function when `<expr>` is omitted: `as my_arg my_arg + 1` is a function that binds its (omitted) argument to `my_arg` and evaluates `my_arg + 1`. This is the primary way to declare a function with a named argument — it directly answers the earlier open question of how something like `containerbuild` (README) gets *defined*, not just called.
3. **The explicit `func` directive.** `func <body>` wraps an expression as a function explicitly; the argument is accessed via `#arg` inside `<body>`, with no named binding. E.g. `func #arg + 1`.

**Resolved 2026-08-26**: omission (1) and `func` (3) combine fine — `func *2+1` is valid, meaning exactly what the bare section `(*2+1)` already means. There's no real semantic difference between the two: `func` doesn't introduce any behavior the omission mechanism doesn't already have on its own. It's effectively an **obsolete wrapper** — just an alternate, explicit spelling (naming the argument `#arg` instead of leaving a blank) for the same underlying function-construction mechanism, not a separate concept.

**The pipe operator, `|>`** (added 2026-08-26, replaces `consider`, §8): `<value> |> <function>` calls `<function>` with `<value>` as its argument — ordinary function application, spelled left-to-right for readability and chaining (`x |> f |> g` means `g(f(x))`). Since `|>`'s left side is an ordinary omittable operand like any other operator's, omitting it (`|> f`) makes the whole pipe expression a function of the omitted value, for free, via the general omission rule above — no special-casing needed. This is what lets a guard chain (§8) become "a function of the thing being tested" without a dedicated construct.

**The context operator, `withctx`** (added 2026-08-26): `<expr> withctx <new_ctx>` evaluates `<expr>` with `<new_ctx>` as the current implicit context (`ctx`, §9) for everything inside it, restoring whatever context was active before once `<expr>` finishes. Precedence-wise it's the loosest operator in the language — looser even than `as`-bind. Its left side follows the same omission rules as `|>`'s (above): an entirely omitted `<expr>` (`withctx narrow_ctx`) makes the whole thing a function of the omitted value, evaluated under `<new_ctx>`.

**Gotcha (found while implementing, worth knowing when writing this):** "loosest operator" describes how `withctx` groups *within one already-complete expression*, not "wraps everything written to its left." Because an `as`-bind's body (§10) itself recurses through the full expression grammar (the same greedy-tail behavior as `present`/`:.`/`::`'s payload, §5), a trailing `withctx` gets absorbed into whatever's already parsing its body rather than reaching back to wrap the whole `as`-bind: `x as a a + 1 withctx narrow_ctx` parses as `x as a (a + 1 withctx narrow_ctx)` — the context change applies only to computing `a + 1`, not to `x`'s own evaluation, and `narrow_ctx` itself is read under the *outer* context either way (`eval_with_ctx` evaluates `<new_ctx>` before swapping). To make `withctx` wrap a whole `as`-bind, parenthesize it explicitly: `(x as a a + 1) withctx narrow_ctx`.

**`chctx`** (added 2026-08-26, sits at the same precedence as `withctx` and chains with it left-associatively — `x withctx c1 chctx c2` is `(x withctx c1) chctx c2`, and each's right side parses one level tighter than either keyword itself, so a further `withctx`/`chctx` there needs parens, same reasoning as the gotcha above): `<expr> chctx <function>` — like `withctx`, but instead of supplying the new context directly, supplies a `<function>` that computes it from the old one: `<expr> withctx (<function> ctx)`, as one operator. `<function>` is called with the context active *before* `<expr>` starts (§9's live-context rule for what a function sees applies here too - see "Context & permissions"). Exists mainly to make relative context edits (narrow/extend one field, leave the rest) reusable as ordinary function values instead of rebuilding the whole context inline every time — `chperm` (§16) is the first such function.

`withctx` **replaces** the context wholesale — it doesn't merge with whatever context was already active. To narrow (or extend) just part of the current context while keeping the rest, build the new one from the old: `<expr> withctx (ctx concat { .permissions = empty })` denies everything inside `<expr>`, using `ctx` (§9) to read the outer context and `Table concat Table`'s (§4/§5) functional-update semantics to override just the one field.

**Asserting function-ness.** `asfunc <expr>` and `asfuncstatic <expr>` don't *construct* a function — they *assert* that an arbitrary expression's already-computed value is one, mirroring the `check`/`static_check` duality (§11):

- `asfunc <expr>` — verified statically when HashedBuild's static analysis can determine it; otherwise falls back to a runtime check, raising via the standard failure channel (§8/§11) if the value turns out not to be callable.
- `asfuncstatic <expr>` — requires the static determination to succeed, with no runtime fallback: fails at that stage, describing why, if static analysis can't establish it.

Both pass the wrapped value through unchanged when the assertion holds. This is how an expression that doesn't syntactically *look* like a function — e.g. a bare name bound to a function value elsewhere, rather than an inline omission section like `*1+3` — can still be treated as an unambiguous function by constructs that otherwise rely on syntactic obviousness (see §8's implicit function application).

## 8. Control flow

Revised 2026-08-26: the bespoke `if`/`andif`/`then` guarded-branch grammar is retired, replaced by composing more general, orthogonal primitives — boolean combinators with their own scope-threading rules, a pattern-test operator, a success-only conditional, and its dedicated failure-recovery counterpart. The old construct is still expressible, just as an ordinary composed expression rather than dedicated syntax:

- **`and`** (spelled out, not `&&`): `<c1> and <c2>` — `Boolean` AND. `c2` is evaluated as a **child of `c1`'s scope**, inheriting any names `c1` bound (e.g. via `is`, below). This is how guard chains now accumulate bindings, replacing the old `andif`.
- **`or`** (spelled out, not `||`): `<c1> or <c2>` — `Boolean` OR. `c1` and `c2` are independent: each inherits scope from `or`'s **own parent**, not from each other — since only one side of an `or` ever actually matters, there's no meaningful "other side's bindings" to share.
- **`is`** (unchanged from the prior round): `<value> is <pattern>` — `Boolean`, true iff `<value>` matches `<pattern>`; false (not a failure) on a mismatch. A match additionally binds pattern names into scope for whatever inherits from it (via `and`, `then`, `else` — see below).
- **`then`** (named `whentrue`, then `whenso`, now settled on `then`; no longer bundles its own `else`): `<condition> then <happy_path>` — if `<condition>` is `true`, evaluates and returns `<happy_path>`, which inherits `<condition>`'s scope the same way `and`'s right side does; if `false`, it **fails** — there's no bad path built in anymore.
- **`else`**: `<conditional> else <expr2>` — catches a *failed conditional* specifically, not failures in general. `else` must appear **immediately** after the conditional it attaches to — today that means directly after a `then` (`<condition> then <happy_path> else <bad_path>`); it is not a free-floating operator you can append to an arbitrary expression. In particular, it does **not** catch a failed `check` (§11) or an `error` (§11) — those are not conditionals, and propagate as fatal failures regardless of any `else` elsewhere in the expression. `<expr2>` inherits the same scope `<happy_path>` would have (the condition's accumulated scope), since `else`'s left side is always, structurally, that same `then`.

**`consider` is retired 2026-08-26**, replaced by the general pipe operator `|>` (§7): rather than a dedicated object-setting construct, the whole guard chain (`(guards) then happy else bad`) is just an ordinary expression that `|>` calls like any other function.

```
object |> (c1 and is p1 and c2) then happy else bad
```

`c1` is tested, `is p1` runs as `c1`'s scope-child (binding pattern names), `c2` runs as `p1`'s scope-child — none of `and`/`is` can themselves fail, they just produce `Boolean`s. `then` is the one thing that can fail here: if the combined condition holds, it evaluates `happy` (a scope-child of the whole condition chain); if not, it fails, and the immediately-following `else` catches that and evaluates `bad`.

### Implicit function application in a guard position

Anywhere a `Boolean` is expected among these primitives' operands, an expression that reads as a function instead — via omission (§7, e.g. `is p1`'s omitted left operand, or a bare `*2>0`) or `asfunc`/`asfuncstatic` (§7) — is applied to the value most recently piped in via `|>`, rather than used as-is. Inside such a function, that value is `#arg` — an ordinary function call, no separate implicit name needed (the old `#object`, §9, is retired along with `consider`).

**Resolved 2026-08-26**: `#arg` used directly inside a guard, `happy_path`, or `bad_path` does reach all the way out to the nearest enclosing `|>`'s value, regardless of intervening hard-boundary slots (§7) — see §9's general rule for exactly why: `#arg` lookup isn't confined by hard boundaries the way a hole is.

### Failure semantics

`then` (a false condition), a failed `check` (§11), and `error` (§11) are three distinct failure sources — but only `then`'s failure is recoverable in-line, and only by an `else` written immediately after it. A failed `check` or an `error` call is **fatal**: it isn't caught by any `else`, however close, and (per §2's async rules) can still poison a whole async evaluation.

**Resolved 2026-08-26**: a failed `check`/`error` is unconditionally fatal — no recovery mechanism exists anywhere in the language, full stop.

**Resolved 2026-08-26**: `and`/`or` do short-circuit, the ordinary way — except under §2's async exception, where *all* operands still get walked/awaited regardless (only the discarded side's *value* goes unused), the same rule that already applies to `then`/`else` branches.

The old "does omitting the leading object promote the whole construct to a function" question (previously an open TODO once `if`/`whentrue` were retired, then carried over as a question about `consider`) is now resolved by retiring `consider` itself: `|>`'s left side is an ordinary omittable operand (§7) like any other, so `|> (guards) then happy else bad` is already a function of the omitted value for free, no special exception ever needed.

### Pattern syntax for `is`

Resolved 2026-08-26:

- **Binding**: any (sub-)pattern can be bound to a name via `<pattern> as <name>` — reusing the ordinary bind-expression syntax (§10) rather than inventing new syntax for it.
- **`Table` destructuring**: `{ <selector>, <selector>, ... }` (comma-separated, trailing comma allowed) matches a `Table` having the given entries. Each selector:
  - `.field` — requires an entry keyed `"field"` to exist; binds nothing by itself.
  - `.field as f` — same requirement, plus binds that entry's value to `f`, per the general binding rule above.
  - `[<expr>]` — requires an entry keyed by the (arbitrary) value of `<expr>`; combinable with `as` the same way.
  - **Sequences**: a bare `{N}` nested directly inside the braces — e.g. `{{4}}` — asserts the table is an **exact** 1-indexed sequence of length `N` (entries at keys `1..N` present, key `N+1` absent — resolved 2026-08-26: exact, not a minimum/prefix check).
  - **Sequences with elementwise selectors**: `{N}` can be followed by `:` and further selectors, combining the exact-length assertion with ordinary destructuring of specific elements — e.g. `{ {2}: .1 as first, [2] as second }` matches an exact 2-element sequence, binding its first entry to `first` and second to `second` (reusing the same `.field`/`[expr]`/`as` selector syntax above, since a sequence index is just an `Integer` key like any other).
- **Variants** (§5): the construction syntax doubles as pattern syntax — `:.<name> <subpattern>` matches the literal tag `<name>` whose payload matches `<subpattern>`; `::<key-expr> <subpattern>` matches a dynamically computed tag key the same way.
- **Optionals** (§5): `present [as <name>]` matches a `present`-tagged table, optionally binding its payload; `empty` matches a `Table` with zero entries, replacing the retired `absent`/`::absent nothing` pattern.

## 9. Implicit names

A system for deriving values from context instead of explicit names:

- Per §7, a hole anywhere within a grammatical slot turns that slot into a function; the omitted value is that function's argument, and fills every hole in the slot (there's no such thing as a second, distinct positional argument).
- `#arg` refers to the nearest enclosing function's argument; `#arg2`, `#arg3`, ... jump *n* levels further out (to enclosing/outer functions).
- **Scope lookup (resolved 2026-08-26):** `#arg` is an ordinary lexical-scope lookup, a fundamentally different mechanism from §7's hard boundaries — a hard boundary governs where a *hole's* implicit function-ness stops propagating, but it doesn't limit how far an *explicit* `#arg` reference searches. `#arg` bubbles outward through guards, `and`/`or`/`then`/`else`, `Table` literal elements, call arguments, and any other hard-boundary slot, stopping only at the nearest enclosing thing that actually supplies an argument value: `|>` (§7/§8), an ordinary function call, or an explicit `func` (§7) declaration.
- **`ctx`** (renamed from `#context`, 2026-08-26 — see below for why it dropped the sigil) refers to the **current** implicit context (§2): a `Table`, conventionally holding at least a `.permissions` field (see "Context & permissions" below). `<expr> withctx <new_ctx>` (§7) is the only way to change it, for the extent of `<expr>`.

  **Why no sigil, and how that squares with `#arg`'s.** `#arg`/`#arg2`/... are `#`-prefixed specifically so they can never collide with an ordinary bound name — that's the whole point of the sigil. `ctx` drops it and is instead a context-sensitive reserved word (§10): reserved wherever a value is expected (so a bare `ctx` always means "the current context," never a variable lookup), but an ordinary spelling anywhere a *name* is expected (a field, a tag, an `as`-bind target) — so `x as ctx ctx` is valid and binds an unrelated name called `ctx`, but the inner bare `ctx` inside that body still means the implicit context, not the just-bound value, since it's never looked up through the environment in the first place.

  **Security boundary (unchanged in spirit from `#context`, restated precisely 2026-08-26):** a called function can only ever see its own context, never its caller's or definer's broader context chain. Concretely, this means `ctx` is **captured at closure-creation time**, the same way a function's lexical scope already is — *not* read live off whatever's currently active at the call site. Calling a function later, from inside a `withctx` that has since widened the ambient context, does not let that function suddenly see the wider context; it still only ever sees the context that was active when it was made. (Builtins like the filesystem operations below are the one exception, by necessity — see "Context & permissions.")
- `#arg`/`#arg2`/... are unaffected by any of this — they're a completely separate mechanism (see above).

So the numbered-jump pattern isn't one unified stack — it's per implicit-value *kind* (`#arg` for function arguments, `ctx` unnumbered since only the current one is ever reachable), each with its own addressing scheme.

> TODO: Is `#arg` (with `#object` now retired) the complete set of kinds, or do other binding-introducing constructs (e.g. `as`-bindings) eventually want their own numbered implicit name too, rather than requiring an explicit name?

### Context & permissions

Added 2026-08-26, alongside `ctx`/`withctx` above and the filesystem builtins (§16) that are `ctx`'s first real consumer.

- **`ctx.permissions`** is a `Table` used as a *set*: it conventionally holds only `nothing` as every value, and a permission is granted iff its key is **present** (not iff its value is "truthy," since `Nothing` has no such notion) — e.g. `ctx.permissions.io` being present at all, regardless of its (always-`nothing`) value, means I/O is allowed. This works because, unlike Lua, a HashedBuild `Table` (§5/§6) genuinely distinguishes "key absent" from "key present with value `nothing`" — the exact distinction a set-of-flags idiom needs, and Lua's conflation of nil-valued and absent keys can't express.
- **The root context** — active at the very start of a program, before any `withctx` — starts with `{ .permissions = { .io = nothing }, .cache = <the cache, below> }`: I/O is allowed by default. `withctx` is how you *narrow* permissions around a sub-computation (e.g. before calling `import`ed code, §13), not how you grant them from nothing. Since `withctx` replaces the context wholesale (§7), a program that narrows permissions via a hand-built `Table` rather than `ctx concat {...}` loses `.cache` too unless it explicitly carries it over.
- **Builtins read `ctx` live, not captured — the one deliberate exception to the closure-capture rule above.** The capture rule protects a function *from* a caller trying to grant it more authority than it was made with; a builtin like `loadfile` (§16) needs the opposite property — it must see whatever `ctx` is *actually* active at its call site, so that wrapping a call in `... withctx (ctx concat { .permissions = empty })` genuinely denies it from the outside. If builtins captured `ctx` at (interpreter-startup) creation time instead, `withctx` could never restrict them at all.
- **`ctx.cache`** (added 2026-08-27) is its own type, distinct from `File` — see §16 for the full write-up. It's "accepted as a directory" (usable as `createfile`'s `.dir`) without actually being one: it can't be read from, traversed, or passed to `loadfile`/`symlink`/`readlink`, only written to via `createfile`.

## 10. Name scopes / bindings

Name scopes are introduced by bindings, which occur in:

1. **The bind-expression**: `<expr> as <name> <body>` — evaluates `<expr>`, binds its result to `<name>`, and evaluates `<body>` with `<name>` in scope. (Replaces an earlier `let <name> = <expr>; <expr>` sketch, and an intermediate `=:` symbol that read oddly as "reversed `:=`".) When `<expr>` is omitted, this becomes a function declaration (§7).
2. **Function definitions** via the explicit `func` directive (§7) — argument accessed through `#arg`, no named binding.
3. **Pattern matching** (the `is` operator, §8) — a successful `is <pattern>` binds names from the pattern into scope for whatever inherits from it via `and`/`then`/`else`; names are spelled out via `<sub-pattern> as <name>` (§8), reusing this same bind-expression syntax.

Each scope establishes its own names. Child scopes overlay (shadow into) parent scopes.

**Context-sensitive keywords (written back 2026-08-26 — this was already true of the implementation, just never stated here):** reserved words (`then`, `else`, `as`, `is`, `and`, `or`, `present`, `empty`, `nothing`, `ctx`, §9, and the rest) are reserved only in the specific grammatical position the language actually looks for them — anywhere a bare *name* is expected instead (a `Table` field, a variant tag, an `as`-bind's target), the identical spelling is just an ordinary name, no different from any other identifier. `:.present 1` (a tag literally named "present") and `x as then 42` (binding a value to a name literally spelled "then") are both valid for exactly this reason.

## 11. Static analysis

- `static_check(<expr>, [error_msg]) <expr>` — enforces a static check. If the check can be statically determined using HashedBuild's static-analysis methods, it's checked at that stage; otherwise it fails, describing why static analysis wasn't possible.
- `check(<expr>, [error_msg]) <expr>` — checks the condition at runtime. If a full static check is available for the same condition, it's checked statically instead, and should never fail at runtime if the static check succeeded.
- `error [msg]` — unconditionally throws a failure, with an optional message, into the same failure channel §8's `then` and a failed `check` raise into — i.e. it propagates to the nearest enclosing `else`, or is fatal if uncaught. Bare keyword-prefix form: no parens, since its one argument is optional rather than one-of-several — there's nothing for parens to disambiguate (§15).

**Resolved 2026-08-26**: `msg` is required to be a `Utf8`.

## 12. Documentation system

A documentation system is planned, intended to be based on the static-analysis mechanism (§11) rather than a conventional type system. No implementation approach has been decided yet.

## 13. Imports

Any `Utf8` value or `File` can be imported, which turns it into a function. Syntax: `import <expr>`. Permissions for imported code are restricted through argument and context restriction — see §9's `#context` security boundary, which presumably underlies this: an imported function's context can only ever be its own, never reaching back into whatever imported it.

**Resolved 2026-08-26**: a `Utf8` given to `import` is treated as inline HashedBuild source text. There's no additional, finer-grained permission restriction at the import site beyond §9's `#context` inaccessibility boundary — for both `Utf8` and `File`, that context boundary is the *only* restriction mechanism.

## 14. Comments

- Line comments: `//`
- Block comments: `/* ... */`

## 15. Serialization, hashing & caching

Four builtins operationalizing §6's "every value is hashable and serializable" claims. Like `import` and `func`, each is a bare keyword prefix taking one trailing expression — no parentheses:

- **`serialize <expr>`** — serializes a value to its canonical binary representation, then base64-encodes that as a `Utf8` string.
- **`serialize_file <expr>`** — the same underlying serialization as `serialize`, but writes the raw binary bytes directly to a file rather than base64-encoding them as text. **Resolved 2026-08-26**: returns the `File` (§3) it just wrote.
- **`sha256 <expr>`** — hashes a value, returning the digest base64-encoded as `Utf8`. **Resolved 2026-08-26**: this *is* §6's "every value is hashable" mechanism — the same one, not a second cryptographic-specific hash living alongside it.
- **`cached <expr>`** — caches a value, or loads it from cache if already present.

(`check`/`static_check` (§11) are the odd ones out, needing parens — plausibly because they take two comma-separated arguments, one optional, and parens are what make multiple arguments unambiguous; a single trailing expression needs no such grouping. Not confirmed as a general rule, just the pattern so far.)

**Resolved 2026-08-26**: `serialize`/`serialize_file`/`sha256` are all part of one consistent underlying system — one canonical binary format, one hash mechanism, shared with §6's general value-hash (used for ordering/equality everywhere, e.g. `Table`'s key-sorted hash and `File`'s directory hash, §3/§5).

**`cached`'s mechanism (resolved 2026-08-26):** the cached expression is treated *as a function* and hashed as one — the cache key is the hash (per the one system above) of that function representation, not a hash of its resolved output value. `cached` is not inherently async by itself; async-ness is controlled explicitly by *where* `async` (§2) is placed: `async cached <expr>` makes the cache lookup/store itself asynchronous, while `cached async <expr>` instead makes the underlying expression's own evaluation asynchronous, with the caching wrapper around it synchronous.

> TODO: Where does the cache actually live (on-disk location, process-local vs. shared/distributed) — not addressed by this round's resolution of the cache-*key* mechanism.

## 16. Filesystem builtins

Added 2026-08-26. Unlike everything in §7–§15, these are **not syntax** — no new grammar, no keyword-prefix parsing. They're ordinary `Function` values, pre-bound to names in the global scope before any program runs, called exactly like any other function (`loadfile some_path`, `f arg`). This is a deliberate, minimal way to grow the standard library without growing the grammar: a future addition here never needs a parser change.

The four filesystem operations below are gated by [`ctx.permissions.io`](#9-implicit-names) (present ⇒ allowed) at the moment they're actually called — see "Context & permissions" (§9) for why builtins check `ctx` live rather than capturing it. Denied or failed calls raise into the ordinary failure channel (§8) — catchable by an enclosing `then`/`else`, fatal if uncaught, same as `check`/`error` (§11).

- **`loadfile <path>`** — reads the file or directory at `<path>` (a `Utf8`), returning it as a `File` (§3). `<path>` is an ordinary filesystem path (relative to the process's working directory, or absolute) — this form does not sandbox to any directory, relying solely on the `io` permission check above.
- **`loadfile { .dir = <handle>, .path = <sub_path> }`** — reads `<sub_path>` (`Utf8`) relative to `<handle>` (a `File` previously obtained from `loadfile`, naming a directory), returning a `File` the same way. **`<sub_path>` cannot resolve to anything outside `<handle>`'s directory** — not just literal `..` segments, but also via a symlink inside the directory that points outward. **Implementation note (revised 2026-08-26):** originally specified as enforced via Linux's `openat2`/`RESOLVE_BENEATH`; in practice that hit an environment-specific kernel bug during development (`openat` via a real directory fd failing unless `O_CREAT` is set, on at least one WSL2 build), so containment is instead done with a manual, component-by-component walk — every intermediate directory is opened with `O_NOFOLLOW`, rejecting *any* symlink encountered along the way (not just one that would resolve outward) — using only the long-portable `*at()` syscall family rather than the newer, less consistently supported `openat2`.
- **Either form, given a directory, returns a `File` that can itself be used as `<handle>` in a further `loadfile`/`createfile`/`symlink`/`readlink` call** — this is how a directory gets traversed: open it once, then address everything inside it relative to that one handle, each access independently contained to it.
- **`createfile { [.dir = <handle>], .path = <path>, .content = <value> }`** — creates a new file at `<path>` (contained to `<dir>` if given, exactly like `loadfile`'s two-argument form; an ordinary unsandboxed path if `.dir` is omitted) with `<content>` (`Utf8` or `Bytes`) as its bytes, returning the `File` it just created. **Exclusive for now**: fails if a file already exists at that path — no overwrite mode yet.
- **`symlink { .dir = <handle>, .path = <path>, .target = <value> }`** — creates a symlink at `<path>` (contained to `<dir>`, same rule as above — `.dir` is *not* optional here, since a symlink is always an entry inside some directory, §3) whose target string is `<value>` (`Utf8`). The target is stored as-is, not validated or resolved — consistent with §3's directory-hash treatment of symlinks ("target is NOT followed/resolved"). Returns `nothing` — a symlink isn't a `File` value in its own right (§3).
- **`readlink { .dir = <handle>, .path = <path> }`** — reads the target string of the symlink at `<path>` (contained to `<dir>`) without following it, returning it as `Utf8`.
- **`filetext <file>`** (added 2026-08-27, partially resolving the TODO below) — the minimal fix for "there's no way to get content back out of a `File`": takes a `File` (a *regular* file — fails for a directory `File`) and returns its content as `Utf8`, failing if the bytes aren't valid UTF-8. Not gated by `io` — the actual read already happened when `loadfile` produced the `File`; this just views already-in-memory bytes as text. `Bytes` extraction (for content that isn't valid UTF-8) is still open, per the TODO below.

> TODO: `filetext` only covers the `Utf8` half of "get content back out of a `File`" - a `Bytes`-returning counterpart is still unspecified, same underlying gap as §3's open `Bytes`↔`Utf8` conversion question. Also unspecified: what a directory `File`'s "listing" looks like as a value (so you can enumerate its entries, not just address a name you already know).

**`chperm { .name = <tag>, .enabled = <bool> }`** (added 2026-08-26) — not gated by `io` itself (it doesn't touch the filesystem, just builds a value); returns a `ctx`-changing function (§7/§9's `chctx`) that, given a context, produces a copy of it with `.permissions.<name>` present (if `<enabled>` is true) or absent (if false), every other field unchanged. Meant to be used right into `chctx`: `<expr> chctx chperm { .name = "io", .enabled = false }` denies `io` for just `<expr>`. Exists specifically so a single-permission edit reads as a small, reusable, named function rather than a `ctx concat {...}` expression rebuilt inline every time.

### `ctx.cache`

Added 2026-08-27. A write-only, content-addressed blob store, its own type (distinct from `File`) even though `createfile`'s `.dir` accepts it exactly like a directory handle — reading, traversal, and `loadfile`/`symlink`/`readlink` all refuse it, since there's no meaningful name to look anything up by (see below). Gated by `io` like the other filesystem operations.

- **Location.** Resolved once per program run, in order: the CLI's `--cache-dir <path>` if given; otherwise `$XDG_CACHE_HOME/hashedbuild`; otherwise `$HOME/.cache/hashedbuild`. The directory (and any missing ancestor) is created lazily, on the first actual write — a program that never touches `ctx.cache` never creates it.
- **Naming.** Every entry is stored under `sha256_<content-hash, base64url, no padding>` — the name *is* the content's own hash, computed by the write itself. This is why "names of the children don't matter": whatever the caller might otherwise think to call an entry is irrelevant, since the store assigns the name, not the caller.
- **Writing.** `createfile { .dir = ctx.cache, .content = <value> }` — note there's no `.path`; it wouldn't mean anything, since the name isn't caller-chosen. Writing content whose hash already has an entry on disk (from this run or an earlier one) **dedupes**: the existing entry is reused as-is, silently, rather than failing like an ordinary exclusive `createfile` or writing a redundant duplicate — this is what makes it a cache across runs, not just a one-shot content dump.
- **The returned `File` is real, but its path is display-only.** `createfile`'s result here is an ordinary `File` (§3), and printing/displaying it (e.g. in the REPL or the live editor's result pane) shows the entry's actual absolute path on disk — but there is no builtin that lets HashedBuild source read that path back out as a `Utf8` value. The program can hold the handle and pass it around, but it never learns *where* its data physically landed; only a human inspecting the program's output does.
- **Not searchable.** There's no `loadfile`/`symlink`/`readlink` counterpart for the cache - `.dir = ctx.cache` is only ever accepted by `createfile`. A program can't ask "is this content already cached?" directly; it can only write and let the store's own dedup decide.
