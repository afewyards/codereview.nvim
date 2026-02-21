# glab-review.nvim Design Document

**Date:** 2026-02-21
**Status:** Approved

## Overview

Neovim plugin for GitLab merge request review with AI-powered code review via Claude CLI. Browse MRs, view diffs with inline comments, approve/merge, see pipelines, and let Claude draft review comments for you to triage.

## Architecture

**Monolithic Lua plugin.** No build step, no external runtimes. HTTP via `plenary.curl`, UI via Neovim extmarks/floats/splits.

### Directory Structure

```
glab-review.nvim/
├── lua/glab_review/
│   ├── init.lua                 -- setup(), config merging
│   ├── config.lua               -- defaults, validation
│   ├── api/
│   │   ├── client.lua           -- HTTP client (plenary.curl)
│   │   ├── auth.lua             -- OAuth device flow + PAT fallback
│   │   └── endpoints.lua        -- GitLab API endpoint wrappers
│   ├── picker/
│   │   ├── init.lua             -- adapter dispatcher (auto-detect)
│   │   ├── telescope.lua        -- Telescope adapter
│   │   ├── fzf.lua              -- fzf-lua adapter
│   │   └── snacks.lua           -- snacks.picker adapter
│   ├── mr/
│   │   ├── list.lua             -- MR listing/filtering
│   │   ├── detail.lua           -- MR detail floating window
│   │   ├── diff.lua             -- Inline diff renderer
│   │   ├── comment.lua          -- View/create/reply to comments
│   │   └── actions.lua          -- Approve, merge, close, create
│   ├── pipeline/
│   │   ├── status.lua           -- Pipeline status display
│   │   └── jobs.lua             -- Job list + log viewer
│   ├── review/
│   │   ├── ai.lua               -- Claude CLI integration
│   │   ├── draft.lua            -- Draft comment management
│   │   └── submit.lua           -- Batch submit to GitLab
│   └── ui/
│       ├── float.lua            -- Floating window helpers
│       ├── split.lua            -- Sidebar split helpers
│       ├── markdown.lua         -- Markdown rendering in buffers
│       ├── signs.lua            -- Gutter signs for comments
│       └── highlight.lua        -- Diff highlight groups, extmarks
├── plugin/glab_review.lua       -- Command registration, autocommands
├── doc/glab_review.txt          -- Vimdoc help
└── tests/                       -- Plenary busted tests
```

### Dependencies

- **Required:** `plenary.nvim` (HTTP, async, testing)
- **Optional (at least one):** `telescope.nvim`, `fzf-lua`, `snacks.nvim`
- **Optional:** `nvim-web-devicons` (file type icons)
- **External:** `claude` CLI (AI review feature only)

## Authentication

### Auth Cascade (priority order)

1. `GITLAB_TOKEN` env var -> `PRIVATE-TOKEN` header
2. glab CLI config (`~/.config/glab-cli/config.yml`) -> read PAT from `hosts.<hostname>.token`
3. OAuth2 Device Authorization Grant (`:GlabReviewAuth`)
4. Plugin-specific token store at `~/.local/share/glab-review/tokens.json` (file permissions 600)

### OAuth2 Device Flow

Supported since GitLab 17.1 (GA in 17.9). Ideal for headless/terminal tools.

1. `:GlabReviewAuth` -> `POST /oauth/authorize_device` with `client_id` + `scope=api`
2. Floating window shows `user_code` + `verification_uri_complete`
3. Plugin polls `POST /oauth/token` with `grant_type=urn:ietf:params:oauth:grant-type:device_code` every `interval` seconds
4. On success: store `access_token` + `refresh_token`
5. Auto-refresh on 401 via refresh token

**PAT scope required:** `api` (read + write). `read_api` sufficient for read-only mode.

### glab CLI Piggyback

Parse `~/.config/glab-cli/config.yml`. Extract `hosts.<hostname>.token`. Skip if `is_oauth2: "true"` (short-lived token without refresh capability). Skip if token field empty (keyring storage).

### Project Detection

Parse `git remote get-url origin` -> extract host + project path. Support:
- SSH: `git@gitlab.com:group/project.git`
- HTTPS: `https://gitlab.com/group/project.git`

Override via `setup({ gitlab_url = "...", project = "..." })`.

## UI Design

### Picker (MR List)

