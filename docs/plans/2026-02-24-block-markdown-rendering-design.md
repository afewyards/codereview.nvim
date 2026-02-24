# Block-Level Markdown Rendering

## Goal

Render full markdown in summary view (MR descriptions + discussion bodies). Currently only inline elements (bold, italic, code spans, links, strikethrough) render. Block-level elements (headers, lists, code blocks, blockquotes, tables, horizontal rules) display as plain text.

## Approach: Two-Pass Block Parser

Extend `markdown.lua` with `parse_blocks(text, base_hl, opts)` that runs a multiline state machine before inline parsing. Same `{lines, highlights}` output format. No new dependencies. Treesitter used only for code block syntax highlighting.

### Pipeline

```
raw text -> parse_blocks(text) -> [block structs] -> render each block:
  header:     strip prefix, parse_inline, apply header hl group
  list:       replace marker with bullet/number, indent, parse_inline
  code_block: emit raw lines with code bg, treesitter highlights
  blockquote: left border extmark, parse_inline on content
  table:      column widths, box-drawing chars, cell wrapping
  hr:         full-width horizontal rule character
  paragraph:  parse_inline (unchanged)
```

Output: `{ lines = {}, highlights = {}, code_blocks = {} }`

## Block Parsing State Machine

States: `normal`, `in_code_block`, `in_table`

### Line classification (normal state)

| Pattern | Block type |
|---------|-----------|
| `^#{1,6} ` | Header (level = # count) |
| `^```(.*)` | Code fence open (capture lang) |
| `^> ` | Blockquote (recursive) |
| `^[-*+] ` or `^\d+\. ` | List item |
| `^\|.*\|$` + separator | Table start |
| `^---$` / `^***$` / `^___$` | Horizontal rule |
| anything else | Paragraph |

## Rendering Spec

### Headers
- Strip `# ` prefix, parse inline content
- `CodeReviewMdH1`..`CodeReviewMdH6` highlight groups (bold for H1-H4)
- Blank line after for spacing

### Lists
- Unordered: `- ` -> `•`, nested: `◦`, `▪`
- Ordered: keep number + `.`
- 2-space indent per nesting level
- Inline parsing on text after marker

### Code blocks
- `CodeReviewMdCodeBlock` background on all lines
- 2-space left padding
- Treesitter syntax highlighting via `vim.treesitter.get_string_parser(code, lang)`
- Fallback: code background only if parser not installed

### Blockquotes
- `▌` left border via extmark virt_text
- `CodeReviewMdBlockquote` highlight (italic)
- Recursive: inner content runs through `parse_blocks` again
- Nested blockquotes increase indent

### Tables
- Parse header, separator (alignment), data rows
- Column widths capped at `opts.width / num_cols`
- Cell text wrapping expands row to multiple buffer lines
- Box-drawing: `┌─┬─┐`, `│ │ │`, `├─┼─┤`, `└─┴─┘`
- Header row: `CodeReviewMdTableHeader` (bold)
- Alignment from separator: `:---` left, `:---:` center, `---:` right

### Horizontal rules
- `─` repeated to fill width
- `CodeReviewMdHr` highlight

## Edge Cases

- **Blockquote containing code/list:** Recursive parse_blocks on inner content
- **Unclosed code fence:** Implicitly close at end of text
- **Inconsistent table columns:** Pad short rows, ignore extra cells
- **Mixed list markers:** Same type = same list; type change = new list
- **HTML tags:** Pass through as plain text
- **`---` inside table:** Table state takes priority
- **`# ` inside code block:** Code block state takes priority
- **Multi-paragraph list items:** Blank + indented continuation

## New Highlight Groups

```
CodeReviewMdH1              bold, fg=#c8d3f5
CodeReviewMdH2              bold, fg=#c8d3f5
CodeReviewMdH3              bold, fg=#a9b1d6
CodeReviewMdH4              bold, fg=#a9b1d6
CodeReviewMdH5              fg=#828bb8
CodeReviewMdH6              fg=#828bb8, italic
CodeReviewMdCodeBlock       bg=#1a1b26
CodeReviewMdBlockquote      bg=#2a2a3a, fg=#828bb8, italic
CodeReviewMdBlockquoteBorder fg=#565f89
CodeReviewMdTableHeader     bold, bg=#1e2030
CodeReviewMdTableBorder     fg=#565f89
CodeReviewMdHr              fg=#565f89
CodeReviewMdListBullet      fg=#7aa2f7
```

All `default = true` for colorscheme override.

## Integration Points

### `markdown.lua`
- New: `parse_blocks(text, base_hl, opts)` -> `{ lines, highlights, code_blocks }`
- `parse_inline` unchanged, called internally

### `detail.lua`
- `build_header_lines`: Replace per-line `parse_inline` loop for description with `parse_blocks(review.description, ...)`
- `build_activity_lines`: Replace per-line `parse_inline` loops for note bodies with `parse_blocks(note.body, ...)`

### `diff.lua`
- `render_summary`: After setting buffer lines, apply treesitter highlights for code blocks via `apply_code_block_highlights(buf, ns, code_blocks)`

### `highlight.lua`
- Add new highlight groups listed above

### No changes to
- `split.lua`, `keymaps.lua`, `config.lua`, extmark application loop in `render_summary`
