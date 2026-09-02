# WIP
**This project in not yet ready to use. Only a couple of core features are implemented.**

---

# About

*HashedBuild* is a functional programming language targetted at build systems and automation. 
It is designed to be relatively easy to use, and not much technical. 
It's purpose is to set up automation for repetetive task or that which need reproducibility
when a functional paradime is better suited.
It aims to be cross-platform (Windows, Linux, MacOS), and currently Windows and Linux are
under the development.
It supports incremental evaluation though caching like [Nix](nixos.org) or [Guix](guix.gnu.org),
and it was inspired by them.

# Examples
## Build Script in a Codebase (Make-style)
This assumes a harness that expects a graph of dependencies as the output.
```
// build.hb (in the codebase's root directory)
is { ..., dir, ccomp};
// "<expression> is <pattern>; <expression>" is normally pattern-maching for the first expression but when in an expression
// something is omitted (for example instead of `1+2`, `+2`) then it becomes a function (f(x) = x + 2).
// So is { ..., dir} tells us that the whole program is a function that gives us a struct with a "dir" field.
let srcdir = dirmember { dir, "src" };
let c_filenames = (dirmembers srcdir) map (.name) map (extractfext ()) filter (== ".c");
let c_tasks = c_filenames map {
 name = #arg,
 executor = func ccomp.compiletoobj (dirmember {srcdir, #arg2 /* the arg of the map function */}),
 // Let's assume "complitetoobj" produces the object file in the directory of its argument.
};
let compile_task = {
 name = "compile",
 // No executor
 dependencies = {
   ...c_filenames,
 },
};
let link_task = {
 name = "link",
 dependencies = {
  compile_task.name,
 },
 executor = func ccomp.linkobjfiles {{ ... c_filenames map stripfext () map concat ".o" }, outfile = ensure_dirs "/bin/program" },
 // "ensure_dirs" is a builtin that creates the parent directories for the argument path.
};
{
 ...c_tasks, // All the c_tasks are included in the structure as a separate entries
 compile_task,
 link_task,
}
```

# Current State
The language specification is not complete.
An evalutor is implemented for a subset of the language.
The subset covers asynchronous runtime.
A [DAP](https://microsoft.github.io/debug-adapter-protocol/) server is implemented for the subset.

All mentioned above are very buggy.

# Donate
You can support me by a donation via: [a bank transfer](https://janstrakowski.github.io/jansdonations/) or [BuyMeACoffie](https://buymeacoffee.com/janstrakowski).
