# GitHub Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add GitHub PR support alongside existing GitLab MR support, rename plugin from `glab_review` to `codereview`, introduce a provider abstraction layer.

**Architecture:** Provider interface (`providers/gitlab.lua`, `providers/github.lua`) encapsulates all platform-specific API calls. Existing modules call provider methods instead of raw HTTP. Platform auto-detected from git remote URL.

**Tech Stack:** Lua, plenary.nvim (HTTP + async), Neovim 0.10+

## Phases

- **Phase 1: Rename** — Task 1. Rename `glab_review` → `codereview`. Pure mechanical, no logic changes.
- **Phase 2: Provider layer** — Tasks 2-7. Types, detection, providers, auth, client. **Additive only** — old client methods kept alongside new ones so existing modules still work.
- **Phase 3: Wire up + integrate** — Tasks 8-18. Rewire all modules, update field access patterns, delete dead code, add `.codereview.json`, integration tests.

## Parallelism Map

```
Phase 2:
  Wave A (parallel): Task 2 (types) + Task 6 (auth) + Task 7 (client)
  Wave B (parallel, after 2): Task 4 (gitlab) + Task 5 (github)
  Wave C (after 4+5): Task 3 (detection)

Phase 3:
  Wave D (parallel): Task 8 (list) + Task 11 (comment) + Task 12 (actions) + Task 15 (.codereview.json)
  Wave E (after 8): Task 9 (detail) + Task 10a (picker)
  Wave F (after 9+11): Task 10 (diff)
  Wave G (after all): Task 13 (init) → Task 14 (delete endpoints) → Task 16 (integration tests)
```

## Normalized Data Shapes (reference)

After normalization, **all modules use these field names**. Key changes from raw GitLab shapes:

| Normalized | Was (GitLab raw) | Notes |
|---|---|---|
| `review.id` | `mr.iid` | Display as `#%d` (not `MR !%d`) |
| `review.author` | `mr.author.username` | **String**, not `{ username }` table |
| `review.base_sha` | `mr.diff_refs.base_sha` | Flat, not nested |
| `review.head_sha` | `mr.diff_refs.head_sha` | Flat |
| `review.start_sha` | `mr.diff_refs.start_sha` | GitLab-only; GitHub sets to `base_sha` |
| `review.pipeline_status` | `mr.head_pipeline.status` | String or nil |
| `review.approved_by` | `mr.approved_by[].user.username` | **List of strings**, not list of tables |
| `review.web_url` | `mr.web_url` | |
| `review.description` | `mr.description` | |
| `note.author` | `note.author.username` | **String**, not table |
| `note.resolved_by` | `note.resolved_by.username` | **String or nil**, not table |
| `entry.id` | `entry.iid` | |
| `entry.review` | `entry.mr` | Full normalized review object |

---

## Phase 1: Rename

### Task 1: Rename `glab_review` → `codereview` (module paths + commands)

Pure mechanical rename. No logic changes.

**Files:**
- Rename: `lua/glab_review/` → `lua/codereview/`
- Rename: `plugin/glab_review.lua` → `plugin/codereview.lua`
- Rename: `tests/glab_review/` → `tests/codereview/`
- Modify: all `.lua` files (require paths, string literals, commands)

**Step 1: Rename directories**

```bash
git mv lua/glab_review lua/codereview
git mv plugin/glab_review.lua plugin/codereview.lua
git mv tests/glab_review tests/codereview
```

**Step 2: Find-and-replace in all Lua files**

In every `.lua` file under `lua/codereview/` and `tests/codereview/`:
- `require("glab_review.` → `require("codereview.`
- All other `glab_review` string literals → `codereview`

**IMPORTANT:** Also replace the string table in `lua/codereview/picker/init.lua`:
```lua
-- These are NOT require() calls — they're strings in a table passed to require() later
"glab_review.picker.telescope" → "codereview.picker.telescope"
"glab_review.picker.fzf"       → "codereview.picker.fzf"
"glab_review.picker.snacks"    → "codereview.picker.snacks"
```

