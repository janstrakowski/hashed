package main

// Converts SPEC.md into a standalone, styled SPEC.html, matching the design
// published as an Artifact. Parsing is delegated entirely to vendor:commonmark
// (a binding of the mature cmark reference library) - this file only walks
// the resulting node tree and wraps it in the page's own template, special-casing
// the two things specific to SPEC.md's dialect: numbered "## N. Title" sections
// and "> TODO: ..." blockquotes rendered as callouts.
//
// Requires the system `cmark` library (Arch: `pacman -S cmark`).
//
// Usage: odin run tools/spec-html -- [input.md] [output.html]
//        defaults to SPEC.md -> SPEC.html in the current directory.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import cm "vendor:commonmark"

Section :: struct {
	title: string, // already-escaped inline HTML, numeric prefix stripped
	body:  strings.Builder,
}

main :: proc() {
	in_path := "SPEC.md"
	out_path := "SPEC.html"
	if len(os.args) > 1 do in_path = os.args[1]
	if len(os.args) > 2 do out_path = os.args[2]

	data, read_err := os.read_entire_file(in_path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("error: could not read %s (%v)", in_path, read_err)
		os.exit(1)
	}
	source := string(data)

	options := cm.Options{.Validate_UTF8}
	root := cm.parse_document_from_string(source, options)
	defer cm.node_free(root)

	lede: strings.Builder
	strings.builder_init(&lede)

	sections: [dynamic]Section
	cur: ^Section = nil

	child := cm.node_first_child(root)
	for child != nil {
		#partial switch cm.node_get_type(child) {
		case .Thematic_Break:
			// purely decorative in the source; the page's own section
			// borders provide visual separation instead.

		case .Heading:
			level := int(cm.node_get_heading_level(child))
			if level == 1 {
				// document title is fixed page chrome (see `title` below);
				// the H1 text itself still appears in the masthead, but is
				// picked up as part of the surrounding flow, not specially.
				frag := render_node(child, options)
				strings.write_string(&lede, frag)
			} else if level == 2 {
				new_section: Section
				strings.builder_init(&new_section.body)
				new_section.title = strip_number_prefix(render_children(child, options))
				append(&sections, new_section)
				cur = &sections[len(sections) - 1]
			} else {
				frag := render_node(child, options)
				append_frag(cur, &lede, frag)
			}

		case .Block_Quote:
			html, ok := try_render_todo(child, options)
			if !ok do html = render_node(child, options)
			append_frag(cur, &lede, html)

		case:
			frag := render_node(child, options)
			append_frag(cur, &lede, frag)
		}
		child = cm.node_next(child)
	}

	now := time.now()
	year, month, day := time.date(now)
	date_str := fmt.tprintf("%4d-%02d-%02d", year, int(month), day)

	page := build_page(strings.to_string(lede), sections[:], date_str)

	if write_err := os.write_entire_file(out_path, transmute([]byte)page); write_err != nil {
		fmt.eprintfln("error: could not write %s (%v)", out_path, write_err)
		os.exit(1)
	}
	fmt.printfln("wrote %s (%d sections)", out_path, len(sections))
}

// Writes `frag` into the current section's body if one is open, otherwise
// into the front-matter (`lede`) builder for content that precedes the
// first "## " heading.
append_frag :: proc(cur: ^Section, lede: ^strings.Builder, frag: string) {
	if cur != nil {
		strings.write_string(&cur.body, frag)
	} else {
		strings.write_string(lede, frag)
	}
}

// Renders a single node (and its full subtree) to an owned HTML string.
render_node :: proc(node: ^cm.Node, options: cm.Options) -> string {
	html := cm.render_html(node, options)
	defer cm.free(html)
	return strings.clone(string(html))
}

// Renders just a node's children (skipping the node's own wrapping tag) -
// used for headings, where the page supplies its own wrapper markup.
render_children :: proc(node: ^cm.Node, options: cm.Options) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	child := cm.node_first_child(node)
	for child != nil {
		frag := render_node(child, options)
		strings.write_string(&b, frag)
		delete(frag)
		child = cm.node_next(child)
	}
	return strings.to_string(b)
}

