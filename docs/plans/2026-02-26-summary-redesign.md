# Summary View Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Redesign the summary view with GitHub PR-style layout: bordered header card, section headers, Nerd Font activity icons, file context in discussions, context-sensitive Tab navigation.

**Architecture:** Rewrite `build_header_lines` and `build_activity_lines` in `detail.lua`, split activity into two sections (system events + discussions), add new highlight groups, update Tab keymaps for discussion cycling.

**Tech Stack:** Lua, Neovim API (extmarks, highlights), Nerd Font glyphs

---

### Task 1: Add new highlight groups

**Files:**
- Modify: `lua/codereview/ui/highlight.lua:77` (before sign definitions)
- Test: `tests/codereview/ui/highlight_spec.lua` (if exists, else skip)

**Step 1: Write the failing test**

```lua
-- tests/codereview/ui/highlight_spec.lua
-- Add test that new groups exist after setup()
describe("summary redesign highlights", function()
  it("defines header card groups", function()
    require("codereview.ui.highlight").setup()
    local card = vim.api.nvim_get_hl(0, { name = "CodeReviewHeaderCardBorder" })
    assert.is_not_nil(card.fg)
    local state_open = vim.api.nvim_get_hl(0, { name = "CodeReviewStateOpened" })
    assert.is_not_nil(state_open.fg)
  end)

  it("defines activity icon groups", function()
    require("codereview.ui.highlight").setup()
    local commit_icon = vim.api.nvim_get_hl(0, { name = "CodeReviewActivityCommit" })
    assert.is_not_nil(commit_icon.fg)
    local resolve_icon = vim.api.nvim_get_hl(0, { name = "CodeReviewActivityResolved" })
    assert.is_not_nil(resolve_icon.fg)
  end)

  it("defines file path group", function()
    require("codereview.ui.highlight").setup()
    local fp = vim.api.nvim_get_hl(0, { name = "CodeReviewDiscussionFilePath" })
    assert.is_not_nil(fp.fg)
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `bunx vitest run tests/codereview/ui/highlight_spec.lua`
Expected: FAIL — groups not defined yet

**Step 3: Add highlight definitions**

Insert before line 78 (sign definitions) in `lua/codereview/ui/highlight.lua`:

```lua
  -- Summary header card
  vim.api.nvim_set_hl(0, "CodeReviewHeaderCardBorder", { fg = "#565f89", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewHeaderCardTitle", { fg = "#c8d3f5", bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewHeaderCardId", { fg = "#7aa2f7", bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewStateOpened", { fg = "#9ece6a", bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewStateMerged", { fg = "#bb9af7", bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewStateClosed", { fg = "#f7768e", bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewHeaderBranch", { fg = "#e0af68", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewHeaderMergeOk", { fg = "#9ece6a", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewHeaderMergeConflict", { fg = "#f7768e", default = true })
  -- Activity icons
  vim.api.nvim_set_hl(0, "CodeReviewActivityAssign", { fg = "#7aa2f7", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewActivityCommit", { fg = "#bb9af7", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewActivityComment", { fg = "#7aa2f7", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewActivityResolved", { fg = "#9ece6a", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewActivityApproved", { fg = "#9ece6a", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewActivityMerged", { fg = "#bb9af7", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewActivityGeneric", { fg = "#565f89", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewActivityTime", { fg = "#565f89", default = true })
  -- Discussion file path
  vim.api.nvim_set_hl(0, "CodeReviewDiscussionFilePath", { fg = "#7aa2f7", underline = true, default = true })
```

**Step 4: Run test to verify it passes**

Run: `bunx vitest run tests/codereview/ui/highlight_spec.lua`
Expected: PASS

**Step 5: Commit**

```bash
git add lua/codereview/ui/highlight.lua tests/codereview/ui/highlight_spec.lua
git commit -m "feat(highlights): add summary redesign highlight groups"
```

---

### Task 2: Rewrite `build_header_lines` — bordered card

**Files:**
- Modify: `lua/codereview/mr/detail.lua:17-63` (replace `build_header_lines`)
- Test: `tests/codereview/mr/detail_spec.lua`

**Step 1: Write the failing test**

```lua
describe("build_header_lines redesign", function()
  it("renders bordered header card", function()
    local detail = require("codereview.mr.detail")
    local review = {
      id = 42, title = "Fix auth", author = "maria",
      source_branch = "fix/token", target_branch = "main",
      state = "opened", pipeline_status = "success",
      approved_by = { "alice" }, approvals_required = 2,
      description = "", merge_status = "can_be_merged",
    }
    local result = detail.build_header_lines(review, 60)
    -- First line should be top border ╭...╮
    assert.is_truthy(result.lines[1]:match("^╭─+╮$"))
    -- Last border line should be ╰...╯
    local found_bottom = false
    for _, l in ipairs(result.lines) do
      if l:match("^╰─+╯$") then found_bottom = true end
    end
    assert.is_truthy(found_bottom)
  end)

  it("includes state in header", function()
    local detail = require("codereview.mr.detail")
    local review = {
      id = 42, title = "Fix auth", author = "maria",
      source_branch = "fix/token", target_branch = "main",
      state = "opened", pipeline_status = "success",
      approved_by = {}, approvals_required = 0,
      description = "",
    }
    local result = detail.build_header_lines(review, 60)
    local has_state = false
    for _, l in ipairs(result.lines) do
      if l:find("opened") then has_state = true end
    end
    assert.is_truthy(has_state)
  end)

  it("shows description section header", function()
    local detail = require("codereview.mr.detail")
    local review = {
      id = 42, title = "Fix", author = "m",
      source_branch = "a", target_branch = "b",
      state = "opened", description = "Hello world",
      approved_by = {}, approvals_required = 0,
    }
    local result = detail.build_header_lines(review, 60)
    local found = false
    for _, l in ipairs(result.lines) do
      if l:match("^## Description") then found = true end
    end
    assert.is_truthy(found)
  end)

  it("omits description section when empty", function()
    local detail = require("codereview.mr.detail")
    local review = {
      id = 42, title = "Fix", author = "m",
      source_branch = "a", target_branch = "b",
      state = "opened", description = "",
      approved_by = {}, approvals_required = 0,
    }
    local result = detail.build_header_lines(review, 60)
    for _, l in ipairs(result.lines) do
      assert.is_falsy(l:match("^## Description"))
    end
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `bunx vitest run tests/codereview/mr/detail_spec.lua`
Expected: FAIL — no bordered card yet

**Step 3: Implement `build_header_lines`**

Replace `detail.lua:17-63` with:

```lua
function M.build_header_lines(review, width)
  width = width or 70
  local highlights = {}
  local lines = {}

  -- ── Header card ─────────────────────────────────────────────────
  local inner_w = width - 2  -- inside │ ... │
  table.insert(lines, "╭" .. string.rep("─", inner_w) .. "╮")
  table.insert(highlights, { #lines - 1, 0, #lines[#lines], "CodeReviewHeaderCardBorder" })

  -- Line 1: │  #id  title                          state │
  local id_str = "#" .. review.id
  local state_str = review.state or "unknown"
  local title_max = inner_w - #id_str - #state_str - 6  -- 2 pad each side + 2 spaces
  local title = review.title or ""
  if #title > title_max then title = title:sub(1, title_max - 1) .. "…" end
  local gap1 = math.max(1, inner_w - 2 - #id_str - 2 - #title - #state_str)
  local line1 = "│  " .. id_str .. "  " .. title .. string.rep(" ", gap1) .. state_str .. "  │"
  -- Pad/trim to exact width
  local row1 = #lines
  table.insert(lines, line1)
  table.insert(highlights, { row1, 0, 1, "CodeReviewHeaderCardBorder" })
  table.insert(highlights, { row1, #line1 - 1, #line1, "CodeReviewHeaderCardBorder" })
  local id_start = 3
  table.insert(highlights, { row1, id_start, id_start + #id_str, "CodeReviewHeaderCardId" })
  local title_start = id_start + #id_str + 2
  table.insert(highlights, { row1, title_start, title_start + #title, "CodeReviewHeaderCardTitle" })
  local state_start = #line1 - 2 - #state_str
  local state_hl = ({ opened = "CodeReviewStateOpened", merged = "CodeReviewStateMerged", closed = "CodeReviewStateClosed" })[review.state] or "CodeReviewThreadMeta"
  table.insert(highlights, { row1, state_start, state_start + #state_str, state_hl })

  -- Line 2: │  @author  source → target   CI  1/2 approved │
  local pipeline_icon = require("codereview.mr.list").pipeline_icon(review.pipeline_status)
  local author_str = "@" .. review.author
  local branch_str = review.source_branch .. " → " .. (review.target_branch or "main")
  local right_parts = {}
  table.insert(right_parts, pipeline_icon)
  local approved_by = (type(review.approved_by) == "table") and review.approved_by or {}
  local approvals_required = (type(review.approvals_required) == "number") and review.approvals_required or 0
  if approvals_required > 0 or #approved_by > 0 then
    table.insert(right_parts, #approved_by .. "/" .. approvals_required .. " approved")
  end
  if review.merge_status then
    local ms = review.merge_status == "can_be_merged" and "mergeable" or "conflicts"
    table.insert(right_parts, ms)
  end
  local right_str = table.concat(right_parts, "   ")
  local gap2 = math.max(1, inner_w - 2 - #author_str - 2 - #branch_str - 3 - #right_str)
  local line2 = "│  " .. author_str .. "  " .. branch_str .. string.rep(" ", gap2) .. right_str .. "  │"
  local row2 = #lines
  table.insert(lines, line2)
  table.insert(highlights, { row2, 0, 1, "CodeReviewHeaderCardBorder" })
  table.insert(highlights, { row2, #line2 - 1, #line2, "CodeReviewHeaderCardBorder" })
  local a_start = 3
  table.insert(highlights, { row2, a_start, a_start + #author_str, "CodeReviewCommentAuthor" })
  local b_start = a_start + #author_str + 2
  table.insert(highlights, { row2, b_start, b_start + #branch_str, "CodeReviewHeaderBranch" })

  -- Bottom border
  table.insert(lines, "╰" .. string.rep("─", inner_w) .. "╯")
  table.insert(highlights, { #lines - 1, 0, #lines[#lines], "CodeReviewHeaderCardBorder" })

  -- ── Description section ──────────────────────────────────────────
  local block_result = nil
  if review.description and review.description ~= "" then
    table.insert(lines, "")
    local desc_header_row = #lines
    table.insert(lines, "## Description")
    table.insert(highlights, { desc_header_row, 0, 14, "CodeReviewMdH2" })
    local desc_start = #lines
    block_result = require("codereview.ui.markdown").parse_blocks(review.description, "CodeReviewComment", { width = width })
    for _, bl in ipairs(block_result.lines) do
      table.insert(lines, "  " .. bl)
    end
    for _, h in ipairs(block_result.highlights) do
      table.insert(highlights, { desc_start + h[1], h[2] + 2, h[3] + 2, h[4] })
    end
  end

  return {
    lines = lines,
    highlights = highlights,
    code_blocks = block_result and block_result.code_blocks or {},
  }
end
```

**Step 4: Run test to verify it passes**

Run: `bunx vitest run tests/codereview/mr/detail_spec.lua`
Expected: PASS

**Step 5: Commit**

```bash
git add lua/codereview/mr/detail.lua tests/codereview/mr/detail_spec.lua
git commit -m "feat(summary): rewrite header as bordered card with state and merge info"
```

---

### Task 3: Rewrite `build_activity_lines` — split into Activity + Discussions

This is the biggest change. `build_activity_lines` currently handles both system notes AND user discussions in one loop. Split into two sections:
1. **Activity** — system notes with Nerd Font icons and relative time
2. **Discussions** — user comment threads with file context

**Files:**
- Modify: `lua/codereview/mr/detail.lua:90-260` (replace `build_activity_lines`)
- Test: `tests/codereview/mr/detail_spec.lua`

**Step 1: Write the failing test**

```lua
describe("build_activity_lines redesign", function()
  local tvl_format = require("codereview.mr.thread_virt_lines").format_time_relative

  local function make_system_note(body, author, created_at)
    return {
      id = 1, author = author or "bot", body = body,
      created_at = created_at or "2026-02-20T11:00:00Z",
      system = true, resolvable = false, resolved = false,
    }
  end

  local function make_discussion(opts)
    return {
      id = opts.id or "d1", resolved = opts.resolved or false,
      notes = opts.notes or {},
    }
  end

  it("renders Activity section header", function()
    local detail = require("codereview.mr.detail")
    local discussions = {
      make_discussion({ notes = { make_system_note("assigned to @olaf", "olaf") } }),
    }
    local result = detail.build_activity_lines(discussions, 60)
    local found = false
    for _, l in ipairs(result.lines) do
      if l:match("^## Activity") then found = true end
    end
    assert.is_truthy(found)
  end)

  it("renders Discussions section header with unresolved count", function()
    local detail = require("codereview.mr.detail")
    local discussions = {
      make_discussion({
        resolved = false,
        notes = {{
          id = 1, author = "alice", body = "fix this",
          created_at = "2026-02-20T11:00:00Z",
          system = false, resolvable = true, resolved = false,
        }},
      }),
    }
    local result = detail.build_activity_lines(discussions, 60)
    local found = false
    for _, l in ipairs(result.lines) do
      if l:match("## Discussions.*unresolved") then found = true end
    end
    assert.is_truthy(found)
  end)

  it("shows file path for inline comments", function()
    local detail = require("codereview.mr.detail")
    local discussions = {
      make_discussion({
        notes = {{
          id = 1, author = "alice", body = "fix this",
          created_at = "2026-02-20T11:00:00Z",
          system = false, resolvable = true, resolved = false,
          position = { new_path = "src/auth.ts", new_line = 42 },
        }},
      }),
    }
    local result = detail.build_activity_lines(discussions, 60)
    local found = false
    for _, l in ipairs(result.lines) do
      if l:find("src/auth.ts:42") then found = true end
    end
    assert.is_truthy(found)
  end)

  it("assigns file_path row_map type for jumpable file paths", function()
    local detail = require("codereview.mr.detail")
    local discussions = {
      make_discussion({
        notes = {{
          id = 1, author = "alice", body = "fix this",
          created_at = "2026-02-20T11:00:00Z",
          system = false, resolvable = true, resolved = false,
          position = { new_path = "src/auth.ts", new_line = 42 },
        }},
      }),
    }
    local result = detail.build_activity_lines(discussions, 60)
    local found_file_row = false
    for _, entry in pairs(result.row_map) do
      if entry.type == "file_path" then found_file_row = true end
    end
    assert.is_truthy(found_file_row)
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `bunx vitest run tests/codereview/mr/detail_spec.lua`
Expected: FAIL

**Step 3: Implement the rewrite**

Replace `detail.lua` `build_activity_lines` (lines 90-260) with two-section approach. The function keeps the same signature and return shape.

Key implementation details:

**Icon detection** — pattern-match on system note body:
```lua
local ACTIVITY_ICONS = {
  { pattern = "assigned",        icon = "\xef\x90\x95", hl = "CodeReviewActivityAssign" },    -- U+F415
  { pattern = "added %d+ commit", icon = "\xef\x90\x97", hl = "CodeReviewActivityCommit" },   -- U+F417
  { pattern = "review",          icon = "\xef\x90\x9f", hl = "CodeReviewActivityComment" },   -- U+F41F
  { pattern = "resolved",        icon = "\xef\x90\xae", hl = "CodeReviewActivityResolved" },  -- U+F42E
  { pattern = "approved",        icon = "\xef\x90\x9d", hl = "CodeReviewActivityApproved" },  -- U+F41D
  { pattern = "merged",          icon = "\xef\x90\x99", hl = "CodeReviewActivityMerged" },    -- U+F419
}
local FALLBACK_ICON = { icon = "\xef\x91\x84", hl = "CodeReviewActivityGeneric" }             -- U+F444
```

**Two passes over discussions:**
1. First pass: collect system notes → render Activity section
2. Second pass: collect non-system, non-position discussions → render general Discussions section
3. Third pass: collect non-system, with-position discussions → also in Discussions section, with file path line

**File path row_map entry:**
```lua
row_map[row] = {
  type = "file_path",
  discussion = disc,
  path = note.position.new_path,
  line = note.position.new_line,
}
```

**Relative time** — use existing `format_time_relative` from `thread_virt_lines.lua` (already imported as `format_time_short` at line 88).

**Discussion count** — use existing `M.count_discussions()` from detail.lua to get unresolved count for section header.

**Step 4: Run test to verify it passes**

Run: `bunx vitest run tests/codereview/mr/detail_spec.lua`
Expected: PASS

**Step 5: Commit**

```bash
git add lua/codereview/mr/detail.lua tests/codereview/mr/detail_spec.lua
git commit -m "feat(summary): split activity/discussions, add icons and file paths"
```

---

### Task 4: Update `render_summary` for new layout

**Files:**
- Modify: `lua/codereview/mr/diff_sidebar.lua:20-121`
- No new tests needed — existing render_summary tests + manual verification

The `render_summary` function mostly stays the same since it already assembles header + activity and applies extmarks. Changes:
- Offset code blocks from description by 2 (indent) — already handled in Task 2's `build_header_lines`
- Ensure `summary_row_map` preserves new `file_path` type entries from Task 3

**Step 1: Verify existing tests still pass**

Run: `bunx vitest run tests/codereview/mr/diff_sidebar_spec.lua`
Expected: PASS (or no such file — render_summary may not have unit tests)

**Step 2: Update `render_summary` if needed**

The function should work as-is because:
- It calls `build_header_lines` and `build_activity_lines` which return the same shape
- It applies highlights from both via extmarks
- It builds `summary_row_map` from `activity.row_map`

Only change: ensure code_block indent offsets account for the 2-space description indent. Check that `cb.indent` from `build_header_lines` already includes the 2-space offset (it does per Task 2 implementation).

**Step 3: Run full test suite**

Run: `bunx vitest run`
Expected: PASS

**Step 4: Commit (if changes needed)**

```bash
git add lua/codereview/mr/diff_sidebar.lua
git commit -m "fix(summary): adjust render_summary for redesigned layout"
```

---

### Task 5: Context-sensitive Tab navigation

**Files:**
- Modify: `lua/codereview/mr/diff_keymaps.lua:925-952` (the summary→diff transition block)
- Test: manual — keymaps are hard to unit test in headless Neovim

**Step 1: Understand current behavior**

Current `select_next_note` (line 926-928):
```lua
if state.view_mode ~= "diff" then
  -- immediately transition to diff view
  state.view_mode = "diff"
```

**Step 2: Implement context-sensitive Tab**

Replace the summary transition block (lines 926-952) with:

```lua
if state.view_mode ~= "diff" then
  -- In summary: cycle through discussion thread headers
  local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]
  local thread_rows = {}
  for row, entry in pairs(state.summary_row_map or {}) do
    if entry.type == "thread_start" then
      table.insert(thread_rows, row)
    end
  end
  table.sort(thread_rows)

  -- Find next thread header after cursor
  for _, r in ipairs(thread_rows) do
    if r > cursor_row then
      vim.api.nvim_win_set_cursor(layout.main_win, { r, 0 })
      return
    end
  end

  -- Past last thread: transition to diff view
  if not state.files or #state.files == 0 then return end
  state.view_mode = "diff"
  -- ... rest of existing diff transition code ...
```

Similarly for `select_prev_note`: cycle backward through `thread_rows`, stay on first.

**Step 3: Add file path jump keymap**

In the keymap setup section, add handler for `c` and `<CR>` in summary mode that checks `summary_row_map` for `file_path` entries:

```lua
-- When cursor is on a file_path row in summary, jump to that file in diff
local entry = state.summary_row_map[cursor_row]
if entry and entry.type == "file_path" then
  -- Find file index by path
  for idx, f in ipairs(state.files or {}) do
    if f.new_path == entry.path or f.old_path == entry.path then
      state.view_mode = "diff"
      diff_nav.switch_to_file(layout, state, idx)
      -- TODO: jump to specific line if possible
      return
    end
  end
end
```

**Step 4: Run full test suite**

Run: `bunx vitest run`
Expected: PASS

**Step 5: Commit**

```bash
git add lua/codereview/mr/diff_keymaps.lua
git commit -m "feat(summary): context-sensitive Tab and jumpable file paths"
```

---

### Task 6: Integration test — full summary render

**Files:**
- Create: `tests/codereview/mr/summary_integration_spec.lua`

**Step 1: Write integration test**

```lua
describe("summary redesign integration", function()
  it("renders complete summary with all sections", function()
    local detail = require("codereview.mr.detail")
    local review = {
      id = 99, title = "Big feature", author = "dev",
      source_branch = "feat/big", target_branch = "main",
      state = "opened", pipeline_status = "success",
      approved_by = { "reviewer" }, approvals_required = 2,
      description = "This is a **bold** description",
      merge_status = "can_be_merged",
    }
    local discussions = {
      { id = "d1", resolved = false, notes = {{
        id = 1, author = "bot", body = "assigned to @dev",
        created_at = "2026-02-20T11:00:00Z", system = true,
        resolvable = false, resolved = false,
      }}},
      { id = "d2", resolved = false, notes = {{
        id = 2, author = "alice", body = "Please fix this",
        created_at = "2026-02-25T14:00:00Z", system = false,
        resolvable = true, resolved = false,
        position = { new_path = "src/main.ts", new_line = 10 },
      }}},
    }

    local header = detail.build_header_lines(review, 70)
    local activity = detail.build_activity_lines(discussions, 70)

    -- Verify structure
    assert.is_truthy(header.lines[1]:match("^╭"))
    local all_text = table.concat(header.lines, "\n") .. "\n" .. table.concat(activity.lines, "\n")
    assert.is_truthy(all_text:find("## Description"))
    assert.is_truthy(all_text:find("## Activity"))
    assert.is_truthy(all_text:find("## Discussions"))
    assert.is_truthy(all_text:find("src/main.ts:10"))
  end)
end)
```

**Step 2: Run to verify it passes**

Run: `bunx vitest run tests/codereview/mr/summary_integration_spec.lua`
Expected: PASS

**Step 3: Run full suite**

Run: `bunx vitest run`
Expected: all existing tests PASS

**Step 4: Commit**

```bash
git add tests/codereview/mr/summary_integration_spec.lua
git commit -m "test(summary): add integration test for redesigned summary"
```

---

## Task Dependencies

```
Task 1 (highlights) ──┬── Task 2 (header card)
                      ├── Task 3 (activity/discussions) ── Task 4 (render_summary)
                      └── Task 5 (Tab navigation) ─── depends on Task 3
Task 6 (integration test) ─── depends on Tasks 2, 3, 4, 5
```

- Task 1 has no deps — can start immediately
- Tasks 2 and 3 depend on Task 1 — can run in parallel after Task 1
- Task 4 depends on Tasks 2 and 3
- Task 5 depends on Task 3
- Task 6 depends on all others
