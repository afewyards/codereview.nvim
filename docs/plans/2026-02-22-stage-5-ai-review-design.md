# Stage 5: AI Review + MR Creation — Design

**Goal:** Claude CLI reviews MR diffs, user triages suggestions (accept/edit/delete), accepted suggestions posted as platform-specific draft comments and published in bulk. Also: create new MRs with Claude-drafted titles and descriptions.

**Depends on:** Stages 1–3 (providers, UI, diff renderer)

---

## Module Layout

```
lua/codereview/
├── ai/
│   ├── subprocess.lua    # Claude CLI runner (stdin pipe via jobstart)
│   └── prompt.lua        # Prompt builders (review + MR creation)
├── review/
│   ├── init.lua          # Orchestrator: fetch data → run AI → open triage
│   ├── triage.lua        # Triage UI (split layout + diff + suggestion sidebar)
│   └── submit.lua        # Filter accepted → provider draft → publish
└── mr/
    └── create.lua        # MR creation (Claude draft → edit buffer → submit)
```

Provider additions (new methods on gitlab.lua + github.lua):
- `create_draft_comment(client, ctx, review, params)`
- `publish_review(client, ctx, review)`
- `create_review(client, ctx, params)`

---

## AI Subprocess (`ai/subprocess.lua`)

Single function: `run(prompt, callback)`.

Pipes prompt to `claude -p` via stdin using `vim.fn.jobstart` + `chansend`. No temp files.

```
cmd: {config.ai.claude_cmd, "-p", "--output-format", "json", "--max-turns", "1"}
stdin: prompt string via chansend(), then chanclose()
stdout_buffered: true
on_stdout: callback(output)
on_exit: callback(nil, error) on non-zero exit
```

Config: `config.ai = { enabled = true, claude_cmd = "claude" }` (already exists).

## Prompt Builders (`ai/prompt.lua`)

- `build_review_prompt(review, file_diffs)` — MR title, description, all diffs. Instructs Claude to output JSON array: `[{file, line, severity, comment}, ...]`
- `build_mr_prompt(branch, diff)` — Branch name + diff. Instructs Claude to output `## Title\n<title>\n\n## Description\n<description>`.

Parsing lives next to usage, not in the prompt module.

## Triage UI (`review/triage.lua`)

Reuses existing `ui/split` layout. Sidebar = suggestion list, main pane = file diff via `mr/diff.render_file_diff()`.

**State:**
```lua
{ layout, review, diffs, discussions, suggestions[], current_idx, line_data }
```

**Suggestion shape:** `{ file, line, severity, comment, status }` — status: `pending | accepted | edited | deleted`.

**Rendering:**
- AI suggestions as virtual text (extmarks) below the relevant diff line, styled with `CodeReviewAIDraft` highlight group
- Sidebar: numbered list with status icons (`o` pending, `+` accepted, `x` deleted), current item pointer

**Keymaps** (both sidebar + main pane):
| Key | Action |
|-----|--------|
| `a` | Accept current suggestion |
| `d` | Delete current suggestion |
| `e` | Edit (opens small float, `<CR>` saves + accepts) |
| `]c` / `[c` | Navigate suggestions (skip deleted) |
| `A` | Accept all pending |
| `S` | Submit review |
| `q` | Quit triage |

Navigating switches main pane to the relevant file diff and scrolls to the suggestion line.

## Review Submission (`review/submit.lua`)

1. `filter_accepted(suggestions)` → status == "accepted" or "edited"
2. For each → `provider.create_draft_comment(client, ctx, review, { body, path, line })`
3. After all → `provider.publish_review(client, ctx, review)`

**Platform behavior:**
- **GitLab:** `create_draft_comment` → POST `/draft_notes` with position. `publish_review` → POST `/draft_notes/bulk_publish`.
- **GitHub:** `create_draft_comment` accumulates comments locally. `publish_review` → POST `/pulls/:id/reviews` with `event: "COMMENT"` and all comments batched (GitHub's native model).

Partial failures collected and reported; don't abort submission.

## MR Creation (`mr/create.lua`)

Simplified: title + description only, no labels/assignee.

1. Get current branch (guard against main/master)
2. Detect target branch from `refs/remotes/origin/HEAD`
3. `git diff <target>...HEAD` for branch diff
4. `ai/subprocess.run(build_mr_prompt(branch, diff), callback)`
5. Parse: extract `## Title` + `## Description` (fallback: first line = title, rest = description)
6. Open floating editable buffer: title line 1, blank, description below
7. `<CR>` submit, `q` cancel
8. `provider.create_review(client, ctx, { source_branch, target_branch, title, description })`

**Platform behavior:**
- **GitLab:** POST `/projects/:id/merge_requests`
- **GitHub:** POST `/repos/:owner/:repo/pulls`

After creation: notify with web URL, open in detail view.

---

## Provider Interface Additions

```lua
-- New methods added to both gitlab.lua and github.lua:

-- Post a draft/pending comment on a review
M.create_draft_comment(client, ctx, review, params)
-- params: { body, path, line }

-- Publish all draft comments as a review
M.publish_review(client, ctx, review)

-- Create a new MR/PR
M.create_review(client, ctx, params)
-- params: { source_branch, target_branch, title, description }
```
