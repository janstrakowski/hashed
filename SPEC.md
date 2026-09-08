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

## Typographical Conventions
- *a reference of a concept*
- ***The definition of a concept***

## Syntax
### Specification Conventions
The *source* grammar construct is the entrypoint of the grammar. 
It is the source file or any string being parsed.

When specifing a grammar construct, unless said otherwise, *ignorable constructs* can appear after the specified construct.
*Ignorable costructs* can also appear in the very beginning of the source.
Ignorable constructs are: *a whitespace* or *a comment*; i.e. one or more of them (may be mixed).

### Grammar Definition
A ***whitespace*** — one or more of Unicode `White_Space` characters.

A ***comment***: either a *single-line comment* or *line-agnostic comment*.
A ***single-line comment*** — `//`, zero or more of any Unicode characters except `Line_Break={BK or CR or LF or NL}`.
A ***line-agnostic comment*** — `/*`, zero or more of any characters except the `*/` sequence, unless `*/` is a part of
`\*/`.

An ***identifier*** — one `XID_START` Unicode character and zero or more `XID_CONTINUE` Unicode characters.
Whether it can be followed by a whitespace is left to define to the parent constructs.

A ***source*** — zero or more *program attribute directives* and an *expression* (and an *expression* specifically in this place is called
***the root expression***).

A ***program attribute directive*** (***PAD***) — `#`, an *identifier* (in this place – ***program attribute name***), zero or more *literals* (here 
***program attribute values***), 
and ';'.

An ***expression*** — either: a *literal*, an *identifier* (here a ***parameter reference***), or an *operation*.
A ***literal*** — either: an *integer*, a *float* or a *string*.
An ***operation*** either: a *table constructor*, 

### PADs (Program Attribute Directives)
Before the *root expression*, there may be zero or more *program attribute directives* (PADs).
They are a `#` succeeded by 
```hashed
#Attribute-Name val1 val2 valN ;
```
