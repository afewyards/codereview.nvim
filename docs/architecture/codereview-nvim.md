# codereview.nvim Architecture

Generated 2026-02-25. Updated 2026-03-01 to reflect post-decomposition module structure (~60 Lua source files).

## Overview

codereview.nvim is a Neovim plugin for reviewing merge requests (GitLab) and pull requests (GitHub) entirely inside the editor. It provides a split-pane UI with a sidebar file tree and a main pane that renders unified diffs with inline comment threads, AI-generated review suggestions, and full markdown rendering. The plugin supports two view modes (summary and diff), two diff display modes (per-file and all-files scroll), a review session system for batching draft comments, and an AI review pipeline that spawns configurable AI backends. A pipeline view shows CI/CD job status with retry/cancel/play controls. The large monolithic `mr/diff.lua` has been decomposed into ~9 focused modules.

## Structure

```
plugin/
  codereview.lua              # Vim command definitions (10 user commands)

lua/codereview/
  init.lua                    # Plugin entry point: setup(), open(), ai_review(), ai_review_file(), submit(), etc.
  config.lua                  # Configuration: defaults, deep_merge, validation
  keymaps.lua                 # Keymap registry: defaults table, apply() to buffers
  git.lua                     # Git helpers: parse_remote(), get_remote_url(), get_repo_root()
  log.lua                     # Debug logger: writes to .codereview.log when config.debug=true

  api/
    client.lua                # HTTP client: wraps plenary.curl, sync+async, pagination (301 lines)
    auth.lua                  # Token resolution: env vars -> .codereview.nvim file -> config (119 lines)

  providers/
    init.lua                  # Platform detection: git remote -> gitlab/github (50 lines)
    types.lua                 # Normalization: normalize_review, normalize_note, normalize_discussion (56 lines)
    gitlab.lua                # GitLab API: 29 functions, MR CRUD, discussions, drafts (435 lines)
    github.lua                # GitHub API: 29 functions, PR CRUD, reviews, GraphQL for node IDs (644 lines)

  mr/
    list.lua                  # MR listing: fetch + format entries for picker
    detail.lua                # MR detail/summary view: header, activity, draft resume
    diff.lua                  # Thin orchestrator: delegates to diff_state/render/sidebar/nav/keymaps
    diff_state.lua            # State factory (create_state) + mutation helpers (apply_scroll_result, etc.)
    diff_render.lua           # Buffer rendering: set_lines, extmarks, highlights, sign placement
    diff_sidebar.lua          # Thin wrapper: render_sidebar() delegates to sidebar_layout; render_summary()
    diff_keymaps.lua          # All keymaps, autocmds, callback closures for the diff layout
    diff_nav.lua              # Navigation: nav_file, switch_to_file, jump_to_file/comment, toggle_scroll_mode
    diff_comments.lua         # Comment helpers: build_row_items, cycle_row_selection, create_comment_at_cursor
    diff_parser.lua           # Unified diff parser: parse_hunks, build_display, word_diff
    sidebar_layout.lua        # Sidebar orchestrator: composes 5 components, normalises highlights
    sidebar_help.lua          # Sidebar help text builder
    sidebar_components/
      header.lua              # Review ID + title + pipeline + branch line
      status.lua              # Session status block (AI progress, draft counts, thread counts)
      summary_button.lua      # "ℹ Summary" navigation row
      file_tree.lua           # Directory-grouped file list with review-status icons and badge counts
      footer.lua              # Dynamic keymap footer (context-sensitive by view_mode and session)
    comment.lua               # Comment creation: floating input popup, inline/range/draft variants
    comment_float.lua         # Low-level float window for comment input
    thread_virt_lines.lua     # Comment thread rendering as virtual lines
    review_tracker.lua        # Hunk-based review progress: init_file(), mark_visible() → unvisited/partial/reviewed
    actions.lua               # MR actions: approve, unapprove, merge, close
    create.lua                # MR creation: ensure_pushed, fetch_remote_branches, open_editor, submit_mr
    merge_float.lua           # Merge confirmation float: checkbox/cycle items, platform-specific options
    submit_float.lua          # Submit review float: Comment/Approve/Request Changes with AI summary

  review/
    init.lua                  # AI review: start_single(), start_multi(), start_file() (M.start dispatches)
    session.lua               # Review session state machine: active/ai_pending/idle
    submit.lua                # Draft submission: filter_accepted, submit_review, bulk_publish
    drafts.lua                # Server-side draft detection: fetch, discard, check_and_prompt

  ui/
    split.lua                 # Layout: creates sidebar+main split pane (80 lines)
    highlight.lua             # Highlight group definitions (~200 lines)
    markdown.lua              # Markdown parser: inline formatting, tables, code blocks (867 lines)
    inline_float.lua          # Floating window helpers: reserve_space, highlight_lines (~120 lines)
    spinner.lua               # AI progress spinner in top-right corner (80 lines)

  picker/
    init.lua                  # Picker abstraction: detect telescope/fzf-lua/snacks; also pick_branches
    telescope.lua             # Telescope adapter
    fzf.lua                   # fzf-lua adapter
    snacks.lua                # snacks.nvim adapter
    comments.lua              # Comment/suggestion picker: build entries, navigate
    files.lua                 # File picker: build entries with counts, navigate

  pipeline/
    init.lua                  # Pipeline float: open(), close(), polling, job controls
    state.lua                 # Pipeline state: create(), fetch(), start_polling(), stop_polling()
    render.lua                # Build display lines for pipeline stages and jobs; row_map
    keymaps.lua               # Pipeline float keymaps: toggle/retry/cancel/play/browser/close
    log_view.lua              # Job log float: open(), close(), ANSI stripping
    ansi.lua                  # ANSI escape code stripping for log output
```

