# GitLab Outdated Comments Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix GitLab MR comments on old diff versions so they render on the correct line (via `change_position` remapping) or gracefully disappear from diff view with an activity-view fallback.

**Architecture:** Preserve position SHAs + `change_position` during normalization. Detect outdated by comparing note SHA to review SHA. Use `change_position` line numbers for placement. Unmappable comments appear in activity view only. Remapped comments get a subtle "outdated" badge.

**Tech Stack:** Lua, Neovim API, Busted test framework

---

### Task 1: Preserve position SHAs and change_position in normalize_note

**Files:**
- Modify: `lua/codereview/providers/gitlab.lua:67-97` (normalize_note)
- Test: `tests/codereview/providers/gitlab_spec.lua`

**Step 1: Write failing test for SHA preservation**

In `tests/codereview/providers/gitlab_spec.lua`, add inside the `normalize_discussion` describe block:

```lua
it("preserves position SHAs from note", function()
  local disc = {
    id = "disc-sha",
    notes = { {
      id = 200, author = { username = "alice" },
      body = "old comment", created_at = "2026-01-01T00:00:00Z",
      system = false, resolvable = true, resolved = false,
      position = {
        new_path = "foo.lua", old_path = "foo.lua",
        new_line = 10, old_line = nil,
        base_sha = "aaa111", head_sha = "bbb222", start_sha = "ccc333",
      },
    } },
  }
  local d = gitlab.normalize_discussion(disc)
  local pos = d.notes[1].position
  assert.equal("aaa111", pos.base_sha)
  assert.equal("bbb222", pos.head_sha)
  assert.equal("ccc333", pos.start_sha)
end)
```

**Step 2: Run test to verify it fails**

Run: `bunx busted tests/codereview/providers/gitlab_spec.lua --filter "preserves position SHAs"`
Expected: FAIL — `pos.base_sha` is nil

**Step 3: Write failing test for change_position**

```lua
it("preserves change_position when present", function()
  local disc = {
    id = "disc-cp",
    notes = { {
      id = 201, author = { username = "bob" },
      body = "moved comment", created_at = "2026-01-01T00:00:00Z",
      system = false, resolvable = true, resolved = false,
      position = {
        new_path = "foo.lua", old_path = "foo.lua",
        new_line = 10, old_line = nil,
        base_sha = "old-base", head_sha = "old-head", start_sha = "old-start",
      },
      change_position = {
        new_path = "foo.lua", old_path = "foo.lua",
        new_line = 15, old_line = nil,
        base_sha = "new-base", head_sha = "new-head", start_sha = "new-start",
      },
    } },
  }
  local d = gitlab.normalize_discussion(disc)
  local cp = d.notes[1].change_position
  assert.is_not_nil(cp)
  assert.equal(15, cp.new_line)
  assert.equal("foo.lua", cp.new_path)
end)

it("sets change_position nil when absent", function()
  local disc = {
    id = "disc-nocp",
    notes = { {
      id = 202, author = { username = "carol" },
      body = "normal comment", created_at = "2026-01-01T00:00:00Z",
      system = false, resolvable = true, resolved = false,
      position = {
        new_path = "bar.lua", old_path = "bar.lua",
        new_line = 5, old_line = nil,
        base_sha = "aaa", head_sha = "bbb", start_sha = "ccc",
      },
    } },
  }
  local d = gitlab.normalize_discussion(disc)
  assert.is_nil(d.notes[1].change_position)
end)
```

**Step 4: Run tests to verify they fail**

Run: `bunx busted tests/codereview/providers/gitlab_spec.lua --filter "change_position"`
Expected: FAIL

**Step 5: Implement normalize_note changes**

In `lua/codereview/providers/gitlab.lua:67-97`, modify `normalize_note` to preserve SHAs and `change_position`:

