# Phase 2: Provider Layer

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create the provider abstraction layer — types, detection, GitLab provider, GitHub provider, platform-aware auth, extended HTTP client.

**Prereqs:** Phase 1 (rename) must be complete.

> **CRITICAL:** Phase 2 is **additive only**. Do NOT remove existing `client.build_url`, `client.encode_project`, `client.build_headers`, or `client.parse_next_page`. Old methods stay alongside new ones so existing modules keep working until Phase 3 wires them to providers.

## Parallelism Map

```
Wave A (parallel): Task 2 (types) + Task 6 (auth) + Task 7 (client)
Wave B (parallel, after 2): Task 4 (gitlab) + Task 5 (github)
Wave C (after 4+5): Task 3 (detection)
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
| `note.author` | `note.author.username` | **String**, not table |
| `note.resolved_by` | `note.resolved_by.username` | **String or nil**, not table |
| `entry.id` | `entry.iid` | |
| `entry.review` | `entry.mr` | Full normalized review object |

---

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

Key implementation notes:
- `normalize_mr` must populate `start_sha` from `mr.diff_refs.start_sha`
- `normalize_discussion` must flatten `note.author.username` → string and `note.resolved_by.username` → string
- Add `post_range_comment` method for `line_range` support (GitLab's range comment format)
- All high-level methods (`list_reviews`, `get_review`, `get_diffs`, `get_discussions`, `post_comment`, `post_range_comment`, `reply_to_discussion`, `resolve_discussion`, `approve`, `unapprove`, `merge`, `close`)

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

Key implementation notes:
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
