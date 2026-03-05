# Commit Filter Deep Dive -- codereview.nvim

Generated 2026-03-01. Traces the complete data flow for per-commit diff viewing, from commit selection through diff fetch to rendering.

## Overview

The commit filter feature allows users to view diffs scoped to a single commit (or a range of commits since their last review) rather than the full MR/PR diff. It works by:
1. Fetching the commit list for the MR from the provider API
2. Letting the user select a commit via sidebar click or Telescope picker ("C" keymap)
3. Filtering `state.files` and `state.discussions` to only those relevant to the selected commit
4. Re-running `git diff` with the commit's parent SHA and the commit SHA instead of the MR-level `base_sha..head_sha`

## Files Involved

| File | Role |
|------|------|
| `lua/codereview/mr/commit_filter.lua` | Core module: `apply()`, `clear()`, `select()`, `get_changed_paths()`, `matches_discussion()` |
| `lua/codereview/mr/sidebar_components/commits.lua` | Sidebar component: renders commit list with active indicator |
| `lua/codereview/picker/commits.lua` | Telescope picker: "All changes", "Since last review", per-commit entries |
| `lua/codereview/mr/diff_render.lua` | `render_file_diff()` accepts `commit_filter` param; `render_all_files()` does NOT |
| `lua/codereview/mr/diff_keymaps.lua` | Wires "C" keymap (`pick_commits`), sidebar `<CR>` on commit rows, passes `state.commit_filter` to render calls |
| `lua/codereview/mr/diff_nav.lua` | All per-file render calls pass `state.commit_filter` |
| `lua/codereview/mr/diff_state.lua` | State factory: `commits`, `commit_filter`, `original_files`, `original_discussions` fields |
| `lua/codereview/mr/detail.lua` | Entry point: fetches commits via `provider.get_commits()`, fetches `last_reviewed_sha` |
| `lua/codereview/mr/sidebar_components/header.lua` | Shows commit filter indicator line in sidebar header |
| `lua/codereview/providers/gitlab.lua` | `get_commits()` (line 243), `get_last_reviewed_sha()` (line 209) |
| `lua/codereview/providers/github.lua` | `get_commits()` (line 302), `get_last_reviewed_sha()` (line 325) |
| `lua/codereview/providers/types.lua` | `normalize_commit()` (line 84) |
| `lua/codereview/keymaps.lua` | `pick_commits = { key = "C" }` (line 33) |

## Data Flow: End-to-End

### Phase 1: Loading Commits at MR Open Time

```
detail.open(entry)                              -- detail.lua:420
  -> provider.get_commits(client, ctx, review)  -- detail.lua:440-442
     GitLab: GET /projects/:id/merge_requests/:mr_iid/commits  -- gitlab.lua:246
     GitHub: GET /repos/:owner/:repo/pulls/:number/commits     -- github.lua:306
  -> types.normalize_commit(raw) for each       -- types.lua:84-92
     Returns: { sha, short_sha, title, author, created_at }
  -> commits stored in create_state opts         -- detail.lua:468
  -> diff_state.create_state({ commits = commits, ... })  -- diff_state.lua:57

  -> provider.get_last_reviewed_sha(client, ctx, review, user)  -- detail.lua:476-478
     GitLab: approval_state + versions API       -- gitlab.lua:209-239
     GitHub: PR reviews API                      -- github.lua:325-344
  -> state.last_reviewed_sha = sha               -- detail.lua:478
```

**State after Phase 1:**
- `state.commits` = array of normalized Commit objects
- `state.last_reviewed_sha` = SHA string or nil
- `state.commit_filter` = nil (no filter active)

### Phase 2: Rendering Commits in the Sidebar

```
sidebar_layout.render(buf, state)               -- sidebar_layout.lua:88
  -> commits_comp.render(state, mid_lines, mid_row_map, WIDTH)  -- sidebar_layout.lua:134
     Source: sidebar_components/commits.lua:13

     If #commits == 0: early return (no section rendered)

     Auto-collapse: if #commits > 8, set state.collapsed_commits = true  -- commits.lua:17-19

     Header row: " ▸ Commits (N) ────"          -- commits.lua:22-26
       row_map entry: { type = "commits_header" }

     If collapsed: just a blank line, return     -- commits.lua:28-31

     Per-commit rows:                            -- commits.lua:33-44
       Active commit (commit_filter.to_sha matches): " ● <title>"
       Inactive commit: "   <title>"
       row_map entry: { type = "commit", sha = c.sha, title = c.title }

     "Since last review" row (if last_reviewed_sha set):  -- commits.lua:46-65
       Counts commits after last_reviewed_sha (iterating from end of array)
       row_map entry: { type = "since_last_review", from_sha, to_sha, count }
```