Adapter pattern supporting Telescope, fzf-lua, and snacks.picker. Auto-detects installed picker, configurable override.

MR picker shows: title, author, branch, pipeline status icon, approval status. Filterable by scope: `created_by_me`, `assigned_to_me`, `all`.

### MR Detail View (Floating Window)

Header: title, author, branch, pipeline status, approvals.

Description body with rendered markdown (treesitter markdown highlighting).

Activity feed below description:
- General comment threads with replies (rendered markdown)
- System notes as compact one-liners (approvals, labels, force-pushes)
- Reply and open-in-browser actions per thread

Footer summary: discussion count (unresolved count), approval status.

Keymaps: `d` diff, `c` comment, `a` approve, `A` AI review, `p` pipeline, `m` merge, `q` quit.

### Diff View (Split Layout)

**Left sidebar (~30%):** File tree with MR metadata.
- MR title, status, pipeline, approvals at top
- File list with diff stats (+/-) and comment count icons
- Discussion list below files: resolved/unresolved status per thread
- Action keymaps at bottom

**Right pane (~70%):** Inline unified diff.
- **No +/- prefixes.** Deleted lines: soft red background (full line width). Added lines: soft green background (full line width). Context lines: normal background.
- Word-level diff: changed segments within a line get a darker shade of the line's color.
- Full-width line highlighting via `nvim_buf_set_extmark()` with `line_hl_group`.
- Word-level via `nvim_buf_add_highlight()` on changed segments.
- Dual line numbers (old + new) like GitLab.
- Hunk-based display with configurable context lines (default 3, range 0-20). Hidden lines between hunks shown as "... N lines hidden (press <CR> to expand) ...".
- Comment threads appear inline between diff lines via `virt_lines`. Collapsed by default, expand on `<CR>` or when navigating to them.
- Sign column for comment indicators.

**Highlight groups:**
- `GlabReviewDiffAdd` — soft green line background
- `GlabReviewDiffDelete` — soft red line background
- `GlabReviewDiffAddWord` — darker green for changed words
- `GlabReviewDiffDeleteWord` — darker red for changed words
- `GlabReviewComment` — comment thread background
- `GlabReviewCommentUnresolved` — unresolved thread indicator

**Diff navigation:** `]f`/`[f` next/prev file, `]c`/`[c` next/prev comment, `cc` new comment on current line.