// Strips a leading "N. " (as in "3. Primitive types") from an already-
// rendered heading string. Digits/". " are unaffected by HTML-entity
// escaping, so this is safe to run on cmark's rendered output.
strip_number_prefix :: proc(s: string) -> string {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' do i += 1
	if i > 0 && i + 1 < len(s) && s[i] == '.' && s[i + 1] == ' ' {
		return s[i + 2:]
	}
	return s
}

// A blockquote whose first paragraph starts with the literal "TODO:" is
// rendered as a `.todo` callout instead of a plain <blockquote>. The prefix
// is stripped from the underlying text node (so it isn't duplicated next to
// the callout's own "TODO" tag) before rendering the paragraph(s) normally -
// this preserves any inline formatting (like `code` spans) inside the TODO.
try_render_todo :: proc(bq: ^cm.Node, options: cm.Options) -> (html: string, ok: bool) {
	para := cm.node_first_child(bq)
	if para == nil || cm.node_get_type(para) != .Paragraph do return "", false

	text_node := cm.node_first_child(para)
	if text_node == nil || cm.node_get_type(text_node) != .Text do return "", false

	literal := string(cm.node_get_literal(text_node))
	prefix :: "TODO:"
	if !strings.has_prefix(literal, prefix) do return "", false

	remainder := strings.trim_left_space(literal[len(prefix):])
	cm.node_set_literal(text_node, strings.clone_to_cstring(remainder))

	b: strings.Builder
	strings.builder_init(&b)
	strings.write_string(&b, "<div class=\"todo\">\n<span class=\"todo-tag\">TODO</span>\n")
	p := para
	for p != nil {
		frag := render_node(p, options)
		strings.write_string(&b, frag)
		delete(frag)
		p = cm.node_next(p)
	}
	strings.write_string(&b, "</div>\n")
	return strings.to_string(b), true
}

build_page :: proc(lede_html: string, sections: []Section, date_str: string) -> string {
	b: strings.Builder
	strings.builder_init(&b)

	strings.write_string(&b, PAGE_HEAD)

	strings.write_string(&b, "<div class=\"shell\">\n<header class=\"masthead\">\n<div class=\"masthead-inner\">\n")
	strings.write_string(&b, "<p class=\"eyebrow\">Draft &middot; living document</p>\n")
	strings.write_string(&b, "<div class=\"lede\">\n")
	strings.write_string(&b, lede_html)
	strings.write_string(&b, "</div>\n")
	fmt.sbprintf(&b, "<div class=\"meta-row\"><span>Generated <strong>%s</strong></span><span><strong class=\"todo-count\" id=\"todo-count\">&mdash;</strong> open questions</span><span>Source: <code>SPEC.md</code></span></div>\n", date_str)
	strings.write_string(&b, "</div>\n</header>\n")

	strings.write_string(&b, "<div class=\"layout\">\n<nav class=\"toc\" aria-label=\"Sections\"><ol id=\"toc-list\">\n")
	for sec, i in sections {
		fmt.sbprintf(&b, "<li><a href=\"#sec-%d\"><span class=\"num\">%02d</span><span>%s</span></a></li>\n", i + 1, i + 1, sec.title)
	}
	strings.write_string(&b, "</ol></nav>\n<main id=\"content\">\n")

	for sec, i in sections {
		fmt.sbprintf(&b, "<section class=\"spec-section\" id=\"sec-%d\">\n<div class=\"sec-head\"><span class=\"num\">&sect;%02d</span><h2>%s</h2></div>\n", i + 1, i + 1, sec.title)
		strings.write_string(&b, strings.to_string(sec.body))
		strings.write_string(&b, "</section>\n")
	}

	strings.write_string(&b, "</main>\n</div>\n")
	strings.write_string(&b, "<footer class=\"spec-footer\"><div class=\"masthead-inner\">HashedBuild &mdash; a living draft, not a finalized specification. Regenerate with <code>odin run tools/spec-html -- SPEC.md SPEC.html</code>.</div></footer>\n")
	strings.write_string(&b, "</div>\n")

	strings.write_string(&b, PAGE_SCRIPT)
	return strings.to_string(b)
}