**Step 3: Rename commands in `plugin/codereview.lua`**

```
vim.g.loaded_glab_review  → vim.g.loaded_codereview
:GlabReview              → :CodeReview
:GlabReviewPipeline      → :CodeReviewPipeline
:GlabReviewAI            → :CodeReviewAI
:GlabReviewSubmit        → :CodeReviewSubmit
:GlabReviewApprove       → :CodeReviewApprove
:GlabReviewOpen          → :CodeReviewOpen
```

**Step 4: Rename highlight groups and sign names**

Rename all `GlabReview*` → `CodeReview*` throughout:

In `lua/codereview/ui/highlight.lua` — all 16 `nvim_set_hl` and `sign_define` calls:
- `GlabReviewDiffAdd` → `CodeReviewDiffAdd` (etc. for all highlight groups)
- `GlabReviewCommentSign` → `CodeReviewCommentSign`
- `GlabReviewUnresolvedSign` → `CodeReviewUnresolvedSign`

In `lua/codereview/mr/diff.lua`:
- Namespace: `"glab_review_diff"` → `"codereview_diff"` (line 7)
- Sign group: `"GlabReview"` → `"CodeReview"` in `sign_place`/`sign_unplace` calls (lines 113, 127-128)
- All `GlabReviewDiffAdd`, `GlabReviewDiffDelete`, etc. highlight references (~15 occurrences)

In `tests/codereview/ui/highlight_spec.lua` — update all `nvim_get_hl` queries.

**Step 5: Rename picker display strings**

```lua
-- telescope.lua: "GitLab Merge Requests" → "Code Reviews"
-- snacks.lua:    "GitLab Merge Requests" → "Code Reviews"
-- fzf.lua:       "GitLab MRs> "          → "Reviews> "
```

**Step 6: Update buffer names and variables**

In `lua/codereview/mr/detail.lua`:
- `"glab://mr/%d"` → `"codereview://review/%d"`
- `vim.b[buf].glab_review_mr` → `vim.b[buf].codereview_mr`
- `vim.b[buf].glab_review_discussions` → `vim.b[buf].codereview_discussions`

In `lua/codereview/init.lua`:
- `vim.b[buf].glab_review_mr` → `vim.b[buf].codereview_mr`

**Step 7: Run tests**

```bash
bunx busted --run unit tests/
```

**Step 8: Commit**

```bash
git add -A
git commit -m "refactor: rename glab_review to codereview"
```

---

## Phase 2: Provider Layer

> **CRITICAL:** Phase 2 is **additive only**. Do NOT remove existing `client.build_url`, `client.encode_project`, `client.build_headers`, or `client.parse_next_page`. Old methods stay alongside new ones so existing modules keep working until Phase 3 wires them to providers.

### Task 2: Create provider types module (`providers/types.lua`)

> Wave A — can run parallel with Tasks 6, 7.

Normalized data shapes all modules will use.

**Files:**
- Create: `lua/codereview/providers/types.lua`
- Create: `tests/codereview/providers/types_spec.lua`

**Step 1: Write the test**

