# Diff Cursor Clamp Design

**Date:** 2026-02-22
**Goal:** Prevent cursor from entering the 14-char line number prefix in the main diff buffer.

## Approach

Two layers — `CursorMoved` autocmd as safety net + buffer-local remaps for common motions.

## Implementation

### 1. `CursorMoved` autocmd

Attached to main diff buffer. On every move, if cursor col < `LINE_NR_WIDTH` (14), snap to col 14 (0-indexed). Catches all navigation: search, jumps, mouse, `:normal`, `|`, etc.

### 2. Buffer-local key remaps

Remap `0`, `^`, `h`, `<Left>`, `<BS>` to clamp at column 15 (1-indexed display). Avoids snap delay for the most common horizontal motions.

### 3. New function

`M.clamp_cursor_to_content(buf, win)` in `diff.lua`:
- Creates buffer-scoped `CursorMoved` autocmd
- Sets buffer-local remaps for `0`, `^`, `h`, `<Left>`, `<BS>`

### 4. Integration

Called from `M.open()` after layout creation, targeting only `layout.main_buf` / `layout.main_win`.

## Scope

- Main diff buffer only (not sidebar)
- Works in both scroll mode and per-file mode (same buffer)
- Autocmd persists across buffer re-renders (`nvim_buf_set_lines` doesn't clear autocmds)
