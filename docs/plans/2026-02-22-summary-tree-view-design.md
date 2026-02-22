# Summary Tree View Design

## Problem

The MR detail/summary view uses a plain floating buffer with no file tree sidebar. Users must press `d` to enter the diff view before seeing the file tree. The summary and diff views feel disconnected.

## Solution

Unify summary and diff into a single split layout with a shared sidebar. Add a `view_mode` field (`"summary"` | `"diff"`) to state. The sidebar always shows a file tree with a **Summary button** above the first file. Navigation between views is done entirely via the sidebar.

## Architecture

### Entry Point Change

`detail.open(mr_entry)` becomes the unified entry point:
1. Fetches MR details + discussions (same as now)
2. Creates `split.create()` layout (sidebar + main)
3. Builds shared state with `view_mode = "summary"`, `files = nil` (lazy)
4. Renders sidebar with Summary button + file count placeholder
5. Renders summary content in main pane
6. Sets up all keymaps once

### Lazy Diff Loading

Diffs are **not** fetched in `detail.open`. When the user first clicks a file in the sidebar:
1. Fetch diffs → `state.files = files`
2. Re-render sidebar with actual file tree
3. Set `view_mode = "diff"`, render diff in main pane

Subsequent view switches just swap main pane content.

### Sidebar Layout

```
▸ ℹ Summary              ← active indicator when view_mode == "summary"
                          ← blank separator
▾ src/components/
  ▸ Button.lua [2]        ← active indicator when this file is current in diff mode
    Modal.lua
▾ tests/
    button_spec.lua
──────────────────────────────
s:summary  R:refresh  q:quit
```

- `sidebar_row_map[row] = { type = "summary" }` for the Summary button
- Summary gets `▸` indicator when `view_mode == "summary"` (no file has `▸`)
- In diff mode, Summary loses `▸`, active file gets it
- New highlight group: `GlabReviewSummaryButton`
- Summary is **not** part of `state.files` — purely a UI entry

### Sidebar `<CR>` Handler

| Entry type | Action |
|-----------|--------|
| `summary` | Set `view_mode = "summary"`, render summary in main pane |
| `file` | Load diffs if needed, set `view_mode = "diff"`, render file diff |
| `dir` | Toggle collapse (unchanged) |

### View Mode: Summary

Main pane renders (reusing existing functions):
- `detail.build_header_lines(mr)` — MR metadata
- `detail.build_activity_lines(discussions)` — general discussion threads
- Footer with discussion count + keymap hints

Keymaps active on main_buf:
- `c` — general MR comment
- `a` — approve
- `m` — merge
- `o` — open in browser
- `R` — refresh
- `q` — quit
- `p` — pipeline (stub)
- `A` — AI review (stub)

### View Mode: Diff

Main pane renders diffs (existing logic, unchanged). All existing diff keymaps active: `]f`, `[f`, `]c`, `[c`, `cc`, `r`, `gt`, `+`, `-`, `C-f`, `C-a`, `R`, `q`.

### Navigation Model

No `d` or `s` keymaps. All view switching via sidebar:
- Click **Summary** → summary view
- Click **file** → diff view for that file

### State Structure

```lua
state = {
  view_mode = "summary",  -- "summary" | "diff"
  mr = mr,
  files = nil,            -- nil until first diff load, then file list
  discussions = discussions,
  current_file = 1,
  collapsed_dirs = {},
  sidebar_row_map = {},
  -- diff-specific (populated on first diff load):
  layout = layout,
  line_data_cache = {},
  row_disc_cache = {},
  context = cfg.diff.context,
  scroll_mode = nil,       -- set on first diff load
  file_sections = {},
  scroll_line_data = {},
  scroll_row_disc = {},
  file_contexts = {},
}
```

### Removed

- `detail.lua`'s floating buffer creation (`vim.api.nvim_create_buf` + `vim.cmd("buffer")`)
- `d` keymap from detail view
- `s` keymap from diff view
- `back()` function in diff keymaps

### New Highlight Group

`GlabReviewSummaryButton` — applied to the Summary button row in the sidebar.