```lua
-- tests/codereview/providers/types_spec.lua
local types = require("codereview.providers.types")

describe("providers.types", function()
  describe("normalize_review", function()
    it("passes through normalized data", function()
      local input = {
        id = 42, title = "Fix bug", author = "alice",
        source_branch = "fix/bug", target_branch = "main",
        state = "open", base_sha = "aaa", head_sha = "bbb",
        start_sha = "ccc",
        web_url = "https://example.com/pr/42", description = "desc",
        pipeline_status = nil, approved_by = {}, approvals_required = 0,
      }
      local r = types.normalize_review(input)
      assert.equal(42, r.id)
      assert.equal("alice", r.author)
      assert.equal("ccc", r.start_sha)
    end)
  end)

  describe("normalize_discussion", function()
    it("normalizes a discussion with notes", function()
      local input = {
        id = "disc-1", resolved = false,
        notes = { {
          id = "n1", author = "bob", body = "comment",
          created_at = "2026-01-01T00:00:00Z",
          system = false, resolvable = true, resolved = false,
          position = { path = "foo.lua", new_line = 10, old_line = nil, side = "right" },
        } },
      }
      local d = types.normalize_discussion(input)
      assert.equal("disc-1", d.id)
      assert.equal("bob", d.notes[1].author)
    end)
  end)

  describe("normalize_file_diff", function()
    it("normalizes file diff entry", function()
      local f = types.normalize_file_diff({
        diff = "@@ -1 +1,2 @@\n old\n+new",
        new_path = "foo.lua", old_path = "foo.lua",
        renamed_file = false, new_file = false, deleted_file = false,
      })
      assert.equal("foo.lua", f.new_path)
    end)
  end)
end)
```

**Step 2: Run test — expect FAIL**

```bash
bunx busted --run unit tests/codereview/providers/types_spec.lua
```

**Step 3: Implement types module**

```lua
-- lua/codereview/providers/types.lua
local M = {}

function M.normalize_review(raw)
  return {
    id = raw.id,
    title = raw.title or "",
    author = raw.author or "",                -- STRING, not table
    source_branch = raw.source_branch or "",
    target_branch = raw.target_branch or "main",
    state = raw.state or "unknown",
    base_sha = raw.base_sha,
    head_sha = raw.head_sha,
    start_sha = raw.start_sha,                -- GitLab-only; GitHub sets to base_sha
    web_url = raw.web_url or "",
    description = raw.description or "",
    pipeline_status = raw.pipeline_status,     -- string or nil
    approved_by = raw.approved_by or {},       -- LIST OF STRINGS, not tables
    approvals_required = raw.approvals_required or 0,
    sha = raw.sha or raw.head_sha,
  }
end

function M.normalize_note(raw)
  return {
    id = raw.id,
    author = raw.author or "",                -- STRING
    body = raw.body or "",
    created_at = raw.created_at or "",
    system = raw.system or false,
    resolvable = raw.resolvable or false,
    resolved = raw.resolved or false,
    resolved_by = raw.resolved_by,            -- STRING or nil
    position = raw.position,                  -- { path, new_path, old_path, new_line, old_line, side }
  }
end

function M.normalize_discussion(raw)
  local notes = {}
  for _, n in ipairs(raw.notes or {}) do
    table.insert(notes, M.normalize_note(n))
  end
  return { id = raw.id, resolved = raw.resolved or false, notes = notes }
end

function M.normalize_file_diff(raw)
  return {
    diff = raw.diff or "",
    new_path = raw.new_path or "",
    old_path = raw.old_path or "",
    renamed_file = raw.renamed_file or false,
    new_file = raw.new_file or false,
    deleted_file = raw.deleted_file or false,
  }
end

return M
```

**Step 4: Run test — expect PASS**

**Step 5: Commit**

```bash
git add lua/codereview/providers/types.lua tests/codereview/providers/types_spec.lua
git commit -m "feat: add normalized provider types module"
```

---

### Task 3: Create provider interface + detection (`providers/init.lua`)

> Wave C — runs after Tasks 4+5.

Provider registry, auto-detection from git remote, config override.

**Files:**
- Create: `lua/codereview/providers/init.lua`
- Modify: `lua/codereview/config.lua` (add `platform` field, keep `gitlab_url` as alias)
- Modify: `lua/codereview/git.lua` (add `get_repo_root`)
- Create: `tests/codereview/providers/init_spec.lua`
- Modify: `tests/codereview/git_spec.lua`, `tests/codereview/config_spec.lua`

**Step 1: Write the tests**

