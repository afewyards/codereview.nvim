# Parallel Per-File AI Review — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the single-subprocess multi-file AI review with a two-phase pipeline that renders suggestions progressively as each file completes.

**Architecture:** Phase 1 = one Claude CLI call to summarize all diffs. Phase 2 = N parallel Claude CLI calls (one per file), each receiving its diff + summaries of other files. Each completion triggers immediate rendering.

**Tech Stack:** Lua (Neovim plugin), Claude CLI (`claude -p`), `vim.fn.jobstart`

---

### Task 1: Add `build_summary_prompt()` and `parse_summary_output()` to prompt module

**Files:**
- Modify: `lua/codereview/ai/prompt.lua:116` (before `build_orchestrator_prompt`)
- Test: `tests/codereview/ai/prompt_spec.lua`

**Step 1: Write failing tests**

Add to `tests/codereview/ai/prompt_spec.lua` after the `build_orchestrator_prompt` describe block (before the final `end`):

```lua
describe("build_summary_prompt", function()
  it("includes MR context and all file diffs", function()
    local review = { title = "Fix auth", description = "Token fix" }
    local diffs = {
      { new_path = "src/auth.lua", diff = "@@ -1,2 +1,3 @@\n-old\n+new\n" },
      { new_path = "src/config.lua", diff = "@@ -5,1 +5,2 @@\n+added\n" },
    }
    local result = prompt.build_summary_prompt(review, diffs)
    assert.truthy(result:find("Fix auth"))
    assert.truthy(result:find("src/auth.lua"))
    assert.truthy(result:find("src/config.lua"))
    assert.truthy(result:find("JSON"))
    assert.truthy(result:find("one%-sentence summary"))
  end)
end)

describe("parse_summary_output", function()
  it("extracts file-to-summary map from JSON block", function()
    local output = '```json\n{"src/auth.lua": "Fixed token refresh logic", "src/config.lua": "Added timeout setting"}\n```'
    local summaries = prompt.parse_summary_output(output)
    assert.equals("Fixed token refresh logic", summaries["src/auth.lua"])
    assert.equals("Added timeout setting", summaries["src/config.lua"])
  end)

  it("returns empty table on missing JSON", function()
    local summaries = prompt.parse_summary_output("no json here")
    assert.same({}, summaries)
  end)

  it("returns empty table on nil input", function()
    local summaries = prompt.parse_summary_output(nil)
    assert.same({}, summaries)
  end)
end)
```

**Step 2: Run tests to verify they fail**

Run: `busted tests/codereview/ai/prompt_spec.lua`
Expected: FAIL — `build_summary_prompt` and `parse_summary_output` do not exist

**Step 3: Implement `build_summary_prompt` and `parse_summary_output`**

Add to `lua/codereview/ai/prompt.lua` before `build_orchestrator_prompt` (line 116):

```lua
function M.build_summary_prompt(review, diffs)
  local parts = {
    "You are summarizing changes in a merge request for context.",
    "",
    "## MR Title",
    review.title or "",
    "",
    "## MR Description",
    review.description or "(no description)",
    "",
    "## Changed Files",
    "",
  }

  for _, file in ipairs(diffs) do
    table.insert(parts, "### " .. (file.new_path or file.old_path))
    table.insert(parts, "```diff")
    table.insert(parts, file.diff or "")
    table.insert(parts, "```")
    table.insert(parts, "")
  end

  table.insert(parts, "## Instructions")
  table.insert(parts, "")
  table.insert(parts, "For each file, write a one-sentence summary of what changed.")
  table.insert(parts, "Output a JSON object in a ```json code block:")
  table.insert(parts, '{"path/to/file.lua": "Summary of changes", ...}')

  return table.concat(parts, "\n")
end

function M.parse_summary_output(output)
  if not output or output == "" then return {} end

  local json_str = output:match("```json%s*\n(.+)\n```")
  if not json_str then
    json_str = output:match("%{.+%}")
  end
  if not json_str then return {} end

  local ok, data = pcall(vim.json.decode, json_str)
  if not ok or type(data) ~= "table" then return {} end

  return data
end
```

**Step 4: Run tests to verify they pass**

Run: `busted tests/codereview/ai/prompt_spec.lua`
Expected: ALL PASS

**Step 5: Commit**

```
feat(ai): add summary prompt builder and parser