**Sidebar also shows a filter indicator in the header:**
```
header.render(state, width)                     -- header.lua:25
  If state.commit_filter and commit_filter.label:   -- header.lua:51-58
    Adds line: " magnifier_emoji <label>"
    Highlighted with "CodeReviewCommitFilter"
```

### Phase 3: User Selects a Commit

Two entry paths:

**Path A: Sidebar click (`<CR>` on a commit row)**
```
diff_keymaps.lua sidebar <CR> handler           -- diff_keymaps.lua:1519-1521
  entry.type == "commit" or "since_last_review"
  -> select_commit_entry(entry)
     -> commit_filter.select(state, layout, entry)  -- commit_filter.lua:118
```

**Path B: Telescope picker ("C" keymap)**
```
keymaps.lua:33 -- pick_commits = { key = "C" }

diff_keymaps.lua main/sidebar callbacks:        -- diff_keymaps.lua:1329-1331, 1373-1375
  pick_commits = function()
    require("codereview.picker.commits").pick(state, select_commit_entry)
  end

picker/commits.lua:55                           -- opens Telescope
  entries = build_entries(state.commits, state.last_reviewed_sha)
  On selection: on_select(entry) -> select_commit_entry(entry)
```

### Phase 4: Applying the Commit Filter

`commit_filter.select(state, layout, entry)` at `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/commit_filter.lua:118-169` handles three entry types:

**Type "all" (clear filter):**
```lua
-- commit_filter.lua:136-143
if M.is_active(state) then
  M.clear(state)               -- restores original_files, original_discussions
  diff.render_sidebar(...)
  if state.view_mode == "diff" then render_current_file() end
end
```

**Type "since_last_review":**
```lua
-- commit_filter.lua:144-152
local paths = M.get_changed_paths(entry.from_sha, state.review.head_sha)
M.apply(state, {
  from_sha = entry.from_sha, to_sha = state.review.head_sha,
  label = "Since last review", changed_paths = paths,
})
state.view_mode = "diff"
diff.render_sidebar(...)
render_current_file()
```

**Type "commit" (single commit):**
```lua
-- commit_filter.lua:153-168
local parent_sha
for i, c in ipairs(state.commits) do
  if c.sha == entry.sha then
    parent_sha = i > 1 and state.commits[i - 1].sha or state.review.base_sha
    break
  end
end
local paths = M.get_changed_paths(parent_sha, entry.sha)
M.apply(state, {
  from_sha = parent_sha, to_sha = entry.sha,
  label = entry.title or entry.sha:sub(1, 8), changed_paths = paths,
})
state.view_mode = "diff"
diff.render_sidebar(...)
render_current_file()
```

### Phase 4a: `commit_filter.apply()` internals

`/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/commit_filter.lua:39-72`

```lua
function M.apply(state, filter)
  -- 1. Back up originals (only on first apply; re-apply uses existing backups)
  if not state.original_files then
    state.original_files = state.files
  end
  if not state.original_discussions then
    state.original_discussions = state.discussions
  end

  -- 2. Set the filter on state
  state.commit_filter = { from_sha, to_sha, label }

  -- 3. Filter files: only keep files whose new_path is in changed_paths
  local path_set = {}
  for _, p in ipairs(filter.changed_paths or {}) do path_set[p] = true end
  state.files = [f for f in original_files if path_set[f.new_path]]

  -- 4. Filter discussions: only keep discussions whose note position
  --    has head_sha or commit_sha matching filter.to_sha
  state.discussions = [d for d in original_discussions if matches_discussion(d, filter)]

  -- 5. Reset navigation and clear all caches
  state.current_file = 1
  clear_caches(state)  -- line_data_cache, row_disc_cache, git_diff_cache, etc.
end
```

### Phase 4b: `get_changed_paths()` internals

`/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/commit_filter.lua:101-111`

```lua
function M.get_changed_paths(from_sha, to_sha)
  local result = vim.fn.system({ "git", "diff", "--name-only", from_sha .. ".." .. to_sha })
  -- Returns list of file paths that differ between the two commits
end
```

This runs locally against the working copy's git repo. It uses `..` (two-dot) range, which is equivalent to `git diff <from> <to>` -- a direct tree-to-tree comparison.

### Phase 5: Rendering the Filtered Diff

After `apply()`, `render_current_file()` is called (defined inline in `commit_filter.select()` at lines 123-133):

