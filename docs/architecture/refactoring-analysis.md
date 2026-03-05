# Refactoring Analysis -- codereview.nvim

Generated 2026-02-25. Based on full scan of all 37 Lua source files and 36 test files.

## Ranked Refactoring Targets

### #1. `lua/codereview/mr/diff.lua` -- CRITICAL (2997 lines, 95 functions)

**The single highest-priority refactoring target in the entire codebase.** This file is a textbook god module: it owns rendering, navigation, keymaps, state management, comment creation, sidebar rendering, summary rendering, and the main entry points. It changed in 40 of the last 100 commits.

**Specific issues:**

1. **`setup_keymaps()` is 1243 lines (line 1630-2872).** It defines 16 closures and a 26-entry `main_callbacks` table, a `sidebar_callbacks` table, non-registry keymaps, autocmds, and cursor management. This single function is larger than every other file in the codebase except `markdown.lua`.

2. **State management is scattered and duplicated.** The "unpack render result into state" pattern is copy-pasted 7 times:
   ```lua
   state.file_sections = result.file_sections
   state.scroll_line_data = result.line_data
   state.scroll_row_disc = result.row_discussions
   state.scroll_row_ai = result.row_ai
   ```
   Found at lines: 1367, 1490, 1616, 1654, 1794, 2179, 2755.

   The per-file cache assignment pattern appears 6+ times:
   ```lua
   state.line_data_cache[idx] = ld
   state.row_disc_cache[idx] = rd
   state.row_ai_cache[idx] = ra
   ```

3. **Dual state initialization.** The state object with 22 fields is constructed twice: once in `M.open()` (line 2917) and once in `detail.open()` (line 323 of detail.lua). They drift out of sync.

4. **Scroll vs. per-file branching everywhere.** Nearly every action in `main_callbacks` has an `if state.scroll_mode then ... else ... end` branch that duplicates the same logic for two view modes. Examples: `create_comment` (lines 1917-1988), `create_range_comment` (lines 1990-2074), `select_next_note` (lines 2468-2540), `select_prev_note` (lines 2542-2614).

5. **`render_all_files()` (246 lines, line 510-752)** heavily duplicates `render_file_diff()` (140 lines, line 370-506). Both do: parse hunks, build display, apply highlights, word-diff, comment signs, AI suggestions. The only difference is the loop-over-files wrapper.

6. **`render_sidebar()` (215 lines, line 1009-1220)** mixes data computation (counting comments, stats) with presentation (building lines, applying highlights) and footer construction.

**Recommended decomposition:**
- Extract `diff_state.lua` -- state factory, `apply_scroll_result()`, `apply_file_result()`, cache helpers
- Extract `diff_keymaps.lua` -- all of `setup_keymaps()` content
- Extract `diff_render.lua` -- `render_file_diff()`, `render_all_files()`, highlight application
- Extract `diff_sidebar.lua` -- `render_sidebar()`, `build_footer()`, counting helpers
- Extract `diff_nav.lua` -- `nav_file()`, `jump_to_file()`, `jump_to_comment()`, `toggle_scroll_mode()`, anchor logic
- Extract `diff_comments.lua` -- `create_comment_at_cursor()`, `create_comment_range()`, optimistic update closures
- Keep `diff.lua` as a thin orchestrator

---

### #2. `lua/codereview/mr/comment.lua` -- HIGH (651 lines, 24 functions)

**`open_input_popup()` is 283 lines (line 9-292).** This single function handles:
- Buffer creation and initialization
- Inline float positioning with spacer math
- Fallback centered float
- Window styling and highlight management
- Auto-resize timer with debouncing
- Scroll adjustment (two distinct scroll strategies)
- WinLeave confirm dialog
- WinClosed cleanup
- Self-healing on diff buffer rewrite
- Keymap registration (q, Esc, Ctrl-Enter)

This function has 5 levels of nesting in places (timer callback -> schedule -> if/else chains).

**Also duplicated patterns:**
- `create_inline()`, `create_inline_range()`, `create_inline_draft()`, `create_inline_range_draft()` all share the same structure: open popup -> call provider -> handle error/success. They could share a generic `create_comment_with_opts()`.