## Key Abstractions

### State Object (`mr/diff_state.lua:18-57`)

The central data structure. A plain table with 25+ mutable fields, created by `diff_state.create_state(opts)` -- the single canonical factory as of the decomposition. Threaded through nearly every function in the diff subsystem.

Key fields:

- `view_mode` ("summary" | "diff") -- which pane content is shown
- `review` -- normalized review/PR object from provider
- `provider`, `ctx` -- detected platform provider module and context (base_url, project)
- `files` -- array of normalized file diffs
- `discussions` -- array of normalized discussion threads (comments)
- `current_file` -- 1-indexed index into `files`
- `scroll_mode` -- boolean, true = all-files view, false = per-file view
- `line_data_cache`, `row_disc_cache`, `row_ai_cache` -- per-file rendering caches
- `scroll_line_data`, `scroll_row_disc`, `scroll_row_ai` -- scroll-mode rendering data
- `file_sections` -- in scroll mode, maps file ranges to buffer rows
- `ai_suggestions` -- array of AI suggestion objects (from review/init.lua)
- `ai_summary_pending` -- boolean, true while AI summary is generating
- `ai_summary_callbacks` -- callbacks to fire when summary generation completes
- `ai_review_summary` -- cached AI summary string
- `row_selection` -- tracks which comment/suggestion is "selected" at the cursor row
- `local_drafts` -- array of locally-created draft discussions
- `context` -- number of diff context lines (default 8)
- `current_user` -- username string for edit/delete permission checks
- `git_diff_cache` -- keyed by `"path:base_sha..head_sha"`, avoids repeat git calls
- `file_review_status` -- `{ [path] = { hunks_total, hunks_seen, status } }` from review_tracker
- `sidebar_component_ranges` -- maps component names to `{ start, end }` line ranges
- `collapsed_dirs` -- `{[dir_path]=true}` tracks which directory groups are collapsed
- `sidebar_row_map`, `summary_row_map` -- buffer-row-to-semantic-entry maps

### Provider Interface (`providers/gitlab.lua`, `providers/github.lua`)

Both providers export the same set of ~20 functions. No formal interface definition exists -- it is convention-based. Key methods:

