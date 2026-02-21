# Stage 5: AI Review + MR Creation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Claude CLI reviews MRs and drafts comments for you to triage (accept/edit/delete). Also create new MRs with Claude-drafted titles and descriptions.

**Architecture:** Shell out to `claude` CLI with MR diff as input. Parse structured JSON output. Triage UI reuses the sidebar+diff split from Stage 3. Accepted suggestions become GitLab draft notes, published in bulk. MR creation uses Claude to generate title/description from branch diff.

**Tech Stack:** Lua, Neovim API, Claude CLI (subprocess), plenary.nvim

**Depends on:** Stage 1 (API), Stage 2 (float, picker), Stage 3 (diff renderer, split layout)

---

### Task 1: Claude CLI Subprocess

**Files:**
- Create: `lua/glab_review/review/ai.lua`
- Create: `tests/glab_review/review/ai_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/review/ai_spec.lua
local ai = require("glab_review.review.ai")

describe("review.ai", function()
  describe("build_review_prompt", function()
    it("builds prompt with MR context", function()
      local mr = {
        title = "Fix auth token refresh",
        description = "Fixes the bug where tokens expire silently",
      }
      local diffs = {
        {
          new_path = "src/auth.lua",
          diff = "@@ -10,3 +10,4 @@\n context\n-old\n+new\n+added\n",
        },
      }
      local prompt = ai.build_review_prompt(mr, diffs)
      assert.truthy(prompt:find("Fix auth token refresh"))
      assert.truthy(prompt:find("src/auth.lua"))
      assert.truthy(prompt:find("JSON"))
    end)
  end)

  describe("parse_review_output", function()
    it("parses JSON array from Claude output", function()
      local output = [[
Here are my findings:

```json
[
  {"file": "src/auth.lua", "line": 15, "severity": "warning", "comment": "Missing error check"},
  {"file": "src/auth.lua", "line": 42, "severity": "info", "comment": "Consider renaming"}
]
```
]]
      local suggestions = ai.parse_review_output(output)
      assert.equals(2, #suggestions)
      assert.equals("src/auth.lua", suggestions[1].file)
      assert.equals(15, suggestions[1].line)
      assert.equals("Missing error check", suggestions[1].comment)
    end)

    it("handles output with no JSON", function()
      local suggestions = ai.parse_review_output("No issues found, looks good!")
      assert.equals(0, #suggestions)
    end)

    it("handles malformed JSON gracefully", function()
      local suggestions = ai.parse_review_output("```json\n{broken\n```")
      assert.equals(0, #suggestions)
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement AI module**

```lua
-- lua/glab_review/review/ai.lua
local config = require("glab_review.config")
local M = {}

function M.build_review_prompt(mr, diffs)
  local parts = {
    "You are reviewing a GitLab merge request.",
    "",
    "## MR Title",
    mr.title or "",
    "",
    "## MR Description",
    mr.description or "(no description)",
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
  table.insert(parts, "Review this merge request. For each issue or suggestion you find, output a JSON array.")
  table.insert(parts, "Each item must have these fields:")
  table.insert(parts, '- "file": the file path (e.g. "src/auth.lua")')
  table.insert(parts, '- "line": the NEW line number in the diff where the issue is')
  table.insert(parts, '- "severity": one of "error", "warning", "info", "suggestion"')
  table.insert(parts, '- "comment": your review comment (be specific and actionable)')
  table.insert(parts, "")
  table.insert(parts, "Output the JSON array in a ```json code block. If there are no issues, output an empty array [].")
  table.insert(parts, "Focus on: bugs, security issues, error handling, edge cases, naming, and code clarity.")
  table.insert(parts, "Do NOT comment on style, formatting, or trivial matters.")

  return table.concat(parts, "\n")
end

function M.parse_review_output(output)
  if not output or output == "" then return {} end

  -- Extract JSON from code block
  local json_str = output:match("```json%s*\n(.-)\n%s*```")
  if not json_str then
    -- Try raw JSON array
    json_str = output:match("%[.-%]")
  end

  if not json_str then return {} end

  local ok, data = pcall(vim.json.decode, json_str)
  if not ok or type(data) ~= "table" then return {} end

  -- Validate and normalize entries
  local suggestions = {}
  for _, item in ipairs(data) do
    if type(item) == "table" and item.file and item.line and item.comment then
      table.insert(suggestions, {
        file = item.file,
        line = tonumber(item.line),
        severity = item.severity or "info",
        comment = item.comment,
        status = "pending",  -- pending | accepted | deleted
      })
    end
  end

  return suggestions
end

function M.run_review(mr, diffs, callback)
  local cfg = config.get()
  if not cfg.ai.enabled then
    vim.notify("AI review is disabled in config", vim.log.levels.WARN)
    return
  end

  local prompt = M.build_review_prompt(mr, diffs)
  local cmd = cfg.ai.claude_cmd

  -- Write prompt to temp file to avoid shell escaping issues
  local tmpfile = os.tmpname()
  local f = io.open(tmpfile, "w")
  if not f then
    callback(nil, "Failed to create temp file")
    return
  end
  f:write(prompt)
  f:close()

  vim.notify("Running AI review...", vim.log.levels.INFO)

  local done = false  -- Prevent double callback from stdout/exit race
  local job_id = vim.fn.jobstart({
    cmd,
    "--print",
    "--max-turns", "1",
    "--prompt", "Review the merge request described below. " ..
      "Output your findings as a JSON array in a ```json code block.",
    tmpfile,
  }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if done then return end
      local output = table.concat(data, "\n")
      if output == "" then return end  -- Ignore empty stdout
      done = true
      vim.schedule(function()
        os.remove(tmpfile)
        local suggestions = M.parse_review_output(output)
        callback(suggestions)
      end)
    end,
    on_exit = function(_, code)
      if done then return end
      done = true
      vim.schedule(function()
        os.remove(tmpfile)
        if code ~= 0 then
          callback(nil, "Claude CLI exited with code " .. code)
        else
          -- stdout was empty but exit was clean — no suggestions
          callback({})
        end
      end)
    end,
  })
  if job_id <= 0 then
    os.remove(tmpfile)
    callback(nil, "Failed to start Claude CLI. Is '" .. cmd .. "' in your PATH?")
    return
  end
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/review/ai.lua tests/glab_review/review/ai_spec.lua
git commit -m "feat: add Claude CLI integration with structured review prompt"
```

---

### Task 2: Draft Comment Management

**Files:**
- Create: `lua/glab_review/review/draft.lua`
- Create: `tests/glab_review/review/draft_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/review/draft_spec.lua
local draft = require("glab_review.review.draft")

describe("review.draft", function()
  describe("suggestion_to_draft_params", function()
    it("builds draft note params from suggestion", function()
      local suggestion = {
        file = "src/auth.lua",
        line = 15,
        comment = "Missing error check",
      }
      local diff_refs = {
        base_sha = "abc",
        head_sha = "def",
        start_sha = "ghi",
      }
      local params = draft.suggestion_to_draft_params(suggestion, diff_refs)
      assert.equals("Missing error check", params.note)
      assert.equals("text", params.position.position_type)
      assert.equals("abc", params.position.base_sha)
      assert.equals("def", params.position.head_sha)
      assert.equals("ghi", params.position.start_sha)
      assert.equals("src/auth.lua", params.position.new_path)
      assert.equals(15, params.position.new_line)
    end)
  end)

  describe("build_sidebar_lines", function()
    it("builds suggestion list for sidebar", function()
      local suggestions = {
        { file = "auth.lua", line = 15, comment = "Missing check", status = "accepted", severity = "warning" },
        { file = "auth.lua", line = 42, comment = "Error swallowed", status = "pending", severity = "error" },
        { file = "diff.lua", line = 23, comment = "Off-by-one", status = "pending", severity = "info" },
      }
      local lines = draft.build_sidebar_lines(suggestions, 2)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("auth.lua:15"))
      assert.truthy(joined:find("auth.lua:42"))
      assert.truthy(joined:find("Reviewed: 1/3"))
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement draft management**

```lua
-- lua/glab_review/review/draft.lua
local M = {}

function M.suggestion_to_draft_params(suggestion, diff_refs)
  return {
    note = suggestion.comment,
    position = {
      position_type = "text",
      base_sha = diff_refs.base_sha,
      head_sha = diff_refs.head_sha,
      start_sha = diff_refs.start_sha,
      new_path = suggestion.file,
      old_path = suggestion.file,
      new_line = suggestion.line,
    },
  }
end

local STATUS_ICONS = {
  accepted = "+",
  pending = "o",
  deleted = "x",
}

function M.build_sidebar_lines(suggestions, current_idx)
  local lines = {}

  local accepted = 0
  for _, s in ipairs(suggestions) do
    if s.status == "accepted" then accepted = accepted + 1 end
  end

  table.insert(lines, string.format("AI Review: %d comments", #suggestions))
  table.insert(lines, string.rep("=", 24))
  table.insert(lines, "")

  for i, s in ipairs(suggestions) do
    if s.status == "deleted" then goto continue end

    local icon = STATUS_ICONS[s.status] or "o"
    local pointer = i == current_idx and "> " or "  "
    local short_file = s.file:match("[^/]+$") or s.file

    table.insert(lines, string.format(
      "%s%s %d. %s:%d",
      pointer, icon, i, short_file, s.line
    ))
    table.insert(lines, string.format(
      "    %s",
      s.comment:sub(1, 40)
    ))

    if s.status == "pending" then
      table.insert(lines, "    [a]ccept [e]dit [d]el")
    else
      table.insert(lines, string.format("    %s", s.status))
    end
    table.insert(lines, "")

    ::continue::
  end

  table.insert(lines, string.rep("=", 24))
  table.insert(lines, string.format("Reviewed: %d/%d", accepted, #suggestions))
  table.insert(lines, "[A] Accept all")
  table.insert(lines, "[S] Submit review")
  table.insert(lines, "[q] Cancel review")

  return lines
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/review/draft.lua tests/glab_review/review/draft_spec.lua
git commit -m "feat: add draft comment management with sidebar builder"
```

---

### Task 3: Review Submission

**Files:**
- Create: `lua/glab_review/review/submit.lua`
- Create: `tests/glab_review/review/submit_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/review/submit_spec.lua
local submit = require("glab_review.review.submit")

describe("review.submit", function()
  describe("filter_accepted", function()
    it("returns only accepted suggestions", function()
      local suggestions = {
        { comment = "a", status = "accepted" },
        { comment = "b", status = "pending" },
        { comment = "c", status = "accepted" },
        { comment = "d", status = "deleted" },
      }
      local accepted = submit.filter_accepted(suggestions)
      assert.equals(2, #accepted)
      assert.equals("a", accepted[1].comment)
      assert.equals("c", accepted[2].comment)
    end)

    it("returns empty for no accepted", function()
      local suggestions = {
        { comment = "a", status = "pending" },
      }
      local accepted = submit.filter_accepted(suggestions)
      assert.equals(0, #accepted)
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement submit module**

```lua
-- lua/glab_review/review/submit.lua
local client = require("glab_review.api.client")
local endpoints = require("glab_review.api.endpoints")
local git = require("glab_review.git")
local draft = require("glab_review.review.draft")
local M = {}

function M.filter_accepted(suggestions)
  local accepted = {}
  for _, s in ipairs(suggestions) do
    if s.status == "accepted" then
      table.insert(accepted, s)
    end
  end
  return accepted
end

function M.create_draft_notes(mr, suggestions)
  local base_url, project = git.detect_project()
  if not base_url or not project then
    vim.notify("Could not detect GitLab project", vim.log.levels.ERROR)
    return false
  end
  local encoded = client.encode_project(project)

  local accepted = M.filter_accepted(suggestions)
  if #accepted == 0 then
    vim.notify("No accepted suggestions to submit", vim.log.levels.WARN)
    return false
  end

  local errors = {}
  for _, suggestion in ipairs(accepted) do
    local params = draft.suggestion_to_draft_params(suggestion, mr.diff_refs)
    local _, err = client.post(base_url, endpoints.draft_notes(encoded, mr.iid), {
      body = params,
    })
    if err then
      table.insert(errors, string.format("%s:%d - %s", suggestion.file, suggestion.line, err))
    end
  end

  if #errors > 0 then
    vim.notify("Some drafts failed:\n" .. table.concat(errors, "\n"), vim.log.levels.WARN)
  end

  return true
end

function M.bulk_publish(mr)
  local base_url, project = git.detect_project()
  if not base_url or not project then return false end
  local encoded = client.encode_project(project)

  local _, err = client.post(base_url, endpoints.draft_notes_publish(encoded, mr.iid), {})
  if err then
    vim.notify("Failed to publish drafts: " .. err, vim.log.levels.ERROR)
    return false
  end

  vim.notify("Review submitted!", vim.log.levels.INFO)
  return true
end

function M.submit_review(mr, suggestions)
  local ok = M.create_draft_notes(mr, suggestions)
  if ok then
    M.bulk_publish(mr)
  end
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/review/submit.lua tests/glab_review/review/submit_spec.lua
git commit -m "feat: add review submission via draft notes and bulk publish"
```

---

### Task 4: AI Review Triage UI

**Files:**
- Create: `lua/glab_review/review/triage.lua`

**Step 1: Implement triage UI**

This is the main orchestrator that wires the sidebar, diff view, and keymaps together.

```lua
-- lua/glab_review/review/triage.lua
local split = require("glab_review.ui.split")
local diff_mod = require("glab_review.mr.diff")
local draft = require("glab_review.review.draft")
local submit_mod = require("glab_review.review.submit")
local float = require("glab_review.ui.float")
local M = {}

function M.open(mr, diffs, discussions, suggestions)
  if #suggestions == 0 then
    vim.notify("AI review found no issues!", vim.log.levels.INFO)
    return
  end

  local layout = split.create({ sidebar_width = 30 })

  local state = {
    layout = layout,
    mr = mr,
    diffs = diffs,
    discussions = discussions,
    suggestions = suggestions,
    current_idx = 1,
  }

  M.render(state)
  M.setup_keymaps(state)

  return state
end

function M.render(state)
  local layout = state.layout

  -- Render sidebar
  local sidebar_lines = draft.build_sidebar_lines(state.suggestions, state.current_idx)
  vim.bo[layout.sidebar_buf].modifiable = true
  vim.api.nvim_buf_set_lines(layout.sidebar_buf, 0, -1, false, sidebar_lines)
  vim.bo[layout.sidebar_buf].modifiable = false

  -- Render diff pane focused on current suggestion
  local current = state.suggestions[state.current_idx]
  if current then
    -- Find the file diff for this suggestion
    for _, file_diff in ipairs(state.diffs) do
      if file_diff.new_path == current.file or file_diff.old_path == current.file then
        state.line_data = diff_mod.render_file_diff(
          layout.main_buf, file_diff, state.mr, state.discussions
        )

        -- Place draft comment inline as virtual text
        M.show_inline_draft(layout.main_buf, state.line_data, current)

        -- Scroll to the relevant line
        M.scroll_to_line(layout.main_win, state.line_data, current.line)
        break
      end
    end
  end
end

function M.show_inline_draft(buf, line_data, suggestion)
  local ns = vim.api.nvim_create_namespace("glab_review_draft")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  -- Find buffer line for this suggestion's line number
  for i, data in ipairs(line_data) do
    if data.new_line == suggestion.line then
      local virt_lines = {
        { { string.rep("-", 50), "GlabReviewComment" } },
        { { " Claude [Draft]", "GlabReviewComment" } },
        { { " " .. suggestion.comment, "GlabReviewComment" } },
        { { "", "GlabReviewComment" } },
        { { " [a]ccept   [e]dit   [d]elete", "GlabReviewComment" } },
        { { string.rep("-", 50), "GlabReviewComment" } },
      }

      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        virt_lines = virt_lines,
        virt_lines_above = false,
      })
      break
    end
  end
end

function M.scroll_to_line(win, line_data, target_line)
  for i, data in ipairs(line_data) do
    if data.new_line == target_line then
      pcall(vim.api.nvim_win_set_cursor, win, { i, 0 })
      vim.cmd("normal! zz")
      return
    end
  end
end

function M.navigate(state, direction)
  local new_idx = state.current_idx
  -- Skip deleted suggestions
  repeat
    new_idx = new_idx + direction
  until new_idx < 1 or new_idx > #state.suggestions or state.suggestions[new_idx].status ~= "deleted"

  if new_idx >= 1 and new_idx <= #state.suggestions then
    state.current_idx = new_idx
    M.render(state)
  end
end

function M.accept(state)
  state.suggestions[state.current_idx].status = "accepted"
  M.navigate(state, 1)
end

function M.delete_suggestion(state)
  state.suggestions[state.current_idx].status = "deleted"
  M.navigate(state, 1)
end

function M.edit(state)
  local current = state.suggestions[state.current_idx]

  -- Open small editable float
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(current.comment, "\n"))
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(60, vim.o.columns - 20)
  local height = math.max(5, #vim.split(current.comment, "\n") + 2)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    width = width,
    height = height,
    col = 2,
    row = 1,
    style = "minimal",
    border = "rounded",
    title = " Edit Comment ",
    title_pos = "center",
  })

  -- Save on close
  vim.keymap.set("n", "<CR>", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    current.comment = table.concat(lines, "\n")
    current.status = "accepted"
    vim.api.nvim_win_close(win, true)
    M.navigate(state, 1)
  end, { buffer = buf })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
