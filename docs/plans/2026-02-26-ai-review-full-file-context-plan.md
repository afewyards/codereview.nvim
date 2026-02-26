# AI Review Full File Context — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Send full HEAD file content alongside diffs in per-file AI review prompts so the AI can review diffs with full file context.

**Architecture:** Lazy content fetch in review orchestrator. Each provider gets a `get_file_content()` method. Content is passed to `build_file_review_prompt()` which adds a `## Full File Content` section before the diff. Config `ai.max_file_size` caps line count.

**Tech Stack:** Lua, Neovim plugin, busted tests, plenary.curl HTTP client

---

### Task 1: Add `ai.max_file_size` config

**Files:**
- Modify: `lua/codereview/config.lua:13` (defaults table)
- Modify: `lua/codereview/config.lua:31-37` (validate function)
- Test: `tests/codereview/config_spec.lua`

**Step 1: Write the failing test**

In `tests/codereview/config_spec.lua`, add:

```lua
it("defaults ai.max_file_size to 500", function()
  config.setup({})
  assert.equals(500, config.get().ai.max_file_size)
end)

it("clamps ai.max_file_size to minimum 0", function()
  config.setup({ ai = { max_file_size = -10 } })
  assert.equals(0, config.get().ai.max_file_size)
end)
```

**Step 2: Run test to verify it fails**

Run: `bunx busted tests/codereview/config_spec.lua --run unit -v`
Expected: FAIL — `max_file_size` not in defaults

**Step 3: Write minimal implementation**

In `config.lua` defaults (line 13), add `max_file_size = 500` to the `ai` table:

```lua
ai = { enabled = true, claude_cmd = "claude", agent = "code-review", review_level = "info", max_file_size = 500 },
```

In `validate()`, add clamping:

```lua
c.ai.max_file_size = math.max(0, c.ai.max_file_size or 500)
```

**Step 4: Run test to verify it passes**

Run: `bunx busted tests/codereview/config_spec.lua --run unit -v`
Expected: PASS

**Step 5: Commit**

```
feat(config): add ai.max_file_size setting
```

---

### Task 2: Add `get_file_content` to GitHub provider

**Files:**
- Modify: `lua/codereview/providers/github.lua` (add new function after `get_diffs`)
- Test: `tests/codereview/providers/github_spec.lua`

**Step 1: Write the failing test**

```lua
describe("get_file_content", function()
  it("returns decoded file content from base64 API response", function()
    -- Stub client.get to return GitHub contents API shape
    local mock_client = {
      get = function(base_url, path, opts)
        assert.truthy(path:find("/repos/owner/repo/contents/src/auth.lua"))
        assert.equals("abc123", opts.query.ref)
        return {
          data = {
            content = vim.base64.encode("local M = {}\nreturn M\n"),
            encoding = "base64",
          },
          status = 200,
        }
      end,
    }
    local ctx = { base_url = "https://api.github.com", project = "owner/repo" }
    -- Stub auth
    local auth = require("codereview.api.auth")
    local orig_get_token = auth.get_token
    auth.get_token = function() return "fake-token", "bearer" end

    local content, err = github.get_file_content(mock_client, ctx, "abc123", "src/auth.lua")

    auth.get_token = orig_get_token
    assert.is_nil(err)
    assert.equals("local M = {}\nreturn M\n", content)
  end)

  it("returns nil on API error", function()
    local mock_client = {
      get = function() return nil, "HTTP 404" end,
    }
    local ctx = { base_url = "https://api.github.com", project = "owner/repo" }
    local auth = require("codereview.api.auth")
    local orig_get_token = auth.get_token
    auth.get_token = function() return "fake-token", "bearer" end

    local content, err = github.get_file_content(mock_client, ctx, "abc123", "missing.lua")

    auth.get_token = orig_get_token
    assert.is_nil(content)
    assert.truthy(err)
  end)
end)
```

Note: `vim.base64` needs stubbing if not available. Check `tests/unit_helper.lua` — if `vim.base64` isn't already stubbed, add: `vim.base64 = vim.base64 or {}; vim.base64.encode = function(s) return require("codereview.util.base64").encode(s) end; vim.base64.decode = function(s) return require("codereview.util.base64").decode(s) end`. Alternatively, use a simple lua base64 implementation inline in the test.

**Step 2: Run test to verify it fails**

Run: `bunx busted tests/codereview/providers/github_spec.lua --run unit -v`
Expected: FAIL — `get_file_content` is nil

