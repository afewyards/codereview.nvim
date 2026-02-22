# All-Files Scroll View Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a GitHub-style all-files scroll view that concatenates all MR diffs into one scrollable buffer, defaulting for MRs ≤50 files.

**Architecture:** New `render_all_files` function in `diff.lua` loops over all files, reusing existing `diff_parser` and extmark rendering. A `file_sections` table maps buffer lines → file metadata for reverse lookups. `<C-a>` toggles between modes. State tracks `scroll_mode = true|false`.

**Tech Stack:** Lua, Neovim API (extmarks, buffers, keymaps), plenary test harness

---

### Task 1: Add `scroll_threshold` config option

**Files:**
- Modify: `lua/glab_review/config.lua:4-11`
- Modify: `tests/glab_review/config_spec.lua`

**Step 1: Write failing test**

```lua
-- In config_spec.lua, add:
it("has scroll_threshold default of 50", function()
  local config = require("glab_review.config")
  config.reset()
  config.setup({})
  assert.equals(50, config.get().diff.scroll_threshold)
end)
```

**Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/glab_review/config_spec.lua"`
Expected: FAIL — `scroll_threshold` is nil

**Step 3: Implement**

In `config.lua`, change defaults:
```lua
diff = { context = 8, scroll_threshold = 50 },
```

**Step 4: Run test to verify pass**

