# Outdated Comments Implementation Plan (GitLab + GitHub)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix outdated comments on both GitLab and GitHub so they either render at the correct remapped line (with an "outdated" badge) or gracefully disappear from diff view while remaining visible in activity view.

**Architecture:** Preserve position metadata during normalization (SHAs + `change_position` for GitLab; `isOutdated` + `originalLine` for GitHub). Detect outdated via SHA comparison (GitLab) or `outdated` flag (GitHub). Use remapped line numbers for placement. Unmappable comments skip diff placement. Shared "outdated" badge in diff.lua for both providers.

**Tech Stack:** Lua, Neovim API, Busted test framework

---

### Task 1: GitLab — preserve position SHAs and change_position

**Files:**
- Modify: `lua/codereview/providers/gitlab.lua:67-97`
- Test: `tests/codereview/providers/gitlab_spec.lua`

**Step 1: Write failing tests**

In `tests/codereview/providers/gitlab_spec.lua`, inside `describe("normalize_discussion")`:

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

it("preserves change_position when present", function()
  local disc = {
    id = "disc-cp",
    notes = { {
      id = 201, author = { username = "bob" },
      body = "moved", created_at = "2026-01-01T00:00:00Z",
      system = false, resolvable = true, resolved = false,
      position = {
        new_path = "foo.lua", old_path = "foo.lua",
        new_line = 10, old_line = nil,
        base_sha = "old-base", head_sha = "old-head", start_sha = "old-start",
      },
      change_position = {
        new_path = "foo.lua", old_path = "foo.lua",
        new_line = 15, old_line = nil,
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
      body = "normal", created_at = "2026-01-01T00:00:00Z",
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

**Step 2: Run tests — expect FAIL**

Run: `bunx busted tests/codereview/providers/gitlab_spec.lua --filter "position SHAs|change_position"`

**Step 3: Implement**

In `lua/codereview/providers/gitlab.lua`, `normalize_note` function (line 67):

Add to position table: `base_sha = p.base_sha`, `head_sha = p.head_sha`, `start_sha = p.start_sha`.

After the position block, add `change_position` extraction:

```lua
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
```

Add `change_position = change_position` to the return table.

**Step 4: Run tests — expect PASS**

Run: `bunx busted tests/codereview/providers/gitlab_spec.lua`

**Step 5: Commit**

`feat(gitlab): preserve position SHAs and change_position in normalize_note`

---

### Task 2: GitHub — add isOutdated/originalLine to GraphQL query and normalization

**Files:**
- Modify: `lua/codereview/providers/github.lua:101-137` (normalize_graphql_threads)
- Modify: `lua/codereview/providers/github.lua:204-232` (GraphQL query)
- Test: `tests/codereview/providers/github_spec.lua`

**Step 1: Write failing tests**

In `tests/codereview/providers/github_spec.lua`, inside `describe("normalize_graphql_threads")`:

```lua
it("falls back to originalLine when line is nil (outdated comment)", function()
  local threads = { {
    id = "PRRT_outdated",
    isResolved = false,
    isOutdated = true,
    diffSide = "RIGHT",
    startDiffSide = nil,
    comments = { nodes = { {
      databaseId = 10, author = { login = "alice" },
      body = "old feedback", createdAt = "2026-01-01T00:00:00Z",
      path = "foo.lua", line = vim.NIL, originalLine = 20,
      startLine = vim.NIL, originalStartLine = vim.NIL,
      outdated = true,
      commit = { oid = "old-sha" },
    } } },
  } }
  local discussions = github.normalize_graphql_threads(threads)
  assert.equal(1, #discussions)
  local pos = discussions[1].notes[1].position
  assert.equal(20, pos.new_line)  -- fell back to originalLine
  assert.is_true(pos.outdated)
end)

it("sets outdated=false for current comments", function()
  local threads = { {
    id = "PRRT_current",
    isResolved = false,
    isOutdated = false,
    diffSide = "RIGHT",
    startDiffSide = nil,
    comments = { nodes = { {
      databaseId = 11, author = { login = "bob" },
      body = "current", createdAt = "2026-01-01T00:00:00Z",
      path = "bar.lua", line = 5, originalLine = 5,
      startLine = vim.NIL, originalStartLine = vim.NIL,
      outdated = false,
      commit = { oid = "cur-sha" },
    } } },
  } }
  local discussions = github.normalize_graphql_threads(threads)
  local pos = discussions[1].notes[1].position
  assert.equal(5, pos.new_line)
  assert.is_false(pos.outdated)
end)
```

**Step 2: Run tests — expect FAIL**

Run: `bunx busted tests/codereview/providers/github_spec.lua --filter "originalLine|outdated"`

**Step 3: Implement normalization changes**

In `lua/codereview/providers/github.lua:101-137`, update `normalize_graphql_threads`:

```lua
position = {
  new_path = c.path,
  new_line = c.line or c.originalLine,
  side = thread.diffSide,
  start_line = c.startLine or c.originalStartLine,
  start_side = thread.startDiffSide,
  commit_sha = c.commit and c.commit.oid,
  outdated = thread.isOutdated or c.outdated or false,
},
```

Handle `vim.NIL` — `c.line` from JSON decode may be `vim.NIL` (not Lua nil). Normalize: `local line = c.line ~= vim.NIL and c.line or nil`.

**Step 4: Update GraphQL query**

In `lua/codereview/providers/github.lua:204-232`, add fields:

On thread level (after `startDiffSide`): `isOutdated`

On comment level (after `startLine`): `originalLine`, `originalStartLine`, `outdated`

**Step 5: Run tests — expect PASS**

Run: `bunx busted tests/codereview/providers/github_spec.lua`

**Step 6: Commit**

`feat(github): query isOutdated/originalLine, fallback for outdated comments`

---

### Task 3: diff.lua — outdated detection and change_position remapping

**Depends on:** Task 1

**Files:**
- Modify: `lua/codereview/mr/diff.lua:148-172` (discussion_matches_file, discussion_line, place_comment_signs signature)
- Modify: `lua/codereview/mr/diff.lua:574` (call site in render_file_diff)
- Modify: `lua/codereview/mr/diff.lua:763-768` (call sites in render_all_files)
- Test: `tests/codereview/mr/diff_spec.lua`

**Step 1: Write failing tests**

Add new `describe("outdated comment remapping")` in `tests/codereview/mr/diff_spec.lua`:

```lua
describe("outdated comment remapping", function()
  it("uses change_position line for GitLab outdated comment", function()
    local buf = vim.api.nvim_create_buf(false, true)
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
          new_line = 10, old_line = nil, head_sha = "old-head",
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
    assert.is_not_nil(row_discs[3])  -- row 3 = new_line 15 from change_position
    assert.is_nil(row_discs[1])

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("skips outdated GitLab comment when change_position is nil", function()
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
          new_line = 99, old_line = nil, head_sha = "old-head",
        },
      } },
    } }
    local file_diff = { new_path = "foo.lua", old_path = "foo.lua" }
    local review = { head_sha = "current-head" }

    local row_discs = diff.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
    for _, v in pairs(row_discs) do
      for _, d in ipairs(v) do
        assert.not_equal("disc-gone", d.id)
      end
    end

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("places GitHub outdated comment using fallback originalLine", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local line_data = {
      { item = { new_line = 20, old_line = 20, type = "context", text = "ctx" }, type = "diff" },
    }
    local discussions = { {
      id = "disc-gh-outdated",
      notes = { {
        id = 302, author = "carol", body = "old",
        created_at = "2026-01-01T00:00:00Z",
        system = false, resolvable = true, resolved = false,
        position = {
          path = "foo.lua", new_path = "foo.lua",
          new_line = 20, outdated = true,
        },
      } },
    } }
    local file_diff = { new_path = "foo.lua", old_path = "foo.lua" }
    local review = { head_sha = "current-head" }

    local row_discs = diff.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
    assert.is_not_nil(row_discs[1])

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("places current-version comment normally", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local line_data = {
      { item = { new_line = 10, old_line = 10, type = "context", text = "ctx" }, type = "diff" },
    }
    local discussions = { {
      id = "disc-current",
      notes = { {
        id = 303, author = "dave", body = "current",
        created_at = "2026-01-01T00:00:00Z",
        system = false, resolvable = true, resolved = false,
        position = {
          path = "foo.lua", new_path = "foo.lua", old_path = "foo.lua",
          new_line = 10, old_line = nil, head_sha = "current-head",
        },
      } },
    } }
    local file_diff = { new_path = "foo.lua", old_path = "foo.lua" }
    local review = { head_sha = "current-head" }

    local row_discs = diff.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
    assert.is_not_nil(row_discs[1])

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
```

**Step 2: Run tests — expect FAIL**

Run: `bunx busted tests/codereview/mr/diff_spec.lua --filter "outdated comment"`

**Step 3: Implement**

Add helper above `discussion_matches_file` (~line 148):

```lua
local function is_outdated(discussion, review)
  local note = discussion.notes and discussion.notes[1]
  if not note then return false end
  -- GitHub: explicit outdated flag
  if note.position and note.position.outdated then return true end
  -- GitLab: SHA comparison
  if not review or not review.head_sha then return false end
  if not note.position or not note.position.head_sha then return false end
  return note.position.head_sha ~= review.head_sha
end
```

Update `discussion_matches_file` to accept `review` and check `change_position` paths for outdated GitLab comments:

```lua
local function discussion_matches_file(discussion, file_diff, review)
  local note = discussion.notes and discussion.notes[1]
  if not note or not note.position then return false end
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

Update `discussion_line` to accept `review` and return outdated flag:

```lua
local function discussion_line(discussion, review)
  local note = discussion.notes and discussion.notes[1]
  if not note or not note.position then return nil end
  local outdated = is_outdated(discussion, review)
  -- GitLab outdated: use change_position, skip if absent
  if outdated and note.change_position then
    local cp = note.change_position
    local end_line = tonumber(cp.new_line) or tonumber(cp.old_line)
    return end_line, nil, true
  elseif outdated and not note.position.outdated and not note.change_position then
    -- GitLab outdated with no change_position: unmappable
    return nil
  end
  -- GitHub outdated with fallback originalLine already baked into new_line by normalizer
  -- or current comment: use position directly
  local pos = note.position
  local end_line = tonumber(pos.new_line) or tonumber(pos.old_line)
  local start_line = tonumber(pos.start_line) or tonumber(pos.start_new_line) or tonumber(pos.start_old_line)
  return end_line, start_line, outdated
end
```

Update `place_comment_signs` signature (line 172):

```lua
function M.place_comment_signs(buf, line_data, discussions, file_diff, row_selection, current_user, review)
```

Update calls inside the function:

```lua
if discussion_matches_file(discussion, file_diff, review) then
  local target_line, range_start, outdated = discussion_line(discussion, review)
```

Store `outdated` flag on the discussion entry in `row_discussions` for use by the badge (Task 4).

Update call site in `render_file_diff` (line 574):

```lua
row_discussions = M.place_comment_signs(buf, line_data, discussions, file_diff, row_selection, current_user, review) or {}
```

Update `render_all_files` inline placement (lines 763-768):

```lua
if discussion_matches_file(disc, section.file, review) then
  local target_line, range_start, outdated = discussion_line(disc, review)
```

**Step 4: Run tests — expect PASS**

Run: `bunx busted tests/codereview/mr/diff_spec.lua`

**Step 5: Commit**

`feat(diff): detect outdated comments and remap via change_position`

---

### Task 4: Outdated badge in comment header + highlight group

**Depends on:** Task 3

**Files:**
- Modify: `lua/codereview/mr/diff.lua:219-240` (place_comment_signs header rendering)
- Modify: `lua/codereview/mr/diff.lua:805-810` (render_all_files header rendering)
- Modify: `lua/codereview/ui/highlight.lua:28` (add CodeReviewCommentOutdated)
- Test: `tests/codereview/mr/diff_spec.lua`

**Step 1: Write failing test**

```lua
describe("outdated badge", function()
  it("renders Outdated indicator for remapped comment", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local line_data = {
      { item = { new_line = 15, type = "add", text = "new code" }, type = "diff" },
    }
    local discussions = { {
      id = "disc-badge",
      notes = { {
        id = 400, author = "alice", body = "old feedback",
        created_at = "2026-02-01T12:00:00Z",
        system = false, resolvable = true, resolved = false,
        position = {
          path = "foo.lua", new_path = "foo.lua", old_path = "foo.lua",
          new_line = 10, old_line = nil, head_sha = "old-head",
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

**Step 2: Run test — expect FAIL**

Run: `bunx busted tests/codereview/mr/diff_spec.lua --filter "Outdated indicator"`

**Step 3: Implement highlight group**

In `lua/codereview/ui/highlight.lua`, after line 28 (CodeReviewCommentResolved):

```lua
vim.api.nvim_set_hl(0, "CodeReviewCommentOutdated", { fg = "#565f89", italic = true, default = true })
```

**Step 4: Implement badge in place_comment_signs**

In `lua/codereview/mr/diff.lua`, in the comment header rendering block (~line 219), the `outdated` variable is available from `discussion_line`. After `status_str`:

```lua
local outdated_str = outdated and " Outdated " or ""
```

Update fill calculation:

```lua
local fill = math.max(0, 62 - #header_text - #header_meta - #status_str - #outdated_str)
```

Update header virt_line to include outdated badge between status and fill:

```lua
local header_chunks = {
  { "  ┌ ", n1_bdr },
  { header_text, n1_aut },
  { header_meta, n1_bdr },
  { status_str, status_hl },
}
if outdated_str ~= "" then
  table.insert(header_chunks, { outdated_str, "CodeReviewCommentOutdated" })
end
table.insert(header_chunks, { string.rep("─", fill), n1_bdr })
table.insert(virt_lines, header_chunks)
```

Apply the same change in `render_all_files` header rendering (~line 805-810).

**Step 5: Run tests — expect PASS**

Run: `bunx busted tests/codereview/mr/diff_spec.lua`

**Step 6: Run full suite**

Run: `bunx busted tests/`

**Step 7: Commit**

`feat(diff): add outdated badge and highlight for remapped comments`

---

### Task 5: Integration test — full outdated flow (both providers)

**Depends on:** Tasks 1-4

**Files:**
- Test: `tests/codereview/integration/gitlab_flow_spec.lua`

**Step 1: Write integration test**

```lua
describe("outdated comment flow", function()
  it("GitLab: normalizes and remaps outdated comment", function()
    local gitlab = require("codereview.providers.gitlab")
    local diff_mod = require("codereview.mr.diff")

    local raw_disc = {
      id = "disc-integ",
      notes = { {
        id = 500, author = { username = "reviewer" },
        body = "please fix", created_at = "2026-01-15T10:00:00Z",
        system = false, resolvable = true, resolved = false,
        position = {
          new_path = "src/main.lua", old_path = "src/main.lua",
          new_line = 20, old_line = nil,
          base_sha = "old-base", head_sha = "old-head", start_sha = "old-start",
        },
        change_position = {
          new_path = "src/main.lua", old_path = "src/main.lua",
          new_line = 25, old_line = nil,
        },
      } },
    }

    local disc = gitlab.normalize_discussion(raw_disc)
    assert.equal("old-head", disc.notes[1].position.head_sha)
    assert.equal(25, disc.notes[1].change_position.new_line)

    local buf = vim.api.nvim_create_buf(false, true)
    local line_data = {
      { item = { new_line = 24, type = "context", text = "ctx" }, type = "diff" },
      { item = { new_line = 25, type = "add", text = "new code" }, type = "diff" },
    }
    local file_diff = { new_path = "src/main.lua", old_path = "src/main.lua" }
    local review = { head_sha = "cur-head" }

    local row_discs = diff_mod.place_comment_signs(buf, line_data, { disc }, file_diff, nil, nil, review)
    assert.is_not_nil(row_discs[2])
    assert.is_nil(row_discs[1])

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("GitHub: normalizes outdated comment with originalLine fallback", function()
    local github = require("codereview.providers.github")
    local diff_mod = require("codereview.mr.diff")

    local threads = { {
      id = "PRRT_outdated",
      isResolved = false,
      isOutdated = true,
      diffSide = "RIGHT",
      startDiffSide = nil,
      comments = { nodes = { {
        databaseId = 600, author = { login = "reviewer" },
        body = "fix this", createdAt = "2026-01-15T10:00:00Z",
        path = "src/app.lua", line = vim.NIL, originalLine = 30,
        startLine = vim.NIL, originalStartLine = vim.NIL,
        outdated = true,
        commit = { oid = "old-sha" },
      } } },
    } }

    local discussions = github.normalize_graphql_threads(threads)
    assert.equal(30, discussions[1].notes[1].position.new_line)
    assert.is_true(discussions[1].notes[1].position.outdated)

    local buf = vim.api.nvim_create_buf(false, true)
    local line_data = {
      { item = { new_line = 30, type = "context", text = "ctx" }, type = "diff" },
    }
    local file_diff = { new_path = "src/app.lua", old_path = "src/app.lua" }
    local review = { head_sha = "cur-head" }

    local row_discs = diff_mod.place_comment_signs(buf, line_data, discussions, file_diff, nil, nil, review)
    assert.is_not_nil(row_discs[1])

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
```

**Step 2: Run integration tests — expect PASS**

Run: `bunx busted tests/codereview/integration/gitlab_flow_spec.lua --filter "outdated comment flow"`

**Step 3: Run full suite**

Run: `bunx busted tests/`

**Step 4: Commit**

`test: integration tests for outdated comment flow (GitLab + GitHub)`
