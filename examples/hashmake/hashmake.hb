// A hashmake build: the dependency graph for a real, multi-source C program.
//
// `hashmake` evaluates this file and gets back a graph. Every node is an
// ordinary HashedBuild function from its prerequisites to the artifact it
// builds, and `.needs` maps a local alias to the name of the target that
// produces it - so a build function receives exactly `{ alias -> artifact }`
// and never a path.
//
// Nothing here names a C file. The sources are discovered by listing the
// vendored cJSON checkout, so adding one to that tree adds a node to this
// graph with nothing edited below.
//
// The incremental behaviour is not this file's doing and not hashmake's: each
// build wraps its `exec` in `cached` (SPEC.md §15), whose key is the code plus
// the *values* it reads. An input is a File and a File is its content (§3), so
// editing one source changes that object's key and the link's, and nothing
// else. There are no timestamps anywhere in this.

let endswith (let a;
  let t a.text; let s a.suffix;
  (textlen t) >= (textlen s)
    and (textslice { .text = t, .start = (textlen t) - (textlen s) + 1, .count = textlen s }) == s);

// The language has no loops; `fold` is the one traversal, so the list helpers
// a build needs are written here rather than being builtins of their own.
let seq_len (let t; fold { .table = t, .init = 0, .step = (let s; s.acc + 1) });
let append (let a; a.seq concat { [(seq_len a.seq) + 1] = a.item });
let concat_seq (let a;
  fold { .table = a.b, .init = a.a, .step = (let s; append { .seq = s.acc, .item = s.value }) });

// Every name in the checkout ending in <suffix>, as { name -> File }.
let cjson loadfile "vendor/cJSON";
let files_matching (let suffix;
  fold {
    .table = listdir cjson,
    .init = empty,
    .step = (let s; (endswith { .text = s.value, .suffix = suffix })
               then (s.acc concat { [s.value] = loadfile { .dir = cjson, .path = s.value } })
               else s.acc),
  });

let sources files_matching ".c";
let headers files_matching ".h";

// "cJSON.c" -> "cJSON.o"
let object_name (let n; (textslice { .text = n, .start = 1, .count = (textlen n) - 2 }) concat ".o");

// One compile target per discovered source. Each is given only its own source
// and the headers - not the whole tree - so editing one .c rebuilds one .o.
let compile_targets fold {
  .table = sources,
  .init = empty,
  .step = (let s;
    let name s.key;
    let obj object_name name;
    s.acc concat {
      [obj] = {
        .needs = empty,
        .build = (let prereqs; cached (
          let r exec {
            .cmd = "clang",
            .args = { "-c", "-O2", "-std=c89", "-I.", name, "-o", obj },
            .inputs = headers concat { [name] = s.value },
            .outputs = { obj },
          };
          check(r.status == 0, "clang failed to compile " concat name) r.outputs[obj])),
      },
    }),
};

// The link needs every object; the alias each arrives under is its own name.
let link_needs fold {
  .table = compile_targets,
  .init = empty,
  .step = (let s; s.acc concat { [s.key] = s.key }),
};

{
  .default = "run",
  .targets = compile_targets concat {
  .link = {
    .needs = link_needs,
    .build = (let objects; cached (
      let r exec {
        .cmd = "clang",
        .args = concat_seq {
          .a = fold { .table = objects, .init = empty, .step = (let s; append { .seq = s.acc, .item = s.key }) },
          .b = { "-o", "cjson-demo", "-lm" },
        },
        .inputs = objects,
        .outputs = { "cjson-demo" },
      };
      check(r.status == 0, "clang failed to link cjson-demo") r.outputs["cjson-demo"])),
  },

  // The run target produces **no artifact**: it answers with the program's
  // own output as text, which is there so hashmake can show it, not for
  // anything to consume. hashmake enforces the difference - a target may only
  // be depended on if it produced a File, so nothing can be built "from" this.
  .run = {
    .needs = { .app = "link" },
    .build = (let prereqs;
      let r exec { .cmd = "./cjson-demo", .inputs = { ["cjson-demo"] = prereqs.app } };
      check(r.status == 0, "cjson-demo exited non-zero") r.stdout),
  },
  },
}