Same command. Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/config.lua tests/glab_review/config_spec.lua
git commit -m "feat(config): add diff.scroll_threshold option"
```

---

### Task 2: Add `GlabReviewFileHeader` highlight group

**Files:**
- Modify: `lua/glab_review/ui/highlight.lua`
- Modify: `tests/glab_review/ui/highlight_spec.lua`

**Step 1: Write failing test**

```lua
it("defines GlabReviewFileHeader highlight", function()
  local hl = vim.api.nvim_get_hl(0, { name = "GlabReviewFileHeader" })
  assert.truthy(hl.bold)
end)
```

**Step 2: Run test — expect FAIL**

**Step 3: Add highlight definition**

In `highlight.lua`, alongside existing highlight groups, add:
```lua
vim.api.nvim_set_hl(0, "GlabReviewFileHeader", { bold = true, bg = "#1e2030", fg = "#c8d3f5" })
```

**Step 4: Run test — expect PASS**

**Step 5: Commit**

```bash
git add lua/glab_review/ui/highlight.lua tests/glab_review/ui/highlight_spec.lua
git commit -m "feat(ui): add GlabReviewFileHeader highlight group"
```

---

### Task 3: Build `render_all_files` — core rendering function

**Files:**
- Modify: `lua/glab_review/mr/diff.lua`
- Modify: `tests/glab_review/mr/diff_spec.lua`

This is the main function. It loops over all files, builds one concatenated buffer.

**Step 1: Write failing test**

```lua
describe("render_all_files", function()
  it("returns file_sections with correct boundaries", function()
    -- Create a test buffer
    local buf = vim.api.nvim_create_buf(false, true)

    -- Mock file diffs (minimal — just need diff text and paths)
    local files = {
      { new_path = "a.lua", old_path = "a.lua", diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n" },
      { new_path = "b.lua", old_path = "b.lua", diff = "@@ -5,2 +5,2 @@\n ctx\n-old2\n+new2\n" },
    }
    local mr = { diff_refs = nil } -- skip git diff, use API diff
    local discussions = {}

    local result = diff.render_all_files(buf, files, mr, discussions, 8)

    -- Should have 2 file sections
    assert.equals(2, #result.file_sections)
    -- First section starts at line 1 (header) or 2 (first content line)
    assert.truthy(result.file_sections[1].start_line >= 1)
    -- Second section starts after first ends
    assert.truthy(result.file_sections[2].start_line > result.file_sections[1].end_line)
    -- Each section records file index
    assert.equals(1, result.file_sections[1].file_idx)
    assert.equals(2, result.file_sections[2].file_idx)
    -- line_data is populated
    assert.truthy(#result.line_data > 0)
    -- Buffer has content
    assert.truthy(vim.api.nvim_buf_line_count(buf) > 1)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("renders file header lines with path", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local files = {
      { new_path = "src/foo.lua", old_path = "src/foo.lua", diff = "@@ -1,1 +1,1 @@\n-a\n+b\n" },
    }
    local result = diff.render_all_files(buf, files, { diff_refs = nil }, {}, 8)

    -- First line should be the file header containing the path
    local first_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.truthy(first_line:find("src/foo.lua"))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
```

**Step 2: Run test — expect FAIL** (`render_all_files` doesn't exist yet)

**Step 3: Implement `render_all_files`**

Add to `diff.lua` before `M.open`:

```lua
function M.render_all_files(buf, files, mr, discussions, context)
  local parser = require("glab_review.mr.diff_parser")
  local config = require("glab_review.config")
  context = context or config.get().diff.context

  local all_lines = {}
  local all_line_data = {}
  local file_sections = {}

  for file_idx, file_diff in ipairs(files) do
    local section_start = #all_lines + 1

    -- File header separator
    local path = file_diff.new_path or file_diff.old_path or "unknown"
    local label = path
    if file_diff.renamed_file then
      label = (file_diff.old_path or "") .. " → " .. (file_diff.new_path or "")
    elseif file_diff.new_file then
      label = path .. " (new file)"
    elseif file_diff.deleted_file then
      label = path .. " (deleted)"
    end
    local header = "─── " .. label .. " " .. string.rep("─", math.max(0, 60 - #label - 5))
    table.insert(all_lines, header)
    table.insert(all_line_data, { type = "file_header", file_idx = file_idx })

    -- Parse and build display for this file
    local diff_text = file_diff.diff or ""
    if mr.diff_refs and mr.diff_refs.base_sha and mr.diff_refs.head_sha then
      local fpath = file_diff.new_path or file_diff.old_path
      if fpath then
        local result = vim.fn.system({
          "git", "diff", "-U" .. context,
          mr.diff_refs.base_sha, mr.diff_refs.head_sha, "--", fpath,
        })
        if vim.v.shell_error == 0 and result ~= "" then
          diff_text = result
        end
      end
    end

    local hunks = parser.parse_hunks(diff_text)
    local display = parser.build_display(hunks, context)

    if #display == 0 then
      table.insert(all_lines, "  (no changes)")
      table.insert(all_line_data, { type = "empty", file_idx = file_idx })
    else
      for _, item in ipairs(display) do
        local prefix = M.format_line_number(item.old_line, item.new_line)
        table.insert(all_lines, prefix .. (item.text or ""))
        table.insert(all_line_data, { type = item.type, item = item, file_idx = file_idx })
      end
    end

    -- Blank line between files (except after last)
    if file_idx < #files then
      table.insert(all_lines, "")
      table.insert(all_line_data, { type = "separator", file_idx = file_idx })
    end

    table.insert(file_sections, {
      start_line = section_start,
      end_line = #all_lines,
      file_idx = file_idx,
      file = file_diff,
    })
  end

  -- Set buffer content
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  vim.bo[buf].modifiable = false

  -- Clear previous highlights
  vim.api.nvim_buf_clear_namespace(buf, DIFF_NS, 0, -1)

  -- Apply extmarks
  local prev_delete_row = nil
  local prev_delete_text = nil

  for i, data in ipairs(all_line_data) do
    local row = i - 1
    if data.type == "file_header" then
      apply_line_hl(buf, row, "GlabReviewFileHeader")
      prev_delete_row = nil
      prev_delete_text = nil
    elseif data.type == "add" then
      apply_line_hl(buf, row, "GlabReviewDiffAdd")
      if prev_delete_row == row - 1 and prev_delete_text then
        local segments = parser.word_diff(prev_delete_text, data.item.text or "")
        for _, seg in ipairs(segments) do
          apply_word_hl(buf, prev_delete_row,
            LINE_NR_WIDTH + seg.old_start, LINE_NR_WIDTH + seg.old_end,
            "GlabReviewDiffDeleteWord")
          apply_word_hl(buf, row,
            LINE_NR_WIDTH + seg.new_start, LINE_NR_WIDTH + seg.new_end,
            "GlabReviewDiffAddWord")
        end
      end
      prev_delete_row = nil
      prev_delete_text = nil
    elseif data.type == "delete" then
      apply_line_hl(buf, row, "GlabReviewDiffDelete")
      prev_delete_row = row
      prev_delete_text = data.item.text or ""
    else
      prev_delete_row = nil
      prev_delete_text = nil
    end
  end

  -- Place comment signs and inline threads per file section
  local all_row_discussions = {}
  for _, section in ipairs(file_sections) do
    local section_line_data = {}
    for i = section.start_line, section.end_line do
      table.insert(section_line_data, all_line_data[i])
    end
    for _, disc in ipairs(discussions or {}) do
      if discussion_matches_file(disc, section.file) then
        local target_line = discussion_line(disc)
        if target_line then
          for i = section.start_line, section.end_line do
            local data = all_line_data[i]
            if data.item and (data.item.new_line == target_line or data.item.old_line == target_line) then
              -- Place sign
              local sign_name = is_resolved(disc) and "GlabReviewCommentSign"
                or "GlabReviewUnresolvedSign"
              pcall(vim.fn.sign_place, 0, "GlabReview", sign_name, buf, { lnum = i })

              -- Render inline thread (reuse existing virt_lines logic)
              local notes = disc.notes
              if notes and #notes > 0 then
                local first = notes[1]
                local resolved = is_resolved(disc)
                local bdr = "GlabReviewCommentBorder"
                local aut = "GlabReviewCommentAuthor"
                local body_hl = resolved and "GlabReviewComment" or "GlabReviewCommentUnresolved"
                local status_hl = resolved and "GlabReviewCommentResolved" or "GlabReviewCommentUnresolved"
                local status_str = resolved and " Resolved " or " Unresolved "
                local time_str = format_time_short(first.created_at)
                local header_meta = time_str ~= "" and (" · " .. time_str) or ""
                local header_text = "@" .. first.author.username
                local fill = math.max(0, 62 - #header_text - #header_meta - #status_str)

                local virt_lines = {}
                table.insert(virt_lines, {
                  { "  ┌ ", bdr }, { header_text, aut },
                  { header_meta, bdr }, { status_str, status_hl },
                  { string.rep("─", fill), bdr },
                })
                for _, bl in ipairs(wrap_text(first.body, 64)) do
                  table.insert(virt_lines, { { "  │ ", bdr }, { bl, body_hl } })
                end
                for ni = 2, #notes do
                  local reply = notes[ni]
                  if not reply.system then
                    local rt = format_time_short(reply.created_at)
                    local rmeta = rt ~= "" and (" · " .. rt) or ""
                    table.insert(virt_lines, { { "  │", bdr } })
                    table.insert(virt_lines, {
                      { "  │  ↪ ", bdr }, { "@" .. reply.author.username, aut }, { rmeta, bdr },
                    })
                    for _, rl in ipairs(wrap_text(reply.body, 58)) do
                      table.insert(virt_lines, { { "  │    ", bdr }, { rl, body_hl } })
                    end
                  end
                end
                table.insert(virt_lines, {
                  { "  └ ", bdr }, { "r:reply  gt:un/resolve", body_hl },
                  { " " .. string.rep("─", 44), bdr },
                })
                pcall(vim.api.nvim_buf_set_extmark, buf, DIFF_NS, i - 1, 0, {
                  virt_lines = virt_lines, virt_lines_above = false,
                })
              end

              if not all_row_discussions[i] then all_row_discussions[i] = {} end
              table.insert(all_row_discussions[i], disc)
              break
            end
          end
        end
      end
    end
  end

  return {
    file_sections = file_sections,
    line_data = all_line_data,
    row_discussions = all_row_discussions,
  }
end
```

**Step 4: Run tests — expect PASS**

**Step 5: Commit**

```bash
git add lua/glab_review/mr/diff.lua tests/glab_review/mr/diff_spec.lua
git commit -m "feat(diff): add render_all_files for scroll view"
```

---

### Task 4: Add scroll-mode state and toggle logic to `open`

**Files:**
- Modify: `lua/glab_review/mr/diff.lua:752-804` (the `open` function)

**Depends on:** Task 1, Task 3

**Step 1: Write failing test**

```lua
describe("scroll mode state", function()
  it("defaults to scroll_mode=true when files <= threshold", function()
    -- This tests the state logic, not full open()
    local config = require("glab_review.config")
    config.reset()
    config.setup({ diff = { scroll_threshold = 50 } })
    local files = {}
    for i = 1, 20 do
      table.insert(files, { new_path = "file" .. i .. ".lua" })
    end
    local threshold = config.get().diff.scroll_threshold
    assert.truthy(#files <= threshold)
  end)

  it("defaults to scroll_mode=false when files > threshold", function()
    local config = require("glab_review.config")
    config.reset()
    config.setup({ diff = { scroll_threshold = 5 } })
    local files = {}
    for i = 1, 10 do
      table.insert(files, { new_path = "file" .. i .. ".lua" })
    end
    local threshold = config.get().diff.scroll_threshold
    assert.truthy(#files > threshold)
  end)
end)
```

**Step 2: Run test — expect PASS** (logic test only)

**Step 3: Modify `open` function**

In `M.open`, after building `state`, add:
```lua
state.scroll_mode = #files <= config.get().diff.scroll_threshold
state.file_sections = {}
state.scroll_line_data = {}
state.scroll_row_disc = {}
```

Replace the initial render block with:
```lua
if #files > 0 then
  if state.scroll_mode then
    local result = M.render_all_files(layout.main_buf, files, mr, state.discussions, state.context)
    state.file_sections = result.file_sections
    state.scroll_line_data = result.line_data
    state.scroll_row_disc = result.row_discussions
  else
    local line_data, row_disc = M.render_file_diff(layout.main_buf, files[1], mr, state.discussions, state.context)
    state.line_data_cache[1] = line_data
    state.row_disc_cache[1] = row_disc
  end
end
```

Add toggle function and helper:
```lua
local function toggle_scroll_mode(layout, state)
  state.scroll_mode = not state.scroll_mode
  if state.scroll_mode then
    local result = M.render_all_files(layout.main_buf, state.files, state.mr, state.discussions, state.context)
    state.file_sections = result.file_sections
    state.scroll_line_data = result.line_data
    state.scroll_row_disc = result.row_discussions
    -- Scroll to current file's section
    for _, sec in ipairs(state.file_sections) do
      if sec.file_idx == state.current_file then
        vim.api.nvim_win_set_cursor(layout.main_win, { sec.start_line, 0 })
        break
      end
    end
  else
    -- Switch back to per-file: render current file
    local file = state.files[state.current_file]
    if file then
      local ld, rd = M.render_file_diff(layout.main_buf, file, state.mr, state.discussions, state.context)
      state.line_data_cache[state.current_file] = ld
      state.row_disc_cache[state.current_file] = rd
    end
  end
  M.render_sidebar(layout.sidebar_buf, state)
  vim.notify(state.scroll_mode and "All-files view" or "Per-file view", vim.log.levels.INFO)
end

local function current_file_from_cursor(layout, state)
  local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
  local row = cursor[1]
  for i = #state.file_sections, 1, -1 do
    if row >= state.file_sections[i].start_line then
      return state.file_sections[i].file_idx
    end
  end
  return 1
end
```

**Step 4: Run all diff tests — expect PASS**

**Step 5: Commit**

```bash
git add lua/glab_review/mr/diff.lua tests/glab_review/mr/diff_spec.lua
git commit -m "feat(diff): add scroll mode state and toggle logic"
```

---

### Task 5: Wire up keymaps for scroll mode

**Files:**
- Modify: `lua/glab_review/mr/diff.lua:573-748` (the `setup_keymaps` function)

**Depends on:** Task 4

**Step 1: Add `<C-a>` toggle keymap**

In `setup_keymaps`, add:
```lua
map(main_buf, "n", "<C-a>", function() toggle_scroll_mode(layout, state) end)
map(sidebar_buf, "n", "<C-a>", function() toggle_scroll_mode(layout, state) end)
```

**Step 2: Modify `]f`/`[f` to handle scroll mode**

Replace file navigation maps:
```lua
map(main_buf, "n", "]f", function()
  if state.scroll_mode then
    local cursor = vim.api.nvim_win_get_cursor(layout.main_win)[1]
    for _, sec in ipairs(state.file_sections) do
      if sec.start_line > cursor then
        vim.api.nvim_win_set_cursor(layout.main_win, { sec.start_line, 0 })
        state.current_file = sec.file_idx
        M.render_sidebar(layout.sidebar_buf, state)
        return
      end
    end
  else
    nav_file(layout, state, 1)
  end
end)

map(main_buf, "n", "[f", function()
  if state.scroll_mode then
    local cursor = vim.api.nvim_win_get_cursor(layout.main_win)[1]
    for i = #state.file_sections, 1, -1 do
      if state.file_sections[i].start_line < cursor then
        vim.api.nvim_win_set_cursor(layout.main_win, { state.file_sections[i].start_line, 0 })
        state.current_file = state.file_sections[i].file_idx
        M.render_sidebar(layout.sidebar_buf, state)
        return
      end
    end
  else
    nav_file(layout, state, -1)
  end
end)
```

**Step 3: Modify `cc` comment creation for scroll mode**

```lua
map(main_buf, "n", "cc", function()
  if state.scroll_mode then
    local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
    local row = cursor[1]
    local data = state.scroll_line_data[row]
    if not data or not data.item then
      vim.notify("No diff line at cursor", vim.log.levels.WARN)
      return
    end
    local file = state.files[data.file_idx]
    local comment = require("glab_review.mr.comment")
    comment.create_inline(state.mr, file.old_path, file.new_path, data.item.old_line, data.item.new_line)
  else
    M.create_comment_at_cursor(layout, state)
  end
end)
```

**Step 4: Modify `]c`/`[c`, `r`, `gt` for scroll mode**

Comment nav in scroll mode uses `state.scroll_row_disc` instead of per-file cache. Reply/resolve use same reverse lookup.

**Step 5: Modify `+`/`-`/`gf` for scroll mode**

In scroll mode, these re-render the entire buffer via `render_all_files` and restore scroll position.

**Step 6: Modify sidebar `<CR>` for scroll mode**

In scroll mode, clicking a file scrolls to that section:
```lua
if state.scroll_mode then
  for _, sec in ipairs(state.file_sections) do
    if sec.file_idx == entry.idx then
      vim.api.nvim_win_set_cursor(layout.main_win, { sec.start_line, 0 })
      state.current_file = entry.idx
      M.render_sidebar(layout.sidebar_buf, state)
      vim.api.nvim_set_current_win(layout.main_win)
      return
    end
  end
end
```

**Step 7: Add CursorMoved autocmd for scroll mode sidebar sync**

```lua
vim.api.nvim_create_autocmd("CursorMoved", {
  buffer = main_buf,
  callback = function()
    if not state.scroll_mode or #state.file_sections == 0 then return end
    local file_idx = current_file_from_cursor(layout, state)
    if file_idx ~= state.current_file then
      state.current_file = file_idx
      M.render_sidebar(layout.sidebar_buf, state)
    end
  end,
})
```

**Step 8: Run all tests — expect PASS**

**Step 9: Commit**

```bash
git add lua/glab_review/mr/diff.lua
git commit -m "feat(diff): wire keymaps for scroll mode toggle and navigation"
```

---

### Task 6: Update sidebar to show `<C-a>` hint and mode indicator

**Files:**
- Modify: `lua/glab_review/mr/diff.lua:326-421` (the `render_sidebar` function)

**Depends on:** Task 4

**Step 1: Add mode indicator and keymap hint**

In `render_sidebar`, after the `files changed` line, add:
```lua
local mode_str = state.scroll_mode and "📜 All files" or "📄 Per file"
table.insert(lines, mode_str)
```

Update the keymap hints at the bottom:
```lua
table.insert(lines, "<C-a>:toggle view")
```

**Step 2: Run existing sidebar-related tests — expect PASS**

**Step 3: Commit**

```bash
git add lua/glab_review/mr/diff.lua
git commit -m "feat(sidebar): show scroll mode indicator and C-a hint"
```

---

### Task 7: Integration test — full scroll view round-trip

**Files:**
- Modify: `tests/glab_review/mr/diff_spec.lua`

**Depends on:** Task 3, Task 4, Task 5

**Step 1: Write integration test**

```lua
describe("all-files scroll view integration", function()
  it("file_sections reverse-maps buffer line to correct file", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local files = {
      { new_path = "a.lua", old_path = "a.lua", diff = "@@ -1,2 +1,2 @@\n ctx\n-old\n+new\n" },
      { new_path = "b.lua", old_path = "b.lua", diff = "@@ -1,1 +1,1 @@\n-x\n+y\n" },
    }
    local result = diff.render_all_files(buf, files, { diff_refs = nil }, {}, 8)

    -- Check that line_data entries have correct file_idx
    for _, sec in ipairs(result.file_sections) do
      for i = sec.start_line, sec.end_line do
        assert.equals(sec.file_idx, result.line_data[i].file_idx)
      end
    end

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("handles empty diff gracefully", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local files = {}
    local result = diff.render_all_files(buf, files, { diff_refs = nil }, {}, 8)
    assert.equals(0, #result.file_sections)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("handles renamed files in header", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local files = {
      { new_path = "new.lua", old_path = "old.lua", renamed_file = true, diff = "@@ -1,1 +1,1 @@\n ctx\n" },
    }
    local result = diff.render_all_files(buf, files, { diff_refs = nil }, {}, 8)
    local first_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    assert.truthy(first_line:find("old.lua"))
    assert.truthy(first_line:find("new.lua"))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
```

**Step 2: Run tests — expect PASS**

**Step 3: Commit**

```bash
git add tests/glab_review/mr/diff_spec.lua
git commit -m "test(diff): add integration tests for all-files scroll view"
```

---

## Unresolved Questions

None — design is fully approved.

## Task Dependencies

```
Task 1 (config) ──┐
Task 2 (highlight)─┤
                   ├── Task 3 (render_all_files) ── Task 4 (state/toggle) ──┬── Task 5 (keymaps)
                   │                                                        └── Task 6 (sidebar)
                   └────────────────────────────────────────────────────────────── Task 7 (integration test, after 3+4+5)
```

Tasks 1, 2 are independent and can run in parallel.
Task 3 depends on 1, 2.
Tasks 4 depends on 3.
Tasks 5, 6 depend on 4 and can run in parallel.
Task 7 depends on 3, 4, 5.
