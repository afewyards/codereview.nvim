# Provider System Deep Dive

Generated 2026-03-03. Comprehensive analysis of the code review provider abstraction, registration, selection, auth, and per-provider API surface.

---

## 1. Supported Providers

Two providers are implemented:

| Provider | File | Lines | API Style | Name Field |
|----------|------|-------|-----------|------------|
| **GitLab** | `lua/codereview/providers/gitlab.lua` | 622 | REST v4 | `M.name = "gitlab"` |
| **GitHub** | `lua/codereview/providers/github.lua` | 923 | REST v3 + GraphQL v4 | `M.name = "github"` |

GitLab is the default: any host that is not `github.com` resolves to `"gitlab"` (line 8 of `providers/init.lua`). GitHub is only selected when the git remote host is literally `github.com`, or when `config.platform = "github"` is set explicitly.

---

## 2. Provider Abstraction / Interface

There is **no formal interface definition** -- no metatable, no interface table, no type annotations listing required methods. The contract is convention-based: both providers export the same set of functions with identical signatures.

The closest thing to an interface specification is in `docs/architecture/mock-provider-guide.md`, which catalogs every required function, its callers, and expected return shapes.

### 2a. Complete Method Catalog

Every method follows the signature pattern `fn(client, ctx, ...)` where:
- `client` is the `codereview.api.client` module (provides `get`, `post`, `put`, `delete`, `patch`, `paginate_all`, `paginate_all_url`, `get_url`)
- `ctx` is `{ base_url: string, project: string, host: string, platform: string }`

#### Core Read Methods

| Method | Signature | Returns | GitLab API | GitHub API |
|--------|-----------|---------|------------|------------|
| `list_reviews` | `(client, ctx, opts?)` | `Review[], err` | `GET /api/v4/projects/:id/merge_requests` | `GET /repos/:owner/:repo/pulls` |
| `get_review` | `(client, ctx, id)` | `Review, err` | `GET /api/v4/projects/:id/merge_requests/:iid` | `GET /repos/:owner/:repo/pulls/:number` |
| `get_diffs` | `(client, ctx, review)` | `FileDiff[], err` | `GET .../merge_requests/:iid/diffs` (paginated) | `GET /repos/:owner/:repo/pulls/:number/files` (paginated) |
| `get_discussions` | `(client, ctx, review)` | `Discussion[], err` | `GET .../merge_requests/:iid/discussions` (paginated) | **GraphQL** `pullRequest.reviewThreads` (paginated cursor) |
| `get_file_content` | `(client, ctx, ref, path)` | `string, err` | `GET .../repository/files/:path/raw?ref=` | `GET /repos/:owner/:repo/contents/:path?ref=` (base64 decoded) |
| `get_current_user` | `(client, ctx)` | `string, err` | `GET /api/v4/user` -> `.username` | `GET /user` -> `.login` |
| `get_commits` | `(client, ctx, review)` | `Commit[], err` | `GET .../merge_requests/:iid/commits` (paginated) | `GET /repos/:owner/:repo/pulls/:number/commits` (paginated, reversed to newest-first) |
| `get_commit_stats` | `(client, ctx, commits)` | `void` (mutates) | `GET .../repository/commits/:sha` -> `.stats` | `GET /repos/:owner/:repo/commits/:sha` -> `.stats` |
| `get_commit_diffs` | `(client, ctx, sha)` | `FileDiff[], err` | `GET .../repository/commits/:sha/diff` (paginated) | `GET /repos/:owner/:repo/commits/:sha` -> `.files` |
| `get_last_reviewed_sha` | `(client, ctx, review, username)` | `string or nil` | Approval rules + MR versions | `GET /repos/:owner/:repo/pulls/:number/reviews` (scan by user) |

#### Comment/Discussion Methods

