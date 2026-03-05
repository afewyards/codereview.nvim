# Sidebar Deep Dive -- codereview.nvim

Generated 2026-02-25. Updated 2026-03-01: sidebar has been decomposed into 5 components under `sidebar_components/` orchestrated by `sidebar_layout.lua`.

## Overview

The "sidebar" is the left-hand vertical split pane in codereview.nvim's two-pane layout. It serves as a persistent navigation panel showing the file tree, review session status, and contextual keybinding hints. It is rendered into a dedicated scratch buffer (nofile, no swap) with a fixed width of 30 columns. The sidebar is never directly edited by the user; its content is fully controlled by `render_sidebar()`, which clears and rewrites the entire buffer on every update.

## Files Involved

| File | Role |
|------|------|
| `lua/codereview/mr/sidebar_layout.lua` | **Primary owner (new).** Orchestrates 5 components, normalises highlight formats, writes buffer. |
| `lua/codereview/mr/diff_sidebar.lua` | Thin wrapper: `render_sidebar()` delegates to `sidebar_layout.render()`; owns `render_summary()`. |
| `lua/codereview/mr/sidebar_components/header.lua` | Review ID, title, pipeline icon, source branch line. |
| `lua/codereview/mr/sidebar_components/status.lua` | Session status block (AI progress, draft/AI stats, thread counts). |
| `lua/codereview/mr/sidebar_components/summary_button.lua` | "ℹ Summary" navigation row. |
| `lua/codereview/mr/sidebar_components/file_tree.lua` | Directory-grouped file list with `○/◑/●` review status icons and comment/AI badge counts. |
| `lua/codereview/mr/sidebar_components/footer.lua` | Dynamic keymap footer (changes based on `view_mode` and session state). |
| `lua/codereview/ui/split.lua` | Creates the two-pane layout (sidebar buffer + window, main buffer + window). |
| `lua/codereview/mr/diff_keymaps.lua` | Sidebar keybindings (`<CR>`, CursorMoved snap, `]f`/`[f`, scroll mode sync, review tracker). |
| `lua/codereview/mr/diff_nav.lua` | Navigation helpers that trigger sidebar re-renders. |
| `lua/codereview/mr/diff_state.lua` | State factory (`create_state`) -- `sidebar_row_map`, `sidebar_component_ranges`, `file_review_status`. |
| `lua/codereview/mr/review_tracker.lua` | Hunk-based review progress tracking: `init_file()`, `mark_visible()`. |
| `lua/codereview/mr/diff_render.lua` | Exports `apply_line_hl`, `apply_word_hl`, `discussion_matches_file` used by sidebar components. |
| `lua/codereview/ui/highlight.lua` | Defines all highlight groups used by the sidebar. |
| `lua/codereview/keymaps.lua` | Registry for configurable keybindings; sidebar footer reads from here. |
| `lua/codereview/mr/detail.lua` | One of two entry points that creates the split and renders the initial sidebar. |
| `lua/codereview/mr/diff.lua` | Thin facade: re-exports `render_sidebar` from `diff_sidebar`. |

## Layout Creation -- `ui/split.lua`

`split.create()` (`/Users/kleist/Sites/codereview.nvim/lua/codereview/ui/split.lua:3`) creates the two-pane layout:

```lua
-- Returns:
{
  sidebar_buf = <scratch buffer>,
  sidebar_win = <left vsplit window>,
  main_buf    = <scratch buffer>,
  main_win    = <right main window>,
}
```

**Sidebar window options** (lines 29-34):
- `number = false`, `relativenumber = false` -- no line numbers
- `signcolumn = "no"` -- no sign column
- `winfixwidth = true` -- sidebar width is fixed at 30 columns
- `wrap = false` -- no line wrapping
- `cursorline = true` -- highlight current line for navigation

The sidebar width defaults to 30 and is passed as `opts.sidebar_width`. Currently hardcoded in callers (not user-configurable via config.lua).

`split.close()` (line 70) closes only the sidebar window, leaving the main window intact.

## Sidebar Data Model

