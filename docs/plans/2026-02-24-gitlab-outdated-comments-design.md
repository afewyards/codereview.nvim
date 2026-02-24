# GitLab Outdated Comments Design

## Problem

Comments on old MR diff versions silently disappear or land on wrong lines.

Root cause: `normalize_note` drops position SHAs (`base_sha`, `head_sha`, `start_sha`) and `change_position`. The diff always renders from the MR's current SHAs, so old-version line numbers don't match.

## Approach

SHA-based outdated detection + `change_position` remapping.

### 1. Preserve position SHAs during normalization

`providers/gitlab.lua` `normalize_note`: extract `base_sha`, `head_sha`, `start_sha` from `raw.position`. Extract `change_position` (GitLab populates this when diff version changed) with its `new_line`, `old_line`, `new_path`, `old_path`.

### 2. Detect outdated comments

Compare note's `position.head_sha` to `review.head_sha`. Different = outdated.

### 3. Remap via change_position

If `change_position` has valid line numbers, use those instead of original `position` lines for placement in the diff buffer.

### 4. Unmappable comments fallback

If `change_position` is absent/null or has no valid lines: skip diff placement entirely. These still appear in activity/summary view (already shows all discussions regardless of position).

### 5. Subtle outdated badge

Remapped comments show a small "outdated" indicator in the comment header, next to resolved/unresolved status.

## Files changed

| File | Change |
|------|--------|
| `providers/gitlab.lua` | `normalize_note`: preserve SHAs + `change_position` |
| `mr/diff.lua` | `discussion_line`: use `change_position` when available; detect outdated via SHA comparison |
| `mr/diff.lua` | `place_comment_signs`: "outdated" badge in header for remapped comments |
| `mr/detail.lua` | Pass `review` through to diff rendering for SHA comparison |

## Out of scope

- Activity view: already shows all discussions, no changes needed
- New comment posting: already sends current SHAs
- GitHub provider: separate concern