end

function M.accept_all(state)
  for _, s in ipairs(state.suggestions) do
    if s.status == "pending" then
      s.status = "accepted"
    end
  end
  M.render(state)
end

function M.submit(state)
  submit_mod.submit_review(state.mr, state.suggestions)
  split.close(state.layout)
end

function M.setup_keymaps(state)
  local layout = state.layout
  local opts = { nowait = true }

  for _, buf in ipairs({ layout.main_buf, layout.sidebar_buf }) do
    local buf_opts = vim.tbl_extend("force", opts, { buffer = buf })

    vim.keymap.set("n", "a", function() M.accept(state) end, buf_opts)
    vim.keymap.set("n", "d", function() M.delete_suggestion(state) end, buf_opts)
    vim.keymap.set("n", "e", function() M.edit(state) end, buf_opts)
    vim.keymap.set("n", "A", function() M.accept_all(state) end, buf_opts)
    vim.keymap.set("n", "S", function() M.submit(state) end, buf_opts)

    vim.keymap.set("n", "]c", function() M.navigate(state, 1) end, buf_opts)
    vim.keymap.set("n", "[c", function() M.navigate(state, -1) end, buf_opts)

    -- Allow creating manual comments from triage view
    vim.keymap.set("n", "cc", function()
      local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
      local buf_line = cursor[1]
      local data = state.line_data and state.line_data[buf_line]
      if not data or data.type == "header" or data.type == "hidden" then
        vim.notify("Cannot comment on this line", vim.log.levels.WARN)
        return
      end
      local current = state.suggestions[state.current_idx]
      if not current then return end
      -- Find the file_diff for the current suggestion
      for _, file_diff in ipairs(state.diffs) do
        if file_diff.new_path == current.file or file_diff.old_path == current.file then
          local comment_mod = require("glab_review.mr.comment")
          comment_mod.create_inline(state.mr, file_diff.old_path, file_diff.new_path, data.old_line, data.new_line)
          break
        end
      end
    end, buf_opts)

    vim.keymap.set("n", "q", function() split.close(layout) end, buf_opts)
  end
