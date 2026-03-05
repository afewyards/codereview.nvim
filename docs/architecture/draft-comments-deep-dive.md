# Draft Comments Deep Dive

Generated 2026-03-02.

## Overview

This document traces how draft (unpublished) comments are created, stored, displayed, deleted, and
published in codereview.nvim. It covers all three layers: the UI interaction layer, the in-memory
state layer, and the provider API layer (GitLab and GitHub).

There are two distinct kinds of "draft":

1. **Local drafts** — created during an active review session (`session.active == true`). They are
   held in `state.local_drafts[]` and simultaneously posted server-side in a pending/draft state.
   They are never visible to other users until published.

2. **Server-side drafts** — drafts left on the server from a previous session. Detected on MR open
   via `drafts.check_and_prompt()` and offered to the user as Resume or Discard.

---

## Key Files

| File | Role |
|------|------|
| `lua/codereview/review/session.lua` | Session state machine (IDLE/REVIEWING/REVIEWING+AI) |
| `lua/codereview/review/drafts.lua` | Server-draft detection, bulk discard |
| `lua/codereview/review/submit.lua` | Submit + bulk-publish drafts |
| `lua/codereview/mr/comment.lua` | All comment creation, edit, delete, reply functions |
| `lua/codereview/mr/diff_keymaps.lua` | Keymap callbacks wiring comment actions to UI |
| `lua/codereview/mr/diff_comments.lua` | Row-level comment data helpers (build_row_items, etc.) |
| `lua/codereview/mr/thread_virt_lines.lua` | Virtual-line rendering of comment threads (incl. footer hints) |
| `lua/codereview/providers/gitlab.lua` | GitLab API: draft_notes CRUD |
| `lua/codereview/providers/github.lua` | GitHub API: PENDING review CRUD |
| `lua/codereview/keymaps.lua` | Default keymap registry |

---

## 1. Review Session State Machine (`review/session.lua`)

The session controls whether new comments post immediately or accumulate as drafts.

```
IDLE            (active=false)                       -- cc posts via post_comment() immediately
REVIEWING       (active=true,  ai_pending=false)     -- cc posts via create_draft_comment()
REVIEWING+AI    (active=true,  ai_pending=true)      -- same as REVIEWING, plus AI in background
```

Module-level singleton `_state`:
```lua
{
  active      = false,
  ai_pending  = false,
  ai_job_ids  = {},
  ai_total    = 0,
  ai_completed= 0,
  published   = nil,
}
```

Transitions (`session.lua:34-93`):
- `M.start()` — enters REVIEWING
- `M.stop()` / `M.publish(event)` — exits to IDLE
- `M.ai_start(job_ids, total)` — enters REVIEWING+AI
- `M.ai_finish()` / `M.ai_file_done()` — exits AI sub-state

Keymaps that respect this:
- `create_comment` callback (`diff_keymaps.lua:383`) branches on `session.get().active`
- `create_range_comment` callback (`diff_keymaps.lua:492`) branches the same way

---

## 2. Draft Comment Creation Flow

### 2a. Session Active (Draft Mode)

```
User: "cc" on a diff line  (keymaps.lua:6, mode "n")
  → create_comment callback  (diff_keymaps.lua:383)
    → session.get().active == true
      → comment.create_comment(state.review, {
            title = "Draft Comment",
            api_fn = function(provider, client, ctx, mr, text)
              return provider.create_draft_comment(client, ctx, mr, {
                body = text,
                path = file.new_path,
                line = data.item.new_line,
              })
            end,
            on_success = add_local_draft(file.new_path, data.item.new_line),
            ...
          })
          (diff_keymaps.lua:413-422)
        → comment.open_input_popup("Draft Comment", callback)  (comment.lua:310)
          → Opens floating buffer in insert mode  (comment_float.lua)
          → On <C-Enter> / <C-s>:
              → api_fn() called synchronously  (comment.lua:350-357)
                  → provider.create_draft_comment(client, ctx, mr, params)
              → on_success(text) called  → add_local_draft()(text)
                  → builds disc = { notes=[{author="You (draft)", body=text, position={...}}],
                                    is_draft=true }
                  → table.insert(state.local_drafts, disc)
                  → table.insert(state.discussions, disc)
                  → rerender_view()  (diff_keymaps.lua:109-128)
```

