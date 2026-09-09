# "Hashed" Specification
## Example Program
```hashed
// build.hl (in the codebase's root directory)
# matches { ..., dir, ccomp};
let srcdir = dirmember { dir, "src" };
let c_filenames = dirmembers srcdir map #.name map extractfext # filter # == ".c";
let c_tasks = c_filenames map {
 .name : #,
 .executor : func ccomp.compiletoobj (dirmember {srcdir, # /* the arg of the map function */}),
 // Let's assume "compiletoobj" produces the object file in the directory of its argument.
};
let compile_task = {
 .name : "compile",
 // No executor
 .dependencies : {
   ...c_filenames,
 },
};
let link_task = {
 .name : "link",
 .dependencies : {
  compile_task.name,
 },
 .executor : func ccomp.linkobjfiles {{ ... c_filenames map stripfext # map # ++ ".o" }, outfile : ensure_dirs "/bin/program" },
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
2. [Data Representation](#data-representation)
3. [Names](#names)
4. [Execution Model](#execution-model)
5. [Builtins](#builtins)
6. [Program Attributes](#program-attributes)
7. [CLI](#cli)
8. [Conventions](#conventions)
9. [Extending the Language](#extending-the-language)

## Syntax
### EBNF Conceptual Definition
```ebnf
(* This grammar specification is conceptual, to try to imagine the grammar.
   For the complete, machine-readable one ambiguity resolution (some constructs taking precedence over the other) and
   ignorables (whitespaces and comments) are needed. *)

Source := { Program Attribute Directive }, Root Expression

Identifier := ? Unicode XID_START character ? { ? Unicode XID_CONTINUE character ? }
(* ^^^ EXTRA SPECIFICATION: if a keyword collides with an identifier, the keyword takes precedence but if it doesn't it is
 still an identifier *)
Decimal Digit := ? as the name suggests ?
Binary Digit := ? as the name suggests ?
Octal Digit := ? as the name suggests ?
Hexadecimal Digit := ? a hexadecimal digit — both uppercase and lowercase letters allowed ?

Program Attribute Directive := "#", Program Attribute Name, { Program Attribute Value }, ";"
Program Attribute Name := Identifier
Program Attribute Value := Literal
Root Expression := Expression

Expression := Literal | Parameter Reference | Operation | "(", Expression, ")"
Literal := Integer Literal | Float Literal | String Literal

Parameter Reference := Identifier | Implied Parameter Reference
Implied Parameter Reference := "#", { Decimal Digit }

Integer Literal := Decimal Integer Literal | Hexadecimal Integer Literal | Octal Integer Literal | Binary Integer Literal
Decimal Integer Literal := Decimal Digit, { Decimal Digit }
Hexadecimal Integer Literal := "0x", { Hexadecimal Digit }
(* ^^^ EXTRA SPECIFICATION: a warning if there is no digit *)
Octal Integer Literal := "0o", { Octal Digit }
(* ^^^ EXTRA SPECIFICATION: a warning if there is no digit *)
Binary Integer Literal := "0b", { Binary Digit }
(* ^^^ EXTRA SPECIFICATION: a warning if there is no digit *)

Float Literal := Decimal Float Literal | Binary Float Literal
Decimal Float Literal := Decimal Digit, { Decimal Digit }, ".", Decimal Digit, { Decimal Digit }, [("e" | "E"), [ "-" ], { Decimal Digit } ]
(* ^^^ EXTRA SPECIFICATION: a warning if there is no digit in the exponent part *)
Binary Float Literal := Binary Digit, { Binary Digit }, ".", Binary Digit, { Binary Digit }, [( "e" | "E" ), [ "-" ], { Binary Digit }]
(* ^^^ EXTRA SPECIFICATION: a warning if there is no digit in the exponent part *)