| Method | Signature | Returns | GitLab API | GitHub API |
|--------|-----------|---------|------------|------------|
| `post_comment` | `(client, ctx, review, body, position?)` | `result, err` | `POST .../discussions` (with position) | `POST /repos/:owner/:repo/pulls/:number/comments` (inline) or `POST /repos/:owner/:repo/issues/:number/comments` (general) |
| `post_range_comment` | `(client, ctx, review, body, old_path, new_path, start_pos, end_pos)` | `result, err` | `POST .../discussions` with `line_range` | `POST .../pulls/:number/comments` with `start_line`/`line` |
| `reply_to_discussion` | `(client, ctx, review, disc_id, body)` | `result, err` | `POST .../discussions/:id/notes` | `POST .../pulls/:number/comments/:id/replies` (or via pending review) |
| `edit_note` | `(client, ctx, review, disc_id, note_id, body)` | `result, err` | `PUT .../discussions/:id/notes/:note_id` | `PATCH /repos/:owner/:repo/pulls/comments/:id` |
| `delete_note` | `(client, ctx, review, disc_id, note_id)` | `result, err` | `DELETE .../discussions/:id/notes/:note_id` | `DELETE /repos/:owner/:repo/pulls/comments/:id` |
| `resolve_discussion` | `(client, ctx, review, disc_id, resolved, node_id?)` | `result, err` | `PUT .../discussions/:id {resolved: bool}` | **GraphQL** `resolveReviewThread` / `unresolveReviewThread` mutation |

#### MR/PR Actions

| Method | Signature | Returns | GitLab API | GitHub API |
|--------|-----------|---------|------------|------------|
| `approve` | `(client, ctx, review)` | `result, err` | `POST .../approve` | `POST .../reviews {event: "APPROVE"}` |
| `unapprove` | `(client, ctx, review)` | `result, err` | `POST .../unapprove` | Returns `nil, "not supported"` |
| `merge` | `(client, ctx, review, opts)` | `result, err` | `PUT .../merge` (squash, remove_source_branch, auto_merge) | `PUT .../pulls/:number/merge` (merge_method: merge/squash/rebase) |
| `close` | `(client, ctx, review)` | `result, err` | `PUT .../merge_requests/:iid {state_event: "close"}` | `PATCH .../pulls/:number {state: "closed"}` |
| `create_review` | `(client, ctx, params)` | `result, err` | `POST .../merge_requests` (draft via title prefix) | `POST /repos/:owner/:repo/pulls` (draft via `draft: true`) |

#### Draft/Review Session Methods

| Method | Signature | Returns | GitLab API | GitHub API |
|--------|-----------|---------|------------|------------|
| `create_draft_comment` | `(client, ctx, review, params)` | `result, err` | `POST .../draft_notes` | First call: `POST .../reviews` (creates PENDING review); subsequent: **GraphQL** `addPullRequestReviewThread` |
| `get_draft_notes` (GitLab) | `(client, ctx, review)` | `Draft[], err` | `GET .../draft_notes` (paginated) | N/A |
| `get_pending_review_drafts` (GitHub) | `(client, ctx, review)` | `Draft[], err` | N/A | `GET .../reviews` (find PENDING) + `GET .../reviews/:id/comments` |
| `delete_draft_note` (GitLab) | `(client, ctx, review, draft_id)` | `result, err` | `DELETE .../draft_notes/:id` | N/A |
| `discard_pending_review` (GitHub) | `(client, ctx, review)` | `result, err` | N/A | `DELETE .../reviews/:id` |
| `publish_review` | `(client, ctx, review, opts?)` | `result, err` | `POST .../draft_notes/bulk_publish` + optional note + optional approve | `POST .../reviews/:id/events {event: "COMMENT" or opts.event}` |

#### Pipeline/CI Methods