**Per-file mode (`state.scroll_mode == false`):**
```lua
-- commit_filter.lua:127-131
local file = state.files[state.current_file]
local ld, rd, ra = diff_render.render_file_diff(
  layout.main_buf, file, state.review, state.discussions, state.context,
  state.ai_suggestions, state.row_selection, state.current_user,
  state.editing_note, state.git_diff_cache, state.commit_filter)  -- <-- PASSED
diff_state.apply_file_result(state, state.current_file, ld, rd, ra)
```

**Scroll mode (`state.scroll_mode == true`):**
```lua
-- commit_filter.lua:124-126
local result = diff_render.render_all_files(
  layout.main_buf, state.files, state.review, state.discussions, state.context,
  state.file_contexts, state.ai_suggestions, state.row_selection,
  state.current_user, state.editing_note, state.git_diff_cache)  -- <-- NO commit_filter!
diff_state.apply_scroll_result(state, result)
```

### Phase 5a: How `render_file_diff` uses `commit_filter`

`/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_render.lua:569-602`

```lua
function M.render_file_diff(buf, file_diff, review, discussions, context,
                            ai_suggestions, row_selection, current_user,
                            editing_note, diff_cache, commit_filter)
  -- 1. Cache key includes the filter SHAs for isolation
  local filter_suffix = commit_filter
    and (":" .. commit_filter.from_sha .. ".." .. commit_filter.to_sha) or ""
  local cache_key = path .. ":" .. context .. filter_suffix    -- line 577

  -- 2. Git diff uses filter SHAs instead of MR SHAs
  local base_sha = commit_filter and commit_filter.from_sha or review.base_sha  -- line 589
  local head_sha = commit_filter and commit_filter.to_sha or review.head_sha    -- line 590
  local result = vim.fn.system({
    "git", "diff", "-U" .. context, base_sha, head_sha, "--", path
  })
```

This means:
- In per-file mode, `git diff <parent_sha> <commit_sha> -- path` is run
- The cache key is `path:context:parent_sha..commit_sha` to avoid mixing cached MR diffs with commit diffs
- If git diff fails or returns empty, `file_diff.diff` (the MR-level API diff) is used as fallback

### Phase 5b: How `render_all_files` does NOT use `commit_filter`

`/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_render.lua:755`

```lua
function M.render_all_files(buf, files, review, discussions, context,
                            file_contexts, ai_suggestions, row_selection,
                            current_user, editing_note, diff_cache)
  -- No commit_filter parameter!
  -- Always uses review.base_sha and review.head_sha:
  local cmd = { "git", "diff", "-U" .. context, review.base_sha, review.head_sha, "--" }
```

## Identified Bugs and Issues

### BUG 1: Scroll mode ignores commit filter SHAs (THE LIKELY "EMPTY" DIFF CAUSE)

**Location:** `render_all_files` at `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_render.lua:755`

**Problem:** `render_all_files()` does not accept a `commit_filter` parameter. When a commit filter is active and the user is in scroll mode, the git diff is run with `review.base_sha..review.head_sha` (the full MR range) instead of `commit_filter.from_sha..commit_filter.to_sha`.

However, `commit_filter.apply()` has already filtered `state.files` to only include files changed in the commit. So `render_all_files` iterates the filtered file list but runs `git diff` against the MR range. For files that were changed in a different commit but NOT in the selected commit, this would show the full MR diff. But those files are filtered out. For files that WERE changed in the selected commit, the MR-range diff might differ from the commit-range diff (e.g., if the file was modified in multiple commits).

The real issue: the diff cache key in `render_all_files` does NOT include filter SHAs (`cache_key = path .. ":" .. file_ctx`). If the user previously viewed the full MR diff (which was cached with this key), switching to commit mode in scroll view will serve the CACHED MR diff, not the commit diff. The `clear_caches` call in `apply()` clears `git_diff_cache`, which should avoid this. But the batch fetch at line 776 will re-populate the cache with MR-level diffs.

**Impact:** In scroll mode with commit filter active, diffs show MR-level changes, not commit-level changes. Files may show changes they didn't have in the selected commit, or show the wrong diff content.

### BUG 2: Commit ordering assumption may be wrong for GitLab

**Location:** `commit_filter.select()` at `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/commit_filter.lua:155-157`

**Problem:** The parent SHA lookup does:
```lua
parent_sha = i > 1 and state.commits[i - 1].sha or state.review.base_sha
```

This assumes `state.commits` is ordered **oldest-first** (chronological order). The GitLab `/merge_requests/:id/commits` API returns commits in **newest-first** order (reverse chronological). The GitHub `/pulls/:id/commits` API returns **oldest-first**.

