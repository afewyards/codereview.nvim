# Phase 3: Wire Up + Integrate

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rewire all existing modules to use the provider interface, update all field access patterns, delete dead code, add `.codereview.json` config, write integration tests.

**Prereqs:** Phase 1 (rename) and Phase 2 (provider layer) must be complete.

## Parallelism Map

```
Wave D (parallel): Task 8 (list) + Task 11 (comment) + Task 12 (actions) + Task 15 (.codereview.json)
Wave E (after 8): Task 9 (detail) + Task 10a (picker)
Wave F (after 9+11): Task 10 (diff)
Wave G (after all): Task 13 (init) → Task 14 (delete endpoints) → Task 16 (integration tests)
```

## Normalized Data Shapes (reference)

| Normalized | Was (GitLab raw) | Notes |
|---|---|---|
| `review.id` | `mr.iid` | Display as `#%d` (not `MR !%d`) |
| `review.author` | `mr.author.username` | **String**, not `{ username }` table |
| `review.base_sha` | `mr.diff_refs.base_sha` | Flat, not nested |
| `review.head_sha` | `mr.diff_refs.head_sha` | Flat |
| `review.start_sha` | `mr.diff_refs.start_sha` | GitLab-only; GitHub sets to `base_sha` |
| `review.pipeline_status` | `mr.head_pipeline.status` | String or nil |
| `review.approved_by` | `mr.approved_by[].user.username` | **List of strings**, not list of tables |
| `note.author` | `note.author.username` | **String**, not table |
| `note.resolved_by` | `note.resolved_by.username` | **String or nil**, not table |
| `entry.id` | `entry.iid` | |
| `entry.review` | `entry.mr` | Full normalized review object |

---

### Task 8: Wire up provider in `mr/list.lua`

> Wave D — can run parallel with Tasks 11, 12, 15.

**Files:**
- Modify: `lua/codereview/mr/list.lua`
- Modify: `tests/codereview/mr/list_spec.lua`

**Key changes:**
- Replace `client`/`endpoints`/`git` requires with `providers`
- `format_mr_entry(review)` uses normalized fields: `review.id`, `review.author` (string), `review.pipeline_status`, `review.source_branch`
- Display as `#42` not `!42`
- Entry table: `{ id, title, author, ..., review }` (not `{ iid, ..., mr }`)
- `fetch()` calls `provider.list_reviews(client, ctx, opts)`

**Update tests:** `list_spec.lua` assertions change from `entry.iid` → `entry.id`, `entry.mr` → `entry.review`

**Commit:**

```bash
git add lua/codereview/mr/list.lua tests/codereview/mr/list_spec.lua
git commit -m "refactor(list): wire up provider interface"
```

---

### Task 9: Wire up provider in `mr/detail.lua`

> Wave E — depends on Task 8.

**Files:**
- Modify: `lua/codereview/mr/detail.lua`
- Modify: `tests/codereview/mr/detail_spec.lua`

**Key changes — ALL field access sites:**

In `build_header_lines(review)`:
- `mr.iid` → `review.id`, display as `#%d`
- `mr.author.username` → `review.author` (string)
- `mr.head_pipeline.status` → `review.pipeline_status`
- `mr.approved_by[].user.username` → iterate `review.approved_by` as list of strings (e.g., `"@" .. name` not `"@" .. a.user.username`)

In `build_activity_lines(discussions)`:
- `first_note.author.username` → `first_note.author` (string) — lines 71, 78
- `reply.author.username` → `reply.author` (string) — lines 88-89

In `open(entry)`:
- Replace `client.get(base_url, endpoints.mr_detail(...))` → `provider.get_review(client, ctx, entry.id)`
- Replace `client.paginate_all(base_url, endpoints.discussions(...))` → `provider.get_discussions(client, ctx, entry.id)`
- Buffer name: `codereview://review/%d`
- Buffer vars: `vim.b[buf].codereview_review`, `vim.b[buf].codereview_discussions`
- **`c` keymap (lines 193-202)**: currently calls `client.post(b_url, endpoints.discussions(...))` directly. Must change to `provider.post_comment(client, ctx, review, input, nil)` (nil position = general comment)
- **`m` keymap**: display `#%d` not `!%d`