**Recommended decomposition:**
- Extract the float window management into a reusable `comment_float.lua` module
- Consolidate the 4 `create_inline*` variants into a single parametric function

---

### #3. `lua/codereview/ui/markdown.lua` -- HIGH (867 lines, 25 functions)

**`parse_blocks()` is 191 lines (line 677-867).** It handles: list detection, code fences, blockquotes, horizontal rules, headings, table detection, checkbox lines, paragraph wrapping, and highlight generation. This is a mini markdown parser with a complex state machine.

**`range_is_base()` (inside `parse_inline`) is 136 lines (line 148-284).** This is a markdown inline parser handling: code spans, links, bold/italic/strikethrough, and nested formatting. The function name `range_is_base` is misleading -- it is the core inline parsing loop.

**Table rendering** is split across 7 tightly-coupled local functions (`parse_table_row`, `parse_alignment`, `word_wrap`, `pad_cell`, `process_cell_inline`, `wrapped_hl_slices`, `render_table` + nested `sum_widths`, `make_border`, `emit_border`, `emit_data_line`, `content_offset_for_align`) spanning 280 lines (346-677). These could be extracted into `markdown_table.lua`.

---

### #4. `lua/codereview/providers/github.lua` + `gitlab.lua` -- MEDIUM (644 + 435 lines)

**Repetitive `get_headers()` boilerplate.** Every single API function starts with:
```lua
local headers, err = get_headers()
if not headers then return nil, err end
```
GitHub has this pattern 20 times; GitLab has it 21 times.

**Duplicated provider interface.** Both files implement the same 18+ methods (`list_reviews`, `get_review`, `get_diffs`, `get_discussions`, `post_comment`, `post_range_comment`, `reply_to_discussion`, `edit_note`, `delete_note`, `resolve_discussion`, `approve`, `unapprove`, `get_current_user`, `merge`, `close`, `create_draft_comment`, `publish_review`, `create_review`) but there is no formal interface definition or base class pattern. Adding a new provider requires copy-pasting the entire structure.

**Module-level state in GitHub provider.** `M._pending_review_id`, `M._pending_review_node_id`, `M._cached_user` are module-level mutable state (lines 484-486, 449). This means concurrent reviews or re-entries could cause silent bugs.

**No shared normalization layer.** `types.lua` provides `normalize_review` and `normalize_file_diff` but not `normalize_discussion` or `normalize_note` -- those are inlined differently in each provider.

**Recommended improvements:**
- Create a `provider_base.lua` with a `with_headers(fn)` wrapper to eliminate the boilerplate
- Define the provider interface formally in `types.lua`
- Move discussion/note normalization into a shared layer

---

### #5. `lua/codereview/mr/detail.lua` -- MEDIUM (375 lines, 7 functions)

**`build_activity_lines()` is 172 lines (line 89-259).** It builds the summary-view activity section with inline markdown rendering, highlight tracking, code block tracking, and row mapping. It duplicates significant rendering logic from `thread_virt_lines.lua` but for a different output format (buffer lines + highlights vs. virt_lines).

**Duplicated `wrap_text()` function.** Found identical `wrap_text(text, width)` implementations in:
- `lua/codereview/mr/detail.lua:64` (simple word-wrap)
- `lua/codereview/mr/thread_virt_lines.lua:24` (span-aware word-wrap)
These do slightly different things but share the same name and basic structure. A third variant `word_wrap()` exists in `markdown.lua:346`.

**Tight coupling with `diff.lua`.** `detail.open()` constructs the same 22-field state object that `diff.open()` does, then calls `diff.render_sidebar()`, `diff.render_summary()`, and `diff.setup_keymaps()`. This dual-entry-point pattern causes state drift.

---

### #6. `lua/codereview/review/init.lua` -- MEDIUM (189 lines, 4 functions)

**Contains yet another copy of the render-result-to-state pattern** (lines 25-28 and 38-40), identical to the 7 copies in `diff.lua`. This module reaches deep into `diff_state` internals.

**`start_multi()` nests 5 levels deep:** function -> callback -> for loop -> callback -> if/schedule. The progress tracking and completion detection is interleaved with rendering logic.

---

### #7. `lua/codereview/mr/thread_virt_lines.lua` -- LOW-MEDIUM (236 lines, 7 functions)