The `comment.create_comment()` function (`comment.lua:305-361`) has three code paths:
- **Optimistic path** (`opts.optimistic`): immediate local render, then async API call with retry
- **Retry path** (`opts.use_retry`): no optimistic render, async API call with retry
- **Draft path** (neither): synchronous API call, calls `opts.on_success` on success

Draft creation always uses the draft path (synchronous, no retry).

### 2b. Session Inactive (Immediate Mode)

```
User: "cc" on a diff line
  → create_comment callback
    → session.get().active == false
      → comment.create_comment(state.review, {
            api_fn = provider.post_comment(...)
            optimistic = {
              add    = add_optimistic_comment(old_path, new_path, old_line, new_line),
              remove = remove_optimistic,
              mark_failed = mark_optimistic_failed,
              refresh = refresh_discussions,
            },
            ...
          })
        → optimistic.add(text) called immediately
            → disc = { notes=[{author="You", body=text, is_optimistic=true, ...}] }
            → table.insert(state.discussions, disc)
            → rerender_view()
        → vim.schedule() → async API call → provider.post_comment()
            → On success: refresh_discussions() (re-fetches all from API)
            → On failure: mark_optimistic_failed(disc) → disc.is_failed = true → rerender_view()
```

### 2c. Visual-Range Comments

Same branching logic, but via `create_range_comment` callback (`diff_keymaps.lua:492`).
- In draft mode: calls `create_draft_comment` with the end-line (GitLab/GitHub don't support
  range drafts in the same way as range immediate comments)
- In immediate mode: calls `post_range_comment(client, ctx, mr, text, old_path, new_path, start_pos, end_pos)`

### 2d. AI Suggestion Acceptance

When a user presses `a` (accept) or `e` (edit) on an AI suggestion and a session is active,
the suggestion is posted directly as a draft (`diff_keymaps.lua:736-750`):

```lua
provider.create_draft_comment(client_mod, state.ctx, state.review, {
  body = suggestion.comment,
  path = suggestion.file,
  line = suggestion.line,
})
suggestion.status = "accepted"
suggestion.drafted = true
```

No `local_drafts` entry is created for AI-sourced drafts — they are tracked by `suggestion.drafted`.

---

## 3. Local Draft Storage

Local drafts live in `state.local_drafts[]` (a field in the diff state, `diff_state.lua`).
They are also inserted into `state.discussions[]` so the renderer treats them like any other thread.

**Shape of a local draft discussion:**
```lua
{
  notes = {{
    author    = "You (draft)",
    body      = text,
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    position  = {
      new_path  = new_path,
      new_line  = new_line,
      start_line = start_line,   -- only for range comments
    },
  }},
  is_draft = true,
}
```

**Key distinction:** Local drafts have no `.id` and no `.server_draft_id`. The server-side draft
response is discarded — the plugin does not link back local drafts to the server-side object.

**On refresh (`refresh_discussions` in `diff_keymaps.lua:85-106`):**
```lua
local discs = state.provider.get_discussions(client_mod, state.ctx, state.review) or {}
-- Re-insert local_drafts so they survive the refresh:
for _, d in ipairs(state.local_drafts or {}) do
  table.insert(discs, d)
end
-- Preserve failed optimistic comments:
for _, d in ipairs(state.discussions or {}) do
  if d.is_failed then table.insert(discs, d) end
end
state.discussions = discs
```

Local drafts are intentionally preserved across API refreshes because the server won't return
them via the normal `get_discussions` endpoint.

---

## 4. Server-Side Draft Storage and Detection

### GitLab (`providers/gitlab.lua:443-493`)

GitLab has a dedicated `/draft_notes` API endpoint:

| Operation | Method | Endpoint |
|-----------|--------|----------|
| Fetch all drafts | `GET` | `/api/v4/projects/:id/merge_requests/:iid/draft_notes` |
| Create a draft | `POST` | `/api/v4/projects/:id/merge_requests/:iid/draft_notes` |
| Delete one draft | `DELETE` | `/api/v4/projects/:id/merge_requests/:iid/draft_notes/:draft_id` |
| Publish all | `POST` | `/api/v4/projects/:id/merge_requests/:iid/draft_notes/bulk_publish` |

`get_draft_notes()` normalizes raw drafts into the discussion shape:
```lua
{
  notes = {{
    author          = "You (draft)",
    body            = raw.note,
    created_at      = raw.created_at,
    position        = { new_path, old_path, new_line, old_line, ... },
    change_position = { ... },    -- for outdated drafts
  }},
  is_draft        = true,
  server_draft_id = raw.id,      -- GitLab numeric ID, used for individual delete
}
```

