# Phase 1: Rename — `glab_review` → `codereview`

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rename the plugin from `glab_review` to `codereview` — directories, require paths, commands, highlights, display strings. Pure mechanical, no logic changes.

**Prereqs:** None. This is the first phase.

---

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
