# codereview.nvim — Comprehensive Analysis

Generated 2026-03-04. This document synthesizes all existing architecture docs plus fresh analysis
of recent development (commit-filter, pipeline log sections, provider system) into a single
coherent picture for feature brainstorming.

---

## 1. What the Plugin Does

codereview.nvim is a full-featured Neovim plugin for reviewing GitHub PRs and GitLab MRs without
leaving the editor. The user flow is:

1. `:CodeReview` opens a fuzzy picker showing open PRs/MRs for the current repo
2. Selecting one opens a persistent split-pane layout:
   - **Left sidebar** — file tree with review-progress icons, commit list, session status
   - **Right main pane** — unified diff with virtual-line comment threads, AI suggestions, and
     inline line numbers
3. The user navigates files with `]f`/`[f`, reads and creates comments, runs AI review, and
   eventually submits with `S`
4. A separate pipeline float (`p`) shows CI/CD status and lets the user view logs and retry jobs

---

## 2. Supported Platforms

| Platform | Support level | Notes |
|----------|--------------|-------|
| **GitLab** | Full | All features: drafts, approvals, merge options, pipeline, per-commit review |
| **GitHub** | Full | All features (with some asymmetries — see Section 7) |
| GitHub Enterprise | Manual config required | `config.platform = "github"` + `config.base_url` |
| Self-hosted GitLab | Auto-detected | Any non-github.com host falls back to GitLab |
| Bitbucket / Azure DevOps | Not supported | Would require new provider |

---

## 3. Directory Structure (all ~75 Lua files)

```
plugin/
  codereview.lua             # 10 user-facing commands (:CodeReview, :CodeReviewAI, etc.)

lua/codereview/
  init.lua                   # Public API: open(), ai_review(), submit(), commits(), etc.
  config.lua                 # Defaults + deep_merge + validation (keymaps, ai, diff, pipeline)
  keymaps.lua                # Keymap registry + apply() with collision resolution
  git.lua                    # parse_remote(), get_remote_url(), get_repo_root()
  log.lua                    # Debug logger → .codereview.log (enabled by config.debug=true)

  api/
    client.lua               # plenary.curl wrapper: sync+async, pagination, 429 retry
    auth.lua                 # Token: env var → .codereview.nvim file → config (cached per platform)

  providers/
    init.lua                 # detect() → (provider, ctx, err). Platform detection from git remote.
    types.lua                # normalize_review/note/discussion/file_diff/pipeline/pipeline_job/commit
    gitlab.lua               # GitLab REST v4: ~30 functions (435→622 lines)
    github.lua               # GitHub REST v3 + GraphQL v4: ~30 functions (644→923 lines)

  mr/
    list.lua                 # fetch() → Entry[] for picker
    detail.lua               # open(entry): full data fetch, split creation, state init
    diff.lua                 # Thin re-export facade (145 lines) — stable interface for all callers
    diff_state.lua           # create_state(opts), apply_scroll_result(), apply_file_result()
    diff_render.lua          # render_file_diff(), render_all_files(), extmarks, syntax
    diff_sidebar.lua         # render_sidebar() → sidebar_layout; render_summary()
    diff_keymaps.lua         # All keymaps + autocmds + callback closures
    diff_nav.lua             # nav_file(), switch_to_file(), jump_to_file/comment, toggle modes
    diff_comments.lua        # build_row_items(), cycle_row_selection(), create_comment_at_cursor()
    diff_parser.lua          # parse_hunks(), build_display(), word_diff()
    commit_filter.lua        # build_version_map(), matches_discussion(), apply(), clear(), select()
    comment.lua              # create_comment(), open_input_popup() — all comment creation
    comment_float.lua        # Low-level float window for comment input (inline + centered fallback)
    thread_virt_lines.lua    # build() → virtual lines for comment threads
    review_tracker.lua       # Hunk-based review progress: init_file(), mark_visible() → ○/◑/●
    actions.lua              # approve(), unapprove(), merge(), close()
    create.lua               # MR/PR creation: ensure_pushed, editor, submit_mr
    merge_float.lua          # Merge confirmation float (platform-specific options)
    submit_float.lua         # Submit review float: Comment/Approve/Request Changes
    sidebar_layout.lua       # Composes 5 sidebar components, normalizes highlights
    sidebar_help.lua         # Help text builder
    sidebar_components/
      header.lua             # Review ID + title + pipeline status + branch info
      status.lua             # Session status: AI progress, draft count, thread count, published state
      summary_button.lua     # "ℹ Summary" row
      file_tree.lua          # Directory-grouped file list with ○/◑/● icons + badge counts
      footer.lua             # Dynamic keymap hints (context-sensitive)
      commits.lua            # Commit list with filter indicator, "Since last review" entry

  review/
    init.lua                 # start()/start_file(): AI review orchestration (single/multi/file)
    session.lua              # Session state machine: IDLE / REVIEWING / REVIEWING+AI
    submit.lua               # submit_and_publish(): post accepted AI suggestions + bulk_publish
    drafts.lua               # check_and_prompt(): server-draft detection and Resume/Discard flow

  ui/
    split.lua                # Creates sidebar+main split pane
    highlight.lua            # ~40 highlight group definitions
    markdown.lua             # Inline formatting, tables, code blocks, treesitter for code fences
    inline_float.lua         # reserve_space(), highlight_lines() for comment float anchoring
    spinner.lua              # Top-right progress spinner for AI reviews

  picker/
    init.lua                 # Auto-detect telescope/fzf-lua/snacks; also pick_branches()
    telescope.lua            # Telescope adapter: pick_mr, pick_comments, pick_files, pick_commits
    fzf.lua                  # fzf-lua adapter
    snacks.lua               # snacks.nvim adapter
    comments.lua             # Comment/suggestion picker with navigation
    files.lua                # File picker with diff counts
    commits.lua              # Commit picker (SHA + title + author + time)

  pipeline/
    init.lua                 # open(diff_state): float creation, polling, job controls
    state.lua                # create(), fetch(), start_polling(10s), stop_polling()
    render.lua               # build_lines() → { lines, row_map } for stages and jobs
    keymaps.lua              # r:retry  c:cancel  p:play  o:browser  R:refresh  <CR>:log
    log_view.lua             # Job log float: ANSI rendering, truncation at 5000 lines
    ansi.lua                 # ANSI escape code parser → { lines, highlights }

  ai/
    prompt.lua               # build_review_prompt/file_review_prompt/summary_prompt,
                             #   parse_review_output, annotate_diff_with_lines,
                             #   filter_unchanged_lines, extract_changed_lines
    summary.lua              # generate_summary_with_callbacks() (fires deferred callbacks)
    subprocess.lua           # run_subprocess() — cross-platform process spawner
    providers/
      init.lua               # get() → selected AI provider module
      claude_cli.lua         # claude -p [--agent code-review] (default)
      anthropic.lua          # Direct Anthropic API (claude-sonnet-4-20250514)
      openai.lua             # OpenAI-compatible API (gpt-4o or custom base_url)
      ollama.lua             # Local Ollama (llama3 by default)
      custom_cmd.lua         # Arbitrary shell command
      http.lua               # Shared streaming HTTP for anthropic + openai
```