Phase 1 of parallel review: generates one-line summaries of each
file's changes for cross-file context.
```

---

### Task 2: Add `build_file_review_prompt()` to prompt module

**Files:**
- Modify: `lua/codereview/ai/prompt.lua` (after `parse_summary_output`)
- Test: `tests/codereview/ai/prompt_spec.lua`

**Step 1: Write failing tests**

Add to `tests/codereview/ai/prompt_spec.lua`:

```lua
describe("build_file_review_prompt", function()
  it("includes MR context, other file summaries, and target file diff", function()
    local review = { title = "Fix auth", description = "Token fix" }
    local file = { new_path = "src/auth.lua", diff = "@@ -1,2 +1,3 @@\n-old\n+new\n" }
    local summaries = {
      ["src/auth.lua"] = "Fixed token refresh",
      ["src/config.lua"] = "Added timeout setting",
    }
    local result = prompt.build_file_review_prompt(review, file, summaries)
    -- Contains MR context
    assert.truthy(result:find("Fix auth"))
    assert.truthy(result:find("Token fix"))
    -- Contains other file summaries (not the target file itself)
    assert.truthy(result:find("src/config.lua"))
    assert.truthy(result:find("Added timeout setting"))
    -- Contains the file's diff
    assert.truthy(result:find("%-old"))
    assert.truthy(result:find("%+new"))
    -- Contains review instructions and JSON format
    assert.truthy(result:find("JSON"))
    assert.truthy(result:find("severity"))
  end)

  it("handles empty summaries", function()
    local review = { title = "T", description = "D" }
    local file = { new_path = "a.lua", diff = "diff" }
    local result = prompt.build_file_review_prompt(review, file, {})
    assert.truthy(result:find("a.lua"))
    -- Should still work, just no other files section
    assert.truthy(result:find("JSON"))
  end)
end)
```

**Step 2: Run tests to verify they fail**

Run: `busted tests/codereview/ai/prompt_spec.lua`
Expected: FAIL — `build_file_review_prompt` does not exist

**Step 3: Implement `build_file_review_prompt`**

Add to `lua/codereview/ai/prompt.lua` after `parse_summary_output`:

```lua
function M.build_file_review_prompt(review, file, summaries)
  local path = file.new_path or file.old_path
  local parts = {
    "You are reviewing a single file in a merge request.",
    "",
    "## MR Title",
    review.title or "",
    "",
    "## MR Description",
    review.description or "(no description)",
    "",
  }

  -- Other changed files with summaries
  local others = {}
  for fpath, summary in pairs(summaries or {}) do
    if fpath ~= path then
      table.insert(others, string.format("- `%s`: %s", fpath, summary))
    end
  end
  if #others > 0 then
    table.insert(parts, "## Other Changed Files in This MR")
    for _, line in ipairs(others) do
      table.insert(parts, line)
    end
    table.insert(parts, "")
  end

  table.insert(parts, "## File Under Review: " .. path)
  table.insert(parts, "```diff")
  table.insert(parts, file.diff or "")
  table.insert(parts, "```")
  table.insert(parts, "")
  table.insert(parts, "## Instructions")
  table.insert(parts, "")
  table.insert(parts, "Review this file. Output a JSON array in a ```json code block.")
  table.insert(parts, 'Each item: {"file": "' .. path .. '", "line": <new_line_number>, "severity": "error"|"warning"|"info"|"suggestion", "comment": "text"}')
  table.insert(parts, 'Use \\n inside "comment" strings for line breaks.')
  table.insert(parts, "If no issues, output `[]`.")
  table.insert(parts, "Focus on: bugs, security, error handling, edge cases, naming, clarity.")
  table.insert(parts, "Do NOT comment on style or formatting.")

  return table.concat(parts, "\n")
end
```

**Step 4: Run tests to verify they pass**

Run: `busted tests/codereview/ai/prompt_spec.lua`
Expected: ALL PASS

**Step 5: Commit**

```
feat(ai): add per-file review prompt builder