```lua
local function normalize_note(raw)
  local position = nil
  if raw.position then
    local p = raw.position
    position = {
      path = p.new_path or p.old_path,
      new_path = p.new_path,
      old_path = p.old_path,
      new_line = p.new_line,
      old_line = p.old_line,
      base_sha = p.base_sha,
      head_sha = p.head_sha,
      start_sha = p.start_sha,
    }
    -- Preserve range start from line_range (GitLab range comments)
    if p.line_range and p.line_range.start then
      local s = p.line_range.start
      position.start_new_line = s.new_line
      position.start_old_line = s.old_line
    end
  end

  local change_position = nil
  if raw.change_position then
    local cp = raw.change_position
    change_position = {
      new_path = cp.new_path,
      old_path = cp.old_path,
      new_line = cp.new_line,
      old_line = cp.old_line,
    }
  end

  return {
    id = raw.id,
    author = type(raw.author) == "table" and raw.author.username or "",
    body = raw.body or "",
    created_at = raw.created_at or "",
    system = raw.system or false,
    resolvable = raw.resolvable or false,
    resolved = raw.resolved or false,
    resolved_by = type(raw.resolved_by) == "table" and raw.resolved_by.username or nil,
    position = position,
    change_position = change_position,
  }
end
```

**Step 6: Run all tests to verify they pass**

Run: `bunx busted tests/codereview/providers/gitlab_spec.lua`
Expected: ALL PASS

**Step 7: Commit**

```bash
git add lua/codereview/providers/gitlab.lua tests/codereview/providers/gitlab_spec.lua
git commit -m "feat(gitlab): preserve position SHAs and change_position in normalize_note"
```

---

### Task 2: Outdated detection and change_position remapping in diff placement

**Depends on:** Task 1

**Files:**
- Modify: `lua/codereview/mr/diff.lua:148-164` (discussion_matches_file, discussion_line)
- Modify: `lua/codereview/mr/diff.lua:172` (place_comment_signs signature)
- Modify: `lua/codereview/mr/diff.lua:574` (place_comment_signs call site)
- Test: `tests/codereview/mr/diff_spec.lua`

**Step 1: Write failing test — outdated comment uses change_position line**

Add to `tests/codereview/mr/diff_spec.lua`:

```lua
describe("outdated comment remapping", function()
  it("uses change_position line when comment is outdated", function()
    local buf = vim.api.nvim_create_buf(false, true)
    -- line_data simulating a 3-line diff: context at new_line=13, add at new_line=14, add at new_line=15
    local line_data = {
      { item = { new_line = 13, old_line = 13, type = "context", text = "ctx" }, type = "diff" },
      { item = { new_line = 14, type = "add", text = "added1" }, type = "diff" },
      { item = { new_line = 15, type = "add", text = "added2" }, type = "diff" },
    }
    local discussions = { {
      id = "disc-outdated",
      notes = { {
        id = 300, author = "alice", body = "fix this",
        created_at = "2026-01-01T00:00:00Z",
        system = false, resolvable = true, resolved = false,
        position = {
          path = "foo.lua", new_path = "foo.lua", old_path = "foo.lua",
          new_line = 10, old_line = nil,
          head_sha = "old-head",
        },
        change_position = {
          new_path = "foo.lua", old_path = "foo.lua",
          new_line = 15, old_line = nil,
        },
      } },
    } }
    local file_diff = { new_path = "foo.lua", old_path = "foo.lua" }
    local review = { head_sha = "current-head" }

    local row_discs = diff.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
    -- Should land on row 3 (new_line=15 from change_position), not row 0 (new_line=10 not in line_data)
    assert.is_not_nil(row_discs[3])
    assert.is_nil(row_discs[1])
    assert.is_nil(row_discs[2])

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `bunx busted tests/codereview/mr/diff_spec.lua --filter "uses change_position"`
Expected: FAIL

**Step 3: Write failing test — unmappable outdated comment is skipped**

```lua
it("skips outdated comment when change_position is nil", function()
  local buf = vim.api.nvim_create_buf(false, true)
  local line_data = {
    { item = { new_line = 13, old_line = 13, type = "context", text = "ctx" }, type = "diff" },
  }
  local discussions = { {
    id = "disc-gone",
    notes = { {
      id = 301, author = "bob", body = "gone",
      created_at = "2026-01-01T00:00:00Z",
      system = false, resolvable = true, resolved = false,
      position = {
        path = "foo.lua", new_path = "foo.lua", old_path = "foo.lua",
        new_line = 99, old_line = nil,
        head_sha = "old-head",
      },
    } },
  } }
  local file_diff = { new_path = "foo.lua", old_path = "foo.lua" }
  local review = { head_sha = "current-head" }

  local row_discs = diff.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
  -- No placement — no row should have this discussion
  for _, v in pairs(row_discs) do
    for _, d in ipairs(v) do
      assert.not_equal("disc-gone", d.id)
    end
  end

  vim.api.nvim_buf_delete(buf, { force = true })
end)