**Update tests:** `detail_spec.lua` must pass normalized shapes (string `author`, string list `approved_by`, flat `pipeline_status`).

**Commit:**

```bash
git add lua/codereview/mr/detail.lua tests/codereview/mr/detail_spec.lua
git commit -m "refactor(detail): wire up provider interface"
```

---

### Task 10: Wire up provider in `mr/diff.lua`

> Wave F — depends on Tasks 9 and 11.

**Files:**
- Modify: `lua/codereview/mr/diff.lua`
- Modify: `tests/codereview/mr/diff_spec.lua`

**CRITICAL: `state.mr` key strategy** — Rename to `state.review` throughout the file (28 occurrences). The parameter to `M.open` also renames from `mr` to `review`.

**All field access sites to update:**

| Location | Current | New |
|---|---|---|
| Lines 196, 202-203 (`render_file_diff`) | `mr.diff_refs.base_sha`, `mr.diff_refs.head_sha` | `review.base_sha`, `review.head_sha` |
| Line 218-220 | `mr.diff_refs.head_sha` | `review.head_sha` |
| Lines 348, 353 (`render_all_files`) | `mr.diff_refs.base_sha`, `mr.diff_refs.head_sha` | `review.base_sha`, `review.head_sha` |
| Line 142 (virt_lines) | `first.author.username` | `first.author` (string) |
| Line 173 (virt_lines) | `reply.author.username` | `reply.author` (string) |
| Line 535 (virt_lines) | `first.author.username` | `first.author` (string) |
| Line 554 (virt_lines) | `reply.author.username` | `reply.author` (string) |
| Line 605 (`render_sidebar`) | `mr.iid or 0` → `"MR !%d"` | `review.id` → `"#%d"` |
| Line 607 (`render_sidebar`) | `mr.head_pipeline and mr.head_pipeline.status` | `review.pipeline_status` |
| Line 583 (`render_sidebar`) | `mr.source_branch` | `review.source_branch` |
| Lines 711, 733, 1065, 1083, 1121-1153 (keymaps) | `state.mr` passed to comment/actions | `state.review` |
| Lines 1207-1208 (keymaps) | `detail.open(state.mr)` | `detail.open(state.review)` |
| Lines 1288-1353 (`open`) | Direct API calls | Provider calls (see below) |

**`open` entry point:**
```lua
function M.open(review, discussions)
  local providers = require("codereview.providers")
  local split = require("codereview.ui.split")
  local client_mod = require("codereview.api.client")

  local provider, ctx, err = providers.detect()
  if not provider then
    vim.notify(err or "Could not detect platform", vim.log.levels.ERROR)
    return
  end

  local files, fetch_err = provider.get_diffs(client_mod, ctx, review.id)
  -- ...
  local state = { review = review, files = files, ... }
```

**Bug fix (line 1181):** `config.get()` references out-of-scope `config` variable. Fix: move `local config = require("codereview.config")` to module level or capture inside the keymap closure.

**Commit:**

```bash
git add lua/codereview/mr/diff.lua tests/codereview/mr/diff_spec.lua
git commit -m "refactor(diff): wire up provider interface"
```

---

### Task 10a: Update picker modules for new entry shape

> Wave E — can run parallel with Task 9.

**Files:**
- Modify: `lua/codereview/picker/telescope.lua`
- Modify: `lua/codereview/picker/fzf.lua`
- Modify: `lua/codereview/picker/snacks.lua`
- Modify: `tests/codereview/picker/init_spec.lua`