PAGE_HEAD :: `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>HashedBuild Spec</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Fragment+Mono:ital@0;1&family=Source+Serif+4:ital,opsz,wght@0,8..60,400;0,8..60,500;0,8..60,600;1,8..60,400&display=swap');

  :root {
    --bg: #f6f7fa;
    --surface: #ffffff;
    --text: #171a21;
    --text-secondary: #565d6d;
    --border: #dee1e8;
    --accent: #8a5f0c;
    --accent-soft: rgba(138, 95, 12, 0.08);
    --code-bg: #edeff4;
  }

  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --bg: #0f1217;
      --surface: #161a22;
      --text: #e7e9ee;
      --text-secondary: #9aa1b0;
      --border: #262b35;
      --accent: #e0a94d;
      --accent-soft: rgba(224, 169, 77, 0.1);
      --code-bg: #1b2029;
    }
  }
  :root[data-theme="dark"] {
    --bg: #0f1217;
    --surface: #161a22;
    --text: #e7e9ee;
    --text-secondary: #9aa1b0;
    --border: #262b35;
    --accent: #e0a94d;
    --accent-soft: rgba(224, 169, 77, 0.1);
    --code-bg: #1b2029;
  }

  * { box-sizing: border-box; }
  @media (prefers-reduced-motion: reduce) {
    * { animation-duration: 0.001ms !important; transition-duration: 0.001ms !important; }
  }

  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: "Source Serif 4", Georgia, "Times New Roman", serif;
    font-size: 17px;
    line-height: 1.65;
    -webkit-font-smoothing: antialiased;
  }

  code { font-family: "Fragment Mono", "SFMono-Regular", Consolas, "Liberation Mono", monospace; }
  code {
    background: var(--code-bg);
    border: 1px solid var(--border);
    border-radius: 3px;
    padding: 0.05em 0.35em;
    font-size: 0.86em;
    color: var(--text);
  }

  a { color: var(--accent); text-decoration-thickness: 1px; text-underline-offset: 2px; }
  a:focus-visible, button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

  .shell { max-width: 1180px; margin: 0 auto; padding: 0 clamp(20px, 4vw, 48px); }

  .masthead { padding: clamp(40px, 7vw, 76px) 0 clamp(28px, 5vw, 44px); border-bottom: 1px solid var(--border); }
  .masthead-inner { max-width: 760px; }
  .eyebrow {
    font-family: "Fragment Mono", monospace;
    font-size: 0.78rem;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: var(--accent);
    display: inline-flex;
    align-items: center;
    gap: 0.55em;
    margin: 0 0 1.1em;
  }
  .eyebrow::before { content: ""; width: 7px; height: 7px; background: var(--accent); display: inline-block; border-radius: 1px; }

  .masthead h1 {
    font-family: "Fragment Mono", monospace;
    font-weight: 500;
    font-size: clamp(1.9rem, 4vw, 2.7rem);
    line-height: 1.15;
    letter-spacing: -0.01em;
    margin: 0 0 0.5em;
    text-wrap: balance;
  }
  .lede p { color: var(--text-secondary); font-size: 1.09rem; max-width: 62ch; margin: 0 0 1.6em; }
  .meta-row {
    display: flex; flex-wrap: wrap; gap: 0.6em 1.6em;
    font-family: "Fragment Mono", monospace; font-size: 0.82rem; color: var(--text-secondary);
  }
  .meta-row strong { color: var(--text); font-weight: 500; }
  .meta-row .todo-count { color: var(--accent); }

  .layout {
    display: grid;
    grid-template-columns: 232px minmax(0, 1fr);
    gap: clamp(24px, 4vw, 64px);
    padding: clamp(32px, 5vw, 56px) 0 100px;
    align-items: start;
  }

  nav.toc { position: sticky; top: 24px; max-height: calc(100vh - 48px); overflow-y: auto; padding-right: 4px; }
  nav.toc ol { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
  nav.toc a {
    display: flex; gap: 0.7em; align-items: baseline;
    padding: 6px 10px; border-radius: 4px;
    color: var(--text-secondary); text-decoration: none;
    font-size: 0.87rem; line-height: 1.35;
    transition: background 0.12s ease, color 0.12s ease;
  }
  nav.toc a:hover { background: var(--code-bg); color: var(--text); }
  nav.toc a.active { background: var(--accent-soft); color: var(--accent); font-weight: 600; }
  nav.toc .num { font-family: "Fragment Mono", monospace; font-size: 0.78rem; color: var(--text-secondary); flex-shrink: 0; width: 1.6em; }
  nav.toc a.active .num { color: var(--accent); }

  main { min-width: 0; max-width: 720px; }

  section.spec-section {
    padding-top: clamp(28px, 4vw, 40px);
    margin-top: clamp(28px, 4vw, 40px);
    border-top: 1px solid var(--border);
    scroll-margin-top: 24px;
  }
  section.spec-section:first-of-type { border-top: none; margin-top: 0; padding-top: 0; }

  .sec-head { display: flex; align-items: baseline; gap: 0.75em; margin: 0 0 0.85em; }
  .sec-head .num { font-family: "Fragment Mono", monospace; color: var(--accent); font-size: 0.95rem; flex-shrink: 0; }
  section.spec-section h2 {
    font-family: "Fragment Mono", monospace; font-weight: 500; font-size: 1.32rem;
    margin: 0; letter-spacing: -0.005em; text-wrap: balance;
  }

  section.spec-section p { margin: 0 0 1.05em; max-width: 66ch; }
  section.spec-section ul, section.spec-section ol {
    margin: 0 0 1.1em; padding-left: 1.3em; max-width: 64ch;
  }
  section.spec-section li { margin-bottom: 0.5em; }
  section.spec-section li:last-child { margin-bottom: 0; }

  section.spec-section pre {
    background: var(--code-bg); border: 1px solid var(--border); border-radius: 5px;
    padding: 14px 18px; margin: 0 0 1.1em; overflow-x: auto;
  }
  section.spec-section pre code { background: none; border: none; padding: 0; font-size: 0.88rem; white-space: pre; }

  section.spec-section blockquote {
    border-left: 2px solid var(--border); margin: 0 0 1.1em; padding: 2px 16px; color: var(--text-secondary);
  }

  .todo {
    border-left: 2px solid var(--accent);
    background: var(--accent-soft);
    border-radius: 0 5px 5px 0;
    padding: 10px 16px;
    margin: 0 0 1em;
    max-width: 64ch;
  }
  .todo-tag { font-family: "Fragment Mono", monospace; font-size: 0.72rem; letter-spacing: 0.1em; color: var(--accent); font-weight: 500; display: block; margin-bottom: 0.35em; }
  .todo p { margin: 0; font-size: 0.95rem; color: var(--text); max-width: none; }

  footer.spec-footer { border-top: 1px solid var(--border); padding: 28px 0 60px; color: var(--text-secondary); font-size: 0.86rem; font-family: "Fragment Mono", monospace; }

  @media (max-width: 860px) {
    .layout { grid-template-columns: 1fr; }
    nav.toc { position: static; max-height: none; border-bottom: 1px solid var(--border); padding-bottom: 14px; margin-bottom: 8px; }
    nav.toc ol { flex-direction: row; flex-wrap: nowrap; overflow-x: auto; gap: 4px; }
    nav.toc a { white-space: nowrap; }
    main { max-width: none; }
  }
</style>
</head>
<body>
`

PAGE_SCRIPT :: `<script>
  (function () {
    var sections = Array.prototype.slice.call(document.querySelectorAll('.spec-section'));
    var links = Array.prototype.slice.call(document.querySelectorAll('#toc-list a'));

    var todoCountEl = document.getElementById('todo-count');
    todoCountEl.textContent = document.querySelectorAll('.todo').length;

    if ('IntersectionObserver' in window) {
      var observer = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          var link = document.querySelector('#toc-list a[href="#' + entry.target.id + '"]');
          if (!link) return;
          if (entry.isIntersecting) {
            links.forEach(function (l) { l.classList.remove('active'); });
            link.classList.add('active');
          }
        });
      }, { rootMargin: '-10% 0px -75% 0px', threshold: 0 });
      sections.forEach(function (sec) { observer.observe(sec); });
    }
  })();
</script>
</body>
</html>
`
