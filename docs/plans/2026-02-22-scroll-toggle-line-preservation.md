# Scroll Toggle Line Preservation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Preserve exact cursor line when toggling between scroll and per-file diff views.

**Architecture:** Two pure helpers (`find_anchor`, `find_row_for_anchor`) extract and resolve diff-line anchors. `toggle_scroll_mode` calls them before/after re-rendering. Match priority: exact new_line → closest new_line → first diff line in file.

**Tech Stack:** Lua, Neovim API, busted (tests via `bunx vitest` → actually `busted` via `nvim --headless`)

---

### Task 1: Add `find_anchor` helper + tests

**Files:**
- Modify: `lua/glab_review/mr/diff.lua:827` (insert before `current_file_from_cursor`)
- Test: `tests/glab_review/mr/diff_spec.lua`

**Step 1: Write the failing tests**

Add to `tests/glab_review/mr/diff_spec.lua` inside `describe("mr.diff", ...)`, after the `render_all_files` block:

```lua
describe("find_anchor", function()
  it("extracts old_line/new_line from a diff line", function()
    local line_data = {
      { type = "file_header", file_idx = 1 },
      { type = "context", item = { old_line = 10, new_line = 10, text = "ctx" }, file_idx = 1 },
      { type = "delete", item = { old_line = 11, new_line = nil, text = "old" }, file_idx = 1 },
      { type = "add", item = { old_line = nil, new_line = 11, text = "new" }, file_idx = 1 },
    }
    local anchor = diff.find_anchor(line_data, 2, 1)
    assert.equals(1, anchor.file_idx)
    assert.equals(10, anchor.old_line)
    assert.equals(10, anchor.new_line)
  end)

  it("returns file_idx only for non-diff lines", function()
    local line_data = {
      { type = "file_header", file_idx = 1 },
      { type = "add", item = { old_line = nil, new_line = 5, text = "x" }, file_idx = 1 },
    }
    local anchor = diff.find_anchor(line_data, 1, 1)
    assert.equals(1, anchor.file_idx)
    assert.is_nil(anchor.old_line)
    assert.is_nil(anchor.new_line)
  end)

  it("uses explicit file_idx for per-file line_data (no file_idx field)", function()
    local line_data = {
      { type = "context", item = { old_line = 5, new_line = 5, text = "x" } },
    }
    local anchor = diff.find_anchor(line_data, 1, 3)
    assert.equals(3, anchor.file_idx)
    assert.equals(5, anchor.old_line)
  end)
end)
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/kleist/Sites/gitlab.nvim && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/glab_review/mr/diff_spec.lua" +qa 2>&1`
Expected: FAIL — `find_anchor` not defined

**Step 3: Implement `find_anchor`**

Insert in `lua/glab_review/mr/diff.lua` at line 827 (before `current_file_from_cursor`):

```lua
--- Extract a position anchor from line_data at cursor_row.
--- @param line_data table[] line_data array (per-file or scroll mode)
--- @param cursor_row number 1-indexed buffer row
--- @param file_idx number? fallback file_idx (for per-file line_data which lacks file_idx)
--- @return table anchor { file_idx, old_line?, new_line? }
function M.find_anchor(line_data, cursor_row, file_idx)
  local data = line_data[cursor_row]
  if not data then return { file_idx = file_idx or 1 } end
  local fi = data.file_idx or file_idx or 1
  local item = data.item
  if item then
    return { file_idx = fi, old_line = item.old_line, new_line = item.new_line }
  end
  return { file_idx = fi }
end
```

**Step 4: Run tests to verify they pass**

Same command as Step 2.
Expected: PASS

**Step 5: Commit**

```
git add lua/glab_review/mr/diff.lua tests/glab_review/mr/diff_spec.lua
git commit -m "feat(diff): add find_anchor helper for cursor position extraction"
```

---

### Task 2: Add `find_row_for_anchor` helper + tests

**Files:**
- Modify: `lua/glab_review/mr/diff.lua` (insert right after `find_anchor`)
- Test: `tests/glab_review/mr/diff_spec.lua`

**Step 1: Write the failing tests**

Add to `tests/glab_review/mr/diff_spec.lua` after the `find_anchor` block:

```lua
describe("find_row_for_anchor", function()
  it("finds exact new_line match", function()
    local line_data = {
      { type = "file_header", file_idx = 1 },
      { type = "context", item = { old_line = 10, new_line = 10 }, file_idx = 1 },
      { type = "add", item = { old_line = nil, new_line = 11 }, file_idx = 1 },
    }
    local row = diff.find_row_for_anchor(line_data, { file_idx = 1, new_line = 11 })
    assert.equals(3, row)
  end)

  it("finds exact old_line match for delete-only anchor", function()
    local line_data = {
      { type = "file_header", file_idx = 1 },
      { type = "delete", item = { old_line = 20, new_line = nil }, file_idx = 1 },
      { type = "context", item = { old_line = 21, new_line = 20 }, file_idx = 1 },
    }
    local row = diff.find_row_for_anchor(line_data, { file_idx = 1, old_line = 20, new_line = nil })
    assert.equals(2, row)
  end)

  it("falls back to closest new_line in same file", function()
    local line_data = {
      { type = "file_header", file_idx = 1 },
      { type = "context", item = { old_line = 5, new_line = 5 }, file_idx = 1 },
      { type = "context", item = { old_line = 50, new_line = 50 }, file_idx = 1 },
    }
    -- Anchor line 8 doesn't exist; line 5 is closer than line 50
    local row = diff.find_row_for_anchor(line_data, { file_idx = 1, new_line = 8 })
    assert.equals(2, row)
  end)

  it("falls back to first diff line when anchor has no line numbers", function()
    local line_data = {
      { type = "file_header", file_idx = 1 },
      { type = "context", item = { old_line = 1, new_line = 1 }, file_idx = 1 },
      { type = "file_header", file_idx = 2 },
      { type = "context", item = { old_line = 1, new_line = 1 }, file_idx = 2 },
    }
    local row = diff.find_row_for_anchor(line_data, { file_idx = 2 })
    assert.equals(4, row)
  end)

  it("returns 1 when nothing matches", function()
    local line_data = {
      { type = "file_header", file_idx = 1 },
    }
    local row = diff.find_row_for_anchor(line_data, { file_idx = 5, new_line = 99 })
    assert.equals(1, row)
  end)

  it("matches correct file_idx in multi-file scroll data", function()
    local line_data = {
      { type = "context", item = { old_line = 10, new_line = 10 }, file_idx = 1 },
      { type = "context", item = { old_line = 10, new_line = 10 }, file_idx = 2 },
    }
    local row = diff.find_row_for_anchor(line_data, { file_idx = 2, new_line = 10 })
    assert.equals(2, row)
  end)
end)
```

**Step 2: Run tests to verify they fail**

Same test command. Expected: FAIL — `find_row_for_anchor` not defined

**Step 3: Implement `find_row_for_anchor`**

Insert right after `find_anchor` in `lua/glab_review/mr/diff.lua`:

```lua
--- Find the buffer row in line_data that best matches an anchor.
--- Priority: exact new_line (or old_line for deletes) > closest new_line > first diff line in file.
--- @param line_data table[] target view's line_data
--- @param anchor table { file_idx, old_line?, new_line? }
--- @param fallback_file_idx number? override file_idx for per-file line_data
--- @return number row 1-indexed buffer row
function M.find_row_for_anchor(line_data, anchor, fallback_file_idx)
  local target_fi = anchor.file_idx
  local target_new = anchor.new_line
  local target_old = anchor.old_line
  local has_target = target_new or target_old

  local first_diff_row = nil
  local closest_row = nil
  local closest_dist = math.huge

  for row, data in ipairs(line_data) do
    local fi = data.file_idx or fallback_file_idx
    if fi == target_fi then
      local item = data.item
      if item then
        -- Track first diff line in this file
        if not first_diff_row then first_diff_row = row end

        if has_target then
          -- Exact match: prefer new_line; for delete-only anchors use old_line
          if target_new and item.new_line == target_new then return row end
          if not target_new and target_old and item.old_line == target_old then return row end

          -- Closest match by new_line distance
          local item_line = item.new_line or item.old_line
          local anchor_line = target_new or target_old
          if item_line and anchor_line then
            local dist = math.abs(item_line - anchor_line)
            if dist < closest_dist then
              closest_dist = dist
              closest_row = row
            end
          end
        end
      end
    end
  end

  if not has_target and first_diff_row then return first_diff_row end
  if closest_row then return closest_row end
  if first_diff_row then return first_diff_row end
  return 1
end
```