The sidebar rendering depends on these `state` fields (all defined in `diff_state.create_state()` at `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_state.lua:18-54`):

| Field | Type | Purpose |
|-------|------|---------|
| `state.review` | table | The MR/PR object -- provides `id`, `title`, `source_branch`, `pipeline_status` |
| `state.files` | table[] | Array of file diffs -- drives the file tree |
| `state.discussions` | table[] | Comment threads -- counted per-file for badges |
| `state.ai_suggestions` | table[] | AI suggestions -- counted per-file for badges |
| `state.local_drafts` | table[] | Draft comments from review session |
| `state.view_mode` | "summary" or "diff" | Controls which file gets the `">"` indicator |
| `state.current_file` | number | 1-indexed into `state.files` -- highlighted in sidebar |
| `state.scroll_mode` | boolean | Displayed as "All files" vs "Per file" label |
| `state.collapsed_dirs` | table | `{[dir_path]=true}` -- tracks collapsed directory groups |
| `state.sidebar_row_map` | table | `{[row]={type, idx/path/action}}` -- maps buffer rows to semantic entries |
| `state.sidebar_component_ranges` | table | `{ header={start,end}, status=…, summary_button=…, file_tree=…, footer=… }` -- written by `sidebar_layout.render()` |

Note: The old `sidebar_status_row`, `sidebar_drafts_row`, `sidebar_threads_row` fields are no longer used -- the component ranges replace them.

## Sidebar Layout (Top to Bottom)

The sidebar is rendered by `diff_sidebar.render_sidebar()` (`/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_sidebar.lua:172-383`). Here is the exact layout, section by section:

### 1. Review Header (lines 179-183)
```
#42
feat: add new login flow
[ok] feature/login
──────────────────────────────
```
- Line 1: `#<review_id>`
- Line 2: Review title (truncated to 28 chars)
- Line 3: Pipeline icon + source branch
- Line 4: Horizontal rule separator

### 2. Session Status Block (lines 189-235, conditional)

Only shown when a review session is active (`session.get().active == true`):

```
⟳ AI reviewing... 3/8        (when ai_pending)
● Review in progress          (when active, not ai_pending)
✎ 2 drafts  ✓3 ✗1 ⏳2 AI    (when drafts/AI stats exist)
```

Or thread counts (always shown if threads > 0):
```
💬 5 threads  ⚠ 2 open
```

Tracked via `state.sidebar_status_row`, `state.sidebar_drafts_row`, `state.sidebar_threads_row` for targeted highlighting.

### 3. File Count + Mode (lines 240-243)
```
12 files changed
All files                     (or "Per file")

```

### 4. Summary Button (lines 267-271)
```
▸ ℹ Summary                  (selected, view_mode == "summary")
  ℹ Summary                  (not selected)
```

Mapped in `sidebar_row_map` as `{ type = "summary" }`.

### 5. File Tree (lines 273-316)

Files are grouped by directory. Directories are collapsible.

```
▾ src/components/
    ▸ Button.tsx [2] 🤖1 ⚠1  (current file in diff mode)
      Input.tsx [1]
▸ src/utils/                  (collapsed directory)
    Modal.tsx                 (root-level file, no dir)
```

**Directory grouping** (lines 245-263):
- `vim.fn.fnamemodify(path, ":h")` extracts directory
- `vim.fn.fnamemodify(path, ":t")` extracts filename
- Files with dir == "." are treated as root-level
- Directory order is preserved from the `state.files` array

**Per-file indicators** (from `file_tree.lua:60-87`):

- Review status icon: `▸` for current file in diff mode; `○`/`◑`/`●` for unvisited/partial/reviewed (from `review_tracker`)
- ` N`: comment count (from `count_file_comments`)
- ` ✨N`: non-dismissed AI suggestion count (from `count_file_ai`; note: icon changed from 🤖 to ✨)
- ` ⚠N`: unresolved thread count (from `count_file_unresolved`)
- File names truncated to fit within remaining width

**Row map entries**:
- `{ type = "dir", path = dir }` for directory rows
- `{ type = "file", idx = N }` for file rows (1-indexed into `state.files`)