If the GitLab API returns `[C3, C2, C1]` (newest first):
- Selecting C2 (index 2): `parent_sha = commits[1].sha = C3` (WRONG -- C3 is newer, not the parent)
- The correct parent would be `commits[3].sha = C1` (or we need `i + 1`)

This would cause `get_changed_paths(C3, C2)` to return the wrong file set (or empty, since diffing a newer commit against an older one in the wrong order gives reversed diffs), leading to files being filtered out and the commit view appearing empty.

**Impact:** On GitLab, selecting a commit uses the wrong parent SHA, causing:
- `get_changed_paths` returns wrong or empty file list
- The diff runs between wrong SHAs
- Some commits appear to have no changes ("empty")

**Note:** The "Since last review" counter in `commits.lua:49` also counts from the END of the array backwards, which is consistent with an oldest-first assumption. On GitLab, this counter would be wrong too.

### BUG 3: Missing `ensure_git_objects` for commit filter SHAs

**Location:** `render_file_diff` at `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_render.lua:586-602`

**Problem:** When a commit filter is active, `render_file_diff` runs `git diff <parent_sha> <commit_sha> -- path`. If these SHA objects are not available locally (e.g., the user's local clone is behind), the git diff fails silently, and the function falls back to `file_diff.diff` (the MR-level API diff). Unlike `render_all_files` which calls `ensure_git_objects()` on failure, `render_file_diff` never calls it.

This means: if the commit SHAs are not locally available, the per-file diff silently shows the MR-level diff instead of the commit diff. There is no error notification to the user.

**Impact:** Stale local repos will show MR-level diffs even when a commit filter is active, with no indication that the commit-specific diff failed.

### BUG 4: API diff fallback is MR-level, not commit-level

**Location:** `render_file_diff` at `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_render.lua:588`

**Problem:** The fallback `diff_text = file_diff.diff or ""` uses the `file_diff.diff` field, which contains the MR-level API diff (fetched by `provider.get_diffs()`). When a commit filter is active, this fallback is semantically wrong -- it should either:
- Fetch a commit-level diff from the API, or
- Show an empty diff with a message, or
- At minimum show an error

Instead it silently shows the full MR diff for that file, which is confusing when the user has selected a single commit.

### Issue 5: File filter uses `new_path` only

**Location:** `commit_filter.apply()` at `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/commit_filter.lua:56`

```lua
if path_set[f.new_path] then
```

For renamed or deleted files, `new_path` may differ from `old_path`. The `get_changed_paths` function returns paths as they appear in the diff output, which for renames includes both old and new paths. However, the filter only checks `new_path`, so a file that was renamed in the selected commit might be missed if `get_changed_paths` returns the old path.

## State Machine

```
                                    ┌──────────────┐
                                    │  No Filter   │
                                    │ (default)    │
                                    │              │
                                    │ state.files =│
                                    │  all MR files│
                                    └──────┬───────┘
                                           │
                     ┌─────────────────────┤
                     │ User selects commit │
                     │ (C keymap or        │
                     │  sidebar click)     │
                     │                     │
                     ▼                     ▼
              ┌──────────────┐     ┌──────────────────┐
              │ Single Commit│     │ Since Last Review │
              │   Filter     │     │     Filter        │
              │              │     │                    │
              │ from = parent│     │ from = last_review │
              │ to = commit  │     │ to = head_sha      │
              │ files=changed│     │ files = changed    │
              └──────┬───────┘     └────────┬───────────┘
                     │                      │
                     │  User selects "All"  │
                     │  or another commit   │
                     │◄─────────────────────┘
                     │
                     ▼
              ┌──────────────┐
              │  clear()     │
              │ Restore      │
              │ originals    │
              └──────────────┘
```

## Key State Fields

Defined in `diff_state.create_state()` at `/Users/kleist/Sites/codereview.nvim/lua/codereview/mr/diff_state.lua:57-60`:

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `state.commits` | `Commit[]` | `[]` | Full list of MR commits from provider API |
| `state.commit_filter` | `table\|nil` | `nil` | `{ from_sha, to_sha, label }` when active |
| `state.original_files` | `table[]\|nil` | `nil` | Backup of `state.files` before filtering |
| `state.original_discussions` | `table[]\|nil` | `nil` | Backup of `state.discussions` before filtering |
| `state.last_reviewed_sha` | `string\|nil` | `nil` | SHA at time of user's last approval |
| `state.collapsed_commits` | `bool\|nil` | `nil` | Whether commits section is collapsed in sidebar |

## Commit Data Shape

Produced by `types.normalize_commit()` at `/Users/kleist/Sites/codereview.nvim/lua/codereview/providers/types.lua:84-92`:

```lua
{
  sha = "abc123def456...",        -- full SHA
  short_sha = "abc123de",         -- 8-char short SHA
  title = "feat: add login flow", -- first line of commit message
  author = "alice",               -- author name or login
  created_at = "2026-03-01T10:00:00Z",
}
```

## Call Sites That Pass `commit_filter`

Every `render_file_diff` call site passes `state.commit_filter` as the last argument:

| Location | File | Line |
|----------|------|------|
| `commit_filter.select` render helper | `commit_filter.lua` | 130 |
| `diff_keymaps` rerender_view | `diff_keymaps.lua` | 58 |
| `diff_keymaps` after AI render | `diff_keymaps.lua` | 208 |
| `diff_keymaps` toggle_full_file | `diff_keymaps.lua` | 688 |
| `diff_keymaps` sidebar file click | `diff_keymaps.lua` | 1509 |
| `diff_nav.nav_file` | `diff_nav.lua` | 28 |
| `diff_nav.switch_to_file` | `diff_nav.lua` | 42 |
| `diff_nav.jump_to_file` | `diff_nav.lua` | 73 |
| `diff_nav.adjust_context` | `diff_nav.lua` | 288 |
| `diff_nav.toggle_scroll_mode` | `diff_nav.lua` | 334 |
| `diff.open` initial render | `diff.lua` | 110 |
| `diff.open` draft resume | `diff.lua` | 138 |

NO call site for `render_all_files` passes `commit_filter`:

| Location | File | Line | Passes commit_filter? |
|----------|------|------|-----------------------|
| `commit_filter.select` scroll render | `commit_filter.lua` | 125 | NO |
| `diff_keymaps` rerender_view | `diff_keymaps.lua` | 53 | NO |
| `diff_keymaps` after AI render | `diff_keymaps.lua` | 203 | NO |
| `diff_keymaps` context adjust scroll | `diff_keymaps.lua` | 674 | NO |
| `diff_keymaps` tab/s-tab transition | `diff_keymaps.lua` | 993 | NO |
| `diff_keymaps` sidebar file click scroll | `diff_keymaps.lua` | 1497 | NO |
| `diff_nav.jump_to_file` scroll | `diff_nav.lua` | 61 | NO |
| `diff_nav.adjust_context` scroll | `diff_nav.lua` | 277 | NO |
| `diff_nav.toggle_scroll_mode` to-scroll | `diff_nav.lua` | 345 | NO |
| `diff.open` scroll render | `diff.lua` | 107 | NO |
| `diff.open` draft resume scroll | `diff.lua` | 135 | NO |

## Summary of Root Causes for "Empty Commit" Bug

The most likely cause of commits appearing empty is **BUG 2 (commit ordering)**:

1. GitLab returns commits newest-first: `[C3, C2, C1]`
2. User selects C2 (index 2 in the array)
3. Code computes `parent_sha = commits[1].sha = C3` (the NEWER commit, not the parent)
4. `get_changed_paths("C3", "C2")` runs `git diff --name-only C3..C2`
5. This diff is "backwards" -- it shows what changed going from C3 to C2, which is the REVERSE of the C2->C3 diff. For files only changed in C3, this returns those files. For files only changed in C2, the reverse diff also includes them, but the direction is wrong.
6. However, for the **first commit** in the newest-first list (C3, index 1), `parent_sha = state.review.base_sha`, which IS correct since it's the most recent commit.
7. For commits in the middle, the parent lookup is always wrong, producing unexpected file lists and wrong diff content.

Secondary contributing factor is **BUG 1 (scroll mode)**: if the filtered file count is small enough to trigger scroll mode, `render_all_files` ignores the commit filter entirely and uses MR-level SHAs.

## Recommendations

1. **Fix commit ordering**: Either reverse the GitLab commits array after fetching, or adjust the parent lookup to use `commits[i + 1]` for newest-first ordering (and detect the ordering). The cleanest fix is to normalize both providers to return oldest-first.

2. **Add `commit_filter` parameter to `render_all_files`**: Mirror the `render_file_diff` approach -- use `commit_filter.from_sha`/`to_sha` for `git diff` SHAs and include filter SHAs in cache keys.

3. **Call `ensure_git_objects` for commit filter SHAs**: In both `render_file_diff` and `get_changed_paths`, ensure the parent and commit SHAs are fetched before running git diff.

4. **Fix file filter to check both `new_path` and `old_path`**: In `commit_filter.apply()`, check `path_set[f.new_path] or path_set[f.old_path]`.
