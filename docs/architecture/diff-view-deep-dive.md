# Diff View Deep Dive -- codereview.nvim

Generated 2026-02-25. Focused analysis of the diff view buffer architecture, rendering pipeline, floating windows, syntax highlighting, and LSP compatibility.

## Overview

The diff view is the core UI of codereview.nvim. It renders unified diffs inside a Neovim scratch buffer (`buftype=nofile`) with no filetype, no buffer name, and `modifiable=false`. The buffer content is **plain text lines stripped from unified diff output** (context lines, additions, deletions) with line numbers rendered as inline virtual text via extmarks. Comment threads and AI suggestions are rendered entirely as virtual lines (extmarks with `virt_lines`), not real buffer content. Syntax highlighting uses Vim's legacy `syntax` commands (not treesitter) applied directly to the buffer.

**Key insight for LSP compatibility**: The main diff buffer has `buftype=nofile`, no `filetype`, no buffer name, and contains interleaved add/delete/context lines from potentially multiple files. LSP servers cannot attach to this buffer in any meaningful way -- there is no filetype to trigger attachment, no file path for the language server to resolve, and the buffer content is not valid source code.

## Buffer Setup

### Main Buffer (diff content)

Created in `/Users/kleist/Sites/codereview.nvim/lua/codereview/ui/split.lua:14-17`:

```lua
local main_buf = vim.api.nvim_create_buf(false, true)  -- unlisted, scratch
vim.bo[main_buf].bufhidden = "wipe"
vim.bo[main_buf].buftype = "nofile"
vim.bo[main_buf].swapfile = false
```

**Properties at creation time:**
| Property | Value | Effect |
|----------|-------|--------|
| `listed` | `false` | Does not appear in `:ls` |
| `scratch` | `true` | Scratch buffer flag |
| `bufhidden` | `"wipe"` | Buffer is wiped when hidden |
| `buftype` | `"nofile"` | Not associated with any file |
| `swapfile` | `false` | No swap file |
| `filetype` | (unset, empty) | No filetype is ever set on the main buffer |
| `modifiable` | toggled | Set to `true` before writing lines, `false` after |
| `syntax` | set per file | In per-file mode, set to the detected filetype's syntax |
| buffer name | (none) | `nvim_buf_set_name` is never called |

**Window options** (lines 37-40):
```lua
vim.wo[main_win].number = false
vim.wo[main_win].relativenumber = false
vim.wo[main_win].signcolumn = "yes"
vim.wo[main_win].wrap = false
```

### Sidebar Buffer

Created identically (`buftype=nofile`, scratch, `bufhidden=wipe`). Window has `signcolumn="no"`, `winfixwidth=true`, `cursorline=true`.

### Comment Float Buffer

Created in `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/comment_float.lua:25-27`:

```lua
local buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].bufhidden = "wipe"
vim.bo[buf].filetype = "markdown"
```

This is the **only buffer type with a filetype set** -- the comment input popup uses `filetype=markdown`. This means LSP markdown servers (if configured) could technically attach to comment input floats.

## Buffer Content: What the Diff View Actually Contains

### Per-File Mode (`render_file_diff`)

Source: `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_render.lua:479-630`

The buffer content is built from parsed unified diff hunks. Each buffer line is **the raw code text from the diff** (with the `+`/`-`/` ` prefix stripped). The diff line-number gutter is rendered as inline virtual text, not actual buffer characters.

**Buffer line construction** (lines 543-546):
```lua
for _, item in ipairs(display) do
    table.insert(lines, item.text or "")   -- raw code text, no diff prefix
    table.insert(line_data, { type = item.type, item = item })
end
```

**Example buffer content** (what `nvim_buf_get_lines` returns):
```
  ↑ Press <CR> to load more context above ↑       ← load_more sentinel
  local foo = require("bar")                        ← context line (plain text)
  local baz = require("qux")                        ← context line
  local old_var = 42                                 ← delete line (plain text)
  local new_var = 43                                 ← add line (plain text)
  return M                                           ← context line
  ↓ Press <CR> to load more context below ↓       ← load_more sentinel
```