---

## 4. Key Abstractions

### 4a. State Object (`mr/diff_state.lua`)

The central data structure — a plain table with 30+ mutable fields created once by
`diff_state.create_state(opts)`. Threaded through essentially every function.

**Critical fields:**

| Field | Type | Purpose |
|-------|------|---------|
| `view_mode` | `"summary"\|"diff"` | Which pane content is shown |
| `scroll_mode` | `boolean` | All-files scroll vs per-file mode |
| `review` | `Review` | Normalized MR/PR from provider |
| `provider`, `ctx` | module, table | Cached provider + context (base_url, project) |
| `files` | `FileDiff[]` | Current file list (may be filtered by commit) |
| `discussions` | `Discussion[]` | Current thread list (may be filtered by commit) |
| `commits` | `Commit[]` | MR/PR commit history |
| `versions` | table | GitLab MR versions (for commit→version_head_sha mapping) |
| `commit_filter` | table or nil | Active commit filter `{from_sha, to_sha, label, changed_paths_set}` |
| `original_files` | `FileDiff[]` | Backup when commit filter active |
| `original_discussions` | `Discussion[]` | Backup when commit filter active |
| `current_file` | `number` | 1-indexed index into `files` |
| `local_drafts` | `Discussion[]` | Locally-created draft discussions |
| `ai_suggestions` | table | Parsed AI suggestions `{file, line, code, severity, comment, status}` |
| `row_selection` | table | Which comment/suggestion is selected at cursor |
| `line_data_cache` | `{[i]: LineData[]}` | Per-file render data (per-file mode) |
| `row_disc_cache` | `{[i]: {[row]: Disc[]}}` | Per-file discussion row maps |
| `scroll_line_data` | `LineData[]` | All-files render data |
| `file_sections` | table | In scroll mode: maps file ranges to buffer rows |
| `git_diff_cache` | `{[key]: string}` | Keyed by `"path:base..head"` |
| `file_review_status` | `{[path]: {status, hunks_total, hunks_seen}}` | `○/◑/●` state |
| `sidebar_row_map` | `{[row]: {type, ...}}` | Sidebar buffer row → semantic entry |
| `collapsed_dirs` | `{[dir]=true}` | Collapsed directory groups in file tree |
| `collapsed_commits` | `boolean` | Whether commits section is folded |

