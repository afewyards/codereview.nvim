# Outdated Comments Design (GitLab + GitHub)

## Problem

Comments on old diff versions are broken on both providers:

- **GitLab:** Comments land on **wrong lines** — `normalize_note` drops position SHAs and `change_position`, so old-version line numbers are matched against the current diff.
- **GitHub:** Comments **silently vanish** — when a comment becomes outdated, `line` becomes null in the GraphQL response. The query doesn't fetch `isOutdated` or `originalLine` as fallback.

## Approach

### GitLab

SHA-based outdated detection + `change_position` remapping.

1. **Preserve position SHAs** — `normalize_note`: extract `base_sha`, `head_sha`, `start_sha` from `raw.position`. Extract `change_position` with its `new_line`, `old_line`, `new_path`, `old_path`.
2. **Detect outdated** — compare note's `position.head_sha` to `review.head_sha`. Different = outdated.
3. **Remap via change_position** — use `change_position` line numbers instead of original when available.
4. **Unmappable fallback** — no `change_position` or no valid lines: skip diff placement. Still visible in activity view.

### GitHub

Query missing fields + `originalLine` fallback.

1. **Add to GraphQL query** — `isOutdated` on thread, `originalLine`/`originalStartLine`/`outdated` on comment.
2. **Fallback to originalLine** — when `line` is null, use `originalLine`. GitHub does server-side remapping so `line` already has the remapped value when mappable.
3. **Pass `outdated` flag** — normalize `isOutdated`/`outdated` into position so diff.lua can badge it.

### Shared (diff.lua)

1. **Outdated badge** — subtle "Outdated" indicator in comment header for any comment with `position.outdated = true`.
2. **Pass review to placement** — `place_comment_signs` receives `review` for GitLab SHA comparison.

## Files changed

| File | Change |
|------|--------|
| `providers/gitlab.lua` | `normalize_note`: preserve SHAs + `change_position` |
| `providers/github.lua` | GraphQL: add `isOutdated`, `originalLine`, `originalStartLine`, `outdated`; `normalize_graphql_threads`: fallback to `originalLine`, set `outdated` flag |
| `mr/diff.lua` | `discussion_line`: use `change_position` when outdated (GitLab); detect via SHA or `outdated` flag |
| `mr/diff.lua` | `place_comment_signs`: accept `review`, render "outdated" badge |

## Out of scope

- Activity view: already shows all discussions, no changes needed
- New comment posting: already sends current SHAs on both providers