| Method | Purpose |
|--------|---------|
| `list_reviews(client, ctx, opts)` | List open MRs/PRs |
| `get_review(client, ctx, id)` | Fetch single MR/PR with details |
| `get_diffs(client, ctx, review)` | Fetch file diffs |
| `get_discussions(client, ctx, review)` | Fetch comment threads |
| `post_comment(client, ctx, review, opts)` | Post inline comment |
| `post_range_comment(client, ctx, review, opts)` | Post range comment |
| `reply_to_discussion(client, ctx, review, disc_id, body)` | Reply to thread |
| `create_draft_comment(client, ctx, review, opts)` | Create draft (review session) |
| `publish_review(client, ctx, review)` | Publish accumulated drafts |
| `get_current_user(client, ctx)` | Get authenticated username |
| `approve/unapprove/merge/close` | MR/PR actions |
| `get_draft_notes` / `get_pending_review_drafts` | Resume server-side drafts |

All methods take `(client, ctx, ...)` where `client` is `api/client.lua` and `ctx` is `{ base_url, project, host, platform }`.

### Review Session (`review/session.lua`)

State machine with three states:

```
IDLE (active=false)                     -- comments post immediately to API
REVIEWING (active=true, ai_pending=false) -- comments accumulate as local drafts
REVIEWING+AI (active=true, ai_pending=true) -- AI subprocess running in background
```

Session is a singleton module-level `_state` table. `start()` enters review mode, `ai_start(job_ids)` records AI jobs, `ai_file_done()` tracks completion, `stop()` exits and clears.

### Normalized Data Types (`providers/types.lua`)

- **Review**: `{ id, title, author, source_branch, target_branch, state, base_sha, head_sha, start_sha, web_url, description, pipeline_status, approved_by, approvals_required, sha, merge_status }`
- **Discussion**: `{ id, resolved, notes = [Note, ...] }`
- **Note**: `{ id, author, body, created_at, system, resolvable, resolved, resolved_by, position }`
- **Position**: `{ new_path, old_path, new_line, old_line }` (normalized from GitLab/GitHub shapes)
- **FileDiff**: `{ diff, new_path, old_path, renamed_file, new_file, deleted_file }`
- **Pipeline**: `{ id, status, ref, sha, web_url, created_at, updated_at, duration }`
- **PipelineJob**: `{ id, name, stage, status, duration, web_url, allow_failure, started_at, finished_at }`

### AI Suggestion Object (produced by `ai/prompt.lua:159-176`)

```lua
{ file = "path", line = 42, code = "...", severity = "warning", comment = "text", status = "pending" }
```

Status transitions: `"pending"` -> `"accepted"` | `"edited"` | `"dismissed"`. The `drafted` flag marks suggestions already posted to the server.

## Data Flow

### 1. Opening a Review (main flow)

```
User: :CodeReview
  -> init.open() (init.lua:14)
    -> mr/list.fetch() -> providers.detect() -> provider.list_reviews(client, ctx)
      -> API call via api/client.lua -> plenary.curl
    -> picker.pick_mr(entries, callback)  -- telescope/fzf-lua/snacks
      -> User selects MR
        -> detail.open(entry) (detail.lua)
          -> provider.get_review()         -- fetch full MR details
          -> provider.get_discussions()    -- fetch comment threads
          -> provider.get_diffs()          -- fetch file diffs (lazy: may be deferred)
          -> split.create()                -- sidebar+main layout
          -> diff_state.create_state(opts) -- canonical factory, view_mode="summary"
          -> diff.render_sidebar()         -- delegates to sidebar_layout.render()
          -> diff.render_summary()         -- header + activity threads
          -> diff.setup_keymaps()          -- delegates to diff_keymaps.setup_keymaps()
          -> provider.get_current_user()   -- populate state.current_user
          -> drafts.check_and_prompt()     -- resume server-side drafts
```

### 2. Viewing a Diff (per-file mode)

From summary view, user presses `<CR>` on a file in the sidebar or navigates via `]f`/`[f`:

```
sidebar <CR> or ]f/[f
  -> nav_file(layout, state, direction) (diff.lua ~line 1570)
    -> diff.render_file_diff(buf, file_diff, review, discussions, ...) (diff.lua:432)
      -> git diff -U{context} base_sha..head_sha -- path  (local git for more context)
      -> diff_parser.parse_hunks(diff_text)
      -> diff_parser.build_display(hunks)
      -> Write lines to buffer
      -> Apply line highlights (add=green, delete=red, word-diff)
      -> place_comment_signs() -> thread_virt_lines.build() -> extmarks
      -> place_ai_suggestions() -> render_ai_suggestions_at_row() -> extmarks
    -> Returns: line_data, row_discussions, row_ai
    -> Cached in state.line_data_cache[file_idx], etc.
```

### 3. Viewing a Diff (all-files scroll mode)

When `#files <= scroll_threshold` (default 50), or toggled with `<C-a>`:

```
diff.render_all_files(buf, files, review, discussions, ...) (diff.lua:572)
  -> For each file:
    -> Render file header separator ("--- path ---")
    -> Parse hunks, build display (same as per-file)
    -> Track file_sections with start_line/end_line ranges
  -> Set all lines at once into buffer
  -> Apply highlights across all files
  -> Place comment signs and AI suggestions across all sections
  -> Returns: { file_sections, line_data, row_discussions, row_ai }
  -> Stored in state.scroll_line_data, state.scroll_row_disc, etc.
```

### 4. AI Review Flow

Three entry points dispatch to three functions in `review/init.lua`:

```
:CodeReviewAI / "A" keymap
  -> M.start(review, diff_state, layout)
    -> If #files == 1: start_single()
    -> If #files > 1:  start_multi()

:CodeReviewAIFile
  -> M.start_file(review, diff_state, layout)
    -> Reviews only diff_state.files[current_file]
```

**Single-file review** (`review/init.lua:99-141`):
```
start_single():
  -> prompt.build_review_prompt(review, diffs)      -- all diffs in one prompt
  -> ai_providers.get().run(prompt, callback)
      Spawns configured provider (default: claude -p --agent code-review)
  -> On completion:
      -> prompt.parse_review_output(output)
          Extracts ```json block, decodes, validates fields
          Returns array of {file, line, code, severity, comment, status="pending"}
      -> prompt.filter_unchanged_lines(suggestions, diffs) -- removes hallucinated lines
      -> render_file_suggestions(diff_state, layout, suggestions)
          Merges into state.ai_suggestions; re-renders current view
      -> generate_summary_with_callbacks(diff_state, review, diffs)
          Sets ai_summary_pending=true; runs summary prompt; fires ai_summary_callbacks
```

**Multi-file review** (`review/init.lua:143-232`):
```
start_multi():
  Phase 1: Summary pre-pass (skip_agent=true, no --agent flag)
    -> prompt.build_summary_prompt(review, diffs)
    -> ai_providers.get().run(prompt, callback, { skip_agent = true })
    -> parse_summary_output() -> { "path": "one-sentence summary", ... }

  Phase 2: Parallel per-file reviews
    -> For each file:
        -> fetch_file_content() -- optional full file via provider.get_file_content()
        -> prompt.build_file_review_prompt(review, file, summaries, content)
        -> ai_providers.get().run(file_prompt, callback)  -- N parallel AI processes
        -> On each completion:
            -> parse_review_output() + filter_unchanged_lines()
            -> render_file_suggestions() -- incremental updates
            -> session.ai_file_done() -- progress tracking
            -> spinner.set_label(" AI reviewing… 3/8 files ")
    -> When all files done:
        -> generate_summary_with_callbacks()
```

**Single-file AI review** (`review/init.lua:235-305`):
```
start_file():
  Phase 1: Summary pre-pass (same as start_multi phase 1)
    -> build_summary_prompt + run (skip_agent=true)
    -> parse_summary_output()
  Phase 2: Review only the current file (one AI call)
    -> build_file_review_prompt(review, target_file, summaries, content)
    -> parse_review_output() + filter_unchanged_lines()
    -> Replaces only this file's suggestions (preserves others)
    -> render_file_suggestions()
    -> generate_summary_with_callbacks()