### GitHub (`providers/github.lua:620-763`)

GitHub has no dedicated draft notes endpoint. Drafts are modeled as a **PENDING review**:

| Operation | Method | Endpoint |
|-----------|--------|----------|
| Create first draft | `POST` | `/repos/:owner/:repo/pulls/:id/reviews` (creates PENDING review with first comment) |
| Add subsequent drafts | GraphQL mutation | `addPullRequestReviewThread` on the pending review node |
| Fetch drafts | `GET` `/reviews` + filter `PENDING` + `GET` `/reviews/:id/comments` | |
| Discard all drafts | `DELETE` | `/repos/:owner/:repo/pulls/:id/reviews/:review_id` |
| Publish all | `POST` | `/repos/:owner/:repo/pulls/:id/reviews/:review_id/events` with `{event:"COMMENT"}` |

**Module-level mutable state (a known gotcha):**
```lua
M._pending_review_id      = nil   -- integer, REST ID of the PENDING review
M._pending_review_node_id = nil   -- string, GraphQL node ID
```
These are set on first `create_draft_comment()` call and cleared after `publish_review()` or
`discard_pending_review()`. Concurrent reviews on different PRs within the same Neovim session
would conflict.

`get_pending_review_drafts()` (`github.lua:676-727`):
- Lists all reviews on the PR, finds the PENDING one
- Fetches its comments
- Returns normalized draft discussions (no `server_draft_id`, just the outer comment `id`)
- Also sets `_pending_review_id` and `_pending_review_node_id` so future `create_draft_comment`
  calls reuse the existing PENDING review

---

## 5. Server-Draft Lifecycle on MR Open (`review/drafts.lua`)

Called from `detail.open()` after the initial data fetch:

```
drafts.check_and_prompt(provider, client, ctx, review, on_done)
  → M.fetch_server_drafts(provider, client, ctx, review)
      GitLab: provider.get_draft_notes(...)
      GitHub: provider.get_pending_review_drafts(...)
  → If #server_drafts == 0: on_done(nil)  (no drafts, proceed normally)
  → If #server_drafts > 0:
      → vim.ui.select({"Resume", "Discard"}, prompt, callback)
          → "Resume": on_done(server_drafts)
              → caller inserts these into state.local_drafts and state.discussions
              → caller enters review session (session.start())
          → "Discard": M.discard_server_drafts(...)
              GitLab: provider.delete_draft_note() for each draft (by server_draft_id)
              GitHub: provider.discard_pending_review()  (deletes entire PENDING review)
              → on_done(nil)
          → Cancel (nil choice): on_done(nil)  (drafts stay on server, no session started)
```

---

## 6. Draft Deletion

### 6a. Deleting a Single Published Note (not a draft)

The `delete_note` callback (`diff_keymaps.lua:954-982`) handles deleting any posted note:

```
User: "x" on a selected comment thread  (keymaps.lua:30, mapped to delete_note)
  → delete_note callback  (diff_keymaps.lua:954)
    → Guards: view_mode == "diff", disc exists at cursor, note selected, author == current_user
    → comment.delete_note(disc, note, mr, on_success)  (comment.lua:250-276)
        → vim.ui.input({ prompt = "Delete this comment? (Y/n): " })
        → On confirm:
            → provider.delete_note(client, ctx, mr, disc.id, note.id)
                GitLab: DELETE /discussions/:disc_id/notes/:note_id
                GitHub: DELETE /pulls/comments/:note_id  (disc.id unused)
            → Removes note from disc.notes[] in-place
            → If disc.notes becomes empty:
                → on_success({ removed_disc = true })
                    → caller removes disc from state.discussions[]
            → Else: on_success()
        → rerender_view()
```

**Footer hint** in thread virtual lines (`thread_virt_lines.lua:247-252`):
- When the selected note belongs to `current_user`: `"r:reply  gt:un/resolve  e:edit  x:delete"`
- Otherwise: `"r:reply  gt:un/resolve"`

### 6b. Deleting a Draft Comment (local draft, no server ID)

**There is currently no UI action to delete an individual local draft comment.** The "x" key
for `delete_note` only applies to comments that have a real `disc.id` and `note.id` from the server.
Local drafts have no `.id` and guard at the provider call would silently fail or error.