String Literal := Standard String Literal | Line-Formatting String Literal
Standard String Literal := [ String Interpolation Marker ], '"', { String Literal Codepoint | String Interpolation }, '"'
(* ^^^ EXTRA SPECIFICATION 1: String Interpolation exists only if String Interpolation Marker is present. *)
(* ^^^ EXTRA SPECIFICATION 2: Here the ending " takes precedence over " in String Literal Codepoint *)
Line-Formatting String Literal := [ String Interpolation Marker ], '"""', { String Literal Codepoint | String Interpolation }, '"""'
(* ^^^ EXTRA SPECIFICATION 1: String Interpolation exists only if String Interpolation Marker is present. *)
(* ^^^ EXTRA SPECIFICATION 2: here """ takes precedence over three consecutive " String Literal Codepoints *)
String Interpolation Marker := "$"
String Literal Codepoint := As-Is Codepoint | Escape Sequence
As-Is Codepoint := ? Any printable Unicode character, except \ ?
Escape Sequence := Short Escape Sequence | 2-Byte Escape Sequence | 4-Byte Escape Sequence
Short Escape Sequence := "\'" | '\"' | "\?" | "\\" | "\a" | "\b" | "\f" | "\n" | "\r" | "\t" | "\v" | "\0"
2-Byte Escape Sequence := "\u", Hexadecimal Digit, Hexadecimal Digit, Hexadecimal Digit, Hexadecimal Digit
4-Byte Escape Sequence := "\U", Hexadecimal Digit, Hexadecimal Digit, Hexadecimal Digit, Hexadecimal Digit,
  Hexadecimal Digit, Hexadecimal Digit, Hexadecimal Digit, Hexadecimal Digit
String Interpolation := "${", Expression, "}"
(* ^^^ EXTRA SPECIFICATION: String Interpolation does not exist if ${ is preceded by an odd number of $. *)

Operation := Function Application | Func | Table Constructor | Map Application | Binary Interfix Operator | Unary Operator | Let | Then | Matches
Func := "func", Expression
Function Application := Expression, Expression
Map Application := Expression, ( ".", Identifier | "[", Expression, "]" )

Table Constructor := "{", Table Constructor Entry, { ",", Table Constructor Entry }, [ "," ], "}"
Table Constructor Entry := Position-Based Table Constructor Entry | Key-Value Table Constructor Entry | Expansion Table Constructor Entry
Position-Based Table Constructor Entry := Expression
Key-Value Table Constructor Entry := ("[", Expression, "]" | ".", Identifier ), ":", Expression
Expansion Table Constructor Entry := "...", Expression

Binary Interfix Operator := Pipe Operator | Map Operator | Filter Operator | String Concatenation | Binary Arithmetic Operator | Comparison Operator | Binary Logical Operator
Pipe Operator := Expression, "|>", Expression
String Concatenation := Expression, "++", Expression

Map Operator := Expression, "map", Expression
Filter Operator := Expression, "filter", Expression

Binary Arithmetic Operator := Multiplication Operator | Division Operator | Modulo Operator | Addition Operator | Subtraction Operator
Multiplication Operator := Expression, "*", Expression
Division Operator := Expression, "/", Expression
Modulo Operator := Expression, "%", Expression
Addition Operator := Expression, "+", Expression
Subtraction Operator := Expression, "-", Expression

Comparison Operator := Equality Operator | Inequality Operator | Less Than Operator | Greater Than Operator | Less Than Or Equal Operator | Greater Than Or Equal Operator
Equality Operator := Expression, "==", Expression
Inequality Operator := Expression, "!=", Expression
Less Than Operator := Expression, "<", Expression
Greater Than Operator := Expression, ">", Expression
Less Than Or Equal Operator := Expression, "<=", Expression
Greater Than Or Equal Operator := Expression, ">=", Expression

Binary Logical Operator := Conjunction Operator | Disjunction Operator
Conjunction Operator := Expression, "&&", Expression
Disjunction Operator := Expression, "||", Expression

Unary Operator := Arithmetic Negation | Logical Negation
Arithmetic Negation := "-", Expression
Logical Negation := "!", Expression

Let := "let", Identifier, "=", Expression, ";", Expression
Then := Expression, "then", Expression
Matches := Expression, "matches", Table Pattern
Else := Expression, "else", Expression

Table Pattern := "{", ( Table Pattern Entry | Anything-Else Table Pattern Marker ), { ",", (Table Pattern Entry | Anything-Else Table Pattern Marker) }, [ "," ], "}"
Table Pattern Entry := ( "[", Expression, "]" | ".", Identifier | "_" ), [ "matches", Table Pattern ], [ "let", Identifier ]
Anything-Else Table Pattern Marker := "..."
```
### Ignorables
The ignorables are exceptional constructs not mentioned in the first definition, because they are supposed to appear "anywhere"
in the grammar. 
"anywhere" here means zero or more of *Ignorable* constructs before, after or in between all constructs except the literals, parameter references and the identifiers,
and their underlying hierarchies, except again in the expression of the string interpolation.
#### EBNF Definition
```ebnf
(* This grammar specification defines the ignorables. *)
Ignorable := ? Unicode Pattern_White_Space codepoint ? | Comment
Comment := Single-Line Comment | Line-Agnostic Comment
Single-Line Comment := "//", { ? any Unicode codepoint except Unicode Line_Break={BK, CR, LF or NL} ? }
Line-Agnostic Comment := "/*", { ? any Unicode codepoint except the sequence */ unless the sequence is prefixed
  with an odd number of * }, "*/"
```
### Ambiguity Resolution
#### Operator Precedence
(the higher rows win over the lower; all left-associative)
| No. | Operations |
|----|------|
| 1 | Map Application |
| 2 | Function Application |
| 3 | String Concatenation |
| 4 | Multiplication, Division, Modulo |
| 5 | Addition, Subtraction, Arithmetic Negation |
| 6 | Logical Negation |
| 7 | Comparison |
| 8 | Conjunction |
| 9 | Disjunction |
| 10 | Pipe Operator, Map Operator, Filter Operator |
| 11 | Let, Then, Matches, Else |
| 12 | Func |
#### Juxtaposition Function Application
The *Function Application* is juxtaposition, which brings a lot of ambiguity to the grammar, because every adjacent construct can be interpreted as juxtaposition.
The solution is to restrict the *Function Application* right-hand-side and left-hand-side to levels 1 and 2: 2+ level constructs can 
be neither side of the *Function Application*.
#### Arithmetic Negation
The Arithmetic Negation occurs only in the beginning of an addition/subtraction series (e.g. `-1 + 2 - 3`).
Then it binds only to the first term (`-1`).

## Data Representation
### Data Types
#### Primitive Data Types
- *Integer* — an integer between $$-2^{63}$$ and $$2^{63}-1$$.
- *Float* — a double-precision floating point number.
- *Byte String* — a string of raw bytes.
- *UTF8 String* — a piece of UTF-8 encoded text.
#### Complex Data Types
- *Function* — a function takes two values, returns two values and can produce IO-related side-effects.
  It takes an explicit argument and an implicit context value and produces an explicit result and an implicit context value.
  All four values are just *Data Types* like any other: the context ones only are required to be of a specific structure
  by the evaluators.
- *Table* — an associative array of values to values.
### Boolean Representation
Booleans are represented with *Integers*.
`0` means false, and anything else — true.
### Data Structure Representation
Data structures are represented using *Tables*. 
Product types are tables with the field names as strings as the keys.
Sum types are tables with one key, and depending on what is the key, the subtype is determined.
Tuples and Arrays are represented as tables, where the keys are consecutive *Integers* beginning from **1**.

## Evaluation
The evaluation is done by exploring the expression hierarchy and sequentially reducing the lowest 
expressions into their evaluations. 
For the expressions on the same level (siblings), the evaluation takes place in the order of the text flow.
Moreover in *Logical Operators*, when evaluating according to the text flow the final value is already determined,
the evaluation of the other siblings is omitted.
### Functions
Function is a value, and a value is not tied to the expression hierarchy: for example a function can stand behind a parameter
reference, and be defined entirely elsewhere in the source or in a different source piece imported to the current one.
When a *function* is applied, the evaluation jumps to its definition, and returns afterwards. 
If the *function* is built in, then it is evaluated internally.
### Parameters
An expression can be just an identifier (e.g. `abc`), then it refers to a named parameter `abc`.
Actually, it is a syntax sugar for `ctx.params.abc`, and `ctx` is a special parameter reference that
points to the context value passed to every function.

On the other hand, when a name is created (`let`, `matches` patterns), then the appropriate values are
assigned to `ctx.params`. `ctx.params` is actually a table as the notation suggests. The newly-assigned values 
shadow the previous.
### Control Flow Expression
There are expressions `then` and `else` and they are called *control flow expressions*.
`<expr1> then <expr2>` evaluates to *expr2* if *expr1* evaluates to *true*.
If *expr1* is *false*, then an *control flow exception* is raised and the control is handled to the parent expression.
If the parent expression is `<expr1> else <expr2>`, it evaluates to *expr2*.
If the parent expression is not `else`, then the exception is turned into an unrecoverable error.

## Mechanics
TODO.
## Standalone Programs
TODO.
## CLI
TODO.