```

### 5. Comment Creation Flow

```
User presses "cc" on a diff line:
  -> main_callbacks.create_comment (diff.lua ~line 1981)
    -> If session active (draft mode):
        -> comment.create_inline_draft(review, path, line, on_draft, popup_opts)
          -> comment.open_input_popup("Comment", callback, opts)
            -> Creates float buffer (markdown mode)
            -> inline_float.reserve_space() on diff buffer
            -> On submit (<C-Enter>):
                -> on_draft(text) -- adds to state.local_drafts
                -> provider.create_draft_comment() -- posts to server
    -> If session inactive (immediate mode):
        -> comment.create_inline(review, old_path, new_path, old_line, new_line, callbacks, opts)
          -> open_input_popup() ...
            -> On submit:
                -> callbacks.add() -- optimistic local discussion
                -> provider.post_comment() -- async API call
                -> On success: callbacks.refresh() -- re-fetch discussions
                -> On failure: callbacks.mark_failed()
```

### 6. Pipeline View Flow

```
User: :CodeReviewPipeline or "p" keymap
  -> init.pipeline() (init.lua:36)
    -> pipeline.open(diff_state) (pipeline/init.lua:15)
      -> pipeline_state.create({ review, provider, client, ctx })
      -> pipeline_state.fetch(pstate)
          -> provider.get_pipelines() + provider.get_pipeline_jobs()
          -> Normalizes into pstate.pipeline (normalize_pipeline) + pstate.stages (grouped jobs)
      -> render.build_lines(pipeline, stages, collapsed)
          -> Returns { lines, row_map }  row_map[row] = { job?, stage? }
      -> Create float (centered, 80x70% editor size)
      -> keymaps.setup(buf, pstate, handle, callbacks)
          -> r: retry job  c: cancel job  p: play job  o: browser  R: refresh
          -> <CR>/<Space>: toggle stage collapse / open log view
      -> If pipeline is not terminal: pipeline_state.start_polling(10s, redraw)
```

### 7. Merge Float Flow

```
User presses "m" from summary view:
  -> diff_keymaps merge callback (diff_keymaps.lua:839)
    -> providers.detect() -- get ctx.platform
    -> merge_float.open(review, ctx.platform) (merge_float.lua:79)
      -> build_items(platform)
          GitLab: [squash checkbox, remove_source_branch checkbox, auto_merge checkbox]
          GitHub:  [merge_method cycle (merge/squash/rebase), remove_source_branch checkbox]
      -> Create centered float (40 wide, items+4 tall)
      -> Keymaps: j/k navigate, <Space> toggle checkbox, <Tab>/<S-Tab> cycle method, <CR> confirm
      -> On confirm: collect_opts(items) -> actions.merge(review, opts)
```

### 8. Submit / Publish Flow

```
User: :CodeReviewSubmit or "S" keymap
  -> init.submit() (init.lua:48)
    -> submit.submit_and_publish(review, ai_suggestions) (review/submit.lua:57)
      -> filter_accepted(suggestions) -- only status=accepted|edited, not yet drafted
      -> For each: provider.create_draft_comment()
      -> submit.bulk_publish(review) -> provider.publish_review()
    -> session.stop()