```lua
-- tests/codereview/providers/init_spec.lua
local providers = require("codereview.providers")

describe("providers", function()
  describe("detect_platform", function()
    it("returns github for github.com", function()
      assert.equal("github", providers.detect_platform("github.com"))
    end)
    it("returns gitlab for gitlab.com", function()
      assert.equal("gitlab", providers.detect_platform("gitlab.com"))
    end)
    it("returns gitlab for self-hosted", function()
      assert.equal("gitlab", providers.detect_platform("git.company.com"))
    end)
  end)

  describe("get_provider", function()
    it("returns gitlab provider", function()
      local p = providers.get_provider("gitlab")
      assert.equal("gitlab", p.name)
      assert.is_function(p.list_reviews)
    end)
    it("returns github provider", function()
      local p = providers.get_provider("github")
      assert.equal("github", p.name)
      assert.is_function(p.list_reviews)
    end)
    it("errors on unknown", function()
      assert.has_error(function() providers.get_provider("bitbucket") end)
    end)
  end)
end)
```

**Step 2: Run test — expect FAIL**

**Step 3: Implement provider init**

```lua
-- lua/codereview/providers/init.lua
local M = {}

local GITHUB_HOSTS = { ["github.com"] = true }

function M.detect_platform(host)
  if not host then return "gitlab" end
  if GITHUB_HOSTS[host] then return "github" end
  return "gitlab"
end

function M.get_provider(platform)
  if platform == "gitlab" then
    return require("codereview.providers.gitlab")
  elseif platform == "github" then
    return require("codereview.providers.github")
  else
    error("Unknown platform: " .. tostring(platform))
  end
end

function M.detect()
  local config = require("codereview.config").get()
  local git = require("codereview.git")

  local host, project
  if config.base_url and config.project then
    local url = config.base_url
    host = url:match("^https?://([^/]+)")
    project = config.project
  else
    local remote_url = git.get_remote_url()
    if not remote_url then return nil, nil, "Could not get git remote" end
    host, project = git.parse_remote(remote_url)
    if not host then return nil, nil, "Could not parse git remote" end
  end

  local platform = config.platform or M.detect_platform(host)
  local provider = M.get_provider(platform)

  -- GHE fix: respect config.base_url even for GitHub platform
  local base_url
  if platform == "github" then
    base_url = config.base_url or "https://api.github.com"
  else
    base_url = config.base_url or ("https://" .. host)
  end

  return provider, { base_url = base_url, project = project, host = host, platform = platform }, nil
end

return M
```

**Step 4: Update config.lua**

Add `platform` and `base_url` fields. Keep `gitlab_url` as backward-compat alias:

```lua
local defaults = {
  base_url = nil,     -- API base URL override (auto-detected). Alias: gitlab_url
  project = nil,
  platform = nil,     -- "github" | "gitlab" | nil (auto-detect)
  token = nil,
  picker = nil,
  diff = { context = 8, scroll_threshold = 50 },
  ai = { enabled = true, claude_cmd = "claude" },
}

-- In setup(), after deep_merge:
-- Backward compat: gitlab_url → base_url
if current.gitlab_url and not current.base_url then
  current.base_url = current.gitlab_url
end
```

**Step 5: Add `get_repo_root` to git.lua**

```lua
function M.get_repo_root()
  local result = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or #result == 0 then return nil end
  return vim.trim(result[1])
end
```

Update `detect_project` to use `base_url` (keep old `gitlab_url` working via config alias).

**Step 6: Update tests, run all, commit**

```bash
git add lua/codereview/providers/init.lua lua/codereview/config.lua lua/codereview/git.lua tests/
git commit -m "feat: add provider detection and registry"
```

---

### Task 4: Create GitLab provider (`providers/gitlab.lua`)

> Wave B — can run parallel with Task 5. Depends on Task 2.

Extract all GitLab API logic into a provider implementation.

**Files:**
- Create: `lua/codereview/providers/gitlab.lua`
- Create: `tests/codereview/providers/gitlab_spec.lua`