### 4b. Provider Interface (`providers/gitlab.lua`, `providers/github.lua`)

Convention-based duck-typed interface. No formal definition exists. Full catalog in
`docs/architecture/provider-system-deep-dive.md`. Key methods:

- `list_reviews` / `get_review` / `get_diffs` / `get_discussions` — core data fetch
- `post_comment` / `post_range_comment` / `reply_to_discussion` — comment creation
- `edit_note` / `delete_note` / `resolve_discussion` — comment mutation
- `create_draft_comment` / `publish_review` — review session lifecycle
- `approve` / `unapprove` / `merge` / `close` — MR/PR actions
- `get_commits` / `get_commit_diffs` / `get_last_reviewed_sha` — commit navigation
- `get_pipeline` / `get_pipeline_jobs` / `get_job_trace` / `retry_job` / `cancel_job` — CI/CD
- `get_versions` (GitLab only) — MR versions for commit-discussion matching

### 4c. Review Session State Machine (`review/session.lua`)

```
IDLE (active=false)           — comments post immediately via post_comment()
REVIEWING (active=true)       — comments accumulate as drafts via create_draft_comment()
REVIEWING+AI (ai_pending=true) — same as REVIEWING, AI background jobs running
```

After `S` (submit), the state transitions to a `published` sub-state (non-active) with the event
type (`APPROVE`, `COMMENT`, `REQUEST_CHANGES`), which the sidebar status component renders as a
confirmation banner.

### 4d. AI Suggestion Object (`ai/prompt.lua`)

```lua
{ file = "path", line = 42, code = "...", severity = "info|warning|error",
  comment = "text", status = "pending|accepted|edited|dismissed", drafted = false }
```

Suggestions are placed on buffer rows using `line_data` for exact matching with a fuzzy fallback
on `code` snippet if the line number is wrong. `filter_unchanged_lines()` is applied at all three
parse sites to prevent suggestions on context lines.

---

## 5. Data Flow

### 5a. Opening a Review

```
:CodeReview
  → init.open()
    → mr_list.fetch() → providers.detect() → provider.list_reviews(client, ctx)
    → picker.pick_mr(entries, callback)
      → User selects MR
        → detail.open(entry)
          → provider.get_review() + get_discussions() + get_diffs() + get_commits()
          → (GitLab only) provider.get_versions() → state.versions
          → provider.get_last_reviewed_sha() → state.last_reviewed_sha
          → split.create() → sidebar_buf + main_buf
          → diff_state.create_state(opts) — view_mode="summary"
          → provider.get_current_user() → state.current_user
          → drafts.check_and_prompt() — resume or discard server-side drafts
          → diff.render_sidebar() + diff.render_summary()
          → diff_keymaps.setup_keymaps()
```

### 5b. Commit Filter Flow (recent feature)

```
User presses C or clicks sidebar commit entry
  → picker.commits.pick() or sidebar_callbacks commit handler
    → commit_filter.select(state, layout, entry)
      → entry.type == "commit":
          → provider.get_commit_diffs(client, ctx, sha) → commit_files[]
          → diff_render.ensure_git_objects(base_sha, sha)
          → git rev-parse sha~1 → parent_sha
          → commit_filter.apply(state, { from_sha=parent_sha, to_sha=sha, ... })
              → backup state.files → state.original_files
              → filter state.files to changed paths
              → build_version_map(state.commits, state.versions) — GitLab SHA bridging
              → filter state.discussions via matches_discussion()
                  1) direct SHA match (note.position.head_sha == to_sha)
                  2) version map match (note's head_sha ∈ versions owned by this commit)
                  3) file-path fallback (note's path ∈ commit's changed_paths_set)
              → reset current_file=1, clear all caches
          → render_sidebar() + render_current_file()
      → entry.type == "since_last_review":
          → git diff --name-only from_sha..head_sha → paths
          → commit_filter.apply(state, { from_sha, to_sha=head_sha, ... })
      → entry.type == "all" and filter active:
          → commit_filter.clear(state) → restore original files/discussions
```