### 6c. Discarding All Server-Side Drafts (bulk)

This is the only way to remove server-side drafts in bulk:

```
drafts.discard_server_drafts(provider, client, ctx, review, server_drafts)
  GitLab: for each draft with server_draft_id:
            provider.delete_draft_note(client, ctx, review, d.server_draft_id)
  GitHub: provider.discard_pending_review(client, ctx, review)
            → DELETE /repos/:owner/:repo/pulls/:id/reviews/:pending_review_id
```

This is only called when the user chooses "Discard" from the resume prompt on MR open.

---

## 7. Draft Publishing

```
User: "S" keymap  (keymaps.lua:18)
  → submit callback  (diff_keymaps.lua:828)
    → submit_float.open({ on_submit = ... })
        → User chooses event (COMMENT / APPROVE / REQUEST_CHANGES) and optional body text
        → on_submit(body, event):
            → submit_mod.submit_and_publish(review, ai_suggestions, { body, event })
                (review/submit.lua:57-71)
              Phase 1: Post any accepted AI suggestions that haven't been drafted yet:
                → submit_review(review, suggestions)  (submit.lua:16-55)
                    → provider.create_draft_comment() for each accepted suggestion
              Phase 2: Bulk-publish:
                → bulk_publish(review, opts)  (submit.lua:73-85)
                    → provider.publish_review(client, ctx, review, { body, event })
                        GitLab: POST /draft_notes/bulk_publish
                                POST /notes if body present
                                POST /approve if event == APPROVE
                        GitHub: POST /reviews/:pending_review_id/events
                                  { event: "COMMENT"|"APPROVE"|"REQUEST_CHANGES", body }
            → state.local_drafts = {}
            → session.publish(event) → session.stop()
            → refresh_discussions()
```

---

## 8. UI Rendering of Draft Comments

Draft discussions render identically to regular discussions through `thread_virt_lines.build()`
(`thread_virt_lines.lua:88-266`). They are placed in `state.discussions[]` alongside server
discussions.

**Draft-specific rendering:**
- `disc.is_draft == true` does not alter the border or highlight group (no special styling)
- The footer hints (`thread_virt_lines.lua:241-253`):
  - For failed comments: `"gR:retry  D:discard"`
  - For pending (posting): `"posting…"`
  - For selected note owned by current user: `"r:reply  gt:un/resolve  e:edit  x:delete"`
  - For selected note by other user: `"r:reply  gt:un/resolve"`
- Draft comments show `author = "You (draft)"` — they always pass the `author == current_user`
  guard for the edit/delete footer hint IF `current_user` happens to match that exact string,
  which it won't because `current_user` is the real username. This means draft comments' footer
  does NOT show `e:edit  x:delete` hints.

**Optimistic comments** (pending posting):
- `disc.is_optimistic = true` → border/author highlight = `CodeReviewCommentPending`
- Footer = `"posting…"`
- On failure: `disc.is_failed = true` → border/author highlight = `CodeReviewCommentFailed`
  → footer = `"gR:retry  D:discard"` (these keymaps are not yet implemented in the current
  keymap registry — they appear in the footer text but have no registered callbacks)

---

## 9. Keymaps Summary (Comment-Related)

From `keymaps.lua:3-37` (all remappable):

| Action name | Default key | Mode | What it does |
|-------------|-------------|------|--------------|
| `create_comment` | `cc` | n | Create inline comment or draft (session-dependent) |
| `create_range_comment` | `cc` | v | Range comment or draft |
| `reply` | `r` | n | Reply to selected thread |
| `toggle_resolve` | `gt` | n | Toggle resolve/unresolve on thread |
| `edit_note` | `e` | n | Edit selected note (own notes only) |
| `delete_note` | `x` | n | Delete selected note (own notes only) |
| `select_next_note` | `<Tab>` | n | Select next comment or AI suggestion |
| `select_prev_note` | `<S-Tab>` | n | Select previous comment or AI suggestion |
| `accept_suggestion` | `a` | n | Accept AI suggestion (posts as draft) |
| `dismiss_suggestion` | `x` | n | Dismiss AI suggestion |
| `edit_suggestion` | `e` | n | Edit AI suggestion text |
| `dismiss_all_suggestions` | `ds` | n | Dismiss all AI suggestions |
| `submit` | `S` | n | Open submit float → publish all drafts |