The line numbers (e.g. `   42 |    43 `) are NOT in the buffer text. They are rendered as inline virtual text via extmarks (lines 584-588):
```lua
vim.api.nvim_buf_set_extmark(buf, DIFF_NS, row, 0, {
    virt_text = { { M.format_line_number(data.item.old_line, data.item.new_line), "CodeReviewLineNr" } },
    virt_text_pos = "inline",
})
```

### All-Files Scroll Mode (`render_all_files`)

Source: `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_render.lua:634-883`

Same as per-file mode, but with file header separators between each file:

```
--- src/components/Button.tsx ──────────────────────  ← file_header
  import React from 'react'                           ← context
  const Button = () => {                               ← context
  return <button>{label}</button>                      ← delete
  return <button className={cls}>{label}</button>      ← add
  }                                                    ← context
                                                       ← separator (blank line)
--- src/utils/helpers.ts ──────────────────────────  ← file_header
  export function helper() {                           ← context
  ...
```

### Summary Mode (`render_summary`)

Source: `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_sidebar.lua:387-488`

Renders MR title, description (markdown), and activity (discussion threads). This uses the same main buffer but with different content. When in summary mode, `wrap=true` and `linebreak=true` are set on the window.

## Syntax Highlighting Strategy

### Per-File Mode: `vim.bo[buf].syntax = ft`

Source: `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_render.lua:567-572`

```lua
local path = file_diff.new_path or file_diff.old_path or ""
local ft = vim.filetype.match({ filename = path })
if ft then
    vim.bo[buf].syntax = ft
end
```

This sets the **buffer-level Vim syntax** to match the file extension (e.g., `syntax=lua`, `syntax=typescript`). This means:
- Vim's legacy syntax highlighting is applied to the entire buffer
- Delete lines get syntax-highlighted too (which can be visually useful)
- The syntax changes every time the user navigates to a different file (`]f`/`[f`)
- **This does NOT set filetype** -- only `syntax`. LSP attachment is triggered by `filetype`, not `syntax`.

### All-Files Scroll Mode: `syntax include` Regions

Source: `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_render.lua:768-817`

Much more complex. Uses Vim's `syntax include` + `syntax region` to apply per-file syntax highlighting to different regions of the buffer:

```lua
vim.cmd("syntax clear")
-- For each file section:
vim.cmd("unlet! b:current_syntax")
vim.cmd("syntax include @GlabSyn_typescript syntax/typescript.vim")
vim.cmd('syntax region GlabRegion_1_1 start="\\%5l" end="\\%20l" contains=@GlabSyn_typescript keepend')
```

Key details:
- Delete lines are **skipped** by splitting regions around them (lines 793-812). This prevents syntax state corruption from deleted code interleaving with added code.
- Each file section gets its own numbered syntax region(s)
- The cluster name is `GlabSyn_<ft>` (legacy naming from when the plugin was called "glab")

### Treesitter: Only Used in Summary View

Treesitter is used **exclusively** for code blocks in the summary/activity view (`diff_sidebar.lua:434-473`). It uses `vim.treesitter.get_string_parser` on extracted code block text, then maps capture ranges back to buffer positions. This is **not** used in the diff view at all.

## Extmarks and Highlights

### Namespaces

Three namespaces are used across the diff view:

| Namespace | Name | Used For |
|-----------|------|----------|
| `DIFF_NS` | `"codereview_diff"` | Line highlights (add/delete), inline line numbers, comment thread virt_lines |
| `AIDRAFT_NS` | `"codereview_ai_draft"` | AI suggestion virtual lines and signs |
| `NS` (inline_float) | `"codereview_inline_float"` | Reserved space for comment float, line highlights during comment input |
| `SUMMARY_NS` | `"codereview_summary"` | Summary view highlights and treesitter code blocks |

### Line-Level Highlights (extmarks)

Applied in `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_render.lua:31-33`:

```lua
local function apply_line_hl(buf, row, hl_group)
    vim.api.nvim_buf_set_extmark(buf, DIFF_NS, row, 0, { line_hl_group = hl_group, priority = 50 })
end
```