### 5c. AI Review Flow

```
:CodeReviewAI or "A"
  → review.start(review, diff_state, layout)
    → start_single() if #files <= 1, else start_multi()

start_multi():
  Phase 1: Summary pre-pass (all files in one prompt, skip_agent=true)
    → prompt.build_summary_prompt() → ai_providers.get().run()
    → parse_summary_output() → { "path": "one-sentence summary" }
  Phase 2: Parallel per-file reviews (N concurrent AI processes)
    → For each file:
        → fetch_file_content() (optional, uses provider.get_file_content)
        → prompt.build_file_review_prompt(review, file, summaries, content)
        → ai_providers.get().run(prompt, callback)
        → parse_review_output() → filter_unchanged_lines() → render_file_suggestions()
        → session.ai_file_done() → spinner update
    → When all done: generate_summary_with_callbacks()
```

### 5d. Pipeline View Flow

```
:CodeReviewPipeline or "p"
  → pipeline.open(diff_state)
    → pipeline_state.create() + fetch()
        → provider.get_pipeline() → provider.get_pipeline_jobs()
        → normalize into pstate.pipeline + pstate.stages (grouped by stage name)
    → render.build_lines() → { lines, row_map }
    → Create centered float (80x70% editor)
    → keymaps.setup(): r:retry  c:cancel  p:play  o:browser  R:refresh  <CR>:log
    → <CR> on job → provider.get_job_trace()
        → log_view.open(job, trace) → ansi.parse() → display with highlights
    → If not terminal: start_polling(10s) → auto-redraw on status change
```

---

## 6. Configuration

```lua
require("codereview").setup({
  -- Platform override (auto-detected from git remote)
  base_url  = nil,       -- API base URL; alias: gitlab_url
  project   = nil,       -- "owner/repo" or "group/subgroup/project"
  platform  = nil,       -- "github" | "gitlab" | nil (auto-detect)
  github_token = nil,    -- also reads GITHUB_TOKEN env
  gitlab_token = nil,    -- also reads GITLAB_TOKEN env
  picker    = nil,       -- "telescope" | "fzf" | "snacks" | nil (auto-detect)
  debug     = false,     -- write to .codereview.log

  diff = {
    context          = 8,          -- diff context lines (0–20)
    scroll_threshold = 50,         -- auto-enable scroll mode if <= N files
    comment_width    = 80,         -- virtual line width for comment threads
    separator_char   = "╳",        -- character for hunk separator lines
    separator_lines  = 3,          -- number of separator lines between hunks
  },

  pipeline = {
    poll_interval = 10000,         -- ms between pipeline status polls
    log_max_lines = 5000,          -- truncation limit for job logs
  },

  ai = {
    enabled      = true,
    provider     = "claude_cli",   -- "claude_cli"|"anthropic"|"openai"|"ollama"|"custom_cmd"
    review_level = "info",         -- minimum severity: "info"|"suggestion"|"warning"|"error"
    max_file_size = 500,           -- skip files with > N lines in AI review

    claude_cli = {
      cmd   = "claude",
      agent = "code-review",       -- --agent flag passed to claude
    },
    anthropic = {
      api_key = nil,               -- also reads ANTHROPIC_API_KEY env
      model   = "claude-sonnet-4-20250514",
    },
    openai = {
      api_key  = nil,              -- also reads OPENAI_API_KEY env
      model    = "gpt-4o",
      base_url = nil,              -- for OpenAI-compatible endpoints
    },
    ollama = {
      model    = "llama3",
      base_url = "http://localhost:11434",
    },
    custom_cmd = {
      cmd  = nil,                  -- e.g. "my-ai-tool"
      args = {},                   -- extra args (prompt appended)
    },
  },

  keymaps = {},                    -- override any default keymap by action name
})
```

Per-project override via `.codereview.nvim` file in repo root (dotenv format):

```ini
platform = github
project  = owner/repo
base_url = https://api.github.com
token    = ghp_xxxxxxxxxxxx        # deprecated; prefer GITHUB_TOKEN env
```

---

## 7. Platform Asymmetries (Key Gotchas)