it("places current-version comment normally (no change_position needed)", function()
  local buf = vim.api.nvim_create_buf(false, true)
  local line_data = {
    { item = { new_line = 10, old_line = 10, type = "context", text = "ctx" }, type = "diff" },
  }
  local discussions = { {
    id = "disc-current",
    notes = { {
      id = 302, author = "carol", body = "current",
      created_at = "2026-01-01T00:00:00Z",
      system = false, resolvable = true, resolved = false,
      position = {
        path = "foo.lua", new_path = "foo.lua", old_path = "foo.lua",
        new_line = 10, old_line = nil,
        head_sha = "current-head",
      },
    } },
  } }
  local file_diff = { new_path = "foo.lua", old_path = "foo.lua" }
  local review = { head_sha = "current-head" }

  local row_discs = diff.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
  assert.is_not_nil(row_discs[1])

  vim.api.nvim_buf_delete(buf, { force = true })
end)
```

**Step 4: Run tests to verify they fail**

Run: `bunx busted tests/codereview/mr/diff_spec.lua --filter "outdated comment"`
Expected: FAIL

**Step 5: Implement outdated detection and remapping**

In `lua/codereview/mr/diff.lua`, modify `discussion_line` (~line 156) to accept `review` and handle outdated:

```lua
local function is_outdated(discussion, review)
  if not review or not review.head_sha then return false end
  local note = discussion.notes and discussion.notes[1]
  if not note or not note.position then return false end
  return note.position.head_sha and note.position.head_sha ~= review.head_sha
end

local function discussion_line(discussion, review)
  local note = discussion.notes and discussion.notes[1]
  if not note or not note.position then return nil end

  -- Outdated comment: use change_position if available, else skip
  if is_outdated(discussion, review) then
    local cp = note.change_position
    if not cp then return nil end
    local end_line = tonumber(cp.new_line) or tonumber(cp.old_line)
    return end_line, nil, true -- third return = is_outdated flag
  end

  local pos = note.position
  local end_line = tonumber(pos.new_line) or tonumber(pos.old_line)
  local start_line = tonumber(pos.start_line) or tonumber(pos.start_new_line) or tonumber(pos.start_old_line)
  return end_line, start_line, false
end
```

Also update `discussion_matches_file` to check `change_position` paths for outdated comments:

```lua
local function discussion_matches_file(discussion, file_diff, review)
  local note = discussion.notes and discussion.notes[1]
  if not note or not note.position then return false end

  -- For outdated comments with change_position, match against remapped paths
  if is_outdated(discussion, review) and note.change_position then
    local cp = note.change_position
    local cp_path = cp.new_path or cp.old_path
    return cp_path == file_diff.new_path or cp_path == file_diff.old_path
  end

  local pos = note.position
  local path = pos.new_path or pos.old_path
  return path == file_diff.new_path or path == file_diff.old_path
end
```

Update `place_comment_signs` signature to accept `review`:

```lua
function M.place_comment_signs(buf, line_data, discussions, file_diff, row_selection, current_user, review)
```

Update the internal calls to use `review`:

```lua
if discussion_matches_file(discussion, file_diff, review) then
  local target_line, range_start, outdated = discussion_line(discussion, review)
