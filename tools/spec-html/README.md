# spec-html

Converts `SPEC.md` into a standalone, styled `SPEC.html` you can open directly in a browser — no server, no Claude Artifact, just a static file.

## Prerequisite

Needs the system `cmark` library (parsing is delegated to `vendor:commonmark`, Odin's binding to the mature cmark reference implementation — this tool only handles the page's own template and a couple of SPEC.md-specific conventions).

```sh
# Arch
sudo pacman -S cmark
```

## Usage

From the repo root:

```sh
odin run tools/spec-html -- SPEC.md SPEC.html
```

Both arguments are optional and default to `SPEC.md` → `SPEC.html` in the current directory, so a bare `odin run tools/spec-html` also works from the repo root.

`SPEC.html` is generated output (gitignored) — regenerate it any time `SPEC.md` changes; nothing else needs updating.

## SPEC.md conventions this generator understands

Plain [CommonMark](https://commonmark.org/) plus two conventions specific to this doc:

- **`## N. Title`** headings become numbered sections (`§01`, `§02`, ...) with an auto-generated table of contents. The leading `N. ` is stripped from the displayed title — the number shown is just the heading's position among all `##` headings, not whatever digits happen to be typed in the source.
- **`> TODO: ...`** blockquotes are rendered as callouts instead of plain quotes, and counted in the page header. Only the *first paragraph* of a blockquote is checked for the `TODO:` prefix, and only at the top level of a section (not nested inside a list item) — see the caveats below.

Everything else (paragraphs, lists, `code` spans, fenced code blocks, **bold**/*italic*, blockquotes not starting with `TODO:`) is rendered by cmark as ordinary HTML and styled generically.

**Not supported:** GFM tables (base cmark implements pure CommonMark only — no table extension). Use a bullet or definition list instead.

## Caveats to know before editing SPEC.md

- **Two TODOs need a blank line between them**, not just a bare `>` continuation — `>` alone joins them into one blockquote (one paragraph each), and only the first paragraph's `TODO:` prefix gets recognized/stripped. If a TODO's callout looks wrong or the rendered TODO count doesn't match `grep -c '^> TODO:' SPEC.md`, this is the first thing to check.
- **A `> TODO:` nested inside a list item** (indented under a numbered/bulleted list) will render as a plain nested `<blockquote>`, not a `.todo` callout — the generator only special-cases top-level blockquotes within a section. Keep TODOs at the top level of a section, not indented inside a list.
