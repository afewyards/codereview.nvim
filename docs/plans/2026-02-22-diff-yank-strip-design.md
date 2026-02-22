# Diff Yank Prefix Stripping Design

**Date:** 2026-02-22
**Goal:** Prevent line number prefix from appearing in yanked/deleted/changed text in the diff buffer.

## Approach

Two layers extending `clamp_cursor_to_content`:

1. **Charwise visual (`v`)** — already handled by existing `CursorMoved` autocmd cursor clamp. No change needed.
2. **`TextYankPost` autocmd** — strips first `LINE_NR_WIDTH` (14) chars from each line in the affected register after any yank/delete/change. Handles linewise `V`, `dd`, `yy`, `cc` etc.

## Implementation

Extend `M.clamp_cursor_to_content()` in `diff.lua` — add a `TextYankPost` autocmd:
- Read `vim.v.event.regcontents` and `vim.v.event.regname`
- Strip first `LINE_NR_WIDTH` chars from each line (clamped to line length)
- Write back to register via `vim.fn.setreg()`

## Edge Cases

- Short lines (< 14 chars): clamp strip length to `math.min(LINE_NR_WIDTH, #line)`
- Named registers / system clipboard: `vim.v.event.regname` identifies the register
- Visual block mode (`<C-v>`): cursor clamp already prevents prefix in selection