**Key collision resolution** (`keymaps.lua:78-104`): When two actions share the same key (e.g.,
`edit_note` and `edit_suggestion` both on `e`, or `delete_note` and `dismiss_suggestion` both on
`x`), `km.apply()` wraps them in a compound handler that calls both. Each callback checks its
own precondition (`sel.type == "comment"` vs `sel.type == "ai"`) so only one branch fires.

---

## 10. Data Flow: Creating a Draft Comment (End-to-End)

```
State: session.active = true

User: "cc" (normal mode)
  diff_keymaps.lua:383 create_comment callback
    ↓
  session.get().active → true
    ↓
  comment.create_comment(mr, { title="Draft Comment", api_fn=..., on_success=add_local_draft(...) })
    (comment.lua:305)
    ↓
  comment.open_input_popup("Draft Comment", callback)
    (comment.lua:310 → comment_float.open → comment_float.lua)
    ↓
  User types text, presses <C-Enter>
    ↓
  comment.lua:350-357  (draft path: synchronous, no retry)
    api_fn(provider, client, ctx, mr, text)
      → provider.create_draft_comment(client, ctx, mr, { body, path, line })
          GitLab: POST /api/v4/projects/:id/merge_requests/:iid/draft_notes
                  body = { note: text, position: { position_type, base_sha, head_sha, start_sha,
                                                    new_path, old_path, new_line } }
          GitHub: (first draft) POST /repos/:owner/:repo/pulls/:id/reviews
                                  body = { commit_id, comments: [{body, path, line, side}] }
                                → sets M._pending_review_id
                  (subsequent)  GraphQL addPullRequestReviewThread mutation
    ↓ (on success)
  on_success(text) = add_local_draft(new_path, new_line)(text)
    (diff_keymaps.lua:109-128)
    ↓
  state.local_drafts[] += disc    (disc.is_draft = true)
  state.discussions[]  += disc
  rerender_view()
    ↓
  diff_render.render_file_diff() / render_all_files()
  place_comment_signs()
  thread_virt_lines.build(disc, ...)
    → Renders the draft inline below the diff line as virtual lines
```

---

## 11. Gotchas and Missing Pieces

1. **No per-draft delete UI for local drafts.** Once a draft comment is created in a session, the
   user cannot delete it individually. The only way to remove server-side drafts is the bulk
   "Discard" offered at session resume time. The `delete_note` keymap (`x`) only works on
   fully-published notes with real server IDs.

2. **`delete_note` guard requires `disc.id`** (`comment.lua:256` calls
   `provider.delete_note(client, ctx, mr, disc.id, note.id)`). Local draft discs have no `.id`,
   so calling this on a local draft would pass `nil` as `discussion_id`. GitLab would 404;
   GitHub ignores `disc.id` entirely so it would attempt to delete by `note.id` (also nil).

3. **GitHub draft deletion is all-or-nothing.** GitHub has no endpoint to delete a single comment
   from a PENDING review. `discard_pending_review()` deletes the entire review with all its
   draft comments. GitLab's `delete_draft_note()` can target individual drafts by ID.

4. **`gR:retry` and `D:discard` footer hints are not wired.** `thread_virt_lines.lua:242` shows
   `"gR:retry  D:discard"` for failed comments, but no callbacks named `retry_comment` or
   `discard_failed_comment` exist in the keymap registry (`keymaps.lua`) or diff_keymaps callbacks.

5. **Local draft has no `server_draft_id`.** When a user creates a draft via `cc`, the API
   response from `create_draft_comment` is discarded (not stored on the disc object). This means
   there's no way to target that draft for individual deletion later, even if the UI supported it.

6. **`reply` is blocked on drafts.** The `reply` callback (`diff_keymaps.lua:595,607`) guards
   `not disc.is_draft` — you cannot reply to a draft comment thread, only to published threads.

7. **Draft author string `"You (draft)"` won't match `current_user`** — so the
   edit/delete footer hint won't appear for draft comments even though the user owns them.
   This is intentional (you can't edit/delete individual drafts via API) but could be surprising.

8. **GitHub `_pending_review_id` is module-global.** If the user opens two MRs simultaneously
   in the same Neovim session, both providers share the same `_pending_review_id`. The second
   MR would try to add drafts to the first MR's review, failing with a 422.
