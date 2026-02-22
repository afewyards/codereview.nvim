# GitHub Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add GitHub PR support alongside existing GitLab MR support, rename plugin from `glab_review` to `codereview`, introduce a provider abstraction layer.

**Architecture:** Provider interface (`providers/gitlab.lua`, `providers/github.lua`) encapsulates all platform-specific API calls. Existing modules (`mr/` → `review/`) call provider methods instead of raw HTTP. Platform auto-detected from git remote URL.

**Tech Stack:** Lua, plenary.nvim (HTTP + async), Neovim 0.10+

---

### Task 1: Rename `glab_review` → `codereview` (module paths + commands)

Pure mechanical rename. No logic changes. Must be done first so all subsequent tasks use new paths.

**Files:**
- Rename: `lua/glab_review/` → `lua/codereview/`
- Rename: `plugin/glab_review.lua` → `plugin/codereview.lua`
- Rename: `tests/glab_review/` → `tests/codereview/`
- Modify: every `.lua` file under `lua/codereview/` (require paths)
- Modify: `plugin/codereview.lua` (command names + require paths)
- Modify: every test file under `tests/codereview/` (require paths)

**Step 1: Rename directories**

```bash
git mv lua/glab_review lua/codereview
git mv plugin/glab_review.lua plugin/codereview.lua
git mv tests/glab_review tests/codereview
```

**Step 2: Find-and-replace require paths in all Lua files**

In every `.lua` file under `lua/codereview/`:
- Replace `require("glab_review.` → `require("codereview.`
- Replace `glab_review` → `codereview` in string literals (buffer names, notify messages, etc.)

In every test file under `tests/codereview/`:
- Replace `require("glab_review.` → `require("codereview.`

**Step 3: Rename commands in `plugin/codereview.lua`**

```lua
-- Before:
vim.g.loaded_glab_review → vim.g.loaded_codereview
:GlabReview            → :CodeReview
:GlabReviewPipeline    → :CodeReviewPipeline
:GlabReviewAI          → :CodeReviewAI
:GlabReviewSubmit      → :CodeReviewSubmit
:GlabReviewApprove     → :CodeReviewApprove
:GlabReviewOpen        → :CodeReviewOpen
```

**Step 4: Rename Neovim namespace**

In `lua/codereview/mr/diff.lua:7`:
```lua
-- Before:
local DIFF_NS = vim.api.nvim_create_namespace("glab_review_diff")
-- After:
local DIFF_NS = vim.api.nvim_create_namespace("codereview_diff")
```

**Step 5: Update buffer-local variable names**

In `lua/codereview/mr/detail.lua`:
```lua
-- Line 162: "glab://mr/%d" → "codereview://mr/%d"
-- Line 166: vim.b[buf].glab_review_mr → vim.b[buf].codereview_mr
-- Line 167: vim.b[buf].glab_review_discussions → vim.b[buf].codereview_discussions
```

In `lua/codereview/init.lua:41`:
```lua
-- vim.b[buf].glab_review_mr → vim.b[buf].codereview_mr
```

**Step 6: Run tests**

```bash
bunx busted --run unit tests/
```

All tests should pass with new paths.

**Step 7: Commit**

```bash
git add -A
git commit -m "refactor: rename glab_review to codereview"
```

---

### Task 2: Create provider types module (`providers/types.lua`)

Define the normalized data shapes all modules will use instead of raw GitLab/GitHub API responses.

**Files:**
- Create: `lua/codereview/providers/types.lua`
- Create: `tests/codereview/providers/types_spec.lua`

**Step 1: Write the test**

```lua
-- tests/codereview/providers/types_spec.lua
local types = require("codereview.providers.types")

describe("providers.types", function()
  describe("normalize_review", function()
    it("passes through already-normalized data", function()
      local input = {
        id = 42,
        title = "Fix bug",
        author = "alice",
        source_branch = "fix/bug",
        target_branch = "main",
        state = "open",
        base_sha = "aaa",
        head_sha = "bbb",
        web_url = "https://example.com/pr/42",
        description = "desc",
        pipeline_status = nil,
        approved_by = {},
        approvals_required = 0,
      }
      local r = types.normalize_review(input)
      assert.equal(42, r.id)
      assert.equal("Fix bug", r.title)
      assert.equal("alice", r.author)
    end)
  end)

  describe("normalize_discussion", function()
    it("normalizes a discussion with notes", function()
      local input = {
        id = "disc-1",
        resolved = false,
        notes = {
          {
            id = "n1",
            author = "bob",
            body = "comment",
            created_at = "2026-01-01T00:00:00Z",
            system = false,
            resolvable = true,
            resolved = false,
            position = { path = "foo.lua", new_line = 10, old_line = nil, side = "right" },
          },
        },
      }
      local d = types.normalize_discussion(input)
      assert.equal("disc-1", d.id)
      assert.equal(false, d.resolved)
      assert.equal(1, #d.notes)
      assert.equal("bob", d.notes[1].author)
    end)
  end)

  describe("normalize_file_diff", function()
    it("normalizes file diff entry", function()
      local input = {
        diff = "--- a/foo\n+++ b/foo\n@@ -1,1 +1,2 @@\n old\n+new",
        new_path = "foo.lua",
        old_path = "foo.lua",
        renamed_file = false,
        new_file = false,
        deleted_file = false,
      }
      local f = types.normalize_file_diff(input)
      assert.equal("foo.lua", f.new_path)
      assert.truthy(f.diff)
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

```bash
bunx busted --run unit tests/codereview/providers/types_spec.lua
```

Expected: FAIL — module not found.

**Step 3: Implement types module**

```lua
-- lua/codereview/providers/types.lua
local M = {}

