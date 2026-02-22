# Stage 5: AI Review + MR Creation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Claude CLI reviews MR diffs and produces triage-able suggestions; accepted suggestions become platform-specific draft comments published in bulk. Also create new MRs with Claude-drafted title/description.

**Architecture:** `ai/subprocess` pipes prompts to `claude -p` via stdin. `ai/prompt` builds review and MR-creation prompts. `review/triage` reuses `ui/split` + `mr/diff.render_file_diff` for the triage UI. New provider methods handle platform-specific draft/publish. `mr/create` handles MR creation flow.

**Tech Stack:** Lua, Neovim API, Claude CLI (subprocess via jobstart/chansend), busted (tests)

**Test runner:** `busted --run unit` from project root. Tests use `tests/unit_helper.lua` which stubs `plenary.*` and adds `lua/` to package.path. Tests that need `vim.*` must stub those globals.

---

### Task 1: AI Subprocess Runner

**Files:**
- Create: `lua/codereview/ai/subprocess.lua`
- Create: `tests/codereview/ai/subprocess_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/codereview/ai/subprocess_spec.lua
local subprocess = require("codereview.ai.subprocess")

describe("ai.subprocess", function()
  describe("build_cmd", function()
    it("builds default claude command", function()
      local cmd = subprocess.build_cmd("claude")
      assert.same({ "claude", "-p", "--output-format", "json", "--max-turns", "1" }, cmd)
    end)

    it("uses custom command from config", function()
      local cmd = subprocess.build_cmd("/usr/local/bin/claude")
      assert.same({ "/usr/local/bin/claude", "-p", "--output-format", "json", "--max-turns", "1" }, cmd)
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `busted --run unit tests/codereview/ai/subprocess_spec.lua`
Expected: FAIL — module not found

**Step 3: Implement subprocess module**

```lua
-- lua/codereview/ai/subprocess.lua
local config = require("codereview.config")
local M = {}

function M.build_cmd(claude_cmd)
  return { claude_cmd, "-p", "--output-format", "json", "--max-turns", "1" }
end

function M.run(prompt, callback)
  local cfg = config.get()
  if not cfg.ai.enabled then
    callback(nil, "AI review is disabled in config")
    return
  end

  local cmd = M.build_cmd(cfg.ai.claude_cmd)
  local stdout_chunks = {}
  local done = false

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, chunk in ipairs(data) do
          if chunk ~= "" then table.insert(stdout_chunks, chunk) end
        end
      end
    end,
    on_exit = function(_, code)
      if done then return end
      done = true
      vim.schedule(function()
        if code ~= 0 then
          callback(nil, "Claude CLI exited with code " .. code)
        else
          callback(table.concat(stdout_chunks, "\n"))
        end
      end)
    end,
  })

  if job_id <= 0 then
    callback(nil, "Failed to start Claude CLI. Is '" .. cfg.ai.claude_cmd .. "' in your PATH?")
    return
  end

  -- Pipe prompt via stdin, then close stdin
  vim.fn.chansend(job_id, prompt)
  vim.fn.chanclose(job_id, "stdin")
end

return M
```

**Step 4: Run test to verify it passes**

Run: `busted --run unit tests/codereview/ai/subprocess_spec.lua`
Expected: PASS

**Step 5: Commit**

```
feat(ai): add Claude CLI subprocess runner with stdin pipe
```

---

### Task 2: Prompt Builders + Parsers

**Files:**
- Create: `lua/codereview/ai/prompt.lua`
- Create: `tests/codereview/ai/prompt_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/codereview/ai/prompt_spec.lua
local prompt = require("codereview.ai.prompt")