**Step 1: Write the test**

```lua
-- tests/codereview/providers/gitlab_spec.lua
local gitlab = require("codereview.providers.gitlab")

describe("providers.gitlab", function()
  it("has name = gitlab", function()
    assert.equal("gitlab", gitlab.name)
  end)

  describe("normalize_mr", function()
    it("maps GitLab MR fields to normalized review", function()
      local mr = {
        iid = 42, title = "Fix bug",
        author = { username = "alice" },
        source_branch = "fix/bug", target_branch = "main",
        state = "opened",
        diff_refs = { base_sha = "aaa", head_sha = "bbb", start_sha = "ccc" },
        web_url = "https://gitlab.com/mr/42", description = "desc",
        head_pipeline = { status = "success" },
        approved_by = { { user = { username = "bob" } } },
        approvals_before_merge = 1, sha = "bbb",
      }
      local r = gitlab.normalize_mr(mr)
      assert.equal(42, r.id)
      assert.equal("alice", r.author)
      assert.equal("aaa", r.base_sha)
      assert.equal("ccc", r.start_sha)  -- start_sha preserved
      assert.equal("success", r.pipeline_status)
      assert.equal("bob", r.approved_by[1])
    end)
  end)

  describe("normalize_discussion", function()
    it("maps GitLab discussion to normalized discussion", function()
      local disc = {
        id = "disc-1",
        notes = { {
          id = 100, author = { username = "alice" },
          body = "looks good", created_at = "2026-01-01T00:00:00Z",
          system = false, resolvable = true, resolved = false,
          resolved_by = { username = "bob" },
          position = { new_path = "foo.lua", old_path = "foo.lua", new_line = 10, old_line = nil },
        } },
      }
      local d = gitlab.normalize_discussion(disc)
      assert.equal("alice", d.notes[1].author)      -- string, not table
      assert.equal("bob", d.notes[1].resolved_by)   -- string, not table
      assert.equal("foo.lua", d.notes[1].position.path)
    end)
  end)

  describe("build_auth_header", function()
    it("uses PRIVATE-TOKEN for pat", function()
      assert.equal("tok123", gitlab.build_auth_header("tok123", "pat")["PRIVATE-TOKEN"])
    end)
    it("uses Bearer for oauth", function()
      assert.equal("Bearer tok123", gitlab.build_auth_header("tok123", "oauth")["Authorization"])
    end)
  end)

  describe("parse_next_page", function()
    it("reads x-next-page header", function()
      assert.equal(3, gitlab.parse_next_page({ ["x-next-page"] = "3" }))
    end)
    it("returns nil for empty", function()
      assert.is_nil(gitlab.parse_next_page({ ["x-next-page"] = "" }))
    end)
  end)
end)
```

**Step 2: Run test — expect FAIL**

**Step 3: Implement GitLab provider**