| Method | Signature | Returns | GitLab API | GitHub API |
|--------|-----------|---------|------------|------------|
| `get_pipeline` | `(client, ctx, review)` | `Pipeline, err` | Reads `head_pipeline` from MR detail | `GET .../commits/:sha/check-suites` (first suite) |
| `get_pipeline_jobs` | `(client, ctx, review, pipeline_id)` | `PipelineJob[], err` | `GET .../pipelines/:id/jobs` | `GET .../commits/:sha/check-runs` |
| `get_job_trace` | `(client, ctx, review, job_id)` | `string, err` | `GET .../jobs/:id/trace` | Fetches workflow run logs (ZIP download via details_url extraction) |
| `retry_job` | `(client, ctx, review, job_id)` | `result, err` | `POST .../jobs/:id/retry` | `POST .../actions/runs/:run_id/rerun` (extracts run_id from check-run) |
| `cancel_job` | `(client, ctx, review, job_id)` | `result, err` | `POST .../jobs/:id/cancel` | `POST .../actions/runs/:run_id/cancel` |
| `play_job` | `(client, ctx, review, job_id)` | `result, err` | `POST .../jobs/:id/play` | Returns `nil, "Manual job trigger not supported on GitHub"` |

#### Auth/Utility

| Method | Signature | Returns | Notes |
|--------|-----------|---------|-------|
| `build_auth_header` | `(token, token_type?)` | `headers table` | GitLab: `PRIVATE-TOKEN` or `Authorization: Bearer` (oauth). GitHub: `Authorization: Bearer` + Accept + API version headers |
| `parse_next_page` | `(headers)` | `number or nil` or `string or nil` | GitLab: reads `x-next-page` header. GitHub: parses `Link` header for `rel="next"` URL |
| `normalize_pr` / `normalize_mr` | `(raw_api_object)` | `Review` | Platform-specific normalization to the shared Review shape |

### 2b. Platform-Specific Asymmetries

Several methods exist on one provider but not the other, or have different semantics:

| Asymmetry | GitLab | GitHub |
|-----------|--------|--------|
| **Unapprove** | Fully supported (`POST .../unapprove`) | Returns `nil, "not supported"` |
| **Play manual job** | Supported (`POST .../jobs/:id/play`) | Returns `nil, "Manual job trigger not supported on GitHub"` |
| **Draft comment API** | Native draft notes endpoint (`draft_notes`) | Emulated via PENDING review + GraphQL `addPullRequestReviewThread` |
| **Delete drafts** | Per-draft deletion (`delete_draft_note`) | Whole pending review deletion (`discard_pending_review`) |
| **Discussion fetch** | REST pagination | GraphQL cursor pagination |
| **Resolve discussion** | Simple REST `PUT` | GraphQL mutation (requires thread node_id lookup if not cached) |
| **Auth header key** | `PRIVATE-TOKEN` or `Authorization: Bearer` (oauth) | `Authorization: Bearer` only |
| **PR creation draft** | Title prefix `"Draft: "` | `draft: true` field |
| **Merge method** | `squash`, `should_remove_source_branch`, `merge_when_pipeline_succeeds` | `merge_method` (merge/squash/rebase) |
| **Module-level state** | `_cached_user` only | `_cached_user`, `_pending_review_id`, `_pending_review_node_id` |

### 2c. Minimum Viable Provider (Read-Only)

From the mock-provider guide, the minimum set for navigation without write operations:

```
list_reviews, get_review, get_diffs, get_discussions,
get_file_content, get_current_user
```

All write functions can be stubbed as `return nil, "not supported"`.

---

## 3. Provider Registration and Selection

### 3a. Registration (`providers/init.lua:11-19`)

Providers are registered via a hardcoded `if/elseif` chain in `M.get_provider(platform)`:

```lua
function M.get_provider(platform)
  if platform == "gitlab" then
    return require("codereview.providers.gitlab")
  elseif platform == "github" then
    return require("codereview.providers.github")
  else
    error("Unknown platform: " .. tostring(platform))
  end
end
```

There is no registry table, no plugin system, no dynamic registration. Adding a third provider requires editing this function. Providers are loaded lazily via `require()`.

### 3b. Platform Detection (`providers/init.lua:5-9`)

```lua
local GITHUB_HOSTS = { ["github.com"] = true }

function M.detect_platform(host)
  if not host then return "gitlab" end
  if GITHUB_HOSTS[host] then return "github" end
  return "gitlab"
end
```

Only `github.com` maps to GitHub. All other hosts (including GitHub Enterprise hosts) default to GitLab. This means GHE users must explicitly set `config.platform = "github"`.

