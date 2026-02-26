# Summary View Redesign

GitHub PR-style layout with clear visual hierarchy, Nerd Font icons, and jumpable file context.

## Header Card

Rounded box-drawing border (`╭╮╰╯`), auto-fills buffer width.

```
╭──────────────────────────────────────────────────────────╮
│  #42  Fix auth token refresh                      opened │
│  @maria  fix/token → main    CI   1/2 approved         │
╰──────────────────────────────────────────────────────────╯
```

- Line 1: `#id  title` left-aligned, `state` right-aligned (colored: green=opened, purple=merged, red=closed)
- Line 2: `@author  source → target`, pipeline icon, approval count, merge status when available
- All fields use highlight groups (author=cyan, branch=yellow, etc.)

## Description Section

```
## Description
  (markdown-parsed PR description, 2-space indent)
```

- Section header `## Description` with `CodeReviewMdH2` highlight
- Body indented 2 spaces, full markdown support (bold, code, lists, tables, code blocks)
- Section omitted entirely if description is empty

## Activity Section

```
────────────────────────────────────────────────────────────
## Activity

   @olaf assigned to @olaf                         Feb 20
   @thierry added 139 commits                      Feb 20
```

Nerd Font icons per event type, detected by pattern-matching note body:

| Event | Icon | Codepoint |
|-------|------|-----------|
| assign | nf-oct-person | U+F415 |
| commits/pushes | nf-oct-git_commit | U+F417 |
| review comments | nf-oct-comment | U+F41F |
| resolved threads | nf-oct-check | U+F42E |
| approved | nf-oct-thumbsup | U+F41D |
| merged | nf-oct-git_merge | U+F419 |
| generic/fallback | nf-oct-dot_fill | U+F444 |

- Each icon gets its own highlight group for color
- Relative time right-aligned (`2d ago`, `5h ago`, etc.) using existing `format_time_relative`
- Author highlighted
- HTML stripped from bodies (already implemented)

## Discussions Section

```
────────────────────────────────────────────────────────────
## Discussions (3 unresolved)

┌ @alice · 2d ago  Unresolved ─────────────────────────────
│  src/auth/token.ts:42
│ This should handle the edge case where...
│
│ ↪ @bob · 1d ago
│   Good point, I'll fix this.
└ r:reply  gt:un/resolve ──────────────────────────────────
```

- Section header `## Discussions (N unresolved)` with count
- File path + line shown for inline comments (icon `` + `file:line`)
- `c` or `Enter` on file path line jumps to that file's diff at that line
- General comments (no position) skip the file path line
- Thread borders, reply prefix, resolve status, footer keymaps unchanged

## Tab Navigation

Context-sensitive Tab within summary view:

- **Tab** — jump to next discussion thread header (`┌` line). After last thread, exit to diff view.
- **Shift-Tab** — jump to previous thread header. On first thread, stay put.

## Files Changed

- `lua/codereview/mr/detail.lua` — `build_header_lines`, `build_activity_lines` rewrite
- `lua/codereview/mr/diff_sidebar.lua` — `render_summary` updates for new layout
- `lua/codereview/mr/diff_keymaps.lua` — Tab context-sensitive logic, file path jump keymap
- `lua/codereview/ui/markdown.lua` — possible minor adjustments
- `lua/codereview/highlights.lua` — new highlight groups for header card, icons
