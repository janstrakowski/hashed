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
 // Let's assume "complitetoobj" produces the object file in the directory of its argument.
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
### EBNF Conceputal Definition
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
(* ^^^ EXTRA SPECIFICATION 2: here """ takes precedence over three consequent " String Literal Codepoints *)
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

Let := "let", [ "rec" ], Identifier, "=", Expression, ";", Expression
Then := Expression, "then", Expression
Matches := Expression, "matches", Table Pattern
Else := Expression, "else", Expression

Table Pattern := "{", ( Table Pattern Entry | Anything-Else Marker ), { ",", (Table Pattern Entry | Anything-Else Table Pattern Marker) }, [ "," ], "}"
Table Pattern Entry := ( "[", Expression, "]" | ".", Identifier | "_" ), [ "matches", Table Pattern ], [ "let", Identifier ]
Anything-Else Table Pattern Marker := "..."
```
### Ignorables
The ignorables are exceptional constructs not mentioned in the first definition, because they are supposed to appear "anywhere"
in the grammar. 
"anywhere" here means zero or more of *Ignorable* constructs before, after or in between all constructs except the literals, parameter references and the identifiers,
and they underlying hierachies, except again in the expression of the string interpolation.
#### EBNF Definition
```ebnf
(* This grammar specification defines the ignorables. *)
Ignorable := ? Unicode Pattern_White_Space codepoint ? | Comment
Comment := Single-Line Comment | Line-Agnostic Comment
Single-Line Comment := "//", { ? any Unicode codepoint except Unicode Line_Break={BK, CR, LF or NL} ? }
Line-Agnostic Comment := "/*", { ? any Unicode codepoint except the sequence */ unless the sequence is prefixed
  with an odd number of * }, "*/"
```
### Ambigouity Resolution
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
| 10 | Pipe Operator, Map Operator, Filter Operator, Func |
| 11 | Let, Then, Matches, Else |
#### Juxtaposition Function Application
The *Function Application* is juxtaposition, which brings a lot of ambigouity to the grammar, because every adjacent constructs can be intrepreted as juxaposition.
The solution is to restrict the *Function Application* right-hand-side and left-hand-side to levels 1 and 2: 2+ level constructs can 
be neither side of the *Function Application*.
#### Arithmetic Negation
The Arithmetic Negation occurs only in the beggining of an addition/subtraction series (e.i. e.x. `-1 + 2 - 3`).
Then it binds only to the first term (`-1`).