Phase 2 prompt for parallel review: includes MR context, other file
summaries, and the target file's diff.
```

---

### Task 3: Extend session state for multi-job tracking

**Files:**
- Modify: `lua/codereview/review/session.lua`
- Test: `tests/codereview/review/session_spec.lua`

**Step 1: Write failing tests**

Add to `tests/codereview/review/session_spec.lua` before the final `end`:

```lua
describe("ai_start() with multiple jobs", function()
  it("stores job_ids table and sets total count", function()
    session.start()
    session.ai_start({ 10, 20, 30 }, 3)
    local s = session.get()
    assert.is_true(s.ai_pending)
    assert.same({ 10, 20, 30 }, s.ai_job_ids)
    assert.equals(3, s.ai_total)
    assert.equals(0, s.ai_completed)
  end)

  -- Backwards compat: single job_id number still works
  it("wraps single job_id in a table", function()
    session.start()
    session.ai_start(42)
    local s = session.get()
    assert.is_true(s.ai_pending)
    assert.same({ 42 }, s.ai_job_ids)
    assert.equals(1, s.ai_total)
  end)
end)

describe("ai_file_done()", function()
  it("increments completed counter", function()
    session.start()
    session.ai_start({ 10, 20 }, 2)
    session.ai_file_done()
    local s = session.get()
    assert.equals(1, s.ai_completed)
    assert.is_true(s.ai_pending) -- still pending, 1 of 2 done
  end)

  it("calls ai_finish when all files complete", function()
    session.start()
    session.ai_start({ 10, 20 }, 2)
    session.ai_file_done()
    session.ai_file_done()
    local s = session.get()
    assert.equals(2, s.ai_completed)
    assert.is_false(s.ai_pending) -- auto-finished
  end)
end)
```

**Step 2: Run tests to verify they fail**

Run: `busted tests/codereview/review/session_spec.lua`
Expected: FAIL — `ai_job_ids`, `ai_total`, `ai_completed`, `ai_file_done` do not exist

**Step 3: Implement session changes**

Rewrite `lua/codereview/review/session.lua`:

```lua
-- lua/codereview/review/session.lua
-- Review session state machine.
--
-- States:
--   active=false                       → IDLE: comments post immediately
--   active=true, ai_pending=false      → REVIEWING: comments accumulate as drafts
--   active=true, ai_pending=true       → REVIEWING+AI: same, AI processing in background

local M = {}

local _state = {
  active = false,
  ai_pending = false,
  ai_job_ids = {},
  ai_total = 0,
  ai_completed = 0,
}

--- Return a copy of the current session state.
function M.get()
  return {
    active = _state.active,
    ai_pending = _state.ai_pending,
    ai_job_id = _state.ai_job_ids[1], -- backwards compat
    ai_job_ids = _state.ai_job_ids,
    ai_total = _state.ai_total,
    ai_completed = _state.ai_completed,
  }
end

--- Enter review mode. Comments will accumulate as drafts.
function M.start()
  _state.active = true
end

--- Exit review mode.
function M.stop()
  _state.active = false
  _state.ai_pending = false
  _state.ai_job_ids = {}
  _state.ai_total = 0
  _state.ai_completed = 0
  require("codereview.ui.spinner").close()
end

--- Record that AI subprocess(es) have started.
---@param job_ids number|number[] jobstart() handle(s) for cancellation
---@param total? number total file count (defaults to 1 for backwards compat)
function M.ai_start(job_ids, total)
  if type(job_ids) == "number" then
    job_ids = { job_ids }
  end
  _state.ai_pending = true
  _state.ai_job_ids = job_ids
  _state.ai_total = total or #job_ids
  _state.ai_completed = 0
  require("codereview.ui.spinner").open()
end

--- Record that one file's AI review completed. Auto-finishes when all done.
function M.ai_file_done()
  _state.ai_completed = _state.ai_completed + 1
  if _state.ai_completed >= _state.ai_total then
    M.ai_finish()
  end
end

--- Record that the AI subprocess has finished (success or error).
function M.ai_finish()
  _state.ai_pending = false
  _state.ai_job_ids = {}
  require("codereview.ui.spinner").close()
end

--- Reset to idle state.
function M.reset()
  _state.active = false
  _state.ai_pending = false
  _state.ai_job_ids = {}
  _state.ai_total = 0
  _state.ai_completed = 0
end

return M
```

**Step 4: Run tests to verify they pass**

Run: `busted tests/codereview/review/session_spec.lua`
Expected: ALL PASS (old tests should still pass due to backwards compat in `ai_start`)

**Step 5: Commit**

```
feat(review): extend session state for multi-job AI tracking