**Step 3: Write minimal implementation**

After `M.get_diffs` in `github.lua`, add:

```lua
--- Fetch raw file content at a specific ref (commit SHA).
--- Returns the decoded file content as a string, or nil + error.
function M.get_file_content(client, ctx, ref, path)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local api_path = string.format("/repos/%s/%s/contents/%s", owner, repo, path)
  local result, req_err = client.get(ctx.base_url, api_path, {
    headers = headers,
    query = { ref = ref },
  })
  if not result then return nil, req_err end
  local data = result.data
  if type(data) ~= "table" or not data.content then
    return nil, "No content in response"
  end
  -- GitHub returns base64-encoded content (may contain newlines in the encoding)
  local raw = data.content:gsub("%s", "")
  local decoded = vim.base64.decode(raw)
  if not decoded then return nil, "base64 decode failed" end
  return decoded
end
```

**Step 4: Run test to verify it passes**

Run: `bunx busted tests/codereview/providers/github_spec.lua --run unit -v`
Expected: PASS

**Step 5: Commit**

```
feat(github): add get_file_content for fetching full file at ref
```

---

### Task 3: Add `get_file_content` to GitLab provider

**Files:**
- Modify: `lua/codereview/providers/gitlab.lua` (add new function after `get_diffs`)
- Test: `tests/codereview/providers/gitlab_spec.lua`

**Step 1: Write the failing test**

```lua
describe("get_file_content", function()
  it("returns raw file content from GitLab API", function()
    local mock_client = {
      get = function(base_url, path, opts)
        -- GitLab raw endpoint returns plain text in data field
        assert.truthy(path:find("/repository/files/"))
        assert.truthy(path:find("/raw"))
        assert.equals("abc123", opts.query.ref)
        return {
          data = "local M = {}\nreturn M\n",
          status = 200,
        }
      end,
    }
    local ctx = { base_url = "https://gitlab.com", project = "group/repo" }
    local auth = require("codereview.api.auth")
    local orig = auth.get_token
    auth.get_token = function() return "fake-token", "private" end

    local content, err = gitlab.get_file_content(mock_client, ctx, "abc123", "src/auth.lua")

    auth.get_token = orig
    assert.is_nil(err)
    assert.equals("local M = {}\nreturn M\n", content)
  end)

  it("returns nil on API error", function()
    local mock_client = {
      get = function() return nil, "HTTP 404" end,
    }
    local ctx = { base_url = "https://gitlab.com", project = "group/repo" }
    local auth = require("codereview.api.auth")
    local orig = auth.get_token
    auth.get_token = function() return "fake-token", "private" end

    local content, err = gitlab.get_file_content(mock_client, ctx, "abc123", "missing.lua")

    auth.get_token = orig
    assert.is_nil(content)
    assert.truthy(err)
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `bunx busted tests/codereview/providers/gitlab_spec.lua --run unit -v`
Expected: FAIL — `get_file_content` is nil

**Step 3: Write minimal implementation**

After `M.get_diffs` in `gitlab.lua`, add:

```lua
--- Fetch raw file content at a specific ref (commit SHA).
--- Returns the file content as a string, or nil + error.
function M.get_file_content(client, ctx, ref, path)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local encoded_path = path:gsub("/", "%%2F")
  local api_path = string.format(
    "/api/v4/projects/%s/repository/files/%s/raw",
    encoded_project(ctx),
    encoded_path
  )
  local result, req_err = client.get(ctx.base_url, api_path, {
    headers = headers,
    query = { ref = ref },
  })
  if not result then return nil, req_err end
  if type(result.data) == "string" then
    return result.data
  end
  return nil, "Unexpected response format"
end
```

**Step 4: Run test to verify it passes**

Run: `bunx busted tests/codereview/providers/gitlab_spec.lua --run unit -v`
Expected: PASS

**Step 5: Commit**

```
feat(gitlab): add get_file_content for fetching full file at ref
```

---

### Task 4: Update `build_file_review_prompt` to accept and include content

**Files:**
- Modify: `lua/codereview/ai/prompt.lua:250-300` (`build_file_review_prompt`)
- Test: `tests/codereview/ai/prompt_spec.lua`

**Step 1: Write the failing tests**

Add to the `build_file_review_prompt` describe block in `prompt_spec.lua`:

```lua
it("includes full file content section when content is provided", function()
  local review = { title = "T", description = "D" }
  local file = { new_path = "src/foo.lua", diff = "@@ -1,2 +1,3 @@\n-old\n+new\n" }
  local result = prompt.build_file_review_prompt(review, file, {}, "local M = {}\nfunction M.foo()\nend\nreturn M")
  assert.truthy(result:find("## Full File Content"))
  assert.truthy(result:find("local M = {}"))
  assert.truthy(result:find("function M.foo"))
  assert.truthy(result:find("Only review the changes shown in the diff"))
end)