Key implementation notes vs original plan:
- `normalize_mr` must populate `start_sha` from `mr.diff_refs.start_sha`
- `normalize_discussion` must flatten `note.author.username` → string and `note.resolved_by.username` → string
- Add `post_range_comment` method for `line_range` support (GitLab's range comment format)
- All high-level methods (`list_reviews`, `get_review`, `get_diffs`, `get_discussions`, `post_comment`, `post_range_comment`, `reply_to_discussion`, `resolve_discussion`, `approve`, `unapprove`, `merge`, `close`)
- `post_comment` takes `(client, ctx, review_id, body, position)` where position includes `{ path, old_path, new_path, old_line, new_line }` and review ref SHAs come from a separate `review` param (NOT smuggled via `position._review`)

**Updated `post_comment` signature** (applies to both providers):
```lua
function M.post_comment(client, ctx, review, body, position)
  -- review: normalized review (has base_sha, head_sha, start_sha)
  -- position: { path, new_path, old_path, old_line, new_line } or nil for general comment
```

**`post_range_comment` (GitLab only):**
```lua
function M.post_range_comment(client, ctx, review, body, old_path, new_path, start_pos, end_pos)
  -- GitLab line_range format
```

**Step 4: Run tests — expect PASS**

**Step 5: Commit**

```bash
git add lua/codereview/providers/gitlab.lua tests/codereview/providers/gitlab_spec.lua
git commit -m "feat: extract GitLab provider from existing code"
```

---

### Task 5: Create GitHub provider (`providers/github.lua`)

> Wave B — can run parallel with Task 4. Depends on Task 2.

**Files:**
- Create: `lua/codereview/providers/github.lua`
- Create: `tests/codereview/providers/github_spec.lua`

**Step 1: Write the test**

```lua
-- tests/codereview/providers/github_spec.lua
local github = require("codereview.providers.github")

describe("providers.github", function()
  it("has name = github", function()
    assert.equal("github", github.name)
  end)

  describe("normalize_pr", function()
    it("maps GitHub PR fields to normalized review", function()
      local pr = {
        number = 99, title = "Add feature",
        user = { login = "bob" },
        head = { ref = "feat/x", sha = "bbb" },
        base = { ref = "main", sha = "aaa" },
        state = "open",
        html_url = "https://github.com/owner/repo/pull/99",
        body = "description",
      }
      local r = github.normalize_pr(pr)
      assert.equal(99, r.id)
      assert.equal("bob", r.author)
      assert.equal("aaa", r.base_sha)
      assert.equal("aaa", r.start_sha)  -- GitHub: start_sha = base_sha
      assert.equal("feat/x", r.source_branch)
    end)
  end)

  describe("normalize_review_comments_to_discussions", function()
    it("groups by in_reply_to_id and sorts by created_at", function()
      local comments = {
        { id = 2, user = { login = "b" }, body = "reply", created_at = "2026-01-01T00:01:00Z",
          path = "foo.lua", line = 10, side = "RIGHT", commit_id = "abc", in_reply_to_id = 1 },
        { id = 1, user = { login = "a" }, body = "first", created_at = "2026-01-01T00:00:00Z",
          path = "foo.lua", line = 10, side = "RIGHT", commit_id = "abc", in_reply_to_id = nil },
      }
      local discussions = github.normalize_review_comments_to_discussions(comments)
      assert.equal(1, #discussions)
      assert.equal(2, #discussions[1].notes)
      assert.equal("a", discussions[1].notes[1].author)
      assert.equal("b", discussions[1].notes[2].author)
    end)
  end)

  describe("build_auth_header", function()
    it("uses Authorization Bearer", function()
      assert.equal("Bearer ghp_123", github.build_auth_header("ghp_123")["Authorization"])
    end)
  end)

  describe("parse_next_page", function()
    it("extracts next URL from Link header", function()
      local headers = {
        link = '<https://api.github.com/repos/o/r/pulls?page=3>; rel="next", <https://api.github.com/repos/o/r/pulls?page=5>; rel="last"',
      }
      assert.equal("https://api.github.com/repos/o/r/pulls?page=3", github.parse_next_page(headers))
    end)
    it("returns nil when no next", function()
      assert.is_nil(github.parse_next_page({ link = '<url>; rel="last"' }))
    end)
  end)
end)
```

**Step 2: Run test — expect FAIL**

**Step 3: Implement GitHub provider**

Key implementation notes vs original plan:
- `normalize_pr` sets `start_sha = pr.base.sha` (GitHub has no separate start_sha)
- `normalize_review_comments_to_discussions` sorts notes within each thread by `created_at`
- **`side` stored in UPPERCASE** in normalized position (GitHub API requires uppercase on write). Both read and write use uppercase `"RIGHT"`/`"LEFT"`.
- `post_range_comment` — GitHub supports multi-line via `start_line`/`start_side` params. Implement it.
- `resolve_discussion` and `unapprove` return `nil, "not supported"` (callers check error)
- `close` uses `client.patch` (see Task 7)
- `approved_by` — TODO: fetch from `/pulls/:id/reviews` API. For now returns `{}`.
- Add `client.patch` method (added in Task 7)

**Step 4: Run tests — expect PASS**

**Step 5: Commit**

```bash
git add lua/codereview/providers/github.lua tests/codereview/providers/github_spec.lua
git commit -m "feat: add GitHub provider implementation"
```

---

### Task 6: Refactor auth module to be provider-aware

> Wave A — can run parallel with Tasks 2, 7.

**Files:**
- Modify: `lua/codereview/api/auth.lua`
- Modify: `tests/codereview/api/auth_spec.lua`

**Step 1: Update test**

Add platform-aware tests:
```lua
describe("get_token with platform", function()
  before_each(function() auth.reset() end)
  it("reads GITHUB_TOKEN for github", function()
    vim.env.GITHUB_TOKEN = "ghp_test"
    assert.equal("ghp_test", auth.get_token("github"))
    vim.env.GITHUB_TOKEN = nil
  end)
  it("reads GITLAB_TOKEN for gitlab", function()
    vim.env.GITLAB_TOKEN = "glpat_test"
    assert.equal("glpat_test", auth.get_token("gitlab"))
    vim.env.GITLAB_TOKEN = nil
  end)
  it("defaults to gitlab when no platform arg", function()
    vim.env.GITLAB_TOKEN = "glpat_test"
    assert.equal("glpat_test", auth.get_token())
    vim.env.GITLAB_TOKEN = nil
  end)
end)
```

**Step 2: Run test — expect FAIL**

**Step 3: Update auth.lua**

```lua
local M = {}
local cached = {} -- { [platform] = { token, type } }

function M.reset() cached = {} end

function M.get_token(platform)
  platform = platform or "gitlab"
  if cached[platform] then
    return cached[platform].token, cached[platform].type
  end

  local env_var = platform == "github" and "GITHUB_TOKEN" or "GITLAB_TOKEN"
  local env_token = os.getenv(env_var)
  if env_token and env_token ~= "" then
    cached[platform] = { token = env_token, type = "pat" }
    return env_token, "pat"
  end

  local config = require("codereview.config").get()
  if config.token then
    cached[platform] = { token = config.token, type = "pat" }
    return config.token, "pat"
  end

  return nil, nil
end

function M.refresh(platform)
  platform = platform or "gitlab"
  cached[platform] = nil
  return nil, nil
end

return M
```

**Step 4: Run tests — expect PASS. Commit.**

---

### Task 7: Extend HTTP client (additive, no removals)

> Wave A — can run parallel with Tasks 2, 6.

**IMPORTANT:** Do NOT remove existing methods. Only ADD new capabilities.

**Files:**
- Modify: `lua/codereview/api/client.lua`
- Modify: `tests/codereview/api/client_spec.lua`

**Changes:**
1. Add `M.patch` and `M.async_patch` convenience wrappers (GitHub `close` needs PATCH)
2. Add `M.paginate_all_url(start_url, opts)` — follows full URLs from `Link` headers (for GitHub pagination). Existing `M.paginate_all` stays for GitLab (uses page numbers).
3. Keep ALL existing methods (`build_url`, `encode_project`, `build_headers`, `parse_next_page`, `paginate_all`). They will be removed in Phase 3, Task 14.

**Test additions:**
```lua
describe("patch method", function()
  -- verify M.patch delegates to M.request with "patch" method
end)

describe("paginate_all_url", function()
  -- verify it follows full URLs instead of page numbers
end)
```

**Commit:**

```bash
git add lua/codereview/api/client.lua tests/codereview/api/client_spec.lua
git commit -m "feat(client): add patch method and URL-based pagination"
```

---

## Phase 3: Wire Up + Integrate

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