```

Update the call site at line 574:

```lua
row_discussions = M.place_comment_signs(buf, line_data, discussions, file_diff, row_selection, current_user, review) or {}
```

And in `render_all_files` (~line 587+), pass `review` to `place_comment_signs` calls similarly.

**Step 6: Run all tests**

Run: `bunx busted tests/codereview/mr/diff_spec.lua`
Expected: ALL PASS

**Step 7: Commit**

```bash
git add lua/codereview/mr/diff.lua tests/codereview/mr/diff_spec.lua
git commit -m "feat(diff): remap outdated comments via change_position, skip unmappable"
```

---

### Task 3: Outdated badge in comment header

**Depends on:** Task 2

**Files:**
- Modify: `lua/codereview/mr/diff.lua:219-240` (comment header rendering)
- Test: `tests/codereview/mr/diff_spec.lua`

**Step 1: Write failing test for outdated badge**

```lua
describe("outdated badge", function()
  it("renders outdated indicator for remapped comments", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local line_data = {
      { item = { new_line = 15, old_line = nil, type = "add", text = "new code" }, type = "diff" },
    }
    local discussions = { {
      id = "disc-badge",
      notes = { {
        id = 400, author = "alice", body = "old feedback",
        created_at = "2026-02-01T12:00:00Z",
        system = false, resolvable = true, resolved = false,
        position = {
          path = "foo.lua", new_path = "foo.lua", old_path = "foo.lua",
          new_line = 10, old_line = nil,
          head_sha = "old-head",
        },
        change_position = {
          new_path = "foo.lua", old_path = "foo.lua",
          new_line = 15, old_line = nil,
        },
      } },
    } }
    local file_diff = { new_path = "foo.lua", old_path = "foo.lua" }
    local review = { head_sha = "current-head" }

    diff.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)

    -- Check extmarks for "Outdated" text in virtual lines
    local ns = vim.api.nvim_create_namespace("CodeReview")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local found_outdated = false
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details and details.virt_lines then
        for _, vl in ipairs(details.virt_lines) do
          for _, chunk in ipairs(vl) do
            if type(chunk[1]) == "string" and chunk[1]:find("Outdated") then
              found_outdated = true
            end
          end
        end
      end
    end
    assert.is_true(found_outdated)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
```

**Step 2: Run test to verify it fails**

Run: `bunx busted tests/codereview/mr/diff_spec.lua --filter "outdated indicator"`
Expected: FAIL

**Step 3: Implement outdated badge**

In `lua/codereview/mr/diff.lua`, in the comment header rendering section (~line 219), after the `status_str` assignment, add an outdated indicator. The `outdated` flag from `discussion_line` needs to be stored and used:

Store the `outdated` flag per discussion during placement (inside the `for _, discussion` loop):

```lua
local target_line, range_start, outdated = discussion_line(discussion, review)
```

Then in the header rendering, after `status_str` (line 219), add:

```lua
local outdated_str = outdated and " Outdated " or ""
local outdated_hl = "CodeReviewCommentOutdated"
```

Insert the outdated badge into the header virt_line (line 234-240), between `status_str` and the fill `───`:

Change the fill calculation to account for `outdated_str`:

```lua
local fill = math.max(0, 62 - #header_text - #header_meta - #status_str - #outdated_str)
```

And the header virt_line becomes:

```lua
table.insert(virt_lines, {
  { "  ┌ ", n1_bdr },
  { header_text, n1_aut },
  { header_meta, n1_bdr },
  { status_str, status_hl },
  outdated_str ~= "" and { outdated_str, outdated_hl } or nil,
  { string.rep("─", fill), n1_bdr },
})
```

Note: nil entries in virt_line chunk arrays are ignored by Neovim, so this is safe. If not, use a helper to filter nils.

**Step 4: Define the highlight group**

Check where existing highlight groups like `CodeReviewCommentResolved` are defined. Add `CodeReviewCommentOutdated` with a subtle dim style (e.g., linked to `Comment` or a light italic). Find the highlight setup location:

```lua
-- Wherever CodeReviewCommentResolved is defined, add:
vim.api.nvim_set_hl(0, "CodeReviewCommentOutdated", { link = "Comment" })
```

**Step 5: Run all tests**

Run: `bunx busted tests/codereview/mr/diff_spec.lua`
Expected: ALL PASS

**Step 6: Run full test suite**

Run: `bunx busted tests/`
Expected: ALL PASS

**Step 7: Commit**

```bash
git add lua/codereview/mr/diff.lua tests/codereview/mr/diff_spec.lua
# Also add highlight file if modified
git commit -m "feat(diff): add subtle outdated badge for remapped comments"
```

---

### Task 4: Thread render_all_files review parameter

**Depends on:** Task 2

**Files:**
- Modify: `lua/codereview/mr/diff.lua:587+` (render_all_files)
- Test: `tests/codereview/mr/diff_spec.lua`

`render_all_files` already receives `review` as a parameter. It needs to pass it through to `place_comment_signs` within its per-file loop.

**Step 1: Verify render_all_files passes review to place_comment_signs**

Read the render_all_files body to find where it calls place_comment_signs and ensure `review` is forwarded. This is likely a one-line fix at the call site.

**Step 2: Implement**

In `render_all_files`, find the `place_comment_signs` call and add `review` as the last argument (matching the updated signature from Task 2).

**Step 3: Run full test suite**

Run: `bunx busted tests/`
Expected: ALL PASS

**Step 4: Commit**

```bash
git add lua/codereview/mr/diff.lua
git commit -m "fix(diff): pass review to place_comment_signs in render_all_files"
```

---

### Task 5: Integration test — full outdated flow

**Depends on:** Tasks 1-4

**Files:**
- Test: `tests/codereview/integration/gitlab_flow_spec.lua`

**Step 1: Write integration test**

Add to `tests/codereview/integration/gitlab_flow_spec.lua`:

```lua
describe("outdated comment flow", function()
  it("normalizes outdated GitLab note and remaps in diff placement", function()
    local gitlab = require("codereview.providers.gitlab")
    local diff_mod = require("codereview.mr.diff")

    -- Raw GitLab API response for an outdated note
    local raw_disc = {
      id = "disc-integ-outdated",
      notes = { {
        id = 500, author = { username = "reviewer" },
        body = "please fix this", created_at = "2026-01-15T10:00:00Z",
        system = false, resolvable = true, resolved = false,
        position = {
          new_path = "src/main.lua", old_path = "src/main.lua",
          new_line = 20, old_line = nil,
          base_sha = "old-base", head_sha = "old-head", start_sha = "old-start",
        },
        change_position = {
          new_path = "src/main.lua", old_path = "src/main.lua",
          new_line = 25, old_line = nil,
          base_sha = "cur-base", head_sha = "cur-head", start_sha = "cur-start",
        },
      } },
    }

    -- Normalize
    local disc = gitlab.normalize_discussion(raw_disc)
    assert.equal("old-head", disc.notes[1].position.head_sha)
    assert.equal(25, disc.notes[1].change_position.new_line)

    -- Place in diff
    local buf = vim.api.nvim_create_buf(false, true)
    local line_data = {
      { item = { new_line = 24, type = "context", text = "ctx" }, type = "diff" },
      { item = { new_line = 25, type = "add", text = "new code" }, type = "diff" },
    }
    local file_diff = { new_path = "src/main.lua", old_path = "src/main.lua" }
    local review = { head_sha = "cur-head" }

    local row_discs = diff_mod.place_comment_signs(buf, line_data, { disc }, file_diff, nil, nil, review)
    -- Remapped to row 2 (new_line=25)
    assert.is_not_nil(row_discs[2])
    assert.is_nil(row_discs[1])

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
```

**Step 2: Run integration test**

Run: `bunx busted tests/codereview/integration/gitlab_flow_spec.lua --filter "outdated comment flow"`
Expected: PASS

**Step 3: Run full test suite**

Run: `bunx busted tests/`
Expected: ALL PASS

**Step 4: Commit**

```bash
git add tests/codereview/integration/gitlab_flow_spec.lua
git commit -m "test(gitlab): add integration test for outdated comment remapping flow"
```