**Key changes:**
- `telescope.lua` line 19: `entry.iid` → `entry.id` in ordinal
- All three adapters: verify they pass through entry fields correctly to callback

**Commit:**

```bash
git add lua/codereview/picker/
git commit -m "refactor(picker): update for normalized entry shape"
```

---

### Task 11: Wire up provider in `mr/comment.lua`

> Wave D — can run parallel with Tasks 8, 12, 15.

**Files:**
- Modify: `lua/codereview/mr/comment.lua`
- Modify: `tests/codereview/mr/comment_spec.lua`

**Key field access changes:**

In `build_thread_lines(disc)`:
- `first.author.username` → `first.author` (string) — line 28
- `first.resolved_by.username` → `first.resolved_by` (string) — line 19
- `reply.author.username` → `reply.author` (string) — lines 42-43

In `reply(disc, review)`:
- Replace `client.post(base_url, endpoints.discussion_notes(...))` → `provider.reply_to_discussion(client, ctx, review.id, disc.id, body)`

In `resolve_toggle(disc, review, callback)`:
- Replace `client.put(base_url, endpoints.discussion(...))` → `provider.resolve_discussion(client, ctx, review.id, disc.id, resolved)`
- **Handle error return** from unsupported providers: check `err` before calling `callback()`

In `create_inline(review, ...)`:
- Replace direct API call → `provider.post_comment(client, ctx, review, body, position)`

In `create_inline_range(review, ...)`:
- Replace direct API call → `provider.post_range_comment(client, ctx, review, body, old_path, new_path, start_pos, end_pos)`

Remove `client`/`endpoints`/`git` requires. The `detail = require("codereview.mr.detail")` import (used for `detail.format_time`) stays.

**Update tests:** `comment_spec.lua` passes normalized note shapes (string `author`, string `resolved_by`).

**Commit:**

```bash
git add lua/codereview/mr/comment.lua tests/codereview/mr/comment_spec.lua
git commit -m "refactor(comment): wire up provider interface"
```

---

### Task 12: Wire up provider in `mr/actions.lua`

> Wave D — can run parallel with Tasks 8, 11, 15.

**Files:**
- Modify: `lua/codereview/mr/actions.lua`
- Modify: `tests/codereview/mr/actions_spec.lua`

**Implementation:**

```lua
local providers = require("codereview.providers")
local M = {}

function M.approve(review)
  local provider, ctx, err = providers.detect()
  if not provider then return nil, err end
  local client = require("codereview.api.client")
  return provider.approve(client, ctx, review)
end

function M.unapprove(review)
  local provider, ctx, err = providers.detect()
  if not provider then return nil, err end
  local client = require("codereview.api.client")
  local result, unapprove_err = provider.unapprove(client, ctx, review)
  if unapprove_err then
    vim.notify(unapprove_err, vim.log.levels.WARN)
  end
  return result, unapprove_err
end

function M.merge(review, opts)
  local provider, ctx, err = providers.detect()
  if not provider then return nil, err end
  local client = require("codereview.api.client")
  return provider.merge(client, ctx, review, opts)
end

function M.close(review)
  local provider, ctx, err = providers.detect()
  if not provider then return nil, err end
  local client = require("codereview.api.client")
  return provider.close(client, ctx, review)
end

return M
```

**Test update:** Remove `build_merge_params` tests (function deleted — merge param construction moved to providers). Add test that `approve`/`merge`/`close` call through to provider.

**Commit:**

```bash
git add lua/codereview/mr/actions.lua tests/codereview/mr/actions_spec.lua
git commit -m "refactor(actions): wire up provider interface"
```

---

### Task 13: Update init.lua and plugin commands

> Wave G — depends on Tasks 8, 9, 12.

**Files:**
- Modify: `lua/codereview/init.lua`
- Modify: `plugin/codereview.lua`

**Key changes:**
- `M.open()` messages: "Failed to load reviews" (not "MRs"), "No open reviews found"
- `M.approve()`: read `vim.b[buf].codereview_review` (not `codereview_mr`)

