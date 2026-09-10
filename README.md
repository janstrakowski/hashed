# WIP
**This project in not yet ready to use.**

---

# About

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