### 3c. Full Detection Flow (`providers/init.lua:21-48`)

`M.detect()` returns `(provider_module, ctx_table, err_string)`:

```
1. Check config.base_url + config.project (explicit override)
   -> If set: extract host from base_url
   -> Otherwise:
2. git.get_remote_url() -> parse_remote() -> (host, project)
   -> host = "github.com", project = "owner/repo"
3. platform = config.platform or detect_platform(host)
   -> config.platform overrides auto-detection entirely
4. provider = get_provider(platform) -> require("codereview.providers.<platform>")
5. base_url:
   - GitHub: config.base_url or "https://api.github.com"
   - GitLab: config.base_url or "https://<host>"
6. Return provider, { base_url, project, host, platform }
```

The config option `config.platform` (line 37) is the escape hatch that short-circuits detection. This is how GHE, self-hosted GitLab, or a future demo provider would be selected.

### 3d. Detection Call Sites

`providers.detect()` is called from many modules, each time resolving the provider fresh:

| File | Line | Purpose |
|------|------|---------|
| `mr/list.lua:48` | Fetch MR list | `prov.list_reviews(client, pctx, opts)` |
| `mr/detail.lua:469` | Open MR detail view | Full data fetch: review, discussions, diffs, commits |
| `mr/actions.lua:5,11,23,30` | Approve, unapprove, merge, close | One-shot provider calls |
| `mr/create.lua:253` | Submit new MR/PR | `provider.create_review(client, ctx, params)` |
| `mr/comment.lua:73` | Get provider for comment ops | Used by reply, edit, delete, resolve, create_comment |
| `review/submit.lua:17,74` | Submit/publish review | `provider.create_draft_comment` + `provider.publish_review` |
| `mr/diff_keymaps.lua:87` | Refresh action | `provider.get_discussions(...)` |

**Important**: `providers.detect()` re-runs git commands each time it is called (unless config overrides are set). This is why `state.provider` and `state.ctx` are cached on the state object by `detail.open()` and threaded through to avoid repeated detection.

---

## 4. Authentication System

### 4a. Token Resolution (`api/auth.lua:70-106`)

`M.get_token(platform)` resolves auth tokens in priority order:

```
1. Environment variable
   - GitHub: GITHUB_TOKEN
   - GitLab: GITLAB_TOKEN

2. .codereview.nvim file (dotenv format in repo root)
   - Reads key: "token" (platform-agnostic)
   - Safety check: warns if file is not in .gitignore

3. Plugin config
   - GitHub: config.github_token
   - GitLab: config.gitlab_token
```

Tokens are cached per-platform after first resolution (`cached[platform] = { token, type }`). `M.reset()` clears the cache. `M.refresh(platform)` clears a single platform's cache.

The `token_type` is always `"pat"` in the current implementation. The distinction matters only for GitLab where `"oauth"` would use `Authorization: Bearer` instead of `PRIVATE-TOKEN`.

### 4b. Auth Header Construction

Each provider builds its own headers:

**GitLab** (`gitlab.lua:22-28`):
```lua
function M.build_auth_header(token, token_type)
  if token_type == "oauth" then
    return { ["Authorization"] = "Bearer " .. token, ["Content-Type"] = "application/json" }
  else
    return { ["PRIVATE-TOKEN"] = token, ["Content-Type"] = "application/json" }
  end
end
```

**GitHub** (`github.lua:10-17`):
```lua
function M.build_auth_header(token)
  return {
    ["Authorization"] = "Bearer " .. token,
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/vnd.github+json",
    ["X-GitHub-Api-Version"] = "2022-11-28",
  }
end
```

### 4c. Auth in the Request Chain

Every provider method follows this pattern (repeated ~30+ times across both files):

```lua
function M.some_method(client, ctx, ...)
  local headers, err = get_headers()  -- local helper calling auth.get_token()
  if not headers then return nil, err end
  -- ... make API call with headers ...
end
```