**Reasonably well-scoped** but exports `wrap_text` and `md_virt_line` as utilities consumed by `diff.lua` (lines 232-234), which creates a dependency inversion: `diff.lua` imports from `thread_virt_lines.lua` at the module level (line 4-7).

Also exports `format_time_relative` consumed by `detail.lua:87`, and `is_resolved` consumed by `diff.lua:7`. This file has become a utility grab-bag rather than a focused module.

---

## Cross-Cutting Code Smells

### 1. Shotgun Surgery (co-change analysis)

Files that must change together, sorted by frequency:
| Pair | Co-changes |
|------|-----------|
| `mr/comment.lua` <-> `mr/diff.lua` | 6 |
| `mr/diff.lua` <-> `mr/thread_virt_lines.lua` | 4 |
| `providers/github.lua` <-> `providers/gitlab.lua` | 3 |
| `mr/diff.lua` <-> `ui/markdown.lua` | 3 |
| `mr/diff.lua` <-> `ui/highlight.lua` | 3 |
| `mr/detail.lua` <-> `mr/diff.lua` | 3 |

The `diff.lua` <-> everything coupling is the primary driver. Every UI or comment change ripples through diff.lua.

### 2. Duplicated Code Patterns

| Pattern | Locations | Impact |
|---------|-----------|--------|
| Scroll-result-to-state unpacking | 7x in diff.lua, 1x in review/init.lua | Any state shape change requires 8 edits |
| Per-file cache assignment | 6x in diff.lua | Same shape change issue |
| `get_headers()` + error guard | 41x across providers | Boilerplate noise |
| `wrap_text()` function | 3 separate implementations | Inconsistent behavior |
| State object construction | 2x (diff.lua:2917, detail.lua:323) | State field drift |
| `scroll_mode` branching | ~15x in setup_keymaps closures | Logic duplication per view mode |
| Provider detection (`providers.detect()`) | 7 call sites across 6 files | Could be a shared context |

### 3. Inconsistent API Styles

- `render_file_diff()` returns `line_data, row_discussions, row_ai` (3 values)
- `render_all_files()` returns a single table `{ file_sections, line_data, row_discussions, row_ai }`
- These are the same operation at different scales but use incompatible return signatures

### 4. God State Object

The `state` table passed through `diff.lua` has 22+ fields with no type documentation:
`view_mode`, `review`, `provider`, `ctx`, `entry`, `files`, `discussions`, `current_file`, `layout`, `line_data_cache`, `row_disc_cache`, `sidebar_row_map`, `collapsed_dirs`, `context`, `scroll_mode`, `file_sections`, `scroll_line_data`, `scroll_row_disc`, `file_contexts`, `ai_suggestions`, `row_ai_cache`, `scroll_row_ai`, `local_drafts`, `summary_row_map`, `row_selection`, `current_user`, `editing_note`, `sidebar_status_row`, `sidebar_drafts_row`, `sidebar_threads_row`.

This object is mutated freely by any function that receives it, with no encapsulation.

---

## Summary Table

| Rank | File | Lines | Functions | Key Issue | Effort |
|------|------|------:|----------:|-----------|--------|
| 1 | `mr/diff.lua` | 2997 | 95 | God module (6+ responsibilities), 1243-line function | Large -- split into 5-7 modules |
| 2 | `mr/comment.lua` | 651 | 24 | 283-line popup function, 4 near-duplicate create functions | Medium -- extract float, consolidate |
| 3 | `ui/markdown.lua` | 867 | 25 | 191-line parser, 280-line table renderer, misleading names | Medium -- extract table, rename |
| 4 | `providers/github.lua` | 644 | 29 | 41x header boilerplate, module-level mutable state | Medium -- base class + wrapper |
| 4 | `providers/gitlab.lua` | 435 | 29 | Same header boilerplate, no shared normalization | Medium -- same as above |
| 5 | `mr/detail.lua` | 375 | 7 | 172-line activity builder, duplicated state construction | Small-Medium |
| 6 | `review/init.lua` | 189 | 4 | Reaches into diff state internals, deep nesting | Small |
| 7 | `mr/thread_virt_lines.lua` | 236 | 7 | Utility grab-bag, dependency inversion | Small |