**Commit:**

```bash
git add lua/codereview/init.lua plugin/codereview.lua
git commit -m "refactor: update entry point for provider-based flow"
```

---

### Task 14: Delete dead code

> Wave G — after Task 13.

**Files:**
- Delete: `lua/codereview/api/endpoints.lua`
- Delete: `tests/codereview/api/endpoints_spec.lua`
- Modify: `lua/codereview/api/client.lua` — NOW remove old GitLab-specific methods: `encode_project`, `build_headers`, `parse_next_page`. Simplify `build_url` to simple concatenation. Remove auth auto-resolution from `request`/`async_request` (providers handle auth).

**Step 1: Verify no references**

```bash
rg "endpoints" lua/codereview/ --type lua
rg "client.encode_project\|client.build_headers\|client.parse_next_page" lua/codereview/ --type lua
```

Both should return zero results.

**Step 2: Delete + clean up. Run all tests. Commit.**

```bash
git rm lua/codereview/api/endpoints.lua tests/codereview/api/endpoints_spec.lua
git commit -m "chore: remove dead endpoints module and legacy client methods"
```

**Note:** Draft notes/pipeline/job trace endpoint paths are intentionally not preserved in providers — they were unused stubs. When Stage 4 (pipelines) is implemented, add those paths to the relevant provider.

---

### Task 15: Add `.codereview.json` config file support

> Wave D — can run parallel with Tasks 8, 11, 12.

**Files:**
- Modify: `lua/codereview/api/auth.lua`
- Create: `tests/codereview/config_file_spec.lua`

**Key implementation details (fixes from review):**

1. **Use git root, not `getcwd()`:**
```lua
local git = require("codereview.git")
local root = git.get_repo_root()
local config_path = root and (root .. "/.codereview.json") or nil
```

2. **Platform-scoped tokens:**
```json
{
  "platform": "github",
  "github_token": "ghp_...",
  "gitlab_token": "glpat_..."
}
```

Auth reads `json[platform .. "_token"]` first, falls back to `json.token`.

3. **Gitignore safety:** On first read, if `.codereview.json` contains a token field, check if it's gitignored. If not, warn:
```lua
vim.notify(".codereview.json contains tokens but is NOT in .gitignore!", vim.log.levels.WARN)
```

4. **Write real tests** (not `pending`): Use `vim.fn.tempname()` to create temp dir, write a `.codereview.json`, verify token resolution.

**Commit:**

```bash
git add lua/codereview/api/auth.lua lua/codereview/git.lua tests/codereview/config_file_spec.lua
git commit -m "feat: add .codereview.json per-repo config support"
```

---

### Task 16: Integration tests

> Wave G — after all wiring tasks.

**Files:**
- Create: `tests/codereview/integration/github_flow_spec.lua`
- Create: `tests/codereview/integration/gitlab_flow_spec.lua`

**Required test coverage (from review):**

1. **Normalized review → `build_header_lines`**: pass review with `approved_by = {"alice", "bob"}` (strings), `pipeline_status = "success"`, verify output
2. **Normalized review → `render_sidebar`**: pass review with flat `id`, `pipeline_status`, verify `#42` display (not `MR !42`)
3. **Normalized discussion → `build_thread_lines`**: pass notes with string `author` and string `resolved_by`, verify output
4. **Normalized discussion → `build_activity_lines`**: pass notes with string `author`, verify output
5. **GitHub PR normalization**: raw GitHub PR → normalized review → verify all fields
6. **GitHub comment threading**: raw comments with `in_reply_to_id` → discussions → verify grouping and sort order
7. **GitLab MR normalization**: raw GitLab MR → normalized review → verify `start_sha` preserved

**Commit:**

```bash
git add tests/codereview/integration/
git commit -m "test: add integration tests for normalized data shapes"
```