| Line Type | Highlight Group | Color |
|-----------|----------------|-------|
| Add | `CodeReviewDiffAdd` | `bg=#2a4a2a` (green tint) |
| Delete | `CodeReviewDiffDelete` | `bg=#4a2a2a` (red tint) |
| Add word diff | `CodeReviewDiffAddWord` | `bg=#3a6a3a` (brighter green) |
| Delete word diff | `CodeReviewDiffDeleteWord` | `bg=#6a3a3a` (brighter red) |
| File header | `CodeReviewFileHeader` | `bg=#1e2030, fg=#c8d3f5, bold` |
| Load more | `CodeReviewHidden` | `fg=#565f89, italic` |

### Inline Line Numbers (extmarks with virt_text_pos="inline")

Each diff line gets an inline virtual text extmark showing old/new line numbers in the format `   42 |    43 ` (14 chars wide). These are in the `DIFF_NS` namespace with highlight `CodeReviewLineNr` (`fg=#565f89`).

### Comment Threads (extmarks with virt_lines)

Built by `thread_virt_lines.build()` at `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/thread_virt_lines.lua:88-265`. Placed via `nvim_buf_set_extmark` with `virt_lines` in `DIFF_NS`:

```lua
pcall(vim.api.nvim_buf_set_extmark, buf, DIFF_NS, row - 1, 0, {
    virt_lines = result.virt_lines,
    virt_lines_above = false,
})
```

Each virtual line is an array of `{text, highlight_group}` chunks. Box-drawing characters (`┏`, `┃`, `┗`, `━`) form card borders.

### AI Suggestions (extmarks with virt_lines)

Built by `render_ai_suggestions_at_row()` at `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_render.lua:108-205`. Placed in `AIDRAFT_NS`:

```lua
pcall(vim.api.nvim_buf_set_extmark, buf, AIDRAFT_NS, row - 1, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false,
})
```

### Signs (legacy sign_place)

Comment and AI suggestion gutter indicators use legacy `vim.fn.sign_place`:

| Sign Name | Text | Purpose |
|-----------|------|---------|
| `CodeReviewCommentSign` | `"█ "` | Resolved comment thread |
| `CodeReviewUnresolvedSign` | `"█ "` | Unresolved comment thread |
| `CodeReviewAISign` | `"▍ "` | AI suggestion (info severity) |
| `CodeReviewAIWarningSign` | `"▌ "` | AI suggestion (warning) |
| `CodeReviewAIErrorSign` | `"█ "` | AI suggestion (error) |

### Selection Indicator (selective extmark update)

When the cursor moves, `update_selection_at_row()` (`diff_render.lua:220-264`) performs a targeted extmark update on the old and new rows:
1. Clears `AIDRAFT_NS` extmarks on the row
2. Clears `DIFF_NS` virt_lines extmarks on the row (preserving line_hl and virt_text)
3. Re-renders AI suggestions and comment threads with updated selection state

This avoids a full buffer re-render for cursor-driven selection changes.

## Floating Windows

### Comment Input Float

Source: `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/comment_float.lua:13-267`

Two modes:

**Inline mode** (anchored to diff line): Used when `anchor_line` and `win_id` are provided and the window is wide enough (>=40 cols). The float is positioned relative to the diff window using `relative="win"` and `bufpos`:

```lua
handle.win = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    win = opts.win_id,
    bufpos = { anchor_0, 0 },
    width = width,
    height = total_height,
    row = (opts.thread_height or 0) + 1,
    col = 3,
    style = "minimal",
    border = ifloat.border(opts.action_type),
    -- ...
})
```

The float is positioned after any existing comment thread virtual lines (`thread_height` offset). Space is reserved in the diff buffer using virtual lines (`inline_float.reserve_space`).

**Fallback mode** (centered): Used when inline positioning is not possible. Centered in the editor:

```lua
handle.win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = 70,
    height = total_height,
    -- centered row/col
})
```

**Buffer properties**:
- `buftype`: (unset, default "")
- `filetype`: `"markdown"` -- the ONLY buffer in the plugin with a filetype
- `bufhidden`: `"wipe"`
- `modifiable`: true (user edits here)

**Window properties**: `winblend=0`, `winhighlight=NormalFloat:Normal`, `wrap=true`

