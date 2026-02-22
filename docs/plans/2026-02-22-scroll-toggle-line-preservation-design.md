# Scroll Toggle Line Preservation

## Problem

Toggling between scroll mode (all-files) and per-file mode loses cursor position. Currently:
- Entering scroll: jumps to file section header
- Exiting scroll: re-renders file from top

## Design

### Anchor-based position matching

Before toggle, extract an **anchor** from the current view's `line_data` at cursor row:
```
anchor = { file_idx, old_line, new_line }
```

After rendering the target view, scan its `line_data` for the matching anchor and set cursor.

### Match priority

1. **Exact:** same `file_idx` + same `new_line` (or `old_line` for delete-only lines)
2. **Closest:** same `file_idx`, smallest `|new_line - anchor.new_line|` distance (handles full-file mode where cursor may be on a line not in the diff)
3. **File fallback:** first diff line of the file section

### Non-diff cursor (header, separator, load-more)

Anchor has `file_idx` but no `old_line`/`new_line` — falls back to first diff line of that file.

### Helpers

- `find_anchor(line_data, cursor_row)` — extract anchor from current view
- `find_row_for_anchor(line_data, anchor, file_sections?)` — scan target view for best match

### Changes to `toggle_scroll_mode`

**Per-file -> scroll:**
1. `anchor = find_anchor(line_data_cache[current_file], cursor_row)`
2. `render_all_files(...)` (existing)
3. `row = find_row_for_anchor(scroll_line_data, anchor)`
4. Set cursor to `row`

**Scroll -> per-file:**
1. `anchor = find_anchor(scroll_line_data, cursor_row)` (captures `file_idx`)
2. Set `current_file = anchor.file_idx`
3. `render_file_diff(...)` (existing)
4. `row = find_row_for_anchor(line_data_cache[current_file], anchor)`
5. Set cursor to `row`

### Edge cases

- Full-file mode (`C-f`): cursor on non-hunk line -> closest match fallback
- Empty file: cursor stays at file header
- Different context levels: closest match if exact not found