**Collapsed directories**: Toggled via `<CR>` on a dir row. Stored in `state.collapsed_dirs[path] = true`. When collapsed, the `▸` icon is shown and child files are hidden.

### 6. Keymap Footer (lines 318-322, built by `build_footer`)

Dynamic footer that changes based on `state.view_mode` and session state.

**Summary mode footer** (lines 119-131):
```
──────────────────────────────
───── Comment ─────────────────
r reply
gt     resolve
───── Actions ─────────────────
a approve   o open
m merge     R refresh
Q quit
```

**Diff mode footer** (lines 133-167):
```
──────────────────────────────
───── Navigate ────────────────
]f [f  files
Tab S-Tab  notes
───── Comment ─────────────────
cc     new       r reply
gt     resolve
───── Review ──────────────────    (only when session active)
a accept   x dismiss
e edit     ds dismiss all
S submit   A cancel AI
───── View ────────────────────
⌃F full      ⌃A scroll
R refresh   Q quit
```

The `k()` helper (line 86-93) converts Vim notation: `<C-f>` becomes `⌃F`, `<S-Tab>` becomes `S-Tab`. Keys set to `false` in config are omitted.

Footer section headers use `CodeReviewHidden` highlight (dimmed).

## Highlight Groups Used by Sidebar

Defined in `/Users/kleist/Sites/codereview.nvim/lua/codereview/ui/highlight.lua`:

| Highlight Group | Where Used | Default Appearance |
|----------------|------------|-------------------|
| `CodeReviewSummaryButton` | Summary row in sidebar | `fg=#7aa2f7, bold` (blue) |
| `CodeReviewFileChanged` | Currently selected file | `fg=#e0af68` (yellow) |
| `CodeReviewHidden` | Directory headers, footer section headers | `fg=#565f89, italic` (dimmed) |
| `CodeReviewAIDraft` | AI suggestion count badge (`🤖N`) | `bg=#2a2a3a, fg=#bb9af7` (purple) |
| `CodeReviewCommentUnresolved` | Unresolved count badge (`⚠N`), threads line | `bg=#3a2a2a, fg=#ff9966` (orange) |
| `CodeReviewSpinner` | AI reviewing status line | `fg=#7aa2f7, bold` (blue) |
| `CodeReviewFileAdded` | Review-in-progress status, `✓N` accepted count | `fg=#9ece6a` (green) |
| `CodeReviewFileDeleted` | `✗N` dismissed count | `fg=#f7768e` (red) |

**Highlighting logic** (lines 328-382):

1. **Sidebar row map iteration** (lines 330-351): For each row in `sidebar_row_map`:
   - Summary rows: `CodeReviewSummaryButton`
   - Current file rows: `CodeReviewFileChanged`
   - Directory rows: `CodeReviewHidden`
   - File rows with badges: Pattern-match `🤖%d+` for `CodeReviewAIDraft`, `⚠%d+` for `CodeReviewCommentUnresolved`

2. **Status line highlights** (lines 354-360):
   - AI pending: `CodeReviewSpinner`
   - Review active: `CodeReviewFileAdded`
   - Unresolved threads: `CodeReviewCommentUnresolved`

3. **Drafts+AI line highlights** (lines 363-377): Per-segment pattern matching:
   - `✓%d+`: `CodeReviewFileAdded` (green)
   - `✗%d+`: `CodeReviewFileDeleted` (red)
   - `⏳%d+`: `CodeReviewHidden` (dimmed)

All highlights use the `DIFF_NS` namespace (`codereview_diff`), cleared and reapplied on every render.

## Sidebar Keybindings and Navigation

### Sidebar-Specific Keybindings (from `diff_keymaps.lua`)

**`<CR>` on sidebar** (lines 1208-1273):
Three behaviors based on `sidebar_row_map[row].type`:

1. **`type == "summary"`**: Sets `view_mode = "summary"`, renders summary in main pane, focuses main window.
2. **`type == "dir"`**: Toggles `collapsed_dirs[path]`, re-renders sidebar, restores cursor position.
3. **`type == "file"`**:
   - If `state.files` is nil, lazy-loads diffs from API (`provider.get_diffs`)
   - Sets `view_mode = "diff"`, `current_file = entry.idx`
   - In scroll mode: renders all files, scrolls to the file section
   - In per-file mode: renders just that file
   - Focuses main window

**CursorMoved snap** (lines 1275-1308):
An autocmd on `sidebar_buf` restricts the cursor to valid rows (those in `sidebar_row_map`). When the cursor lands on an invalid row (header, blank line, separator), it snaps to the nearest valid row in the direction of movement. Falls back to the opposite direction if no valid row is found.

### Sidebar Callbacks via Registry (lines 1130-1155)

These keymaps are registered on `sidebar_buf` through `km.apply()`:

| Action | Key | Behavior |
|--------|-----|----------|
| `next_file` | `]f` | `diff_nav.nav_file(layout, state, 1)` -- only in diff mode |
| `prev_file` | `[f` | `diff_nav.nav_file(layout, state, -1)` -- only in diff mode |
| `toggle_scroll_mode` | `<C-a>` | `diff_nav.toggle_scroll_mode(layout, state)` -- only in diff mode |
| `pick_comments` | `<leader>fc` | Opens fuzzy comment picker |
| `pick_files` | `<leader>ff` | Opens fuzzy file picker |
| `refresh` | `R` | Full re-fetch from API |
| `quit` | `Q` | Closes the review UI |

Note: `select_next_note` and `select_prev_note` (Tab/Shift-Tab) are NOT bound on the sidebar buffer -- they only work from the main buffer. But they can transition from summary to diff view.

### Scroll Mode Sidebar Sync (lines 1382-1389)

A `CursorMoved` autocmd on `main_buf` syncs the sidebar highlight in scroll mode:
```lua
if state.scroll_mode and #state.file_sections > 0 then
  local file_idx = diff_nav.current_file_from_cursor(layout, state)
  if file_idx ~= state.current_file then
    state.current_file = file_idx
    diff_sidebar.render_sidebar(layout.sidebar_buf, state)
  end
end
```
Uses binary search (`current_file_from_cursor` in `diff_nav.lua:302-317`) over `state.file_sections` to find which file the cursor is in, then re-renders the sidebar to update the `▸` indicator.

## Counting Helpers

Three private functions in `diff_sidebar.lua` (lines 20-45) compute per-file badge values:

### `count_file_comments(file, discussions)` (line 20)
Counts discussions matching a file via `discussion_matches_file()` (imported from `diff_render`). Counts all discussions including resolved, drafts, etc.

### `count_file_unresolved(file, discussions)` (line 28)
Same iteration but excludes `local_draft` discussions and only counts unresolved ones.

### `count_file_ai(file, suggestions)` (line 38)
Counts AI suggestions matching the file path where `status ~= "dismissed"`.

### `count_session_stats(state)` (line 47)
Returns `{ drafts, ai_accepted, ai_dismissed, ai_pending, threads, unresolved }` by iterating `state.local_drafts`, `state.ai_suggestions`, and `state.discussions`.

## Render Trigger Points

The sidebar is re-rendered (`diff_sidebar.render_sidebar(layout.sidebar_buf, state)`) from these locations:

| Trigger | File | Line(s) |
|---------|------|---------|
| Initial open (via detail.open) | `detail.lua` | 338 |
| Initial open (via diff.open) | `diff.lua` | 77 |
| Resume server-side drafts | `diff.lua` | 111, `detail.lua` 348 |
| File navigation (`nav_file`) | `diff_nav.lua` | 27 |
| File switch (`switch_to_file`) | `diff_nav.lua` | 40 |
| Jump to file (summary->diff) | `diff_nav.lua` | 63, 71 |
| Toggle scroll mode | `diff_nav.lua` | 351 |
| Sidebar `<CR>` on file/dir/summary | `diff_keymaps.lua` | 1217, 1229, 1245, 1258, 1266 |
| Scroll mode cursor sync | `diff_keymaps.lua` | 1387 |
| After AI review renders | `diff_keymaps.lua` | 210, 295, 312 |
| After refresh | `diff_keymaps.lua` | 99-100 |
| Tab/Shift-Tab summary->diff transition | `diff_keymaps.lua` | 931, 1031 |
| After full-file toggle | `diff_keymaps.lua` | 780 |

