// Capability-scoped permissions (SPEC.md §9/§16). `ctx` is the ambient
// context; the filesystem builtins read `ctx.permissions.io` *live*, at the
// moment they're called, so narrowing the context genuinely narrows what an
// expression is allowed to do:
//
//   <expr> chctx chperm { .name = "io", .enabled = <bool> }   one permission
//   <expr> withctx <new_ctx>                                  the whole thing
//
// The narrowing applies to the expression it's attached to and nothing else,
// as `.still_ambient` shows. Two things to know: there are no `true`/`false`
// literals yet, hence `1 == 0` for "false"; and a `loadfile` under a
// narrowed context doesn't evaluate to an error value - it fails the whole
// program, since only a false `then` is catchable (§8). Evaluates to
// { ambient: {io: nothing}, io_denied: {}, replaced: {},
//   still_ambient: {io: nothing} }.
{
  .ambient = ctx.permissions,
  .io_denied = ctx.permissions chctx chperm { .name = "io", .enabled = 1 == 0 },
  .replaced = ctx.permissions withctx (ctx concat { .permissions = empty }),
  .still_ambient = ctx.permissions,
}