Adds ai_job_ids, ai_total, ai_completed counters and ai_file_done()
for progressive per-file review completion.
```

---

### Task 4: Add dynamic text support to spinner

**Files:**
- Modify: `lua/codereview/ui/spinner.lua`

**Step 1: Implement `set_label()` on spinner**

Modify `lua/codereview/ui/spinner.lua` to support dynamic label updates:

```lua
-- lua/codereview/ui/spinner.lua
-- Persistent top-right spinner float shown while AI review is running.
local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local DEFAULT_LABEL = " AI reviewing… "
local INTERVAL_MS = 80

local win_id = nil
local buf_id = nil
local timer_id = nil
local frame_idx = 1
local current_label = DEFAULT_LABEL

function M.open()
  if win_id and vim.api.nvim_win_is_valid(win_id) then return end

  current_label = DEFAULT_LABEL
  buf_id = vim.api.nvim_create_buf(false, true)
  vim.bo[buf_id].bufhidden = "wipe"

  local width = #current_label + 2 -- frame char + space
  win_id = vim.api.nvim_open_win(buf_id, false, {
    relative = "editor",
    anchor = "NE",
    row = 0,
    col = vim.o.columns,
    width = width,
    height = 1,
    style = "minimal",
    focusable = false,
    zindex = 50,
    border = "rounded",
  })

  vim.api.nvim_set_option_value("winblend", 0, { win = win_id })

  frame_idx = 1
  local function update()
    if not buf_id or not vim.api.nvim_buf_is_valid(buf_id) then
      M.close()
      return
    end
    local text = " " .. FRAMES[frame_idx] .. current_label
    vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, { text })
    -- Resize window to fit new label
    if win_id and vim.api.nvim_win_is_valid(win_id) then
      local new_width = #text + 1
      vim.api.nvim_win_set_width(win_id, new_width)
    end
    frame_idx = frame_idx % #FRAMES + 1
  end

  update()
  timer_id = vim.fn.timer_start(INTERVAL_MS, function()
    vim.schedule(update)
  end, { ["repeat"] = -1 })
end

--- Update the spinner label text (e.g. " AI reviewing… 3/8 files ").
---@param label string
function M.set_label(label)
  current_label = label
end

function M.close()
  if timer_id then
    vim.fn.timer_stop(timer_id)
    timer_id = nil
  end
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    vim.api.nvim_win_close(win_id, true)
  end
  win_id = nil
  buf_id = nil
  frame_idx = 1
  current_label = DEFAULT_LABEL
end

return M
```

Key changes from original:
- `LABEL` → `DEFAULT_LABEL` + `current_label` variable
- `set_label(label)` function to update text dynamically
- `update()` resizes window width when label changes
- `close()` resets `current_label` to default

**Step 2: Verify no tests broken**

Run: `busted tests/`
Expected: ALL PASS (spinner has no tests; prompt and session tests unaffected)

**Step 3: Commit**

```
feat(spinner): support dynamic label text updates

Adds set_label() to change spinner text at runtime for progressive
review progress display.
```

---

### Task 5: Rewrite multi-file review orchestration in `review/init.lua`

**Files:**
- Modify: `lua/codereview/review/init.lua`
- Modify: `lua/codereview/mr/diff.lua` (cancellation + sidebar status text)

**Depends on:** Tasks 1-4

**Step 1: Rewrite `review/init.lua`**

Replace the entire file:

```lua
-- lua/codereview/review/init.lua
local ai_sub = require("codereview.ai.subprocess")
local prompt_mod = require("codereview.ai.prompt")
local M = {}