The `client` module (`api/client.lua`) also has a fallback: if `opts.headers` is nil, it calls `auth.get_token()` directly and builds GitLab-style headers (lines 104-110). This legacy path exists for backward compatibility but is not used by the current provider code since providers always supply their own headers.

### 4d. Deprecated Config Key

`config.lua:73-78` warns about the old `token` key:
```lua
if current.token then
  vim.notify(
    "[codereview] `token` is deprecated and will NOT be used. Set `github_token` or `gitlab_token` instead.",
    vim.log.levels.WARN
  )
end
```

---

## 5. HTTP Client Layer (`api/client.lua`)

The client is a stateless module wrapping `plenary.curl`. It provides:

| Function | Purpose |
|----------|---------|
| `get/post/put/delete/patch(base_url, path, opts)` | Synchronous HTTP methods |
| `async_get/async_post/async_put/async_delete/async_patch(base_url, path, opts)` | Async via plenary.async |
| `get_url(full_url, opts)` | GET with full URL (for pagination follow-up) |
| `paginate_all(base_url, path, opts)` | Page-number pagination (GitLab: `x-next-page` header) |
| `paginate_all_url(start_url, opts)` | URL-based pagination (GitHub: `Link` header) |
| `request(method, base_url, path, opts)` | Core sync request with logging, rate-limit retry (429), error handling |

Key behaviors:
- **Rate limiting**: On HTTP 429, reads `Retry-After` header (default 5s), waits, retries once (lines 128-139)
- **Response processing**: JSON-decodes body, extracts `next_page` (GitLab) and `next_url` (GitHub) from headers (lines 64-82)
- **Logging**: All requests/responses logged via `codereview.log` when `config.debug = true`

---

## 6. Normalization Layer (`providers/types.lua`)

All raw API responses are normalized to shared shapes before leaving the provider module. This is the abstraction boundary that allows the rest of the plugin to be provider-agnostic.

### 6a. Normalize Functions

| Function | Input | Output Shape |
|----------|-------|-------------|
| `normalize_review(raw)` | Raw MR/PR | `{ id, title, author, source_branch, target_branch, state, base_sha, head_sha, start_sha, web_url, description, pipeline_status, approved_by, approvals_required, sha, merge_status }` |
| `normalize_note(raw)` | Raw note | `{ id, author, body, created_at, system, resolvable, resolved, resolved_by, position }` |
| `normalize_discussion(raw)` | Raw discussion | `{ id, resolved, notes: Note[] }` |
| `normalize_file_diff(raw)` | Raw file diff | `{ diff, new_path, old_path, renamed_file, new_file, deleted_file }` |
| `normalize_pipeline(raw)` | Raw pipeline | `{ id, status, ref, sha, web_url, created_at, updated_at, duration }` |
| `normalize_pipeline_job(raw)` | Raw job | `{ id, name, stage, status, duration, web_url, allow_failure, started_at, finished_at }` |
| `normalize_commit(raw)` | Raw commit | `{ sha, short_sha, title, author, created_at, additions, deletions }` |

### 6b. Provider-Specific Pre-normalization

Each provider does its own pre-normalization before calling `types.normalize_*`:

- **GitLab** (`gitlab.lua:40-65`): `normalize_mr()` extracts `diff_refs.{base,head,start}_sha`, `author.username`, `approved_by[].user.username`, `head_pipeline.status`
- **GitHub** (`github.lua:82-105`): `normalize_pr()` extracts `head.sha`, `base.sha`, `user.login`, derives `merge_status` from `mergeable` boolean
- **GitHub discussions** (`github.lua:109-150`): `normalize_graphql_threads()` maps GraphQL `reviewThreads` to the Discussion shape, preserving `node_id` for later GraphQL mutations

### 6c. Position Shape Differences

GitLab and GitHub positions carry different platform-specific fields:

```
GitLab position:
  { new_path, old_path, new_line, old_line,
    base_sha, head_sha, start_sha,
    start_new_line, start_old_line }  -- range via line_range

  Also: change_position for outdated notes
    { new_path, old_path, new_line, old_line }

GitHub position:
  { new_path, new_line, old_line,
    side, start_line, start_side,
    commit_sha, outdated }
```