| Feature | GitLab | GitHub |
|---------|--------|--------|
| Unapprove | Yes | Returns "not supported" |
| Play manual job | Yes | Returns "not supported" |
| Draft notes API | Native (`/draft_notes` CRUD) | Emulated via PENDING review + GraphQL |
| Delete single draft | Yes (by draft ID) | No — must delete entire PENDING review |
| Discussion fetch | REST paginated | GraphQL cursor paginated (threads with resolve state) |
| Resolve discussion | REST PUT | GraphQL mutation (needs node_id) |
| MR versions (commit mapping) | `GET /versions` | No equivalent — file-path fallback only |
| PR creation draft | Title prefix `"Draft: "` | `draft: true` field |
| Merge options | squash + remove_source_branch + auto_merge | merge_method (merge/squash/rebase) |
| Module-level state | `_cached_user` | `_cached_user` + `_pending_review_id` + `_pending_review_node_id` |
| Approvals list | `approved_by[]` from API | `approved_by()` returns `{}` (not implemented) |

---

## 8. Testing

The project has ~65 spec files using Busted (Lua test framework). Coverage spans:
- Unit tests for every module: diff_parser, markdown, commit_filter, providers, etc.
- Integration tests: `github_flow_spec.lua`, `gitlab_flow_spec.lua`, `note_actions_spec.lua`
- CI via GitHub Actions with Luacheck (lint) and StyLua (format) checks

Test helper: `tests/unit_helper.lua` provides mock provider, mock client, and minimal state factories.

---

## 9. Known Pain Points and Incomplete Areas

### Hard bugs / missing features (from code + docs)

1. **No per-draft delete UI** (`draft-comments-deep-dive.md:§11.1`). Once a draft comment is
   created, the only removal is bulk-discard of all server drafts. The `x` keymap only works on
   published notes.

2. **`gR:retry` and `D:discard` footer hints are unimplemented** (`draft-comments-deep-dive.md:§11.4`).
   Failed optimistic comments show these keys in the virtual-line footer, but no callbacks
   are registered in `keymaps.lua` or `diff_keymaps.lua`.

3. **GitHub `approved_by()` returns empty** (`github.lua:699-702`). There is a TODO comment.
   GitHub PR approvals are not fetched or displayed.

4. **GitHub `_pending_review_id` is module-global** (`provider-system-deep-dive.md:§8`).
   Opening two PRs simultaneously in one Neovim session would corrupt draft state.

5. **GHE not auto-detected** (`providers/init.lua:5`). GitHub Enterprise hosts are not in
   `GITHUB_HOSTS`. Users must set `config.platform = "github"` explicitly.

6. **`reply` blocked on draft threads** (`draft-comments-deep-dive.md:§11.6`). The reply
   callback guards `not disc.is_draft` — can't reply to your own draft.

7. **Log view sections not yet implemented**. Design exists at
   `docs/plans/2026-03-03-log-sections-design.md` — GitHub `##[group]` / GitLab ANSI section
   markers are not yet parsed into collapsible sections.

8. **Review published state not yet implemented**. Design exists at
   `docs/plans/2026-02-28-review-published-state-design.md` — after submitting, there's no
   sidebar confirmation.

9. **Open MR editor not yet enhanced**. Design exists at
   `docs/plans/2026-03-01-open-mr-refinement-design.md` — structured header+body layout,
   auto-push, draft toggle.

### Architectural debt

10. **No formal provider interface** — adding a third provider (Bitbucket, Azure DevOps) requires
    copying ~30 functions. Runtime errors if any method is missing.

11. **`review/drafts.lua` explicitly checks `provider.name`** — the only name-check in the
    otherwise duck-typed system. An architectural violation, noted in provider-system-deep-dive.md.

12. **`diff_keymaps.lua` dual scroll/per-file branching** ~15 times. Primary source of logic
    duplication remaining after the great diff.lua decomposition.

13. **Markdown renderer has no incremental update** — the full `render_summary()` rerenders the
    entire buffer on every discussion refresh.

---

## 10. Recent Development (Last 30 Commits)

Focus areas in chronological order (newest last):

| Date range | Work |
|------------|------|
| Early Feb 2026 | Draft comment deletion (`delete_draft` for draft comments) |
| Mid Feb 2026 | Large diff.lua decomposition into 9 focused modules |
| Late Feb 2026 | Per-commit review (commit picker, filter layer, sidebar commits component) |
| Late Feb 2026 | MR versions for GitLab commit→discussion matching (`get_versions`, `build_version_map`) |
| Late Feb 2026 | File-path fallback in `matches_discussion` for GitHub |
| Early Mar 2026 | Linting/formatting CI (Luacheck + StyLua + pre-commit hook) |
| Early Mar 2026 | Pipeline log sections design (not yet implemented) |
| 2026-03-04 (latest) | GitHub step section markers injected from job metadata (foldable log prep) |