--- Render suggestions for a single file into the diff view.
local function render_file_suggestions(diff_state, layout, suggestions)
  vim.schedule(function()
    -- Merge new suggestions into existing list
    diff_state.ai_suggestions = diff_state.ai_suggestions or {}
    for _, s in ipairs(suggestions) do
      table.insert(diff_state.ai_suggestions, s)
    end

    local diff_mod = require("codereview.mr.diff")

    -- Re-render current view to show new suggestions
    if diff_state.scroll_mode then
      local result = diff_mod.render_all_files(
        layout.main_buf, diff_state.files, diff_state.review,
        diff_state.discussions, diff_state.context,
        diff_state.file_contexts, diff_state.ai_suggestions,
        diff_state.row_selection, diff_state.current_user
      )
      diff_state.file_sections = result.file_sections
      diff_state.scroll_line_data = result.line_data
      diff_state.scroll_row_disc = result.row_discussions
      diff_state.scroll_row_ai = result.row_ai
    else
      local file = diff_state.files and diff_state.files[diff_state.current_file]
      if file then
        local ld, rd, ra = diff_mod.render_file_diff(
          layout.main_buf, file, diff_state.review,
          diff_state.discussions, diff_state.context,
          diff_state.ai_suggestions,
          diff_state.row_selection, diff_state.current_user
        )
        diff_state.line_data_cache[diff_state.current_file] = ld
        diff_state.row_disc_cache[diff_state.current_file] = rd
        diff_state.row_ai_cache[diff_state.current_file] = ra
      end
    end
    diff_mod.render_sidebar(layout.sidebar_buf, diff_state)
    vim.api.nvim_set_current_win(layout.main_win)
  end)
end