it("omits full file content section when content is nil", function()
  local review = { title = "T", description = "D" }
  local file = { new_path = "src/foo.lua", diff = "@@ -1,2 +1,3 @@\n-old\n+new\n" }
  local result = prompt.build_file_review_prompt(review, file, {}, nil)
  assert.falsy(result:find("## Full File Content"))
end)

it("places full file content before the diff section", function()
  local review = { title = "T", description = "D" }
  local file = { new_path = "src/foo.lua", diff = "@@ -1,1 +1,1 @@\n-old\n+new\n" }
  local result = prompt.build_file_review_prompt(review, file, {}, "full content here")
  local content_pos = result:find("## Full File Content")
  local diff_pos = result:find("## File Under Review")
  assert.truthy(content_pos)
  assert.truthy(diff_pos)
  assert.truthy(content_pos < diff_pos, "Full file content should appear before diff section")
end)
```

**Step 2: Run test to verify it fails**

Run: `bunx busted tests/codereview/ai/prompt_spec.lua --run unit -v`
Expected: FAIL — content section not found

**Step 3: Write minimal implementation**

Update `build_file_review_prompt` signature to add `content` parameter:

```lua
function M.build_file_review_prompt(review, file, summaries, content)
```

After the "Other Changed Files" section and before the "File Under Review" line, add:

```lua
  if content and content ~= "" then
    table.insert(parts, "## Full File Content: " .. path)
    -- Detect language from file extension for syntax highlighting hint
    local ext = path:match("%.([^%.]+)$") or ""
    table.insert(parts, "```" .. ext)
    table.insert(parts, content)
    table.insert(parts, "```")
    table.insert(parts, "")
  end
```

Also update the instructions section — add before the existing "Focus on" line:

```lua
  if content and content ~= "" then
    table.insert(parts, "The full file content is provided above for context. Only review the changes shown in the diff.")
  end
