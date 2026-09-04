# "Hashed" Specification
## Example Program
```hashed
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
}
```
## Table of Contents
0. [Example Program](#example-program)
1. [Syntax](#syntax)
2. [Data Types](#data-types)
3. [Names](#names)
4. [Execution Model](#execution-model)
5. [Builtins](#builtins)
6. [Program Attributes](#program-attributes)
7. [CLI](#cli)
8. [Conventions](#conventions)
9. [Extending the Language](#extending-the-language)

## Syntax
### Charset and Encodings
**The charset of the language is [Unicode](unicode.org);** the source is a sequence of [Unicode](unicode.org) characters only.
In this specification, also, very often the concept of *classes* from [Unicode](unicode.org) is brought up, so 
if you are not familiar with it, check it out.

The language is not tied to any specific encoding: it is defined as sequence of characters, which are one level of abstraction
higher than encoding.
Nevertheless, **we require the parsers to accept the input at least in [UTF-8](unicode.org/versions/latest/core-spec/chapter-3/#G7404).**
### Grammar Definition
A ***whitespace*** 

A ***comment*** can be either a *single-line comment* or a *multiple-line comment*. A ***single-line comment*** is denoted by 
`//`, then zero or more of any [Unicode](unicode.org) characters, and it ends before any [Unicode](unicode.org) line break.
A ***mulitple-line comment*** starts with `/*`, contains any [Unicode](unicode.org) characters and ends with `*/`.

In this specification, unless stated otherwise, zero or more *whitespaces* or comments are allowed in between parts of an
expression and in between adjacent expressions. I.e. informally, whitespaces and comments can be put anywhere in the language.

### *Identifiers*
An ***identifier*** is one `ID_START` class [Unicode](unicode.org) character, followed by zero or more `ID_CONTINUE` class characters.

### Source Unit (File)
The biggest piece of *Hashed* code; the root of the syntax tree.
A file is a source unit but it can be really any piece of code that is passed to the *Hashed* parser (stdin, or CLI argument for example).

#### *Root Expression*
The source unit boils down to the *root expression*: a source unit is treated as a one (big or not) expression.
For example
```hashed
1 + 2
```
may be a source unit on its own.

### PADs (Program Attribute Directives)
Before the *root expression*, there may be zero or more *program attribute directives* (PADs).
They are a `#` succeeded by 
```hashed
#Attribute-Name val1 val2 valN ;
```