**Step 4: Run tests to verify they pass**

Same test command. Expected: PASS

**Step 5: Commit**

```
git add lua/glab_review/mr/diff.lua tests/glab_review/mr/diff_spec.lua
git commit -m "feat(diff): add find_row_for_anchor helper for cursor restoration"
```

---

### Task 3: Wire helpers into `toggle_scroll_mode` + tests

**Files:**
- Modify: `lua/glab_review/mr/diff.lua` — `toggle_scroll_mode` function (~line 840-865)
- Test: `tests/glab_review/mr/diff_spec.lua`

**Step 1: Write the failing tests**

These are integration-style unit tests that test the anchor round-trip through real rendered data:

```lua
describe("toggle_scroll_mode line preservation", function()
  local function make_files()
    return {
      { new_path = "a.lua", old_path = "a.lua", diff = "@@ -1,3 +1,3 @@\n ctx1\n-old1\n+new1\n ctx2\n" },
      { new_path = "b.lua", old_path = "b.lua", diff = "@@ -10,3 +10,3 @@\n ctx10\n-old10\n+new10\n ctx11\n" },
    }
  end

  it("round-trips anchor through scroll line_data", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local files = make_files()
    local result = diff.render_all_files(buf, files, { diff_refs = nil }, {}, 8)

    -- Find row for file 2, new_line=10 in scroll data
    local anchor = { file_idx = 2, new_line = 10 }
    local row = diff.find_row_for_anchor(result.line_data, anchor)
    -- Verify it lands on correct file
    assert.equals(2, result.line_data[row].file_idx)
    assert.equals(10, result.line_data[row].item.new_line)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("round-trips anchor through per-file line_data", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local file = { new_path = "b.lua", old_path = "b.lua", diff = "@@ -10,3 +10,3 @@\n ctx10\n-old10\n+new10\n ctx11\n" }
    local ld = diff.render_file_diff(buf, file, { diff_refs = nil }, {}, 8)

    -- Find anchor at some diff line
    local anchor = diff.find_anchor(ld, 2, 2)
    -- Resolve back
    local row = diff.find_row_for_anchor(ld, anchor, 2)
    assert.equals(2, row)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
```

**Step 2: Run tests to verify they pass** (these are pure helper tests, should pass already)

Same test command. Expected: PASS

**Step 3: Modify `toggle_scroll_mode`**

Replace the `toggle_scroll_mode` function at ~line 840-865 with:

```lua
local function toggle_scroll_mode(layout, state)
  local cursor_row = vim.api.nvim_win_get_cursor(layout.main_win)[1]

  if state.scroll_mode then
    -- EXITING scroll mode → per-file
    local anchor = M.find_anchor(state.scroll_line_data, cursor_row)
    state.current_file = anchor.file_idx
    state.scroll_mode = false

    local file = state.files[state.current_file]
    if file then
      local ld, rd = M.render_file_diff(layout.main_buf, file, state.mr, state.discussions, state.context)
      state.line_data_cache[state.current_file] = ld
      state.row_disc_cache[state.current_file] = rd
      local row = M.find_row_for_anchor(ld, anchor, state.current_file)
      vim.api.nvim_win_set_cursor(layout.main_win, { row, 0 })
    end
  else
    -- ENTERING scroll mode → all-files
    local per_file_ld = state.line_data_cache[state.current_file]
    local anchor = M.find_anchor(per_file_ld or {}, cursor_row, state.current_file)
    state.scroll_mode = true

    local result = M.render_all_files(layout.main_buf, state.files, state.mr, state.discussions, state.context, state.file_contexts)
    state.file_sections = result.file_sections
    state.scroll_line_data = result.line_data
    state.scroll_row_disc = result.row_discussions
    local row = M.find_row_for_anchor(state.scroll_line_data, anchor)
    vim.api.nvim_win_set_cursor(layout.main_win, { row, 0 })
  end

  M.render_sidebar(layout.sidebar_buf, state)
  vim.notify(state.scroll_mode and "All-files view" or "Per-file view", vim.log.levels.INFO)
end
```

**Step 4: Run tests to verify they pass**

Same test command. Expected: PASS

**Step 5: Commit**

```
git add lua/glab_review/mr/diff.lua tests/glab_review/mr/diff_spec.lua
git commit -m "feat(diff): preserve cursor line across scroll mode toggle"
```