--- Single-file review (unchanged behavior).
local function start_single(review, diff_state, layout)
  local diffs = diff_state.files
  local review_prompt = prompt_mod.build_review_prompt(review, diffs)
  local session = require("codereview.review.session")
  session.start()

  local job_id = ai_sub.run(review_prompt, function(output, ai_err)
    session.ai_finish()

    if ai_err then
      vim.notify("AI review failed: " .. ai_err, vim.log.levels.ERROR)
      return
    end

    local suggestions = prompt_mod.parse_review_output(output)
    if #suggestions == 0 then
      vim.notify("AI review: no issues found!", vim.log.levels.INFO)
      return
    end

    vim.notify(string.format("AI review: %d suggestions found", #suggestions), vim.log.levels.INFO)

    vim.schedule(function()
      diff_state.ai_suggestions = suggestions

      if diff_state.view_mode ~= "diff" then
        diff_state.view_mode = "diff"
        diff_state.current_file = diff_state.current_file or 1
      end
    end)

    render_file_suggestions(diff_state, layout, suggestions)
  end)

  if job_id and job_id > 0 then
    session.ai_start(job_id)
    vim.notify("AI review started…", vim.log.levels.INFO)
  end
end

--- Multi-file review: Phase 1 (summary) then Phase 2 (parallel per-file).
local function start_multi(review, diff_state, layout)
  local diffs = diff_state.files
  local session = require("codereview.review.session")
  local spinner = require("codereview.ui.spinner")
  session.start()

  diff_state.ai_suggestions = {}

  -- Switch to diff view
  if diff_state.view_mode ~= "diff" then
    diff_state.view_mode = "diff"
    diff_state.current_file = diff_state.current_file or 1
  end

  -- Phase 1: summary pre-pass
  local summary_prompt = prompt_mod.build_summary_prompt(review, diffs)
  local summary_job = ai_sub.run(summary_prompt, function(output, ai_err)
    if ai_err then
      session.ai_finish()
      vim.notify("AI summary failed: " .. ai_err, vim.log.levels.ERROR)
      return
    end

    local summaries = prompt_mod.parse_summary_output(output)

    -- Phase 2: parallel per-file reviews
    local total = #diffs
    local job_ids = {}

    for _, file in ipairs(diffs) do
      local file_prompt = prompt_mod.build_file_review_prompt(review, file, summaries)
      local path = file.new_path or file.old_path

      local file_job = ai_sub.run(file_prompt, function(file_output, file_err)
        if file_err then
          vim.notify("AI review failed for " .. path .. ": " .. file_err, vim.log.levels.WARN)
        else
          local suggestions = prompt_mod.parse_review_output(file_output)
          if #suggestions > 0 then
            render_file_suggestions(diff_state, layout, suggestions)
          end
        end

        -- Update progress
        local s = session.get()
        spinner.set_label(string.format(" AI reviewing… %d/%d files ", s.ai_completed + 1, s.ai_total))

        vim.schedule(function()
          local diff_mod = require("codereview.mr.diff")
          diff_mod.render_sidebar(layout.sidebar_buf, diff_state)
        end)

        session.ai_file_done()

        -- All done?
        if not session.get().ai_pending then
          local count = #(diff_state.ai_suggestions or {})
          if count == 0 then
            vim.schedule(function()
              vim.notify("AI review: no issues found!", vim.log.levels.INFO)
            end)
          else
            vim.schedule(function()
              vim.notify(string.format("AI review: %d suggestions found", count), vim.log.levels.INFO)
            end)
          end
        end
      end)

      if file_job and file_job > 0 then
        table.insert(job_ids, file_job)
      end
    end

    -- Store all job IDs for cancellation; update session with real counts
    session.ai_start(job_ids, total)
    spinner.set_label(string.format(" AI reviewing… 0/%d files ", total))
  end, { skip_agent = true }) -- no --agent for summary call

  if summary_job and summary_job > 0 then
    -- Use summary job as initial tracking; will be replaced in Phase 2
    session.ai_start(summary_job)
    spinner.set_label(" AI summarizing… ")
    vim.notify("AI review started (summarizing files)…", vim.log.levels.INFO)
  end
end

function M.start(review, diff_state, layout)
  local diffs = diff_state.files
  if #diffs <= 1 then
    start_single(review, diff_state, layout)
  else
    start_multi(review, diff_state, layout)
  end
end

return M
```

**Step 2: Update cancellation in `diff.lua`**

In `lua/codereview/mr/diff.lua`, there are two places that cancel AI review by calling `vim.fn.jobstop(sess.ai_job_id)`. Update both to stop ALL jobs:

At line ~2052-2054 (the `quit` function):
```lua
-- BEFORE:
if sess.ai_job_id then vim.fn.jobstop(sess.ai_job_id) end

-- AFTER:
for _, jid in ipairs(sess.ai_job_ids or {}) do
  pcall(vim.fn.jobstop, jid)
end
```

At line ~2554-2556 (the `ai_review` keymap):
```lua
-- BEFORE:
if s.ai_job_id then vim.fn.jobstop(s.ai_job_id) end

-- AFTER:
for _, jid in ipairs(s.ai_job_ids or {}) do
  pcall(vim.fn.jobstop, jid)
end
```

**Step 3: Update sidebar status text for progress**

In `lua/codereview/mr/diff.lua` at line ~1224-1225, update the AI reviewing status line to show progress:
```lua
-- BEFORE:
if sess.ai_pending then
  table.insert(lines, "⟳ AI reviewing…")

-- AFTER:
if sess.ai_pending then
  if sess.ai_total > 0 and sess.ai_completed > 0 then
    table.insert(lines, string.format("⟳ AI reviewing… %d/%d", sess.ai_completed, sess.ai_total))
  else
    table.insert(lines, "⟳ AI reviewing…")
  end
```

**Step 4: Verify no tests broken**

Run: `busted tests/`
Expected: ALL PASS

**Step 5: Manual test checklist** (for the engineer to verify locally if possible)

- [ ] Open a multi-file MR, press `A`
- [ ] Spinner shows "AI summarizing…" initially
- [ ] Spinner updates to "AI reviewing… 0/N files" after summary completes
- [ ] Suggestions appear progressively as each file completes
- [ ] Sidebar updates per-file AI counts as each completes
- [ ] Pressing `A` again cancels all subprocesses
- [ ] Single-file MR still works as before

**Step 6: Commit**

```
feat(review): parallel per-file AI review with progressive rendering

Replaces the single-subprocess orchestrator with a two-phase pipeline:
1. Summary pre-pass for cross-file context
2. Parallel per-file reviews that render as each completes

Spinner and sidebar update progressively. Cancellation stops all jobs.
```

---

### Task 6: Clean up — remove `build_orchestrator_prompt` (dead code)

**Files:**
- Modify: `lua/codereview/ai/prompt.lua` (remove `build_orchestrator_prompt`)
- Modify: `tests/codereview/ai/prompt_spec.lua` (remove orchestrator tests)

**Depends on:** Task 5

**Step 1: Remove `build_orchestrator_prompt` from `lua/codereview/ai/prompt.lua`**

Delete the entire function (current lines 116-182).

**Step 2: Remove orchestrator tests from `tests/codereview/ai/prompt_spec.lua`**

Delete the `describe("build_orchestrator_prompt", ...)` block (current lines 143-195).

**Step 3: Run tests to verify nothing breaks**

Run: `busted tests/`
Expected: ALL PASS

**Step 4: Commit**

```
refactor(ai): remove orchestrator prompt (replaced by parallel pipeline)
```

---

## Unresolved Questions

None — all design decisions were made during brainstorming.