describe("ai.prompt", function()
  describe("build_review_prompt", function()
    it("includes MR title, file path, and JSON instruction", function()
      local review = { title = "Fix auth refresh", description = "Fixes silent token expiry" }
      local diffs = {
        { new_path = "src/auth.lua", diff = "@@ -10,3 +10,4 @@\n context\n-old\n+new\n+added\n" },
      }
      local result = prompt.build_review_prompt(review, diffs)
      assert.truthy(result:find("Fix auth refresh"))
      assert.truthy(result:find("src/auth.lua"))
      assert.truthy(result:find("JSON"))
    end)
  end)

  describe("parse_review_output", function()
    it("extracts JSON array from code block", function()
      local output = [[
Here are my findings:

```json
[
  {"file": "src/auth.lua", "line": 15, "severity": "warning", "comment": "Missing error check"},
  {"file": "src/auth.lua", "line": 42, "severity": "info", "comment": "Consider renaming"}
]
```
]]
      local suggestions = prompt.parse_review_output(output)
      assert.equals(2, #suggestions)
      assert.equals("src/auth.lua", suggestions[1].file)
      assert.equals(15, suggestions[1].line)
      assert.equals("Missing error check", suggestions[1].comment)
      assert.equals("pending", suggestions[1].status)
    end)

    it("handles output with no JSON", function()
      local suggestions = prompt.parse_review_output("No issues found, looks good!")
      assert.equals(0, #suggestions)
    end)

    it("handles malformed JSON gracefully", function()
      local suggestions = prompt.parse_review_output('```json\n{broken\n```')
      assert.equals(0, #suggestions)
    end)
  end)

  describe("build_mr_prompt", function()
    it("includes branch name and instructions", function()
      local result = prompt.build_mr_prompt("fix/auth-refresh", "diff content here")
      assert.truthy(result:find("fix/auth%-refresh"))
      assert.truthy(result:find("Title"))
      assert.truthy(result:find("Description"))
    end)
  end)

  describe("parse_mr_draft", function()
    it("extracts title and description from structured output", function()
      local output = "## Title\nFix auth token refresh\n\n## Description\nFixes the bug.\n- Better errors\n"
      local title, desc = prompt.parse_mr_draft(output)
      assert.equals("Fix auth token refresh", title)
      assert.truthy(desc:find("Better errors"))
    end)

    it("falls back to first-line title", function()
      local output = "Fix auth token refresh\n\nFixes the bug."
      local title, desc = prompt.parse_mr_draft(output)
      assert.equals("Fix auth token refresh", title)
      assert.equals("Fixes the bug.", desc)
    end)
  end)
end)
```

Note: `parse_review_output` uses `vim.json.decode`. The test helper doesn't stub `vim`, so add a stub in this test file:

```lua
-- At top of test file, before require:
_G.vim = _G.vim or {}
vim.json = vim.json or { decode = function(s) return require("dkjson").decode(s) end }
vim.split = vim.split or function(s, sep) ... end
```

Actually, check if `vim` is available in busted. If not, stub `vim.json.decode` with `require("cjson")` or inline JSON parsing. The simplest approach: use `dkjson` which ships with LuaJIT, or just use `load("return " .. s)` for test JSON.

Better approach: stub `vim.json` in `tests/unit_helper.lua` if not already present. Check what other tests do for `vim.json`.

**Step 2: Run test to verify it fails**

Run: `busted --run unit tests/codereview/ai/prompt_spec.lua`
Expected: FAIL — module not found

**Step 3: Implement prompt module**

```lua
-- lua/codereview/ai/prompt.lua
local M = {}

function M.build_review_prompt(review, diffs)
  local parts = {
    "You are reviewing a merge request.",
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
  table.insert(parts, "Review this MR. Output a JSON array in a ```json code block.")
  table.insert(parts, 'Each item: {"file": "path", "line": <new_line_number>, "severity": "error"|"warning"|"info"|"suggestion", "comment": "text"}')
  table.insert(parts, "If no issues, output `[]`.")
  table.insert(parts, "Focus on: bugs, security, error handling, edge cases, naming, clarity.")
  table.insert(parts, "Do NOT comment on style or formatting.")

  return table.concat(parts, "\n")
end

function M.parse_review_output(output)
  if not output or output == "" then return {} end

  local json_str = output:match("```json%s*\n(.-)```")
  if not json_str then
    json_str = output:match("%[.-%]")
  end
  if not json_str then return {} end

  local ok, data = pcall(vim.json.decode, json_str)
  if not ok or type(data) ~= "table" then return {} end

  local suggestions = {}
  for _, item in ipairs(data) do
    if type(item) == "table" and item.file and item.line and item.comment then
      table.insert(suggestions, {
        file = item.file,
        line = tonumber(item.line),
        severity = item.severity or "info",
        comment = item.comment,
        status = "pending",
      })
    end
  end
  return suggestions
end

function M.build_mr_prompt(branch, diff)
  return table.concat({
    "I'm creating a merge request for branch: " .. branch,
    "",
    "Here's the diff:",
    "```diff",
    diff,
    "```",
    "",
    "Write a concise MR title (one line, no prefix) and a clear description.",
    "Format:",
    "## Title",
    "<title>",
    "",
    "## Description",
    "<description with bullet points>",
  }, "\n")
end

function M.parse_mr_draft(output)
  local title = output:match("## Title%s*\n([^\n]+)")
  local description = output:match("## Description%s*\n(.*)")

  if title and description then
    return vim.trim(title), vim.trim(description)
  end

  -- Fallback: first line = title, rest = description
  local lines = vim.split(output, "\n")
  title = lines[1] or ""
  local desc_start = 2
  while desc_start <= #lines and vim.trim(lines[desc_start]) == "" do
    desc_start = desc_start + 1
  end
  description = table.concat(lines, "\n", desc_start)
  return vim.trim(title), vim.trim(description)
end

return M
```

**Step 4: Run test to verify it passes**

Run: `busted --run unit tests/codereview/ai/prompt_spec.lua`
Expected: PASS

**Step 5: Commit**

```
feat(ai): add review and MR creation prompt builders with parsers
```

---

### Task 3: Provider — GitLab Draft Notes + Publish

**Files:**
- Modify: `lua/codereview/providers/gitlab.lua` (append 3 new methods)
- Modify: `tests/codereview/providers/gitlab_spec.lua` (append tests)

**Step 1: Write failing tests**

Append to `tests/codereview/providers/gitlab_spec.lua`:

```lua
describe("create_draft_comment", function()
  it("exists as a function", function()
    assert.is_function(gitlab.create_draft_comment)
  end)
end)

describe("publish_review", function()
  it("exists as a function", function()
    assert.is_function(gitlab.publish_review)
  end)
end)

describe("create_review", function()
  it("exists as a function", function()
    assert.is_function(gitlab.create_review)
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `busted --run unit tests/codereview/providers/gitlab_spec.lua`
Expected: FAIL — functions don't exist

**Step 3: Implement**

Append to `lua/codereview/providers/gitlab.lua` before `return M`:

```lua
--- Create a draft note on an MR (not visible until published).
--- @param params table { body, path, line }
function M.create_draft_comment(client, ctx, review, params)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local payload = {
    note = params.body,
    position = {
      position_type = "text",
      base_sha = review.base_sha,
      head_sha = review.head_sha,
      start_sha = review.start_sha,
      new_path = params.path,
      old_path = params.path,
      new_line = params.line,
    },
  }
  return client.post(ctx.base_url, mr_base(ctx, review.id) .. "/draft_notes", { body = payload, headers = headers })
end

--- Bulk-publish all draft notes on an MR.
function M.publish_review(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  return client.post(ctx.base_url, mr_base(ctx, review.id) .. "/draft_notes/bulk_publish", { body = {}, headers = headers })
end

--- Create a new merge request.
--- @param params table { source_branch, target_branch, title, description }
function M.create_review(client, ctx, params)
  local headers, err = get_headers()
  if not headers then return nil, err end
  return client.post(ctx.base_url, "/api/v4/projects/" .. encoded_project(ctx) .. "/merge_requests", {
    body = {
      source_branch = params.source_branch,
      target_branch = params.target_branch,
      title = params.title,
      description = params.description,
    },
    headers = headers,
  })
end
```

**Step 4: Run test to verify it passes**

Run: `busted --run unit tests/codereview/providers/gitlab_spec.lua`
Expected: PASS

**Step 5: Commit**

```
feat(gitlab): add draft notes, publish review, and create MR methods
```

---

### Task 4: Provider — GitHub Pending Review + Publish

**Files:**
- Modify: `lua/codereview/providers/github.lua` (append 3 new methods)
- Modify: `tests/codereview/providers/github_spec.lua` (append tests)

**Step 1: Write failing tests**

Append to `tests/codereview/providers/github_spec.lua`:

```lua
describe("create_draft_comment", function()
  it("accumulates comments in review_comments table", function()
    local review = { id = 1, sha = "abc123" }
    github.create_draft_comment(nil, nil, review, { body = "Fix this", path = "foo.lua", line = 10 })
    github.create_draft_comment(nil, nil, review, { body = "And this", path = "bar.lua", line = 20 })
    assert.equals(2, #github._pending_comments)
    github._pending_comments = {} -- cleanup
  end)
end)

describe("publish_review", function()
  it("exists as a function", function()
    assert.is_function(github.publish_review)
  end)
end)

describe("create_review", function()
  it("exists as a function", function()
    assert.is_function(github.create_review)
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `busted --run unit tests/codereview/providers/github_spec.lua`
Expected: FAIL

**Step 3: Implement**

Append to `lua/codereview/providers/github.lua` before `return M`:

```lua
-- Accumulator for pending review comments (GitHub batches on publish)
M._pending_comments = {}

--- Stage a draft comment for the next review submission.
--- GitHub doesn't have individual draft notes — comments are batched into a single review.
--- @param params table { body, path, line }
function M.create_draft_comment(client, ctx, review, params) -- luacheck: ignore client ctx
  table.insert(M._pending_comments, {
    body = params.body,
    path = params.path,
    line = params.line,
    side = "RIGHT",
  })
end

--- Publish all accumulated draft comments as a single PR review.
function M.publish_review(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end

  if #M._pending_comments == 0 then
    return nil, "No pending comments to publish"
  end

  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls/%d/reviews", owner, repo, review.id)
  local payload = {
    commit_id = review.sha,
    event = "COMMENT",
    comments = M._pending_comments,
  }

  local result, post_err = client.post(ctx.base_url, path_url, { body = payload, headers = headers })
  M._pending_comments = {} -- clear regardless of success
  return result, post_err
end

--- Create a new pull request.
--- @param params table { source_branch, target_branch, title, description }
function M.create_review(client, ctx, params)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls", owner, repo)
  return client.post(ctx.base_url, path_url, {
    body = {
      head = params.source_branch,
      base = params.target_branch,
      title = params.title,
      body = params.description,
    },
    headers = headers,
  })
end
```

**Step 4: Run test to verify it passes**

Run: `busted --run unit tests/codereview/providers/github_spec.lua`
Expected: PASS

**Step 5: Commit**

```
feat(github): add pending review comments, publish review, and create PR methods
```

---

### Task 5: Review Submission Module

**Files:**
- Create: `lua/codereview/review/submit.lua`
- Create: `tests/codereview/review/submit_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/codereview/review/submit_spec.lua
local submit = require("codereview.review.submit")

describe("review.submit", function()
  describe("filter_accepted", function()
    it("returns only accepted and edited suggestions", function()
      local suggestions = {
        { comment = "a", status = "accepted" },
        { comment = "b", status = "pending" },
        { comment = "c", status = "edited" },
        { comment = "d", status = "deleted" },
      }
      local accepted = submit.filter_accepted(suggestions)
      assert.equals(2, #accepted)
      assert.equals("a", accepted[1].comment)
      assert.equals("c", accepted[2].comment)
    end)

    it("returns empty for no accepted", function()
      local accepted = submit.filter_accepted({
        { comment = "a", status = "pending" },
      })
      assert.equals(0, #accepted)
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `busted --run unit tests/codereview/review/submit_spec.lua`
Expected: FAIL

**Step 3: Implement**

```lua
-- lua/codereview/review/submit.lua
local providers = require("codereview.providers")
local client = require("codereview.api.client")
local M = {}

function M.filter_accepted(suggestions)
  local accepted = {}
  for _, s in ipairs(suggestions) do
    if s.status == "accepted" or s.status == "edited" then
      table.insert(accepted, s)
    end
  end
  return accepted
end

function M.submit_review(review, suggestions)
  local provider, ctx, err = providers.detect()
  if not provider then
    vim.notify("Could not detect platform: " .. (err or ""), vim.log.levels.ERROR)
    return false
  end

  local accepted = M.filter_accepted(suggestions)
  if #accepted == 0 then
    vim.notify("No accepted suggestions to submit", vim.log.levels.WARN)
    return false
  end

  local errors = {}
  for _, suggestion in ipairs(accepted) do
    local _, post_err = provider.create_draft_comment(client, ctx, review, {
      body = suggestion.comment,
      path = suggestion.file,
      line = suggestion.line,
    })
    if post_err then
      table.insert(errors, string.format("%s:%d - %s", suggestion.file, suggestion.line, post_err))
    end
  end

  local _, pub_err = provider.publish_review(client, ctx, review)
  if pub_err then
    table.insert(errors, "Publish failed: " .. pub_err)
  end

  if #errors > 0 then
    vim.notify("Some drafts failed:\n" .. table.concat(errors, "\n"), vim.log.levels.WARN)
  else
    vim.notify(string.format("Review submitted: %d comments", #accepted), vim.log.levels.INFO)
  end

  return #errors == 0
end

function M.bulk_publish(review)
  local provider, ctx, err = providers.detect()
  if not provider then
    vim.notify("Could not detect platform: " .. (err or ""), vim.log.levels.ERROR)
    return false
  end
  local _, pub_err = provider.publish_review(client, ctx, review)
  if pub_err then
    vim.notify("Failed to publish: " .. pub_err, vim.log.levels.ERROR)
    return false
  end
  vim.notify("Review published!", vim.log.levels.INFO)
  return true
end

return M
```

**Step 4: Run test to verify it passes**

Run: `busted --run unit tests/codereview/review/submit_spec.lua`
Expected: PASS

**Step 5: Commit**

```
feat(review): add submission module with filter and platform-aware publish
```

---

### Task 6: Review Triage UI

**Files:**
- Create: `lua/codereview/review/triage.lua`
- Modify: `lua/codereview/ui/highlight.lua:3` (add AI draft highlight)

**Step 1: Add highlight group**

In `lua/codereview/ui/highlight.lua`, add after line 15 (before `CodeReviewFileHeader`):

```lua
vim.api.nvim_set_hl(0, "CodeReviewAIDraft", { bg = "#2a2a3a", fg = "#bb9af7", default = true })
vim.api.nvim_set_hl(0, "CodeReviewAIDraftBorder", { fg = "#bb9af7", default = true })
```

**Step 2: Implement triage module**

```lua
-- lua/codereview/review/triage.lua
local split = require("codereview.ui.split")
local diff_mod = require("codereview.mr.diff")
local submit_mod = require("codereview.review.submit")
local M = {}

local DRAFT_NS = vim.api.nvim_create_namespace("codereview_ai_draft")

local STATUS_ICONS = { accepted = "+", pending = "o", deleted = "x", edited = "~" }

function M.open(review, diffs, discussions, suggestions)
  if #suggestions == 0 then
    vim.notify("AI review found no issues!", vim.log.levels.INFO)
    return
  end

  local layout = split.create({ sidebar_width = 30 })

  local state = {
    layout = layout,
    review = review,
    diffs = diffs,
    discussions = discussions,
    suggestions = suggestions,
    current_idx = 1,
    line_data = nil,
  }

  M.render(state)
  M.setup_keymaps(state)
  return state
end

function M.build_sidebar_lines(suggestions, current_idx)
  local lines = {}
  local accepted = 0
  for _, s in ipairs(suggestions) do
    if s.status == "accepted" or s.status == "edited" then accepted = accepted + 1 end
  end

  table.insert(lines, string.format("AI Review: %d comments", #suggestions))
  table.insert(lines, string.rep("=", 28))
  table.insert(lines, "")

  for i, s in ipairs(suggestions) do
    if s.status == "deleted" then goto continue end
    local icon = STATUS_ICONS[s.status] or "o"
    local pointer = i == current_idx and "> " or "  "
    local short_file = s.file:match("[^/]+$") or s.file
    table.insert(lines, string.format("%s%s %d. %s:%d", pointer, icon, i, short_file, s.line))
    table.insert(lines, string.format("    %s", s.comment:sub(1, 40)))
    if s.status == "pending" then
      table.insert(lines, "    [a]ccept [e]dit [d]el")
    else
      table.insert(lines, string.format("    %s", s.status))
    end
    table.insert(lines, "")
    ::continue::
  end

  table.insert(lines, string.rep("=", 28))
  table.insert(lines, string.format("Reviewed: %d/%d", accepted, #suggestions))
  table.insert(lines, "[A] Accept all  [S] Submit")
  table.insert(lines, "[q] Quit")

  return lines
end

function M.render(state)
  local layout = state.layout

  -- Sidebar
  local sidebar_lines = M.build_sidebar_lines(state.suggestions, state.current_idx)
  vim.bo[layout.sidebar_buf].modifiable = true
  vim.api.nvim_buf_set_lines(layout.sidebar_buf, 0, -1, false, sidebar_lines)
  vim.bo[layout.sidebar_buf].modifiable = false

  -- Main: render diff for current suggestion's file
  local current = state.suggestions[state.current_idx]
  if not current then return end

  for _, file_diff in ipairs(state.diffs) do
    if file_diff.new_path == current.file or file_diff.old_path == current.file then
      state.line_data = diff_mod.render_file_diff(
        layout.main_buf, file_diff, state.review, state.discussions
      )
      M.show_inline_draft(layout.main_buf, state.line_data, current)
      M.scroll_to_line(layout.main_win, state.line_data, current.line)
      break
    end
  end
end

function M.show_inline_draft(buf, line_data, suggestion)
  vim.api.nvim_buf_clear_namespace(buf, DRAFT_NS, 0, -1)

  for i, data in ipairs(line_data) do
    local new_line = data.item and data.item.new_line
    if new_line == suggestion.line then
      local virt_lines = {
        { { string.rep("-", 50), "CodeReviewAIDraftBorder" } },
        { { " AI [" .. suggestion.severity .. "]", "CodeReviewAIDraft" } },
        { { " " .. suggestion.comment, "CodeReviewAIDraft" } },
        { { string.rep("-", 50), "CodeReviewAIDraftBorder" } },
      }
      vim.api.nvim_buf_set_extmark(buf, DRAFT_NS, i - 1, 0, {
        virt_lines = virt_lines,
        virt_lines_above = false,
      })
      break
    end
  end
end

function M.scroll_to_line(win, line_data, target_line)
  for i, data in ipairs(line_data) do
    local new_line = data.item and data.item.new_line
    if new_line == target_line then
      pcall(vim.api.nvim_win_set_cursor, win, { i, 0 })
      vim.cmd("normal! zz")
      return
    end
  end
end

function M.navigate(state, direction)
  local new_idx = state.current_idx
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

  vim.keymap.set("n", "<CR>", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    current.comment = table.concat(lines, "\n")
    current.status = "edited"
    vim.api.nvim_win_close(win, true)
    M.navigate(state, 1)
  end, { buffer = buf })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
end

function M.accept_all(state)
  for _, s in ipairs(state.suggestions) do
    if s.status == "pending" then s.status = "accepted" end
  end
  M.render(state)
end

function M.submit(state)
  submit_mod.submit_review(state.review, state.suggestions)
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
    vim.keymap.set("n", "q", function() split.close(layout) end, buf_opts)
  end
end

return M
```

**Step 3: Commit**

```
feat(review): add triage UI with sidebar, inline drafts, and keymaps
```

---

### Task 7: Review Orchestrator + Wire Commands

**Files:**
- Create: `lua/codereview/review/init.lua`
- Modify: `lua/codereview/init.lua:37-38` (replace ai_review and submit stubs)

**Step 1: Create orchestrator**

```lua
-- lua/codereview/review/init.lua
local providers = require("codereview.providers")
local client = require("codereview.api.client")
local ai_sub = require("codereview.ai.subprocess")
local prompt_mod = require("codereview.ai.prompt")
local triage = require("codereview.review.triage")
local M = {}

function M.start(review)
  local provider, ctx, err = providers.detect()
  if not provider then
    vim.notify("Could not detect platform: " .. (err or ""), vim.log.levels.ERROR)
    return
  end

  -- Fetch diffs
  local diffs, diffs_err = provider.get_diffs(client, ctx, review)
  if not diffs or #diffs == 0 then
    vim.notify("No diffs found: " .. (diffs_err or ""), vim.log.levels.WARN)
    return
  end

  -- Fetch discussions
  local discussions = provider.get_discussions(client, ctx, review) or {}

  -- Run Claude review
  local review_prompt = prompt_mod.build_review_prompt(review, diffs)
  vim.notify("Running AI review...", vim.log.levels.INFO)

  ai_sub.run(review_prompt, function(output, ai_err)
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
    triage.open(review, diffs, discussions, suggestions)
  end)
end

return M
```

**Step 2: Wire commands in init.lua**

Replace lines 37-38 in `lua/codereview/init.lua`:

```lua
-- Replace:
function M.ai_review() vim.notify("AI review not yet implemented (Stage 5)", vim.log.levels.WARN) end
function M.submit() vim.notify("Submit not yet implemented (Stage 5)", vim.log.levels.WARN) end

-- With:
function M.ai_review()
  local buf = vim.api.nvim_get_current_buf()
  local review = vim.b[buf].codereview_review
  if not review then
    vim.notify("No review context. Open a review first with :CodeReview", vim.log.levels.WARN)
    return
  end
  require("codereview.review").start(review)
end

function M.submit()
  local buf = vim.api.nvim_get_current_buf()
  local review = vim.b[buf].codereview_review
  if not review then
    vim.notify("No review context. Open a review first with :CodeReview", vim.log.levels.WARN)
    return
  end
  require("codereview.review.submit").bulk_publish(review)
end
```

**Step 3: Commit**

```
feat: wire AI review orchestrator and commands
```

---

### Task 8: MR Creation Module

**Files:**
- Create: `lua/codereview/mr/create.lua`
- Create: `tests/codereview/mr/create_spec.lua`
- Modify: `lua/codereview/init.lua:48` (replace create_mr stub)

**Step 1: Write failing test**

```lua
-- tests/codereview/mr/create_spec.lua
-- Stub vim globals for unit testing
_G.vim = _G.vim or {}
vim.trim = vim.trim or function(s) return s:match("^%s*(.-)%s*$") end
vim.split = vim.split or function(s, sep)
  local parts = {}
  for part in (s .. sep):gmatch("(.-)" .. sep) do table.insert(parts, part) end
  return parts
end

local prompt_mod = require("codereview.ai.prompt")

describe("mr.create prompts", function()
  describe("build_mr_prompt", function()
    it("includes branch name and diff", function()
      local result = prompt_mod.build_mr_prompt("fix/auth-refresh", "@@ diff content @@")
      assert.truthy(result:find("fix/auth%-refresh"))
      assert.truthy(result:find("diff content"))
    end)
  end)

  describe("parse_mr_draft", function()
    it("extracts structured title and description", function()
      local output = "## Title\nFix auth token refresh\n\n## Description\nFixes the bug.\n- Better errors\n"
      local title, desc = prompt_mod.parse_mr_draft(output)
      assert.equals("Fix auth token refresh", title)
      assert.truthy(desc:find("Better errors"))
    end)

    it("falls back to first-line title", function()
      local output = "Fix auth token refresh\n\nFixes the bug."
      local title, desc = prompt_mod.parse_mr_draft(output)
      assert.equals("Fix auth token refresh", title)
      assert.equals("Fixes the bug.", desc)
    end)
  end)
end)
```

Note: MR draft parsing tests are already in Task 2's prompt_spec. This file tests via the prompt module since parsing lives there. The `create.lua` module itself is mostly vim UI + git subprocess which can't be unit-tested without Neovim. Focus tests on the parseable logic.

**Step 2: Run test to verify it fails**

Run: `busted --run unit tests/codereview/mr/create_spec.lua`
Expected: FAIL

**Step 3: Implement MR creation module**

```lua
-- lua/codereview/mr/create.lua
local providers = require("codereview.providers")
local client = require("codereview.api.client")
local ai_sub = require("codereview.ai.subprocess")
local prompt_mod = require("codereview.ai.prompt")
local M = {}

function M.get_current_branch()
  local result = vim.fn.systemlist({ "git", "branch", "--show-current" })
  if vim.v.shell_error ~= 0 or #result == 0 then return nil end
  return vim.trim(result[1])
end

function M.get_branch_diff(target)
  target = target or "main"
  local result = vim.fn.systemlist({ "git", "diff", target .. "...HEAD" })
  if vim.v.shell_error ~= 0 then return nil end
  return table.concat(result, "\n")
end

function M.detect_target_branch()
  local result = vim.fn.systemlist({ "git", "symbolic-ref", "refs/remotes/origin/HEAD" })
  if vim.v.shell_error == 0 and #result > 0 then
    local branch = result[1]:match("refs/remotes/origin/(.+)")
    if branch then return branch end
  end
  return "main"
end

function M.open_editor(title, description, callback)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = { title, "", }
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
    title = " New MR — line 1 = title, rest = description — <CR> submit, q cancel ",
    title_pos = "center",
  })

  vim.keymap.set("n", "<CR>", function()
    local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local new_title = buf_lines[1] or title
    -- Skip blank lines after title
    local desc_start = 2
    while desc_start <= #buf_lines and vim.trim(buf_lines[desc_start]) == "" do
      desc_start = desc_start + 1
    end
    local new_desc = table.concat(buf_lines, "\n", desc_start)
    vim.api.nvim_win_close(win, true)
    callback(vim.trim(new_title), vim.trim(new_desc))
  end, { buffer = buf })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
end

function M.create()
  local branch = M.get_current_branch()
  if not branch then
    vim.notify("Not on a branch", vim.log.levels.ERROR)
    return
  end
  if branch == "main" or branch == "master" then
    vim.notify("Cannot create MR from " .. branch, vim.log.levels.ERROR)
    return
  end

  local target = M.detect_target_branch()
  local diff = M.get_branch_diff(target)
  if not diff or diff == "" then
    vim.notify("No diff found against " .. target, vim.log.levels.WARN)
    return
  end

  local mr_prompt = prompt_mod.build_mr_prompt(branch, diff)
  vim.notify("Generating MR description...", vim.log.levels.INFO)

  ai_sub.run(mr_prompt, function(output, err)
    if err then
      vim.notify("Claude CLI failed: " .. err, vim.log.levels.ERROR)
      return
    end

    local title, description = prompt_mod.parse_mr_draft(output)
    M.open_editor(title, description, function(final_title, final_desc)
      M.submit_mr(branch, target, final_title, final_desc)
    end)
  end)
end

function M.submit_mr(source_branch, target_branch, title, description)
  local provider, ctx, err = providers.detect()
  if not provider then
    vim.notify("Could not detect platform: " .. (err or ""), vim.log.levels.ERROR)
    return
  end

  local result, post_err = provider.create_review(client, ctx, {
    source_branch = source_branch,
    target_branch = target_branch,
    title = title,
    description = description,
  })

  if not result then
    vim.notify("Failed to create MR: " .. (post_err or ""), vim.log.levels.ERROR)
    return
  end

  local mr = result.data
  if mr then
    local url = mr.web_url or mr.html_url or ""
    local id = mr.iid or mr.number or mr.id
    vim.notify(string.format("MR #%s created: %s", id, url), vim.log.levels.INFO)
  end
end

return M
```

**Step 4: Run test to verify it passes**

Run: `busted --run unit tests/codereview/mr/create_spec.lua`
Expected: PASS

**Step 5: Wire into init.lua**

Replace line 48 in `lua/codereview/init.lua`:

```lua
-- Replace:
function M.create_mr() vim.notify("Create MR not yet implemented (Stage 5)", vim.log.levels.WARN) end

-- With:
function M.create_mr()
  require("codereview.mr.create").create()
end
```

**Step 6: Commit**

```
feat: add MR creation with Claude-drafted title and description
```

---

### Task 9: Integration Test

**Files:**
- Create: `tests/codereview/review/triage_spec.lua`

**Step 1: Write a smoke test for build_sidebar_lines**

Since the triage UI depends on `vim.api` which isn't available in busted, test the pure-function parts:

```lua
-- tests/codereview/review/triage_spec.lua
-- We can only test the pure functions without a running Neovim
-- triage.build_sidebar_lines is pure — no vim.api calls

-- Stub vim namespace
_G.vim = _G.vim or {}
vim.api = vim.api or { nvim_create_namespace = function() return 0 end }
vim.bo = vim.bo or setmetatable({}, { __index = function() return {} end })
vim.wo = vim.wo or setmetatable({}, { __index = function() return {} end })
vim.fn = vim.fn or {}
vim.cmd = vim.cmd or function() end
vim.keymap = vim.keymap or { set = function() end }
vim.tbl_extend = vim.tbl_extend or function(_, a, b)
  local t = {}
  for k, v in pairs(a) do t[k] = v end
  for k, v in pairs(b) do t[k] = v end
  return t
end
vim.o = vim.o or { columns = 120, lines = 40 }
vim.split = vim.split or function(s, sep)
  local parts = {}
  for part in (s .. sep):gmatch("(.-)" .. sep) do table.insert(parts, part) end
  return parts
end

local triage = require("codereview.review.triage")

describe("review.triage", function()
  describe("build_sidebar_lines", function()
    it("renders suggestion list with status", function()
      local suggestions = {
        { file = "auth.lua", line = 15, comment = "Missing check", status = "accepted", severity = "warning" },
        { file = "auth.lua", line = 42, comment = "Error swallowed", status = "pending", severity = "error" },
        { file = "diff.lua", line = 23, comment = "Off-by-one", status = "pending", severity = "info" },
      }
      local lines = triage.build_sidebar_lines(suggestions, 2)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("auth.lua:15"))
      assert.truthy(joined:find("auth.lua:42"))
      assert.truthy(joined:find("Reviewed: 1/3"))
    end)

    it("skips deleted suggestions", function()
      local suggestions = {
        { file = "a.lua", line = 1, comment = "x", status = "deleted", severity = "info" },
        { file = "b.lua", line = 2, comment = "y", status = "pending", severity = "info" },
      }
      local lines = triage.build_sidebar_lines(suggestions, 2)
      local joined = table.concat(lines, "\n")
      assert.falsy(joined:find("a.lua:1"))
      assert.truthy(joined:find("b.lua:2"))
    end)
  end)
end)
```

**Step 2: Run test**

Run: `busted --run unit tests/codereview/review/triage_spec.lua`
Expected: PASS

**Step 3: Commit**

```
test: add triage sidebar unit tests
```