**Self-healing**: An `on_lines` callback on the diff buffer detects when the diff is rewritten (e.g., by AI suggestions arriving) and re-reserves space for the float.

**Auto-resize**: A debounced (15ms) `on_lines` callback on the float buffer recalculates height based on content, updates both the window height and the reserved space extmark.

### Thread Display Float (legacy)

Source: `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/comment.lua:128-182`

A simpler centered float for showing full thread content. Uses `border="rounded"`, `style="minimal"`. The buffer gets `modifiable=false` and `filetype=markdown` (via `markdown.set_buf_markdown`). This appears to be a legacy code path -- threads are now shown as virtual lines inline.

## LSP Compatibility Analysis

### No LSP-Related Code Exists

A comprehensive search for `lsp`, `vim.lsp`, `language.server`, and `diagnostic` across all Lua source files returns **zero matches**. The plugin has no LSP integration whatsoever.

### Why LSP Cannot Attach to the Diff Buffer

1. **No filetype**: The main diff buffer never has `filetype` set. LSP servers are attached via `FileType` autocommands (e.g., `lspconfig`'s `filetypes = {"lua", "python"}`). With no filetype, no server will auto-attach.

2. **No buffer name / no file path**: `nvim_buf_set_name` is never called on the main buffer. LSP servers use the buffer name to determine the file URI (`file:///path/to/file.lua`). Without it, the server cannot resolve the file in its workspace.

3. **`buftype=nofile`**: Most LSP configurations skip `nofile` buffers. Even if you forced attachment, the server would have no file to associate with.

4. **Content is not valid source code**: The buffer contains interleaved context/add/delete lines from a diff, with load-more sentinels and file headers. Even if you could attach an LSP, the content would not parse as valid code in any language.

5. **Syntax != filetype**: In per-file mode, `vim.bo[buf].syntax = ft` is set, but this only controls Vim's legacy syntax highlighting. It does NOT trigger `FileType` autocommands and does NOT cause LSP attachment.

6. **Buffer content is ephemeral**: The buffer is completely rewritten on every file navigation, view mode switch, or re-render. Any LSP state would be invalidated constantly.

### Comment Float: The One Exception

The comment input float (`comment_float.lua:27`) sets `filetype = "markdown"`. This **could** trigger LSP attachment from markdown language servers. However:
- The buffer is short-lived (exists only while the popup is open)
- It has `bufhidden = "wipe"`
- No buffer name is set
- Most markdown LSP servers expect a file path

### What Would Be Needed for LSP on Diff Content

If the goal is to get LSP features (diagnostics, hover, go-to-definition) on the code shown in the diff view, the approach would need to be fundamentally different from attaching to the diff buffer. Possible strategies:

1. **Shadow buffer**: Create a hidden buffer per file with the full file content (from `git show head_sha:path`), set its filetype and name, attach LSP, then map positions between the shadow buffer and the visible diff rows.

2. **Temporary file**: Write the head-sha version to a temp file, open it in a hidden buffer with proper filetype, let LSP attach, and proxy diagnostics/hover results to the diff view.

3. **Virtual buffer with name spoofing**: Create a named buffer (`nvim_buf_set_name`) with the real file path, set its filetype, populate with the full file content, and map LSP responses to diff rows. Risk: conflicts with the actual file if it is also open.

All strategies require a **line mapping layer** between the diff view rows (which omit lines outside the diff context) and the full file line numbers (which LSP operates on). The `line_data` array already provides this mapping -- each entry has `item.new_line` and `item.old_line` corresponding to the original file's line numbers.

## Rendering Pipeline Summary

```
User navigates to file (sidebar <CR>, ]f, [f)
  |
  v
render_file_diff() or render_all_files()
  |
  +--> git diff -U{context} base..head -- path  (local git, O(1) cached)
  |    Falls back to API diff if local git fails
  |
  +--> diff_parser.parse_hunks(diff_text)
  |    Returns: [{ old_start, new_start, lines: [{type, text, old_line, new_line}] }]
  |
  +--> diff_parser.build_display(hunks, context_lines)
  |    Returns: [{type, text, old_line, new_line, hunk_idx, line_idx}]
  |    (Filters to context_lines around changes, inserts "hidden" markers)
  |
  +--> Set buffer lines (modifiable=true, set_lines, modifiable=false)
  |
  +--> Set syntax (per-file: vim.bo.syntax; scroll: syntax include/region)
  |
  +--> Apply extmarks:
  |    - Inline virt_text for line numbers (every diff line)
  |    - line_hl_group for add/delete coloring
  |    - Word-diff hl_group for character-level changes
  |
  +--> place_comment_signs()
  |    - For each discussion matching this file:
  |      - Place gutter sign (resolved vs unresolved)
  |      - Build virt_lines via thread_virt_lines.build()
  |      - Set extmark with virt_lines on the target row
  |    - Returns: row_discussions map
  |
  +--> place_ai_suggestions()
       - For each non-dismissed suggestion matching this file:
         - Match to row by line number (O(1) lookup) + fuzzy code verification
         - Build virt_lines with severity-based styling
         - Set extmark with virt_lines on the target row
       - Returns: row_ai map
```

## Data Flow: Diff Line to Buffer Row

```
API response: file_diff.diff = "--- a/foo.lua\n+++ b/foo.lua\n@@ -10,5 +10,6 @@\n ..."
                                         |
                                         v
parse_hunks() → hunks[1].lines = [
  { type="context", text="local M = {}", old_line=10, new_line=10 },
  { type="delete",  text="local x = 1",  old_line=11, new_line=nil },
  { type="add",     text="local x = 2",  old_line=nil, new_line=11 },
  { type="context", text="return M",     old_line=12, new_line=12 },
]
                                         |
                                         v
build_display() → display = [
  { type="context", text="local M = {}", old_line=10, new_line=10 },
  { type="delete",  text="local x = 1",  old_line=11 },
  { type="add",     text="local x = 2",  new_line=11 },
  { type="context", text="return M",     old_line=12, new_line=12 },
]
                                         |
                                         v
Buffer lines (what nvim_buf_get_lines returns):
  Row 1: "local M = {}"
  Row 2: "local x = 1"
  Row 3: "local x = 2"
  Row 4: "return M"

line_data array:
  [1] = { type="context", item={ text="local M = {}", old_line=10, new_line=10 } }
  [2] = { type="delete",  item={ text="local x = 1",  old_line=11 } }
  [3] = { type="add",     item={ text="local x = 2",  new_line=11 } }
  [4] = { type="context", item={ text="return M",     old_line=12, new_line=12 } }

Visual rendering (what the user sees):
     10 |    10  local M = {}           ← context, no highlight
     11 |        local x = 1           ← delete, red background
        |    11  local x = 2           ← add, green background
     12 |    12  return M              ← context, no highlight
  (line numbers are inline virt_text, not buffer content)
```

## Gotchas

1. **Buffer content is NOT the file content**: The buffer contains stripped diff lines. Context lines are the original code; add/delete lines are changes. Lines outside the diff hunks are not present in the buffer at all.

2. **`syntax` is set but `filetype` is not**: In per-file mode, `vim.bo[buf].syntax = ft` provides syntax highlighting without triggering `FileType` autocommands. This is deliberate -- the buffer is not a real source file.

3. **Content changes on every navigation**: Every `]f`/`[f` press or file selection completely rewrites the buffer with `nvim_buf_set_lines`. All extmarks in `DIFF_NS` are cleared and reapplied.

4. **No buffer name**: The main buffer has no name. Calling `vim.api.nvim_buf_get_name(main_buf)` returns `""`.

5. **Modifiable toggle pattern**: The buffer is set to `modifiable=true` just before writing, then immediately to `modifiable=false`. This prevents user edits but also prevents any tool/plugin that tries to modify the buffer.

6. **Virtual lines vs real lines**: Comment threads and AI suggestions appear visually between buffer lines but are NOT actual buffer lines. `nvim_buf_line_count` returns only the real line count (diff lines). Cursor movement skips over virtual lines. This is important for any tool that tries to map screen coordinates to buffer positions.

7. **The `line_data` array is the rosetta stone**: It maps buffer row (1-indexed) to `{ type, item: { old_line, new_line, text } }`. Any feature that needs to translate between buffer rows and original file line numbers must use this data structure.