**Performance note**: Every render call rewrites the entire sidebar buffer (clear all lines, set all lines, clear namespace, reapply all highlights). There is no incremental update path. The sidebar is typically ~30-60 lines so this is fast, but it happens frequently (every cursor move in scroll mode that crosses a file boundary).

## Interaction with Other Components

### Sidebar <-> Main Pane
- Sidebar `<CR>` on a file triggers `diff_render.render_file_diff()` or `diff_render.render_all_files()` on `layout.main_buf`
- Sidebar `<CR>` on summary triggers `diff_sidebar.render_summary()` on `layout.main_buf`
- Main pane cursor movement in scroll mode triggers sidebar re-render (scroll sync)
- `]f`/`[f` from sidebar triggers `diff_nav.nav_file()` which renders both sidebar and main pane

### Sidebar <-> Review Session
- `session.get()` is called on every `render_sidebar()` to check session state
- Session state controls: status line visibility, draft count, AI progress display, footer review section
- Session start/stop triggers sidebar re-render

### Sidebar <-> AI Review
- AI suggestions completion triggers sidebar re-render to update `🤖N` badges
- AI progress updates the "⟳ AI reviewing... N/M" status line
- The `✓`, `✗`, `⏳` stats in the drafts line reflect AI suggestion dispositions

### Sidebar <-> Floating Windows
- Comment creation (from `comment.lua` / `comment_float.lua`) does not directly interact with the sidebar
- After a comment is posted, `rerender_view()` is called, which triggers sidebar re-render via `refresh_discussions()` -> `diff_sidebar.render_sidebar()`

## Summary View (Also in diff_sidebar.lua)

`render_summary()` (`/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_sidebar.lua:387-490`) renders into the **main pane** (not the sidebar), but lives in the same module because it shares state access patterns. It:

1. Builds header lines via `detail.build_header_lines()` (title, author, branch, pipeline, approvals, description)
2. Builds activity lines via `detail.build_activity_lines()` (non-inline discussion threads with markdown rendering)
3. Applies highlights via extmarks in `SUMMARY_NS` namespace
4. Applies treesitter syntax highlighting to code blocks
5. Builds `state.summary_row_map` mapping buffer rows to discussions
6. Sets `wrap = true`, `linebreak = true` on the main window

## Gotchas and Notes

1. **No incremental sidebar update**: Every change causes a full rewrite. In scroll mode with many files, sidebar re-renders on every file boundary crossing.

2. **Unicode width issues**: Badge strings like `🤖1` and `⚠2` use multi-byte Unicode characters. The `#cstr`, `#aistr`, `#ustr` length calculations use byte length, not display width. This can cause file name truncation to be slightly off.

3. **Sidebar width is not configurable**: Hardcoded as 30 in `split.create()`. The sidebar content layout (truncation limits, footer widths) assumes this width.

4. **sidebar_row_map is rebuilt on every render**: It is a fresh table each time, stored on state. Old references are invalidated.

5. **Summary button is always visible**: Even when there are no discussions or description, the `ℹ Summary` row is present.

6. **Directory display truncation**: Long directory paths are truncated to `..` + last 22 chars (line 278-279). This is a fixed limit, not responsive to sidebar width.

7. **render_summary lives in diff_sidebar.lua**: Despite rendering into the main pane, it was placed here during the diff.lua decomposition because it shares state access patterns with the sidebar. The `SUMMARY_NS` namespace is separate from `DIFF_NS`.

8. **Counting helpers iterate all discussions/suggestions per file**: `count_file_comments`, `count_file_unresolved`, and `count_file_ai` each do a full scan. For N files and D discussions, sidebar rendering is O(N*D). Not a problem at current scale (typically <100 files, <50 discussions).
