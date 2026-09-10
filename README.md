# WIP
**This project in not yet ready to use.**

---

# About

<<<<<<< HEAD
*Hashed* is a functional (or not, if you don't clasify io-related side-effects as functional) general-purpose programming language.
It is design to interact heavily with the OS and filesystem, spawn containers and generally Dev-OPs stuff.
It provides value caching, serialization and hashing in the stdlib/language.
That makes you not bother those technical details while you set up incremental pipelines, compilation containers,
entire OS build pipelines, remote control programs and other DevOPs stuff.

The language is dynamically but strongly typed (like Python for example), supports asynchrounous evaluation and
has a dead-simple model for everything: 
everything is a function of two values to two values — the explicit argument and the implicit context to,
to the explicit argument and the implicit context.
And context contains basically *E v E R y T h I n G*: the names you declare, the permissions that restrict your access to *IO*
and *E v E r Y t H i N g*.

And btw, my goal is to make it a crappy, yet popular language like Python (❤️🐍).

And btw, this project was inspired by Nix and Guix. I have used Nix, and rage-quitted it.

# An Imagined Example
Downloading and building GNU *hello*:
```hashed
let c_dev_tools_ready_linux_root = stdlib.cached_file stdlib.build_dev_tools_root;
stdlib.containerbuild {
  src: stdlib.containerbuild.src.targz "https://ftp.gnu.org/gnu/hello/hello-2.12.tar.gz",
  overlays: c_dev_tools_ready_linux_root,
  cmd: "./configure && make && make install",
  output_location: "/usr/bin/hello",
=======
*Hashed* is a functional programming language targetted at build systems and automation. 
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
// build.hl (in the codebase's root directory)
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
>>>>>>> main
}
```
Prints:
```
<path_to_the_workdir>/hello
```

# Current State
There were some core features implemented (vibe-coded in Odin) but now I'm going to rewrite the project in C manually.
You can see the old project on the 'old-project` branch.
# Donate
If you would like to donate me money, you can choose from two options: [a bank transfer](https://janstrakowski.github.io/jansdonations/) or [BuyMeACoffie](https://buymeacoffee.com/janstrakowski).
Big thanks for the support.