--- Normalized review (MR/PR) shape.
--- Provider implementations must return this from list_reviews/get_review.
---@param raw table
---@return table
function M.normalize_review(raw)
  return {
    id = raw.id,
    title = raw.title or "",
    author = raw.author or "",
    source_branch = raw.source_branch or "",
    target_branch = raw.target_branch or "main",
    state = raw.state or "unknown",
    base_sha = raw.base_sha,
    head_sha = raw.head_sha,
    web_url = raw.web_url or "",
    description = raw.description or "",
    pipeline_status = raw.pipeline_status,
    approved_by = raw.approved_by or {},
    approvals_required = raw.approvals_required or 0,
    sha = raw.sha or raw.head_sha,
  }
end

--- Normalized note shape.
---@param raw table
---@return table
function M.normalize_note(raw)
  return {
    id = raw.id,
    author = raw.author or "",
    body = raw.body or "",
    created_at = raw.created_at or "",
    system = raw.system or false,
    resolvable = raw.resolvable or false,
    resolved = raw.resolved or false,
    resolved_by = raw.resolved_by,
    position = raw.position, -- { path, new_line, old_line, side }
  }
end

--- Normalized discussion (thread) shape.
---@param raw table
---@return table
function M.normalize_discussion(raw)
  local notes = {}
  for _, n in ipairs(raw.notes or {}) do
    table.insert(notes, M.normalize_note(n))
  end
  return {
    id = raw.id,
    resolved = raw.resolved or false,
    notes = notes,
  }
end

--- Normalized file diff shape.
---@param raw table
---@return table
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

**Step 4: Run test to verify it passes**

```bash
bunx busted --run unit tests/codereview/providers/types_spec.lua
```

**Step 5: Commit**

```bash
git add lua/codereview/providers/types.lua tests/codereview/providers/types_spec.lua
git commit -m "feat: add normalized provider types module"
```

---

### Task 3: Create provider interface + detection (`providers/init.lua`)

Provider registry, auto-detection from git remote, config override.

**Files:**
- Create: `lua/codereview/providers/init.lua`
- Modify: `lua/codereview/config.lua` (add `platform` field)
- Modify: `lua/codereview/git.lua` (add `detect_platform`)
- Create: `tests/codereview/providers/init_spec.lua`
- Modify: `tests/codereview/git_spec.lua`
- Modify: `tests/codereview/config_spec.lua`

**Step 1: Write the tests**

```lua
-- tests/codereview/providers/init_spec.lua
local providers = require("codereview.providers")

describe("providers", function()
  describe("detect_platform", function()
    it("returns github for github.com remote", function()
      assert.equal("github", providers.detect_platform("github.com"))
    end)

    it("returns gitlab for gitlab.com remote", function()
      assert.equal("gitlab", providers.detect_platform("gitlab.com"))
    end)

    it("returns gitlab for self-hosted hosts", function()
      assert.equal("gitlab", providers.detect_platform("git.company.com"))
    end)

    it("returns github for github enterprise", function()
      -- GHE hosts are not auto-detectable; rely on config override
      assert.equal("gitlab", providers.detect_platform("github.mycompany.com"))
    end)
  end)

  describe("get_provider", function()
    it("returns a table with required methods for gitlab", function()
      local p = providers.get_provider("gitlab")
      assert.is_table(p)
      assert.equal("gitlab", p.name)
      assert.is_function(p.list_reviews)
    end)

    it("returns a table with required methods for github", function()
      local p = providers.get_provider("github")
      assert.is_table(p)
      assert.equal("github", p.name)
      assert.is_function(p.list_reviews)
    end)

    it("errors on unknown platform", function()
      assert.has_error(function() providers.get_provider("bitbucket") end)
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

```bash
bunx busted --run unit tests/codereview/providers/init_spec.lua
```

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

--- Detect platform and return the provider + base_url + project.
--- Uses config override if set, otherwise auto-detects from git remote.
function M.detect()
  local config = require("codereview.config").get()
  local git = require("codereview.git")

  local host, project
  if config.base_url and config.project then
    -- Manual override
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

  local base_url
  if platform == "github" then
    base_url = "https://api.github.com"
  else
    base_url = config.base_url or ("https://" .. host)
  end

  return provider, { base_url = base_url, project = project, host = host }, nil
end

return M
```

**Step 4: Update config.lua**

In `lua/codereview/config.lua`, replace `gitlab_url` with `base_url` and add `platform`:

```lua
local defaults = {
  base_url = nil,     -- API base URL override (auto-detected)
  project = nil,      -- Project path override (auto-detected)
  platform = nil,     -- "github" | "gitlab" | nil (auto-detect)
  token = nil,
  picker = nil,
  diff = { context = 8, scroll_threshold = 50 },
  ai = { enabled = true, claude_cmd = "claude" },
}
```

**Step 5: Update git.lua**

Replace `detect_project` to use new config key:

```lua
function M.detect_project()
  local config = require("codereview.config").get()
  if config.base_url and config.project then
    return config.base_url, config.project
  end

  local url = M.get_remote_url()
  if not url then return nil, nil end

  local host, project = M.parse_remote(url)
  if not host then return nil, nil end

  return "https://" .. host, project
end
```

**Step 6: Update tests for config and git**

Update `tests/codereview/config_spec.lua` to reference `base_url` instead of `gitlab_url`.
Update `tests/codereview/git_spec.lua` to reference `base_url` instead of `gitlab_url`.

**Step 7: Run all tests**

```bash
bunx busted --run unit tests/
```

**Step 8: Commit**

```bash
git add lua/codereview/providers/init.lua lua/codereview/config.lua lua/codereview/git.lua tests/
git commit -m "feat: add provider detection and registry"
```

---

### Task 4: Create GitLab provider (`providers/gitlab.lua`)

Extract all GitLab API logic from existing modules into a provider implementation.

**Files:**
- Create: `lua/codereview/providers/gitlab.lua`
- Create: `tests/codereview/providers/gitlab_spec.lua`

**Step 1: Write the test**