The most recent commit (`301cf05`) injects GitHub Actions step names as `##[group]` markers into
job logs from the metadata endpoint, setting up the infrastructure for the log-section folding
feature planned in `2026-03-03-log-sections-design.md`.

---

## 11. Feature Brainstorming: Opportunity Map

Based on the codebase analysis, here are the logical next areas to explore:

### Short-term (polish / fill gaps)

- **Log section folding** — parsing `##[group]` and GitLab ANSI section markers into collapsible
  folds. Infrastructure (marker injection) is now in place. Design doc exists.
- **Review published state** — sidebar confirmation after `S` submit. Design doc + affected files
  already identified.
- **Per-draft delete** — allow `x` to delete an individual draft comment. Requires storing
  `server_draft_id` on the local draft object after API response, and a separate delete path in the
  `x` keymap callback.
- **GitHub approvals** — implement `approved_by()` in `github.lua` (currently returns `{}`).
  Fetch from `GET /pulls/:id/reviews`, aggregate "APPROVED" events by user.
- **Retry/discard failed comments** — wire the `gR` and `D` keymaps shown in the virtual-line
  footer but currently unimplemented.

### Medium-term (UX improvements)

- **Enhanced MR creation editor** — structured header+body float with auto-push and draft toggle.
  Design doc exists at `2026-03-01-open-mr-refinement-design.md`.
- **Outdated comment rendering** — GitLab sends `change_position` for outdated notes. GitHub marks
  threads with `isOutdated`. Currently these render with the same style as current threads.
  Visual differentiation (dimmed color, "outdated" badge) would help.
- **Comment search / filter** — extend the `<leader>fc` comments picker to filter by author,
  resolved status, or file. Currently returns all comments unsorted.
- **Diff word-wrap toggle** — sidebar/summary already uses wrap=true. A toggle for diff lines
  (long generated code lines) could be useful.
- **Multi-MR support** — currently only one MR can be open at a time (`diff.close_active()`).
  Tab-based or named-session support would allow parallel reviews.

### Longer-term (new capabilities)

- **LSP on diff content** — shadow buffer approach: create hidden buffer per file with full content
  from `git show head_sha:path`, set filetype, let LSP attach, proxy hover/diagnostics to diff
  rows via `line_data` mapping. The `line_data` array already provides the row↔line-number bridge.
- **Bitbucket or Azure DevOps provider** — minimum viable provider is 6 read-only methods.
  Provider registration is trivial (one `elseif` in `providers/init.lua`).
- **PR/MR templates** — when creating a MR, auto-fill the description from `.github/PULL_REQUEST_TEMPLATE.md`
  or GitLab's MR description templates.
- **Review checklist / audit trail** — track which hunks were scrolled (already done via
  `review_tracker.lua`) and optionally export the `○/◑/●` status as a JSON file for audit.
- **Suggestion grouping** — group AI suggestions by severity in the virtual-line display, or allow
  filtering the diff view to only show files with AI suggestions.
- **Webhook / real-time updates** — poll for new comments on a timer (distinct from pipeline
  polling) and show a notification when someone replies to a thread while you are reviewing.

---

## 12. Existing Documentation Index

| File | Contents |
|------|---------|
| `docs/architecture/codereview-nvim.md` | Main architecture reference (updated 2026-03-01) |
| `docs/architecture/diff-view-deep-dive.md` | Buffer internals, extmarks, LSP incompatibility |
| `docs/architecture/draft-comments-deep-dive.md` | Full draft lifecycle, gotchas |
| `docs/architecture/provider-system-deep-dive.md` | Provider interface catalog, auth, HTTP client |
| `docs/architecture/commit-filter-deep-dive.md` | Commit filter layer (if exists) |
| `docs/architecture/sidebar-deep-dive.md` | Sidebar composition and component API |
| `docs/architecture/refactoring-analysis.md` | Ranked refactoring targets (pre-decomposition) |
| `docs/architecture/mock-provider-guide.md` | How to add a new provider |
| `docs/plans/` | ~45 dated design + plan files (2026-02-24 through 2026-03-03) |