end

return M
```

**Step 2: Commit**

```bash
git add lua/glab_review/review/triage.lua
git commit -m "feat: add AI review triage UI with sidebar and inline drafts"
```

---

### Task 5: Wire :GlabReviewAI Command

**Files:**
- Create: `lua/glab_review/review/init.lua`
- Modify: `lua/glab_review/init.lua`
- Modify: `lua/glab_review/mr/detail.lua`

**Step 1: Create review entry point**

```lua
-- lua/glab_review/review/init.lua
local client = require("glab_review.api.client")
local endpoints = require("glab_review.api.endpoints")
local git = require("glab_review.git")
local ai = require("glab_review.review.ai")
local triage = require("glab_review.review.triage")
local M = {}

function M.start(mr)
  local base_url, project = git.detect_project()
  if not base_url or not project then
    vim.notify("Could not detect GitLab project", vim.log.levels.ERROR)
    return
  end
  local encoded = client.encode_project(project)

  -- Fetch diffs
  local diffs = client.paginate_all(base_url, endpoints.mr_diffs(encoded, mr.iid))
  if not diffs or #diffs == 0 then
    vim.notify("No diffs found for this MR", vim.log.levels.WARN)
    return
  end

  -- Fetch discussions
  local discussions = client.paginate_all(base_url, endpoints.discussions(encoded, mr.iid)) or {}

  -- Run Claude review
  ai.run_review(mr, diffs, function(suggestions, err)
    if err then
      vim.notify("AI review failed: " .. err, vim.log.levels.ERROR)
      return
    end

    if not suggestions or #suggestions == 0 then
      vim.notify("AI review: no issues found!", vim.log.levels.INFO)
      return
    end

    vim.notify(string.format("AI review: %d suggestions found", #suggestions), vim.log.levels.INFO)
    triage.open(mr, diffs, discussions, suggestions)
  end)
end

return M
```

**Step 2: Wire into init.lua**

Replace the `M.ai_review` and `M.submit` stubs:

```lua
function M.ai_review()
  local buf = vim.api.nvim_get_current_buf()
  local mr = vim.b[buf].glab_review_mr
  if not mr then
    vim.notify("No MR context. Open an MR first with :GlabReview", vim.log.levels.WARN)
    return
  end
  require("glab_review.review").start(mr)
end

function M.submit()
  local buf = vim.api.nvim_get_current_buf()
  local mr = vim.b[buf].glab_review_mr
  if not mr then
    vim.notify("No MR context. Open an MR first with :GlabReview", vim.log.levels.WARN)
    return
  end
  local submit_mod = require("glab_review.review.submit")
  submit_mod.bulk_publish(mr)
end
```

**Step 3: Wire `A` keymap in detail.lua**

In `detail.lua`, replace the `A` keymap stub:

```lua
vim.keymap.set("n", "A", function()
  vim.api.nvim_win_close(win, true)
  require("glab_review.review").start(mr)
end, map_opts)
```

**Step 4: Commit**

```bash
git add lua/glab_review/review/init.lua lua/glab_review/init.lua lua/glab_review/mr/detail.lua
git commit -m "feat: wire up :GlabReviewAI command and AI review flow"
```

---

### Task 6: MR Creation with Claude

**Files:**
- Create: `lua/glab_review/mr/create.lua`
- Create: `tests/glab_review/mr/create_spec.lua`
- Modify: `lua/glab_review/init.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/mr/create_spec.lua
local create = require("glab_review.mr.create")

describe("mr.create", function()
  describe("build_mr_prompt", function()
    it("builds prompt from branch diff", function()
      local diff = "@@ -1,3 +1,5 @@\n context\n+added1\n+added2\n context\n"
      local branch = "fix/auth-refresh"
      local prompt = create.build_mr_prompt(branch, diff)
      assert.truthy(prompt:find("fix/auth-refresh"))
      assert.truthy(prompt:find("title"))
      assert.truthy(prompt:find("description"))
    end)
  end)

  describe("parse_mr_draft", function()
    it("extracts title and description from Claude output", function()
      local output = [[
## Title
Fix auth token refresh on expired sessions

## Description
This MR fixes the issue where expired refresh tokens cause silent auth failures.

Changes:
- Add proper error handling for token refresh
- Surface auth errors to the UI
- Add retry logic with exponential backoff
]]
      local title, description = create.parse_mr_draft(output)
      assert.truthy(title:find("Fix auth"))
      assert.truthy(description:find("retry logic"))
    end)

    it("handles simple output", function()
      local output = "Fix auth token refresh\n\nFixes the bug."
      local title, description = create.parse_mr_draft(output)
      assert.equals("Fix auth token refresh", title)
      assert.equals("Fixes the bug.", description)
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement MR creation module**

```lua
-- lua/glab_review/mr/create.lua
local client = require("glab_review.api.client")
local endpoints = require("glab_review.api.endpoints")
local git = require("glab_review.git")
local config_mod = require("glab_review.config")
local float = require("glab_review.ui.float")
local M = {}

function M.build_mr_prompt(branch, diff)
  return table.concat({
    "I'm creating a GitLab merge request for branch: " .. branch,
    "",
    "Here's the diff:",
    "```diff",
    diff,
    "```",
    "",
    "Write a concise MR title (one line, no prefix) and a clear description.",
    "Format your response as:",
    "## Title",
    "<the title>",
    "",
    "## Description",
    "<the description with bullet points for key changes>",
  }, "\n")
end

function M.parse_mr_draft(output)
  -- Try structured format first
  local title = output:match("## Title%s*\n([^\n]+)")
  local description = output:match("## Description%s*\n(.*)")

  if title and description then
    return vim.trim(title), vim.trim(description)
  end

  -- Fallback: first line is title, rest is description
  local lines = vim.split(output, "\n")
  title = lines[1] or ""

  -- Skip empty lines after title
  local desc_start = 2
  while desc_start <= #lines and vim.trim(lines[desc_start]) == "" do
    desc_start = desc_start + 1
  end

  description = table.concat(lines, "\n", desc_start)
  return vim.trim(title), vim.trim(description)
end

function M.get_branch_diff(target)
  target = target or "main"
  local result = vim.fn.systemlist({ "git", "diff", target .. "...HEAD" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return table.concat(result, "\n")
end

function M.get_current_branch()
  local result = vim.fn.systemlist({ "git", "branch", "--show-current" })
  if vim.v.shell_error ~= 0 or #result == 0 then
    return nil
  end
  return vim.trim(result[1])
end

function M.open_editor(title, description, target_branch, mr_opts, callback)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {
    "# MR Title (edit and save with <CR>):",
    title,
    "",
    "# Target Branch:",
    target_branch,
    "",
    "# Labels (comma-separated):",
    "",
    "# Assignee (username):",
    "",
    "# Description:",
    "",
  }
  for _, line in ipairs(vim.split(description, "\n")) do
    table.insert(lines, line)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(#lines + 5, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " New Merge Request ",
    title_pos = "center",
  })

  vim.keymap.set("n", "<CR>", function()
    local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- Parse: line 2 is title, then target branch, labels, assignee, then description
    local new_title = buf_lines[2] or title
    local metadata = {}
    local desc_lines = {}
    local section = nil
    for _, line in ipairs(buf_lines) do
      if line:find("^# Target Branch:") then
        section = "target"
      elseif line:find("^# Labels") then
        section = "labels"
      elseif line:find("^# Assignee") then
        section = "assignee"
      elseif line:find("^# Description:") then
        section = "desc"
      elseif section == "labels" and vim.trim(line) ~= "" then
        metadata.labels = vim.trim(line)
        section = nil
      elseif section == "assignee" and vim.trim(line) ~= "" then
        metadata.assignee = vim.trim(line)
        section = nil
      elseif section == "desc" then
        table.insert(desc_lines, line)
      end
    end
    local new_desc = table.concat(desc_lines, "\n")

    vim.api.nvim_win_close(win, true)
    callback(vim.trim(new_title), vim.trim(new_desc), metadata)
  end, { buffer = buf })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
end

function M.create(opts)
  opts = opts or {}
  local branch = M.get_current_branch()
  if not branch then
    vim.notify("Not on a branch", vim.log.levels.ERROR)
    return
  end

  if branch == "main" or branch == "master" then
    vim.notify("Cannot create MR from " .. branch, vim.log.levels.ERROR)
    return
  end

  -- Pick target branch
  local targets = { "main", "master", "develop" }
  -- Try to detect default branch from remote
  local default_branch = vim.fn.systemlist({ "git", "symbolic-ref", "refs/remotes/origin/HEAD" })
  if vim.v.shell_error == 0 and #default_branch > 0 then
    local db = default_branch[1]:match("refs/remotes/origin/(.+)")
    if db and not vim.tbl_contains(targets, db) then
      table.insert(targets, 1, db)
    end
  end

  vim.ui.select(targets, { prompt = "Target branch:" }, function(target)
    if not target then return end

    local diff = M.get_branch_diff(target)
    if not diff or diff == "" then
      vim.notify("No diff found against " .. target, vim.log.levels.WARN)
      return
    end

    -- Continue with Claude draft...
    M.draft_with_claude(branch, target, diff, opts)
  end)
end

function M.draft_with_claude(branch, target, diff, opts)
  local cfg = config_mod.get()
  local prompt = M.build_mr_prompt(branch, diff)
  local tmpfile = os.tmpname()
  local f = io.open(tmpfile, "w")
  f:write(prompt)
  f:close()

  vim.notify("Generating MR description...", vim.log.levels.INFO)

  local done = false
  local job_id = vim.fn.jobstart({
    cfg.ai.claude_cmd,
    "--print",
    "--max-turns", "1",
    tmpfile,
  }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if done then return end
      local output = table.concat(data, "\n")
      if output == "" then return end
      done = true
      vim.schedule(function()
        os.remove(tmpfile)
        local title, description = M.parse_mr_draft(output)
        M.open_editor(title, description, target, opts, function(final_title, final_desc, metadata)
          M.submit_mr(branch, target, final_title, final_desc, metadata)
        end)
      end)
    end,
    on_exit = function(_, code)
      if done then return end
      done = true
      vim.schedule(function()
        os.remove(tmpfile)
        if code ~= 0 then
          vim.notify("Claude CLI failed with code " .. code, vim.log.levels.ERROR)
        end
      end)
    end,
  })
  if job_id <= 0 then
    os.remove(tmpfile)
    vim.notify("Failed to start Claude CLI. Is '" .. cfg.ai.claude_cmd .. "' in your PATH?", vim.log.levels.ERROR)
    return
  end
end

function M.submit_mr(source_branch, target_branch, title, description, metadata)
  metadata = metadata or {}
  local base_url, project = git.detect_project()
  if not base_url or not project then return end
  local encoded = client.encode_project(project)

  local body = {
    source_branch = source_branch,
    target_branch = target_branch,
    title = title,
    description = description,
  }
  if metadata.labels then body.labels = metadata.labels end
  if metadata.assignee then body.assignee_id = metadata.assignee end

  local result, err = client.post(base_url, endpoints.mr_list(encoded), {
    body = body,
  })

  if not result then
    vim.notify("Failed to create MR: " .. (err or ""), vim.log.levels.ERROR)
    return
  end

  local mr = result.data
  vim.notify(string.format("MR !%d created: %s", mr.iid, mr.web_url), vim.log.levels.INFO)

  -- Open the new MR in detail view
  local detail = require("glab_review.mr.detail")
  detail.open({ iid = mr.iid })
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Wire into init.lua**

Replace the `M.create_mr` stub:

```lua
function M.create_mr()
  require("glab_review.mr.create").create()
end
```

**Step 6: Commit**

```bash
git add lua/glab_review/mr/create.lua tests/glab_review/mr/create_spec.lua lua/glab_review/init.lua
git commit -m "feat: add MR creation with Claude-drafted title and description"
```

---

### Stage 5 Deliverable Checklist

- [ ] Claude CLI called with structured review prompt
- [ ] JSON output parsed into suggestion objects
- [ ] Triage UI: suggestion list sidebar + inline draft comments in diff
- [ ] Navigate suggestions with `]c`/`[c`
- [ ] `a` accept, `e` edit (opens editable float), `d` delete
- [ ] `A` accept all pending
- [ ] `S` submit: creates draft notes via API, then bulk publishes
- [ ] `:GlabReviewAI` command works end-to-end
- [ ] `A` from MR detail triggers AI review
- [ ] `:GlabReviewOpen` creates MR from current branch
- [ ] Claude drafts title + description from branch diff
- [ ] Editable float for reviewing/editing the draft before submission
- [ ] MR created via API, opens in detail view
- [ ] Claude CLI callbacks use completion flag to prevent double invocation
- [ ] `jobstart` return value checked; user notified if Claude not in PATH
- [ ] `cc` keymap available in triage UI for manual comments
- [ ] Target branch picker with auto-detected default branch
- [ ] MR creation editor includes labels and assignee fields
- [ ] `:GlabReviewSubmit` works standalone to publish existing drafts