```

## Patterns

### Virtual Lines for Inline Content

Comment threads and AI suggestions are rendered as Neovim virtual lines (`nvim_buf_set_extmark` with `virt_lines`), not actual buffer lines. This allows them to appear below diff lines without disrupting line numbering. Each virtual line is an array of `{text, highlight_group}` chunks.

- **Comment threads**: Built by `thread_virt_lines.build()` (thread_virt_lines.lua:88). Renders header (author, time, resolve status), body (with markdown inline formatting), replies, and footer (keybind hints). Uses box-drawing characters for visual structure.
- **AI suggestions**: Built by `render_ai_suggestions_at_row()` (diff.lua:212). Similar card structure with severity-based coloring (info=dashed, error=solid borders).
- **Selection indicator**: When a comment/suggestion is "selected" (cursor on its row), a `"XX"` block prefix is prepended in the status highlight color, and a footer with action keybinds appears.

### Row Maps and Line Data

The diff renderer produces parallel arrays:
- `line_data[row]` -- maps buffer row to `{ type, item }` where item has `old_line`, `new_line`, `text`
- `row_discussions[row]` -- maps buffer row to array of discussions at that line
- `row_ai[row]` -- maps buffer row to array of AI suggestions at that line
- `sidebar_row_map[row]` -- maps sidebar row to `{ type, file_idx }` or `{ type, action }`
- `summary_row_map[row]` -- maps summary row to `{ type, discussion }`

These maps are the bridge between buffer coordinates and semantic data.

### Optimistic Updates

When posting a comment outside review session (immediate mode), the plugin adds an "optimistic" discussion to `state.discussions` immediately (with `is_optimistic = true`), re-renders the view, then makes the API call asynchronously. On success, it re-fetches discussions. On failure, it marks the discussion as `is_failed = true` with retry/discard options.

### Dual View Mode Branching

Nearly every action in `setup_keymaps` branches on `state.scroll_mode`:
```lua
if state.scroll_mode then
  -- use state.scroll_line_data, state.scroll_row_disc, etc.
else
  -- use state.line_data_cache[state.current_file], etc.
