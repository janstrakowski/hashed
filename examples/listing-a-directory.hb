// `listdir` (SPEC.md §16): a directory's entries, as a value. This is the half
// of §16's open question that is now answered - a program could always address
// a name it already knew, and can now find out what is there.
//
// **Names only, not kinds.** What an entry *is* can be asked by opening it
// (`loadfile { .dir, .path }`), and a bare sequence is the shape `fold`
// traverses and `[i]` indexes. Sorted byte-wise, for the same reason the
// directory *hash* sorts (§3): readdir order is the filesystem's own business,
// and a build whose argument order changed between machines would cache
// differently on each.
//
// Together with `fold` and `textslice` this is how a build finds its sources
// without naming them - see examples/hashmake/hashmake.hb, which does exactly
// the filter below over a checkout of C sources. Gated by `io` like every
// other read. Evaluates to
// { all: {"alpha.txt", "beta.md", "gamma.txt"}, only_txt: {"alpha.txt", "gamma.txt"} }.

let endswith (let a;
  let t a.text; let s a.suffix;
  (textlen t) >= (textlen s)
    and (textslice { .text = t, .start = (textlen t) - (textlen s) + 1, .count = textlen s }) == s);
let seq_len (let t; fold { .table = t, .init = 0, .step = (let s; s.acc + 1) });
let append (let a; a.seq concat { [(seq_len a.seq) + 1] = a.item });

let names listdir (loadfile "listing");
{
  .all = names,
  .only_txt = fold {
    .table = names,
    .init = empty,
    .step = (let s; (endswith { .text = s.value, .suffix = ".txt" })
               then (append { .seq = s.acc, .item = s.value })
               else s.acc),
  },
}