The rest of the plugin handles both shapes, typically checking `position.new_line` or `position.old_line` to place comments on diff lines.

---

## 7. GitHub-Specific: GraphQL Usage

GitHub uses GraphQL for three operations where the REST API is insufficient:

### 7a. Fetching Discussions (`github.lua:232-298`)

REST `GET /pulls/:number/comments` returns flat comments. To get threaded review discussions with resolve status, GitHub requires GraphQL:

```graphql
query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved diffSide startDiffSide isOutdated
          comments(first: 100) {
            nodes {
              databaseId author { login } body createdAt
              path line originalLine startLine originalStartLine
              outdated commit { oid }
            }
          }
        }
      }
    }
  }
}
```

Cursor-based pagination fetches all threads across multiple pages.

### 7b. Resolve/Unresolve (`github.lua:487-565`)

Resolving a thread requires the GraphQL `threadId` (node_id). The flow:

1. If `node_id` is cached (from `get_discussions`), use it directly
2. Otherwise, fetch all threads via GraphQL lookup query, match by `databaseId`
3. Execute `resolveReviewThread` or `unresolveReviewThread` mutation

### 7c. Adding Draft Comments to Existing Review (`github.lua:650-672`)

After the first draft creates a PENDING review via REST, subsequent drafts are added via GraphQL:

```graphql
mutation($reviewId: ID!, $body: String!, $path: String!, $line: Int!, $side: DiffSide!) {
  addPullRequestReviewThread(input: {
    pullRequestReviewId: $reviewId
    body: $body, path: $path, line: $line, side: $side
  }) {
    thread { id }
  }
}
```

The GraphQL endpoint is derived from the REST base_url (`github.lua:37-41`):
- `api.github.com` -> `api.github.com/graphql`
- `gh.corp.com/api/v3` -> `gh.corp.com/api/graphql` (GHE)

---

## 8. GitHub-Specific: Module-Level Mutable State

The GitHub provider maintains three module-level variables (`github.lua:582, 617-618`):

```lua
M._cached_user = nil              -- Cached current user login
M._pending_review_id = nil        -- REST ID of active PENDING review
M._pending_review_node_id = nil   -- GraphQL node ID of active PENDING review
```

`_pending_review_id` is set when:
1. `create_draft_comment` creates a new PENDING review (line 644)
2. `get_pending_review_drafts` finds an existing PENDING review (line 723)

It is cleared when:
1. `publish_review` submits the review (line 761)
2. `discard_pending_review` deletes it (line 737)

**Gotcha**: These are module-level singletons. If multiple reviews were opened concurrently (not currently possible due to `diff.close_active()` in `detail.open()`), the state would be corrupted.

---

## 9. GitLab-Specific: Draft Notes API

GitLab has a first-class draft notes API. Key differences from GitHub:

- `POST .../draft_notes` creates a standalone draft (no review container needed)
- `GET .../draft_notes` lists all drafts (paginated)
- `DELETE .../draft_notes/:id` deletes individual drafts
- `POST .../draft_notes/bulk_publish` publishes all drafts at once

The `publish_review` method on GitLab (`gitlab.lua:517-534`) does three things sequentially:
1. Bulk-publish all draft notes
2. If `opts.body` is set, post a general MR note (summary comment)
3. If `opts.event == "APPROVE"`, call the approve endpoint

---

## 10. Draft Comment Abstraction (`review/drafts.lua`)

The `review/drafts.lua` module bridges the different draft APIs between providers. It is the **only place** in the codebase that branches on `provider.name`:

```lua
function M.fetch_server_drafts(provider, client, ctx, review)
  if provider.name == "gitlab" then
    return provider.get_draft_notes(client, ctx, review) or {}
  elseif provider.name == "github" then
    return provider.get_pending_review_drafts(client, ctx, review) or {}
  end
  return {}
end

function M.discard_server_drafts(provider, client, ctx, review, server_drafts)
  if provider.name == "gitlab" then
    for _, d in ipairs(server_drafts) do
      if d.server_draft_id then
        provider.delete_draft_note(client, ctx, review, d.server_draft_id)
      end
    end
  elseif provider.name == "github" then
    provider.discard_pending_review(client, ctx, review)
  end
end
```