end
```
This pattern appears ~15 times and is the primary source of code duplication in diff.lua.

### Provider Detection

`providers/init.lua:detect()` resolves the platform once per operation:
1. Check `config.base_url` + `config.project` (explicit config)
2. Otherwise: `git remote get-url origin` -> `git.parse_remote()` -> host
3. `detect_platform(host)`: github.com = "github", everything else = "gitlab"
4. Load provider module, build context `{ base_url, project, host, platform }`

### Picker Abstraction

`picker/init.lua` auto-detects the available fuzzy finder (telescope -> fzf-lua -> snacks) and delegates to the matching adapter. Each adapter implements `pick_mr()`, `pick_comments()`, `pick_files()`.

### AI Prompt Construction

`ai/prompt.lua` builds structured prompts with:
1. MR title and description as context
2. Annotated diffs with L-prefixed line numbers (e.g., `L38: +  local x = 1`)
3. Explicit JSON output format instructions
4. In multi-file mode: other-file summaries for cross-file awareness

The L-prefix annotation (`annotate_diff_with_lines`, prompt.lua:12) adds `L{n}: ` before each diff line so the AI can reference exact line numbers. This is critical for placing suggestions on the correct buffer line.

### Hunk-Based Review Progress Tracking

`review_tracker.lua` provides two functions:
- `init_file(path, line_data, file_idx?)` -- scans `line_data` for `hunk_idx` transitions to build `hunk_rows` (a map from buffer row to hunk_idx for hunk-start rows)
- `mark_visible(file_status, top_row, bot_row)` -- marks any hunk whose start row falls in the visible range as seen; recomputes `status` as `"reviewed"` / `"partial"` / `"unvisited"`

The tracker is driven by a `CursorMoved` autocmd in `diff_keymaps.lua`. It stores results in `state.file_review_status[path]`. The `file_tree.lua` sidebar component reads this to show `○/◑/●` review status icons.

### diff.lua Thin-Orchestrator Pattern

After the decomposition, `mr/diff.lua` (145 lines) is a re-export facade:
```lua
M.render_sidebar    = diff_sidebar.render_sidebar
M.render_summary    = diff_sidebar.render_summary
M.render_file_diff  = diff_render.render_file_diff
M.render_all_files  = diff_render.render_all_files
M.jump_to_file      = diff_nav.jump_to_file
M.jump_to_comment   = diff_nav.jump_to_comment
-- etc.
```
External callers (`init.lua`, `review/init.lua`, `picker/*.lua`) all `require("codereview.mr.diff")` and get a stable interface even as internal modules have been moved.

### Code Snippet Fuzzy Matching

When placing AI suggestions on buffer rows, `place_ai_suggestions()` (diff.lua:311) does:
1. Match by `suggestion.line == data.item.new_line` (exact line number)
2. If `suggestion.code` is present, verify the matched line contains that code
3. If verification fails, search all lines for the code snippet (fuzzy fallback)

This two-pass approach compensates for AI line number hallucinations.

## Dependencies

- **plenary.nvim** -- HTTP client (plenary.curl), async utilities, required
- **telescope.nvim** / **fzf-lua** / **snacks.nvim** -- Fuzzy finder, at least one required for MR selection
- **Claude CLI** (`claude`) -- External binary for AI reviews, optional

## User Commands

| Command | Action | Entry Point |
|---------|--------|-------------|
| `:CodeReview` | Open MR/PR picker, select, show detail | `init.open()` |
| `:CodeReviewAI` | Run AI review on all files | `init.ai_review()` |
| `:CodeReviewAIFile` | Run AI review on current file only | `init.ai_review_file()` |
| `:CodeReviewSubmit` | Publish drafts + accepted AI suggestions | `init.submit()` |
| `:CodeReviewApprove` | Approve current MR/PR | `init.approve()` |
| `:CodeReviewOpen` | Create new MR/PR from current branch | `init.create_mr()` |
| `:CodeReviewStart` | Start manual review session (drafts mode) | `init.start_review()` |
| `:CodeReviewComments` | Fuzzy-pick comments/suggestions | `init.comments()` |
| `:CodeReviewFiles` | Fuzzy-pick changed files | `init.files()` |
| `:CodeReviewPipeline` | Show CI/CD pipeline float for current MR | `init.pipeline()` |

## Default Keymaps (`keymaps.lua:3-32`)

### Navigation
| Key | Action | Mode |
|-----|--------|------|
| `]f` / `[f` | Next/prev file | n |
| `<Tab>` / `<S-Tab>` | Select next/prev note (comment or AI suggestion) | n |
| `<C-a>` | Toggle scroll/per-file view mode | n |
| `<C-f>` | Toggle full file view (expand context to entire file) | n |
| `+` / `-` | Increase/decrease diff context lines | n |

### Comments
| Key | Action | Mode |
|-----|--------|------|
| `cc` | Create new comment at cursor | n |
| `cc` | Create range comment on selection | v |
| `r` | Reply to selected thread | n |
| `gt` | Toggle resolve/unresolve on thread | n |
| `e` | Edit selected note (own notes only) | n |
| `x` | Delete selected note (own notes only) | n |

### AI Suggestions
| Key | Action | Mode |
|-----|--------|------|
| `a` | Accept AI suggestion | n |
| `x` | Dismiss AI suggestion | n |
| `e` | Edit AI suggestion | n |
| `ds` | Dismiss all suggestions | n |
| `A` | Start/cancel AI review | n |

### Actions
| Key | Action | Mode |
|-----|--------|------|
| `S` | Submit/publish drafts | n |
| `a` | Approve MR/PR (summary view) | n |
| `o` | Open in browser | n |
| `m` | Merge | n |
| `R` | Refresh (re-fetch from API) | n |
| `Q` | Quit review | n |
| `<leader>fc` | Fuzzy-pick comments | n |
| `<leader>ff` | Fuzzy-pick files | n |

Note: `a` and `x` are context-dependent -- they map to approve/accept/dismiss depending on whether the cursor is on a summary view, an AI suggestion, or a comment note.

## View Modes

### Summary View (`state.view_mode == "summary"`)

Rendered by `diff_sidebar.render_summary()` (called via `diff.render_summary()`). Shows:
- MR header (title, author, branch, pipeline status, approvals) via `detail.build_header_lines()`
- MR description (rendered via markdown parser)
- Activity section: non-inline discussion threads with full markdown rendering via `detail.build_activity_lines()`
- Treesitter syntax highlighting on code blocks within comments

### Diff View (`state.view_mode == "diff"`)

Two sub-modes controlled by `state.scroll_mode`:

**Per-file mode** (`scroll_mode = false`): Shows one file at a time. Navigation with `]f`/`[f`. Rendered by `diff_render.render_file_diff()`. Includes "load more context" buttons at top/bottom.

**All-files scroll mode** (`scroll_mode = true`): Shows all files concatenated with file header separators. Auto-enabled when `#files <= scroll_threshold` (default 50). Rendered by `diff_render.render_all_files()`. Sidebar highlights current file as cursor moves.

### Sidebar

Rendered by `sidebar_layout.render()` (called via `diff.render_sidebar()`). Shows:
- Header: review ID, title, pipeline icon, source branch
- Status block (when session active): AI progress, draft count, thread count
- Summary button navigation row
- File tree with directory grouping, collapse/expand, review-progress icons (`○/◑/●`), and badge counts
- Dynamic keymap footer based on current view mode and session state

## Gotchas

1. **State constructed in two places**: `diff.open()` and `detail.open()` both call `diff_state.create_state()` now that the factory is centralized, but they still pass different initial `view_mode` values (`"diff"` vs `"summary"`). They can still drift on optional fields if `create_state` opts are not kept aligned.

2. **diff.lua is now a thin orchestrator**: The 3112-line god module has been decomposed. `mr/diff.lua` (145 lines) just re-exports symbols from `diff_state`, `diff_render`, `diff_sidebar`, `diff_nav`, and `diff_comments`. The setup logic for keymaps is in `diff_keymaps.lua`.

3. **No formal provider interface**: Both providers implement the same ~20 methods by convention. Adding a third provider requires copying the full structure. The `get_headers()` + error guard pattern repeats 41 times across both files.

4. **Module-level mutable state in GitHub provider**: `_pending_review_id`, `_pending_review_node_id`, `_cached_user` (github.lua) mean concurrent reviews could cause silent bugs.

5. **AI provider is configurable**: `ai/providers/init.lua` selects among `anthropic`, `openai`, `ollama`, `claude_cli`, and `custom_cmd`. The default remains `claude_cli` (spawns `claude -p`). In multi-file mode, N parallel jobs are spawned regardless of provider.

6. **Diff context comes from local git + SHA fetch**: `diff_render.ensure_git_objects()` (diff_render.lua:31-36) runs `git fetch origin base_sha head_sha` once per unique SHA pair to ensure local availability, then runs `git diff -U{context} base..head -- path`. A `git_diff_cache` keyed by `path:shas` avoids re-running on the same file.

7. **Single-file AI review mode is now a first-class command**: `:CodeReviewAIFile` (`init.ai_review_file()`) calls `review.start_file()` which does a summary pre-pass on all files, then reviews only the currently-selected file. This is distinct from the old behaviour where `start_single()` only applied when `#files <= 1`.

8. **Hunk-based review tracking**: `review_tracker.lua` tracks which diff hunks have been scrolled past per file, updating `state.file_review_status[path].status` to `"unvisited"`, `"partial"`, or `"reviewed"`. The `file_tree.lua` component renders `○`, `◑`, `●` icons accordingly. The tracker is driven by `CursorMoved` autocmds in `diff_keymaps.lua`.

9. **Sidebar decomposed into 5 components**: `sidebar_layout.lua` composes `header`, `status`, `summary_button`, `file_tree`, and `footer` components. Each has a slightly different API (some return `{lines, highlights, row_map}`, some mutate passed arrays). `sidebar_layout.lua` normalizes the two highlight formats into a unified `{row0, line_hl?, word_hl?, hl_group?, col_start?, col_end?}` shape before applying.

10. **merge_float is platform-aware**: `merge_float.build_items("github")` returns a `cycle` item for merge method (merge/squash/rebase) that GitLab does not have. `<Tab>`/`<S-Tab>` cycle the method value; `<Space>` toggles checkboxes. The float is only accessible from the summary view (`state.view_mode == "summary"` guard in the `merge` callback).

11. **Pipeline polling uses a timer**: `pipeline_state.start_polling()` sets a `vim.fn.timer_start` repeating at `cfg.pipeline.poll_interval` (default 10000ms). It stops automatically when `pipeline_state.is_terminal(status)` returns true or when the float is closed.
