# GitHub Support Design — codereview.nvim

## Goal

Add full GitHub support to the plugin (currently GitLab-only). Rename from `gitlab.nvim` to `codereview.nvim`. Both platforms get first-class treatment via a provider abstraction.

## Decisions

- **Feature scope:** Full parity — PR/MR list, diff viewing, comments, merge, approve
- **Architecture:** Provider abstraction layer (not adapter/translator, not separate plugins)
- **Detection:** Auto-detect platform from `git remote origin` URL (`github.com` → GitHub, else GitLab)
- **Auth:** Per-repo `.codereview.json` config file (gitignored), env var fallback (`GITHUB_TOKEN`/`GITLAB_TOKEN`)
- **Implementation:** Pure Lua, no new external deps
- **Rename:** `mr/` → `review/`, `:GlabReview` → `:CodeReview`, plugin name → `codereview.nvim`

## Provider Interface

```lua
---@class Provider
---@field name string            -- "gitlab" | "github"
---@field list_reviews fun(opts): Review[]
---@field get_review fun(id): ReviewDetail
---@field get_diff fun(id): string          -- unified diff text
---@field get_discussions fun(id): Discussion[]
---@field post_comment fun(id, position, body): Comment
---@field edit_comment fun(id, comment_id, body): Comment
---@field delete_comment fun(id, comment_id): boolean
---@field approve fun(id): boolean
---@field unapprove fun(id): boolean
---@field merge fun(id, opts): boolean
---@field get_pipelines fun(id): Pipeline[]  -- future
```

Normalized types defined in `providers/types.lua`.

### Data Normalization

| Normalized field | GitLab source | GitHub source |
|---|---|---|
| `review.id` | `mr.iid` | `pr.number` |
| `review.title` | `mr.title` | `pr.title` |
| `review.author` | `mr.author.username` | `pr.user.login` |
| `review.base_sha` | `mr.diff_refs.base_sha` | `pr.base.sha` |
| `review.head_sha` | `mr.diff_refs.head_sha` | `pr.head.sha` |
| `discussion.notes` | `discussion.notes[]` | Review comments grouped by `in_reply_to_id` |

## Detection & Auth

### Detection flow

1. Parse `git remote get-url origin`
2. Hostname match: `github.com` / `*.github.com` → GitHub, else → GitLab
3. Override via `.codereview.json`: `"platform": "github"` or `"platform": "gitlab"`

### Auth flow

1. `.codereview.json` in repo root: `{ "platform": "github", "token": "ghp_..." }`
2. Fallback: `GITHUB_TOKEN` / `GITLAB_TOKEN` env vars
3. Safety: plugin auto-adds `.codereview.json` to `.gitignore` if it contains a token

## File Structure

```
lua/codereview/
  providers/
    init.lua        -- detect() → returns provider instance
    gitlab.lua      -- GitLab provider
    github.lua      -- GitHub provider
    types.lua       -- shared normalized types
  api/
    client.lua      -- HTTP client (shared, provider-agnostic)
    auth.lua        -- token resolution
  review/           -- renamed from mr/
    list.lua        -- calls provider.list_reviews()
    detail.lua      -- calls provider.get_review()
    diff.lua        -- calls provider.get_diff(), rendering unchanged
    diff_parser.lua -- unchanged (already provider-agnostic)
    comment.lua     -- calls provider.get_discussions()/post_comment()
    actions.lua     -- calls provider.approve()/merge()
  ui/               -- unchanged
  picker/           -- unchanged (uses normalized Review objects)
  config.lua        -- add platform/token config, rename setup entry
  git.lua           -- extract owner/repo alongside existing project detection
```

## GitHub API Specifics

### Comment Positioning
- GitLab: `position.old_line / new_line / base_sha / head_sha / start_sha`
- GitHub: `path`, `line`, `side` ("LEFT"/"RIGHT"), `commit_id`, optionally `start_line`/`start_side`
- Provider translates normalized position → platform format

### Discussions → Review Comments
- GitLab: explicit discussion threads
- GitHub: comments linked via `in_reply_to_id` — provider groups into `Discussion` objects

### Approvals
- GitLab: `POST /approve`
- GitHub: submit review with `event: "APPROVE"`

### Merge
- GitLab: `PUT /merge` with `merge_when_pipeline_succeeds`
- GitHub: `PUT /pulls/:number/merge` with `merge_method` (merge/squash/rebase)

### Pagination
- GitLab: `x-next-page` header
- GitHub: `Link` header with `rel="next"`
- HTTP client handles both via configurable `paginate()` helper

## Testing

- **Provider unit tests:** mock HTTP responses, test normalization both directions
- **Detection tests:** URL pattern matching, config override precedence
- **Integration tests:** full flow (list → get → diff → comment) with mocked providers
- **Existing rendering/diff tests:** unchanged (already provider-agnostic)

## Unresolved Questions

None — all design decisions confirmed.
