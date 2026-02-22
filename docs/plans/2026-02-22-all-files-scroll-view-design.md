# All-Files Scroll View

## Summary

Concatenate all changed files into a single scrollable buffer, like GitHub's PR diff page. Toggle between per-file and all-files mode with `<C-f>`.

## Default Mode Logic

- MRs with ≤50 changed files: default to all-files scroll view
- MRs with >50 changed files: default to per-file view
- `<C-f>` toggles between modes regardless of MR size

## Buffer Layout

Single scratch buffer in the existing right pane (same split layout). All files concatenated vertically:

```
─── lua/glab_review/mr/diff.lua ────────────────────────
   12 |    12  local M = {}
   13 |    13
   14 |        -local old_function()
       |    14  +local new_function()
   15 |    15  end
                    ┌─ @user1 · 2h ago ─────────────┐
                    │ Should we rename this?         │
                    └────────────────────────────────┘

─── lua/glab_review/ui/split.lua ───────────────────────
    4 |     4  local config = require("glab_review.config")
    5 |        -vim.cmd("vsplit")
       |     5  +vim.cmd("topleft vsplit")
```

- File headers: full-width separator with path, `GlabReviewFileHeader` highlight group
- Line numbers reset per file section
- Inline comment threads render as virtual lines (same as per-file view)
- Sidebar stays visible; clicking a file scrolls to that section

## Data Model

```lua
file_sections = {
  { start_line = 1, end_line = 45, file = "...", diff_data = {...} },
  { start_line = 47, end_line = 112, file = "...", diff_data = {...} },
}
```

Enables:
- Sidebar click → `nvim_win_set_cursor` to `section.start_line`
- `CursorMoved` → binary search file_sections → highlight current file in sidebar
- Comment creation → reverse-map buffer line → file + old/new line number
- `]f`/`[f` → jump to next/prev `start_line`

## Keymaps

- `<C-f>` — toggle between per-file and all-files mode
- `]f`/`[f` — jump to next/prev file header (instead of loading new buffer)
- `]c`/`[c` — next/prev comment (works across all files naturally)
- `cc` / visual `cc` — create comment (reverse line map)
- `r` — reply, `gt` — toggle resolve
- `+`/`-` — adjust context (re-renders entire scroll buffer)
- `gf` — load full file for section under cursor
- `s` — back to MR detail, `q` — quit

## Rendering Pipeline

1. For each changed file: parse hunks, build display lines, prepend file header
2. `nvim_buf_set_lines` with all lines at once
3. Apply extmarks: file headers, diff add/delete, word-level diffs, comment virt_lines, sign column

Syntax highlighting via extmarks only (no per-section `vim.bo.syntax`).

## Edge Cases

- Empty diff: centered "No changes in this MR"
- Binary files: header + "(binary file — not shown)"
- Renamed files: header shows `old_path → new_path`
- New/deleted files: header shows `(new file)` or `(deleted)` badge
- Context reload (`+`/`-`/`gf`): re-renders entire buffer, preserves scroll position relative to current file section