Test the key normalization functions — the ones that convert GitLab API responses into normalized types.

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
        iid = 42,
        title = "Fix bug",
        author = { username = "alice" },
        source_branch = "fix/bug",
        target_branch = "main",
        state = "opened",
        diff_refs = { base_sha = "aaa", head_sha = "bbb", start_sha = "ccc" },
        web_url = "https://gitlab.com/mr/42",
        description = "desc",
        head_pipeline = { status = "success" },
        approved_by = { { user = { username = "bob" } } },
        approvals_before_merge = 1,
        sha = "bbb",
      }
      local r = gitlab.normalize_mr(mr)
      assert.equal(42, r.id)
      assert.equal("alice", r.author)
      assert.equal("aaa", r.base_sha)
      assert.equal("bbb", r.head_sha)
      assert.equal("opened", r.state)
      assert.equal("success", r.pipeline_status)
      assert.equal(1, #r.approved_by)
      assert.equal("bob", r.approved_by[1])
    end)
  end)

  describe("normalize_discussion", function()
    it("maps GitLab discussion to normalized discussion", function()
      local disc = {
        id = "disc-1",
        notes = {
          {
            id = 100,
            author = { username = "alice" },
            body = "looks good",
            created_at = "2026-01-01T00:00:00Z",
            system = false,
            resolvable = true,
            resolved = false,
            resolved_by = nil,
            position = {
              new_path = "foo.lua",
              old_path = "foo.lua",
              new_line = 10,
              old_line = nil,
            },
          },
        },
      }
      local d = gitlab.normalize_discussion(disc)
      assert.equal("disc-1", d.id)
      assert.equal(1, #d.notes)
      assert.equal("alice", d.notes[1].author)
      assert.equal("foo.lua", d.notes[1].position.path)
      assert.equal(10, d.notes[1].position.new_line)
    end)
  end)

  describe("build_auth_header", function()
    it("uses PRIVATE-TOKEN for pat", function()
      local h = gitlab.build_auth_header("tok123", "pat")
      assert.equal("tok123", h["PRIVATE-TOKEN"])
    end)

    it("uses Bearer for oauth", function()
      local h = gitlab.build_auth_header("tok123", "oauth")
      assert.equal("Bearer tok123", h["Authorization"])
    end)
  end)

  describe("parse_next_page", function()
    it("reads x-next-page header", function()
      assert.equal(3, gitlab.parse_next_page({ ["x-next-page"] = "3" }))
    end)

    it("returns nil when no next page", function()
      assert.is_nil(gitlab.parse_next_page({ ["x-next-page"] = "" }))
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

```bash
bunx busted --run unit tests/codereview/providers/gitlab_spec.lua
```

**Step 3: Implement GitLab provider**

```lua
-- lua/codereview/providers/gitlab.lua
local types = require("codereview.providers.types")
local M = { name = "gitlab" }

--- Convert GitLab MR response → normalized Review.
function M.normalize_mr(mr)
  local approved_names = {}
  for _, a in ipairs(mr.approved_by or {}) do
    table.insert(approved_names, a.user and a.user.username or "?")
  end
  return types.normalize_review({
    id = mr.iid,
    title = mr.title,
    author = mr.author and mr.author.username or "",
    source_branch = mr.source_branch,
    target_branch = mr.target_branch,
    state = mr.state,
    base_sha = mr.diff_refs and mr.diff_refs.base_sha,
    head_sha = mr.diff_refs and mr.diff_refs.head_sha,
    web_url = mr.web_url,
    description = mr.description,
    pipeline_status = mr.head_pipeline and mr.head_pipeline.status,
    approved_by = approved_names,
    approvals_required = mr.approvals_before_merge or 0,
    sha = mr.sha,
  })
end

--- Convert GitLab discussion → normalized Discussion.
function M.normalize_discussion(disc)
  local notes = {}
  for _, n in ipairs(disc.notes or {}) do
    local pos = nil
    if n.position then
      pos = {
        path = n.position.new_path or n.position.old_path,
        new_path = n.position.new_path,
        old_path = n.position.old_path,
        new_line = n.position.new_line,
        old_line = n.position.old_line,
        side = n.position.new_line and "right" or "left",
      }
    end
    table.insert(notes, {
      id = n.id,
      author = n.author and n.author.username or "",
      body = n.body or "",
      created_at = n.created_at or "",
      system = n.system or false,
      resolvable = n.resolvable or false,
      resolved = n.resolved or false,
      resolved_by = n.resolved_by and n.resolved_by.username,
      position = pos,
    })
  end
  return types.normalize_discussion({
    id = disc.id,
    resolved = disc.resolved or false,
    notes = notes,
  })
end

function M.build_auth_header(token, token_type)
  if token_type == "oauth" then
    return { ["Authorization"] = "Bearer " .. token, ["Content-Type"] = "application/json" }
  else
    return { ["PRIVATE-TOKEN"] = token, ["Content-Type"] = "application/json" }
  end
end

function M.parse_next_page(headers)
  local val = headers and headers["x-next-page"]
  if val and val ~= "" then return tonumber(val) end
  return nil
end

function M.encode_project(project)
  return project:gsub("/", "%%2F")
end

function M.build_url(base_url, path)
  return base_url .. "/api/v4" .. path
end

-- API path builders
local function project_path(pid) return "/projects/" .. pid end
local function mr_path(pid, id) return project_path(pid) .. "/merge_requests/" .. id end

function M.paths(ctx)
  local pid = M.encode_project(ctx.project)
  return {
    mr_list = project_path(pid) .. "/merge_requests",
    mr_detail = function(id) return mr_path(pid, id) end,
    mr_diffs = function(id) return mr_path(pid, id) .. "/diffs" end,
    mr_approve = function(id) return mr_path(pid, id) .. "/approve" end,
    mr_unapprove = function(id) return mr_path(pid, id) .. "/unapprove" end,
    mr_merge = function(id) return mr_path(pid, id) .. "/merge" end,
    discussions = function(id) return mr_path(pid, id) .. "/discussions" end,
    discussion = function(id, did) return mr_path(pid, id) .. "/discussions/" .. did end,
    discussion_notes = function(id, did) return mr_path(pid, id) .. "/discussions/" .. did .. "/notes" end,
  }
end

-- High-level provider methods (these call client internally)

function M.list_reviews(client, ctx, opts)
  opts = opts or {}
  local path = M.paths(ctx).mr_list
  local query = { state = opts.state or "opened", scope = opts.scope or "all", per_page = opts.per_page or 50 }
  local result, err = client.get(ctx.base_url, path, { query = query })
  if not result then return nil, err end
  local reviews = {}
  for _, mr in ipairs(result.data or {}) do
    table.insert(reviews, M.normalize_mr(mr))
  end
  return reviews
end

function M.get_review(client, ctx, id)
  local path = M.paths(ctx).mr_detail(id)
  local result, err = client.get(ctx.base_url, path)
  if not result then return nil, err end
  return M.normalize_mr(result.data)
end

function M.get_diffs(client, ctx, id)
  local path = M.paths(ctx).mr_diffs(id)
  local result, err = client.get(ctx.base_url, path)
  if not result then return nil, err end
  local files = {}
  for _, f in ipairs(result.data or {}) do
    table.insert(files, types.normalize_file_diff(f))
  end
  return files
end

function M.get_discussions(client, ctx, id)
  local path = M.paths(ctx).discussions(id)
  local all_data = client.paginate_all(ctx.base_url, path)
  if not all_data then return {} end
  local discussions = {}
  for _, d in ipairs(all_data) do
    table.insert(discussions, M.normalize_discussion(d))
  end
  return discussions
end

function M.post_comment(client, ctx, id, body, position)
  local path = M.paths(ctx).discussions(id)
  local review = position._review -- the full review object, for diff_refs
  local req_body = { body = body }
  if position.path then
    req_body.position = {
      position_type = "text",
      base_sha = review.base_sha,
      head_sha = review.head_sha,
      start_sha = review._start_sha, -- GitLab-only, stored during normalize
      old_path = position.old_path or position.path,
      new_path = position.new_path or position.path,
      old_line = position.old_line,
      new_line = position.new_line,
    }
  end
  return client.post(ctx.base_url, path, { body = req_body })
end

function M.reply_to_discussion(client, ctx, review_id, discussion_id, body)
  local path = M.paths(ctx).discussion_notes(review_id, discussion_id)
  return client.post(ctx.base_url, path, { body = { body = body } })
end

function M.resolve_discussion(client, ctx, review_id, discussion_id, resolved)
  local path = M.paths(ctx).discussion(review_id, discussion_id)
  return client.put(ctx.base_url, path, { body = { resolved = resolved } })
end

function M.approve(client, ctx, review)
  local path = M.paths(ctx).mr_approve(review.id)
  local body = {}
  if review.sha then body.sha = review.sha end
  return client.post(ctx.base_url, path, { body = body })
end

function M.unapprove(client, ctx, review)
  local path = M.paths(ctx).mr_unapprove(review.id)
  return client.post(ctx.base_url, path, { body = {} })
end

function M.merge(client, ctx, review, opts)
  opts = opts or {}
  local path = M.paths(ctx).mr_merge(review.id)
  local params = {}
  if opts.squash then params.squash = true end
  if opts.remove_source_branch then params.should_remove_source_branch = true end
  if opts.auto_merge then params.merge_when_pipeline_succeeds = true end
  if review.sha then params.sha = review.sha end
  return client.put(ctx.base_url, path, { body = params })
end

function M.close(client, ctx, review)
  local path = M.paths(ctx).mr_detail(review.id)
  return client.put(ctx.base_url, path, { body = { state_event = "close" } })
end

--- Token env var name for GitLab.
function M.token_env_var()
  return "GITLAB_TOKEN"
end

return M
```

**Step 4: Run tests**

```bash
bunx busted --run unit tests/codereview/providers/gitlab_spec.lua
```

**Step 5: Commit**

```bash
git add lua/codereview/providers/gitlab.lua tests/codereview/providers/gitlab_spec.lua
git commit -m "feat: extract GitLab provider from existing code"
```

---

### Task 5: Create GitHub provider (`providers/github.lua`)

The GitHub provider implements the same interface as GitLab but calls GitHub REST API v3.

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
        number = 99,
        title = "Add feature",
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
      assert.equal("bbb", r.head_sha)
      assert.equal("feat/x", r.source_branch)
    end)
  end)

  describe("normalize_review_comments_to_discussions", function()
    it("groups comments into threads by in_reply_to_id", function()
      local comments = {
        { id = 1, user = { login = "a" }, body = "first", created_at = "2026-01-01T00:00:00Z",
          path = "foo.lua", line = 10, side = "RIGHT", commit_id = "abc", in_reply_to_id = nil },
        { id = 2, user = { login = "b" }, body = "reply", created_at = "2026-01-01T00:01:00Z",
          path = "foo.lua", line = 10, side = "RIGHT", commit_id = "abc", in_reply_to_id = 1 },
      }
      local discussions = github.normalize_review_comments_to_discussions(comments)
      assert.equal(1, #discussions)
      assert.equal(2, #discussions[1].notes)
      assert.equal("a", discussions[1].notes[1].author)
      assert.equal("b", discussions[1].notes[2].author)
    end)

    it("handles standalone comments (no replies)", function()
      local comments = {
        { id = 1, user = { login = "a" }, body = "comment", created_at = "2026-01-01T00:00:00Z",
          path = "bar.lua", line = 5, side = "RIGHT", commit_id = "abc", in_reply_to_id = nil },
      }
      local discussions = github.normalize_review_comments_to_discussions(comments)
      assert.equal(1, #discussions)
      assert.equal(1, #discussions[1].notes)
    end)
  end)

  describe("build_auth_header", function()
    it("uses Authorization Bearer", function()
      local h = github.build_auth_header("ghp_123")
      assert.equal("Bearer ghp_123", h["Authorization"])
    end)
  end)

  describe("parse_next_page", function()
    it("extracts next page from Link header", function()
      local headers = {
        link = '<https://api.github.com/repos/o/r/pulls?page=3>; rel="next", <https://api.github.com/repos/o/r/pulls?page=5>; rel="last"',
      }
      assert.equal("https://api.github.com/repos/o/r/pulls?page=3", github.parse_next_page(headers))
    end)

    it("returns nil when no next link", function()
      local headers = {
        link = '<https://api.github.com/repos/o/r/pulls?page=5>; rel="last"',
      }
      assert.is_nil(github.parse_next_page(headers))
    end)

    it("returns nil when no link header", function()
      assert.is_nil(github.parse_next_page({}))
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

```bash
bunx busted --run unit tests/codereview/providers/github_spec.lua
```

**Step 3: Implement GitHub provider**

```lua
-- lua/codereview/providers/github.lua
local types = require("codereview.providers.types")
local M = { name = "github" }

function M.normalize_pr(pr)
  return types.normalize_review({
    id = pr.number,
    title = pr.title,
    author = pr.user and pr.user.login or "",
    source_branch = pr.head and pr.head.ref or "",
    target_branch = pr.base and pr.base.ref or "main",
    state = pr.state,
    base_sha = pr.base and pr.base.sha,
    head_sha = pr.head and pr.head.sha,
    web_url = pr.html_url or "",
    description = pr.body or "",
    pipeline_status = nil, -- GitHub doesn't include this in PR object
    approved_by = {},      -- fetched separately via reviews API
    approvals_required = 0,
    sha = pr.head and pr.head.sha,
  })
end

--- Group GitHub review comments into discussion threads.
--- GitHub links replies via `in_reply_to_id`.
function M.normalize_review_comments_to_discussions(comments)
  local threads = {}   -- id → { id, notes }
  local order = {}     -- track insertion order

  for _, c in ipairs(comments) do
    local note = {
      id = c.id,
      author = c.user and c.user.login or "",
      body = c.body or "",
      created_at = c.created_at or "",
      system = false,
      resolvable = true,
      resolved = false,
      resolved_by = nil,
      position = c.path and {
        path = c.path,
        new_path = c.path,
        old_path = c.path,
        new_line = c.side == "RIGHT" and c.line or nil,
        old_line = c.side == "LEFT" and c.line or nil,
        side = c.side and c.side:lower() or "right",
      } or nil,
    }

    local root_id = c.in_reply_to_id or c.id
    if not threads[root_id] then
      threads[root_id] = { id = tostring(root_id), resolved = false, notes = {} }
      table.insert(order, root_id)
    end
    table.insert(threads[root_id].notes, note)
  end

  local result = {}
  for _, root_id in ipairs(order) do
    table.insert(result, types.normalize_discussion(threads[root_id]))
  end
  return result
end

function M.build_auth_header(token)
  return {
    ["Authorization"] = "Bearer " .. token,
    ["Accept"] = "application/vnd.github+json",
    ["Content-Type"] = "application/json",
    ["X-GitHub-Api-Version"] = "2022-11-28",
  }
end

function M.parse_next_page(headers)
  local link = headers and (headers["link"] or headers["Link"])
  if not link then return nil end
  local next_url = link:match('<([^>]+)>;%s*rel="next"')
  return next_url
end

function M.build_url(base_url, path)
  return base_url .. path
end

function M.paths(ctx)
  local repo = ctx.project -- "owner/repo"
  return {
    pr_list = "/repos/" .. repo .. "/pulls",
    pr_detail = function(id) return "/repos/" .. repo .. "/pulls/" .. id end,
    pr_files = function(id) return "/repos/" .. repo .. "/pulls/" .. id .. "/files" end,
    pr_reviews = function(id) return "/repos/" .. repo .. "/pulls/" .. id .. "/reviews" end,
    pr_comments = function(id) return "/repos/" .. repo .. "/pulls/" .. id .. "/comments" end,
    pr_merge = function(id) return "/repos/" .. repo .. "/pulls/" .. id .. "/merge" end,
    issue_comments = function(id) return "/repos/" .. repo .. "/issues/" .. id .. "/comments" end,
    contents = function(path, ref) return "/repos/" .. repo .. "/contents/" .. path .. "?ref=" .. ref end,
  }
end

-- High-level provider methods

function M.list_reviews(client, ctx, opts)
  opts = opts or {}
  local path = M.paths(ctx).pr_list
  local query = { state = opts.state or "open", per_page = opts.per_page or 50 }
  local result, err = client.get(ctx.base_url, path, { query = query })
  if not result then return nil, err end
  local reviews = {}
  for _, pr in ipairs(result.data or {}) do
    table.insert(reviews, M.normalize_pr(pr))
  end
  return reviews
end

function M.get_review(client, ctx, id)
  local path = M.paths(ctx).pr_detail(id)
  local result, err = client.get(ctx.base_url, path)
  if not result then return nil, err end
  return M.normalize_pr(result.data)
end

function M.get_diffs(client, ctx, id)
  local path = M.paths(ctx).pr_files(id)
  -- GitHub returns file list with patch; need to fetch full diff
  local result, err = client.get(ctx.base_url, path)
  if not result then return nil, err end
  local files = {}
  for _, f in ipairs(result.data or {}) do
    table.insert(files, types.normalize_file_diff({
      diff = f.patch or "",
      new_path = f.filename,
      old_path = f.previous_filename or f.filename,
      renamed_file = f.status == "renamed",
      new_file = f.status == "added",
      deleted_file = f.status == "removed",
    }))
  end
  return files
end

function M.get_discussions(client, ctx, id)
  local path = M.paths(ctx).pr_comments(id)
  local all_data = client.paginate_all(ctx.base_url, path)
  if not all_data then return {} end
  return M.normalize_review_comments_to_discussions(all_data)
end

function M.post_comment(client, ctx, id, body, position)
  if not position or not position.path then
    -- General PR comment (not inline)
    local path = M.paths(ctx).issue_comments(id)
    return client.post(ctx.base_url, path, { body = { body = body } })
  end
  -- Inline review comment
  local path = M.paths(ctx).pr_comments(id)
  local req_body = {
    body = body,
    path = position.new_path or position.path,
    commit_id = position._review and position._review.head_sha or position.commit_id,
    line = position.new_line or position.old_line,
    side = (position.new_line and "RIGHT") or "LEFT",
  }
  return client.post(ctx.base_url, path, { body = req_body })
end

function M.reply_to_discussion(client, ctx, review_id, discussion_id, body)
  -- GitHub: reply via in_reply_to on the PR comments endpoint
  local path = M.paths(ctx).pr_comments(review_id)
  return client.post(ctx.base_url, path, {
    body = { body = body, in_reply_to = tonumber(discussion_id) },
  })
end

function M.resolve_discussion(_, _, _, _, _)
  -- GitHub has no resolve API for individual comment threads.
  -- Could implement via "resolve conversation" GraphQL, but skip for now.
  vim.notify("Resolve is not supported on GitHub (use the web UI)", vim.log.levels.WARN)
  return nil, "not supported"
end

function M.approve(client, ctx, review)
  local path = M.paths(ctx).pr_reviews(review.id)
  return client.post(ctx.base_url, path, {
    body = { event = "APPROVE" },
  })
end

function M.unapprove(_, _, _)
  vim.notify("GitHub does not support unapprove (dismiss the review on web)", vim.log.levels.WARN)
  return nil, "not supported"
end

function M.merge(client, ctx, review, opts)
  opts = opts or {}
  local path = M.paths(ctx).pr_merge(review.id)
  local params = {}
  if opts.squash then params.merge_method = "squash"
  elseif opts.rebase then params.merge_method = "rebase"
  else params.merge_method = "merge" end
  if review.sha then params.sha = review.sha end
  return client.put(ctx.base_url, path, { body = params })
end

function M.close(client, ctx, review)
  local path = M.paths(ctx).pr_detail(review.id)
  return client.patch(ctx.base_url, path, { body = { state = "closed" } })
end

function M.token_env_var()
  return "GITHUB_TOKEN"
end

return M
```

**Step 4: Run tests**

```bash
bunx busted --run unit tests/codereview/providers/github_spec.lua
```

**Step 5: Commit**

```bash
git add lua/codereview/providers/github.lua tests/codereview/providers/github_spec.lua
git commit -m "feat: add GitHub provider implementation"
```

---

### Task 6: Refactor auth module to be provider-aware

The auth module currently hardcodes `GITLAB_TOKEN`. Make it resolve token based on detected provider.

**Files:**
- Modify: `lua/codereview/api/auth.lua`
- Modify: `tests/codereview/api/auth_spec.lua`

**Step 1: Update test**

```lua
-- Add to tests/codereview/api/auth_spec.lua
describe("get_token with platform", function()
  before_each(function() auth.reset() end)

  it("reads GITHUB_TOKEN for github platform", function()
    -- Set env var in test context
    vim.env.GITHUB_TOKEN = "ghp_test"
    local token = auth.get_token("github")
    assert.equal("ghp_test", token)
    vim.env.GITHUB_TOKEN = nil
  end)

  it("reads GITLAB_TOKEN for gitlab platform", function()
    vim.env.GITLAB_TOKEN = "glpat_test"
    local token = auth.get_token("gitlab")
    assert.equal("glpat_test", token)
    vim.env.GITLAB_TOKEN = nil
  end)
end)
```

**Step 2: Run test to verify it fails**

```bash
bunx busted --run unit tests/codereview/api/auth_spec.lua
```

**Step 3: Update auth.lua**

```lua
-- lua/codereview/api/auth.lua
local M = {}

local cached = {} -- { [platform] = { token, token_type } }

function M.reset()
  cached = {}
end

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

**Step 4: Run tests**

```bash
bunx busted --run unit tests/codereview/api/auth_spec.lua
```

**Step 5: Commit**

```bash
git add lua/codereview/api/auth.lua tests/codereview/api/auth_spec.lua
git commit -m "refactor(auth): make token resolution platform-aware"
```

---

### Task 7: Refactor HTTP client to be provider-agnostic

Remove GitLab-specific logic from `api/client.lua`. The client should accept provider-supplied `build_url`, `build_headers`, and `parse_next_page` functions.

**Files:**
- Modify: `lua/codereview/api/client.lua`
- Modify: `tests/codereview/api/client_spec.lua`

**Step 1: Update tests**

Add tests for the new provider-agnostic design:

```lua
-- Add to tests/codereview/api/client_spec.lua
describe("provider-agnostic client", function()
  it("build_url delegates to provider", function()
    -- Old: client.build_url(base, path) → base .. "/api/v4" .. path
    -- New: just base .. path (provider prepends API prefix in its path builders)
    -- Or: client keeps build_url but it's just concatenation
    assert.equal("https://api.github.com/repos/o/r/pulls", client.build_url("https://api.github.com", "/repos/o/r/pulls"))
  end)
end)
```

**Step 2: Simplify client.lua**

The key change: `build_url` becomes a simple concatenation. Provider-specific logic (API prefix, auth headers, pagination) moves to provider modules. The client accepts an `opts.headers` override.

```lua
function M.build_url(base_url, path)
  return base_url .. path
end
```

Remove `encode_project` (moved to GitLab provider). Remove `build_headers` (providers build their own). Remove `parse_next_page` (providers supply their own).

Update `build_params` to accept headers directly:

```lua
local function build_params(method, url, headers, opts)
  local params = { url = url, headers = headers, method = method }
  -- ... body/query handling stays same
end
```

Update `request`/`async_request` to accept headers and pagination parser:

```lua
function M.request(method, url, opts)
  opts = opts or {}
  local params = build_params(method, url, opts.headers, opts)
  -- ... rest stays same, but remove auth.get_token() call
  -- Auth is handled by caller (the provider or the orchestrating module)
end
```

**Step 3: Run all tests**

```bash
bunx busted --run unit tests/
```

**Step 4: Commit**

```bash
git add lua/codereview/api/client.lua tests/codereview/api/client_spec.lua
git commit -m "refactor(client): make HTTP client provider-agnostic"
```

---

### Task 8: Wire up provider in `mr/list.lua`

Replace direct API calls with provider interface.

**Files:**
- Modify: `lua/codereview/mr/list.lua`
- Modify: `tests/codereview/mr/list_spec.lua`

**Step 1: Update list.lua**

Replace:
```lua
local client = require("glab_review.api.client")
local endpoints = require("glab_review.api.endpoints")
local git = require("glab_review.git")
```

With:
```lua
local providers = require("codereview.providers")
```

Replace `format_mr_entry` to use normalized fields:
```lua
function M.format_mr_entry(review)
  local icon = M.pipeline_icon(review.pipeline_status)
  local prefix = review.id  -- providers set this to iid or number
  local display = string.format(
    "%s #%-4d %-50s @%-15s %s",
    icon, prefix, (review.title or ""):sub(1, 50), review.author, review.source_branch
  )
  return {
    display = display,
    id = review.id,
    title = review.title,
    author = review.author,
    source_branch = review.source_branch,
    target_branch = review.target_branch,
    web_url = review.web_url,
    review = review,
  }
end
```

Replace `fetch` to use provider:
```lua
function M.fetch(opts, callback)
  vim.notify("Fetching reviews...", vim.log.levels.INFO)
  local provider, ctx, err = providers.detect()
  if not provider then
    callback(nil, err or "Could not detect platform")
    return
  end

  local client = require("codereview.api.client")
  local reviews, fetch_err = provider.list_reviews(client, ctx, opts)
  if not reviews then
    callback(nil, fetch_err)
    return
  end

  local entries = {}
  for _, r in ipairs(reviews) do
    table.insert(entries, M.format_mr_entry(r))
  end
  callback(entries)
end
```

**Step 2: Update tests**

Update `list_spec.lua` to use normalized review fields (`.id` not `.iid`, `.author` not `.mr.author.username`).

**Step 3: Run tests**

```bash
bunx busted --run unit tests/codereview/mr/list_spec.lua
```

**Step 4: Commit**

```bash
git add lua/codereview/mr/list.lua tests/codereview/mr/list_spec.lua
git commit -m "refactor(list): wire up provider interface"
```

---

### Task 9: Wire up provider in `mr/detail.lua`

Replace direct API calls with provider interface.

**Files:**
- Modify: `lua/codereview/mr/detail.lua`
- Modify: `tests/codereview/mr/detail_spec.lua`

**Step 1: Update detail.lua**

Key changes:
- `build_header_lines(review)` uses normalized fields: `review.id`, `review.author`, `review.source_branch`, `review.pipeline_status`, `review.approved_by` (list of strings), `review.approvals_required`
- Display prefix changes from `MR !%d` to `#%d` (works for both platforms)
- `open(entry)` calls `provider.get_review(client, ctx, entry.id)` and `provider.get_discussions(client, ctx, entry.id)`
- Buffer name: `codereview://review/%d`
- Buffer variables: `vim.b[buf].codereview_review`, `vim.b[buf].codereview_discussions`
- Keymaps for approve/comment/merge call provider methods

**Step 2: Update tests**

Update `detail_spec.lua` to use normalized review shapes.

**Step 3: Run tests**

```bash
bunx busted --run unit tests/codereview/mr/detail_spec.lua
```

**Step 4: Commit**

```bash
git add lua/codereview/mr/detail.lua tests/codereview/mr/detail_spec.lua
git commit -m "refactor(detail): wire up provider interface"
```

---

### Task 10: Wire up provider in `mr/diff.lua`

Replace API calls and GitLab-specific field access.

**Files:**
- Modify: `lua/codereview/mr/diff.lua`

**Step 1: Update diff.lua**

Changes concentrated in these areas:

**Line 196 area (`render_file_diff`):** Replace `mr.diff_refs.base_sha`/`mr.diff_refs.head_sha` → `review.base_sha`/`review.head_sha` (normalized fields are flat, not nested).

**Line 348 area (`render_all_files`):** Same `diff_refs` → flat field replacement.

**Line 580 area (`render_sidebar`):** Replace `mr.iid` → `review.id`, display as `#%d` not `MR !%d`.

**Lines 1288-1353 (`open`):** Replace direct API calls with provider:

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
  if fetch_err then
    vim.notify("Failed to fetch diffs: " .. fetch_err, vim.log.levels.ERROR)
    return
  end
  -- ... rest uses `review` (normalized) and `files` (normalized)
end
```

**Step 2: Run tests**

```bash
bunx busted --run unit tests/codereview/mr/diff_spec.lua
```

Rendering tests should still pass since they test line formatting, not API calls.

**Step 3: Commit**

```bash
git add lua/codereview/mr/diff.lua
git commit -m "refactor(diff): wire up provider interface"
```

---

### Task 11: Wire up provider in `mr/comment.lua`

Replace direct API calls with provider interface.

**Files:**
- Modify: `lua/codereview/mr/comment.lua`
- Modify: `tests/codereview/mr/comment_spec.lua`

**Step 1: Update comment.lua**

Key changes:
- `reply(disc, review)` → calls `provider.reply_to_discussion(client, ctx, review.id, disc.id, body)`
- `resolve_toggle(disc, review, callback)` → calls `provider.resolve_discussion(client, ctx, review.id, disc.id, resolved)`
- `create_inline(review, ...)` → calls `provider.post_comment(client, ctx, review.id, body, position)`
- `create_inline_range(review, ...)` → same, but with range position
- Remove direct `client`/`endpoints`/`git` requires
- Normalized note fields: `.author` (string not table), `.position.path`/`.new_line`/`.old_line`

**Step 2: Run tests**

```bash
bunx busted --run unit tests/codereview/mr/comment_spec.lua
```

**Step 3: Commit**

```bash
git add lua/codereview/mr/comment.lua tests/codereview/mr/comment_spec.lua
git commit -m "refactor(comment): wire up provider interface"
```

---

### Task 12: Wire up provider in `mr/actions.lua`

Replace direct API calls with provider interface.

**Files:**
- Modify: `lua/codereview/mr/actions.lua`
- Modify: `tests/codereview/mr/actions_spec.lua`

**Step 1: Update actions.lua**

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
  return provider.unapprove(client, ctx, review)
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

**Step 2: Run tests**

```bash
bunx busted --run unit tests/codereview/mr/actions_spec.lua
```

**Step 3: Commit**

```bash
git add lua/codereview/mr/actions.lua tests/codereview/mr/actions_spec.lua
git commit -m "refactor(actions): wire up provider interface"
```

---

### Task 13: Update init.lua and plugin commands

Final wiring — update entry point and commands.

**Files:**
- Modify: `lua/codereview/init.lua`
- Modify: `plugin/codereview.lua`

**Step 1: Update init.lua**

```lua
function M.open()
  local mr_list = require("codereview.mr.list")
  local picker = require("codereview.picker")
  local detail = require("codereview.mr.detail")

  mr_list.fetch({}, function(entries, err)
    if err then
      vim.notify("Failed to load reviews: " .. err, vim.log.levels.ERROR)
      return
    end
    if not entries or #entries == 0 then
      vim.notify("No open reviews found", vim.log.levels.INFO)
      return
    end
    vim.schedule(function()
      picker.pick_mr(entries, function(selected)
        detail.open(selected)
      end)
    end)
  end)
end

function M.approve()
  local buf = vim.api.nvim_get_current_buf()
  local review = vim.b[buf].codereview_review
  if not review then
    vim.notify("No review context in current buffer", vim.log.levels.WARN)
    return
  end
  require("codereview.mr.actions").approve(review)
end
```

**Step 2: Run all tests**

```bash
bunx busted --run unit tests/
```

**Step 3: Commit**

```bash
git add lua/codereview/init.lua plugin/codereview.lua
git commit -m "refactor: update entry point for provider-based flow"
```

---

### Task 14: Delete now-unused `api/endpoints.lua`

With all modules using providers, the endpoints module is dead code.

**Files:**
- Delete: `lua/codereview/api/endpoints.lua`
- Delete: `tests/codereview/api/endpoints_spec.lua`

**Step 1: Verify no remaining references**

```bash
rg "endpoints" lua/codereview/ --type lua
```

Should find zero results (all replaced by provider method calls).

**Step 2: Delete files**

```bash
git rm lua/codereview/api/endpoints.lua tests/codereview/api/endpoints_spec.lua
```

**Step 3: Run all tests**

```bash
bunx busted --run unit tests/
```

**Step 4: Commit**

```bash
git commit -m "chore: remove dead endpoints module"
```

---

### Task 15: Add `.codereview.json` config file support

Per-repo config with token and platform override.

**Files:**
- Modify: `lua/codereview/api/auth.lua`
- Create: `tests/codereview/config_file_spec.lua`

**Step 1: Write the test**

```lua
-- tests/codereview/config_file_spec.lua
local auth = require("codereview.api.auth")

describe("codereview.json config", function()
  it("reads token from .codereview.json when present", function()
    -- This test would need to mock vim.fn.filereadable and vim.fn.readfile
    -- or write a temp file. Implementation detail TBD.
    pending("integration test")
  end)
end)
```

**Step 2: Update auth.lua**

Add `.codereview.json` reading before env var check:

```lua
function M.get_token(platform)
  -- ... cached check ...

  -- 1. .codereview.json in repo root
  local config_path = vim.fn.getcwd() .. "/.codereview.json"
  if vim.fn.filereadable(config_path) == 1 then
    local content = table.concat(vim.fn.readfile(config_path), "\n")
    local ok, json = pcall(vim.json.decode, content)
    if ok and json.token then
      cached[platform] = { token = json.token, type = "pat" }
      return json.token, "pat"
    end
  end

  -- 2. Env var (GITHUB_TOKEN or GITLAB_TOKEN)
  -- ... rest same ...
end
```

**Step 3: Run tests**

```bash
bunx busted --run unit tests/
```

**Step 4: Commit**

```bash
git add lua/codereview/api/auth.lua tests/codereview/config_file_spec.lua
git commit -m "feat: add .codereview.json per-repo config support"
```

---

### Task 16: Full integration test

End-to-end test that exercises the provider detection → list → detail → diff flow with mocked HTTP.

**Files:**
- Create: `tests/codereview/integration/github_flow_spec.lua`
- Create: `tests/codereview/integration/gitlab_flow_spec.lua`

**Step 1: Write GitHub integration test**

```lua
-- tests/codereview/integration/github_flow_spec.lua
describe("GitHub full flow", function()
  local github = require("codereview.providers.github")

  it("normalizes a PR list response", function()
    local raw_prs = {
      { number = 1, title = "PR 1", user = { login = "alice" },
        head = { ref = "feat", sha = "abc" }, base = { ref = "main", sha = "def" },
        state = "open", html_url = "https://github.com/o/r/pull/1", body = "desc" },
    }
    local reviews = {}
    for _, pr in ipairs(raw_prs) do
      table.insert(reviews, github.normalize_pr(pr))
    end
    assert.equal(1, #reviews)
    assert.equal(1, reviews[1].id)
    assert.equal("alice", reviews[1].author)
  end)

  it("normalizes PR files to file diffs", function()
    local raw_files = {
      { filename = "foo.lua", previous_filename = "foo.lua", status = "modified",
        patch = "@@ -1,1 +1,2 @@\n old\n+new" },
    }
    local types = require("codereview.providers.types")
    local files = {}
    for _, f in ipairs(raw_files) do
      table.insert(files, types.normalize_file_diff({
        diff = f.patch, new_path = f.filename, old_path = f.previous_filename or f.filename,
        renamed_file = f.status == "renamed", new_file = f.status == "added", deleted_file = f.status == "removed",
      }))
    end
    assert.equal(1, #files)
    assert.equal("foo.lua", files[1].new_path)
  end)
end)
```

**Step 2: Run tests**

```bash
bunx busted --run unit tests/
```

**Step 3: Commit**

```bash
git add tests/codereview/integration/
git commit -m "test: add integration tests for GitHub and GitLab flows"
```