```

**Step 4: Run test to verify it passes**

Run: `bunx busted tests/codereview/ai/prompt_spec.lua --run unit -v`
Expected: PASS

**Step 5: Verify existing tests still pass**

Run: `bunx busted tests/codereview/ai/prompt_spec.lua --run unit -v`
Expected: ALL PASS (existing tests pass nil for content, which is backward compatible)

**Step 6: Commit**

```
feat(prompt): include full file content in per-file review prompt
```

---

### Task 5: Wire content fetch into review orchestrator

**Files:**
- Modify: `lua/codereview/review/init.lua` (start_multi Phase 2 loop, start_file Phase 2)
- Test: `tests/codereview/review/init_spec.lua`

**Step 1: Write the failing tests**

Add to `init_spec.lua`. First, update the stub for `codereview.ai.subprocess` to capture content arg. Actually, we'll check the prompt string for "Full File Content":

```lua
describe("file content in per-file review", function()
  before_each(function()
    captured_calls = {}
    -- Stub provider on diff_state
  end)

  it("includes full file content in per-file prompt for multi-file review", function()
    local content_fetch_calls = {}
    local mock_provider = {
      get_file_content = function(client, ctx, ref, path)
        table.insert(content_fetch_calls, path)
        return "-- full content of " .. path
      end,
    }
    local review = { title = "Multi", description = "desc", head_sha = "abc123" }
    local diff_state = {
      files = {
        { new_path = "a.lua", diff = "@@ -1,1 +1,1 @@\n-old\n+new\n" },
        { new_path = "b.lua", diff = "@@ -1,1 +1,1 @@\n-old\n+new\n" },
      },
      discussions = {},
      ai_suggestions = {},
      view_mode = "diff",
      current_file = 1,
      scroll_mode = false,
      line_data_cache = {},
      row_disc_cache = {},
      row_ai_cache = {},
      provider = mock_provider,
      ctx = { base_url = "https://api.github.com", project = "owner/repo" },
    }
    review_mod.start(review, diff_state, { main_buf = 0, sidebar_buf = 0, main_win = 0 })

    -- Should have fetched content for both files
    assert.equals(2, #content_fetch_calls)
    -- Per-file prompts (calls 2 and 3) should contain full file content
    assert.truthy(captured_calls[2].prompt:find("Full File Content") or
                  captured_calls[3].prompt:find("Full File Content"),
      "per-file prompts should include full file content")
  end)

  it("skips content fetch for deleted files", function()
    local content_fetch_calls = {}
    local mock_provider = {
      get_file_content = function(client, ctx, ref, path)
        table.insert(content_fetch_calls, path)
        return "content"
      end,
    }
    local review = { title = "Multi", description = "desc", head_sha = "abc123" }
    local diff_state = {
      files = {
        { new_path = "a.lua", diff = "@@ -1,1 +1,1 @@\n-old\n+new\n" },
        { new_path = "deleted.lua", old_path = "deleted.lua", deleted_file = true, diff = "@@ -1,1 +0,0 @@\n-gone\n" },
      },
      discussions = {},
      ai_suggestions = {},
      view_mode = "diff",
      current_file = 1,
      scroll_mode = false,
      line_data_cache = {},
      row_disc_cache = {},
      row_ai_cache = {},
      provider = mock_provider,
      ctx = { base_url = "https://api.github.com", project = "owner/repo" },
    }
    review_mod.start(review, diff_state, { main_buf = 0, sidebar_buf = 0, main_win = 0 })

    -- Should only fetch content for a.lua, not deleted.lua
    assert.equals(1, #content_fetch_calls)
    assert.equals("a.lua", content_fetch_calls[1])
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `bunx busted tests/codereview/review/init_spec.lua --run unit -v`
Expected: FAIL — prompts don't contain "Full File Content"

**Step 3: Write minimal implementation**

In `review/init.lua`, add at top:

```lua
local log = require("codereview.log")
```

Add a helper function to fetch content with size check:

```lua
--- Fetch file content if available, respecting max_file_size.
--- Returns content string or nil.
local function fetch_file_content(diff_state, review, path, deleted)
  if deleted then return nil end
  local provider = diff_state.provider
  local ctx = diff_state.ctx
  if not provider or not provider.get_file_content or not ctx then return nil end

  local cfg = require("codereview.config").get()
  local max_size = cfg.ai.max_file_size or 500
  if max_size == 0 then return nil end

  local client = require("codereview.api.client")
  local content, err = provider.get_file_content(client, ctx, review.head_sha, path)
  if not content then
    if err then log.debug("AI: could not fetch content for " .. path .. ": " .. err) end
    return nil
  end

  -- Check line count
  local line_count = 1
  for _ in content:gmatch("\n") do line_count = line_count + 1 end
  if line_count > max_size then
    log.debug(string.format("AI: skipping content for %s (%d lines > %d max)", path, line_count, max_size))
    return nil
  end

  return content
end
```

In `start_multi`, Phase 2 loop (where `build_file_review_prompt` is called), fetch content before building prompt:

```lua
    for _, file in ipairs(diffs) do
      local path = file.new_path or file.old_path
      local content = fetch_file_content(diff_state, review, path, file.deleted_file)
      local file_prompt = prompt_mod.build_file_review_prompt(review, file, summaries, content)
```

In `start_file`, Phase 2 (where single target file is reviewed), same pattern:

```lua
    local content = fetch_file_content(diff_state, review, target_path, target.deleted_file)
    local file_prompt = prompt_mod.build_file_review_prompt(review, target, summaries, content)
```

**Step 4: Run test to verify it passes**

Run: `bunx busted tests/codereview/review/init_spec.lua --run unit -v`
Expected: PASS

**Step 5: Run all tests**

Run: `bunx busted --run unit -v`
Expected: ALL PASS

**Step 6: Commit**

```
feat(review): fetch full file content for per-file AI review prompts
```

---

### Task 6: Final integration verification

**Files:** None (read-only verification)

**Step 1: Run full test suite**

Run: `bunx busted --run unit -v`
Expected: ALL PASS

**Step 2: Verify no regressions in prompt output**

Check that `build_file_review_prompt` with no content (nil 4th arg) produces identical output to before — existing tests cover this since they don't pass a 4th arg.

**Step 3: Manual smoke test notes**

To manually test:
1. Open a PR with `codereview.nvim`
2. Trigger AI review (keybind)
3. Check `.codereview.log` for content fetch logs
4. Verify the AI review produces suggestions that reference context outside the diff hunks