**Creating comments:**
- Normal mode `cc` on a diff line — single-line comment. Opens input prompt.
- Visual mode: select line(s) with `V`, then `cc` — multi-line comment covering the selection. Uses GitLab's `position[line_range][start]` and `position[line_range][end]` for range comments.
- Works in both regular diff view and AI review triage view (adds a manual comment alongside Claude's drafts).

### Comment Threads

Floating window showing full discussion thread with:
- Author, timestamp per note
- Rendered markdown bodies (code blocks, bold, italic, links, lists)
- Reply chain with `↳` indentation
- Resolved/unresolved status
- Keymaps: `r` reply, `R` resolve/unresolve, `o` open in browser

### Pipeline View (Floating Window)

Shows pipeline status, duration. Jobs grouped by stage. Each job shows: status icon, name, duration. `<CR>` on a job opens its log in a scrollable float (ANSI codes stripped). `r` retry failed jobs, `o` open in browser.

## AI Review (Claude Integration)

### Triggering

Press `A` from MR detail/diff or run `:GlabReviewAI`.

### Flow

1. Collect full MR diff via GitLab API (`GET /projects/:id/merge_requests/:iid/diffs`)
2. Spawn `claude` CLI subprocess with MR description + diff as context
3. Structured prompt instructs Claude to output JSON: `{file, line, severity, comment}` per finding
4. Parse Claude's output into review suggestions

### Triage UI (Split Layout)

**Left sidebar (~30%):** Suggestion list.
- Count header ("AI Review: 5 comments")
- Each suggestion: number, file:line, short description
- Status indicators: `✓` accepted, `▸` current, `○` pending
- Per-item actions: `[a]ccept [e]dit [d]el`
- Footer: reviewed count, `[A]` accept all, `[S]` submit review

**Right pane (~70%):** Diff view (same as regular diff view).
- Navigating sidebar syncs the diff pane to the relevant line
- Claude's draft comment shown inline as a floating box with `🤖 Claude [Draft]` header
- Same `[a]ccept [e]dit [d]elete` actions work inline too
- `[e]dit` opens comment text in a small editable float

### Submission

Accepted suggestions become draft notes via `POST /projects/:id/merge_requests/:iid/draft_notes` with position parameters. `[S]ubmit` calls `POST /projects/:id/merge_requests/:iid/draft_notes/bulk_publish` to publish all drafts at once.

## MR Creation

`:GlabReviewOpen` creates a new MR from current branch.

1. Detect current branch + diff against target branch (default: `main`)
2. Shell out to `claude` CLI with diff -> Claude drafts title + description
3. Floating editor buffer with the draft for editing
4. Picker for target branch, labels, assignees, reviewers
5. `POST /projects/:id/merge_requests` to create
6. Open new MR in detail view

## Commands

| Command | Description |
|---------|-------------|
| `:GlabReview` | Open MR picker |
| `:GlabReviewAuth` | Run auth flow |
| `:GlabReviewOpen` | Create new MR (Claude drafts title + description) |
| `:GlabReviewPipeline` | Show pipeline for current MR |
| `:GlabReviewAI` | Run Claude AI review on current MR |
| `:GlabReviewSubmit` | Submit all draft comments |
| `:GlabReviewApprove` | Approve current MR |

## GitLab API Endpoints

All via GitLab REST API v4. Always use `iid` (project-scoped), not `id` (global).

### MR Operations

| Operation | Endpoint |
|-----------|----------|
| List MRs | `GET /projects/:id/merge_requests?scope=...&state=opened` |
| MR details | `GET /projects/:id/merge_requests/:iid` (returns `diff_refs`, `head_pipeline`) |
| MR diffs | `GET /projects/:id/merge_requests/:iid/diffs` (paginated) |
| Create MR | `POST /projects/:id/merge_requests` |
| Approve | `POST /projects/:id/merge_requests/:iid/approve` (pass `sha`) |
| Unapprove | `POST /projects/:id/merge_requests/:iid/unapprove` |
| Merge | `PUT /projects/:id/merge_requests/:iid/merge` (supports `merge_when_pipeline_succeeds`) |

### Comments & Discussions

| Operation | Endpoint |
|-----------|----------|
| List discussions | `GET /projects/:id/merge_requests/:iid/discussions` |
| Create inline comment | `POST /projects/:id/merge_requests/:iid/discussions` + `position[base_sha/head_sha/start_sha/old_path/new_path/old_line/new_line]` |
| Reply to thread | `POST /projects/:id/merge_requests/:iid/discussions/:discussion_id/notes` |
| Resolve thread | `PUT /projects/:id/merge_requests/:iid/discussions/:discussion_id` (`resolved=true`) |
| Create draft note | `POST /projects/:id/merge_requests/:iid/draft_notes` + position params |
| Bulk publish drafts | `POST /projects/:id/merge_requests/:iid/draft_notes/bulk_publish` |

### Pipeline

| Operation | Endpoint |
|-----------|----------|
| MR pipelines | `GET /projects/:id/merge_requests/:iid/pipelines` |
| Pipeline detail | `GET /projects/:id/pipelines/:pipeline_id` |
| Pipeline jobs | `GET /projects/:id/pipelines/:pipeline_id/jobs` |
| Job log | `GET /projects/:id/jobs/:job_id/trace` (raw text, strip ANSI) |

### Key Implementation Notes

- Store `diff_refs` (`base_sha`, `head_sha`, `start_sha`) when loading an MR — needed for every inline comment position.
- Inline comment line placement: added line -> set `new_line` only; deleted line -> set `old_line` only; context line -> set both.
- Pagination: `page`/`per_page` params, follow `X-Next-Page` header.
- Rate limit: 2000 req/min on gitlab.com. Respect `Retry-After` on 429.
- Job logs contain ANSI escape codes — strip before rendering.

## Configuration

```lua
require("glab_review").setup({
  -- Auth
  gitlab_url = nil,           -- auto-detected from git remote
  project = nil,              -- auto-detected from git remote
  token = nil,                -- PAT override (prefer env var)

  -- Picker
  picker = nil,               -- "telescope" | "fzf" | "snacks" | nil (auto-detect)

  -- Diff
  diff = {
    context = 3,              -- context lines above/below hunks (0-20)
  },

  -- AI Review
  ai = {
    enabled = true,
    claude_cmd = "claude",    -- path to claude CLI
  },
})
```