This is an architectural violation of the otherwise provider-agnostic design. Both draft functions (fetch and discard) have different semantics per platform, and the provider interface does not abstract this uniformly.

---

## 11. Key Files Summary

| File | Role | Lines |
|------|------|-------|
| `lua/codereview/providers/init.lua` | Platform detection, provider dispatch | 50 |
| `lua/codereview/providers/types.lua` | Normalized data shapes (7 normalize functions) | 96 |
| `lua/codereview/providers/gitlab.lua` | GitLab REST API (all methods) | 622 |
| `lua/codereview/providers/github.lua` | GitHub REST + GraphQL API (all methods) | 923 |
| `lua/codereview/api/auth.lua` | Token resolution chain (env -> file -> config) | 119 |
| `lua/codereview/api/client.lua` | HTTP client (sync + async, pagination, rate limiting) | 301 |
| `lua/codereview/review/drafts.lua` | Cross-provider draft comment abstraction | 53 |
| `lua/codereview/review/submit.lua` | Submit/publish review (uses providers) | 87 |
| `lua/codereview/mr/actions.lua` | MR actions facade (approve, merge, close) | 36 |
| `lua/codereview/mr/comment.lua` | Comment operations (reply, edit, delete, resolve) | 429 |
| `lua/codereview/mr/create.lua` | MR/PR creation flow | 277 |
| `lua/codereview/config.lua` | Configuration with platform/token options | 90 |

---

## 12. How to Add a New Provider

Based on the existing patterns, adding a third provider (e.g., Bitbucket, Azure DevOps) requires:

1. **Create** `lua/codereview/providers/<name>.lua` implementing all methods from section 2a
2. **Register** in `providers/init.lua:get_provider()` -- add an `elseif` branch
3. **Optionally register** in `providers/init.lua:detect_platform()` -- add host to detection map
4. **Handle drafts** in `review/drafts.lua` -- add `elseif provider.name == "<name>"` branches
5. **Auth token** -- add env var name to `api/auth.lua:get_token()` and config key to `config.lua`

No other files need modification -- all other code uses the provider through `state.provider` or the return value of `providers.detect()`.

---

## 13. Gotchas and Design Notes

1. **No interface enforcement**: Adding a provider that misses a method causes a runtime Lua error (`attempt to call a nil value`) at the call site. There are no upfront checks.

2. **`get_headers()` repeated 30+ times**: Every provider method independently calls `get_headers()`, which calls `auth.get_token()`. The token is cached, but the header construction is repeated.

3. **`providers.detect()` runs git commands**: Without config overrides, each `detect()` call runs `git remote get-url origin`. Callers that need provider access in hot paths should cache the result (as `detail.open()` does with `state.provider` and `state.ctx`).

4. **GitHub PENDING review is a singleton**: Only one PENDING review can exist per user per PR. The `_pending_review_id` module-level state tracks this. If `get_pending_review_drafts` finds an existing PENDING review, it always reuses it (line 723: unconditional set even when there are 0 draft comments).

5. **Pagination styles differ**: GitLab uses page-number pagination (`x-next-page` header, handled by `client.paginate_all`). GitHub uses URL-based pagination (`Link` header, handled by `client.paginate_all_url`). Some GitHub methods (discussions via GraphQL) use cursor pagination implemented inline.

6. **`review/drafts.lua` is the only name-check**: All other code is duck-typed against the provider table. The drafts module explicitly checks `provider.name` because GitLab and GitHub have fundamentally different draft APIs with no common abstraction.

7. **GHE requires explicit config**: GitHub Enterprise hosts are not auto-detected since `detect_platform()` only recognizes `github.com`. Users must set `config.platform = "github"` and `config.base_url = "https://ghe.corp.com/api/v3"`.
