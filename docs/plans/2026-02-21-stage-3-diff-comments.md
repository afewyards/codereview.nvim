# Stage 3: Diff & Comments — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Full MR review workflow: file tree sidebar, inline diff with colored backgrounds, comment threads, create/reply/resolve comments, approve/merge/close MRs.

**Architecture:** Split layout — left sidebar (file tree + discussions) and right pane (inline unified diff). Diff rendered via extmarks with line_hl_group for colored backgrounds. Comments via virt_lines. No +/- prefixes — color only.

**Tech Stack:** Lua, Neovim API (extmarks, virt_lines, signs, splits), plenary.nvim

**Depends on:** Stage 1 (API), Stage 2 (MR detail, float helpers)

---

### Task 1: Highlight Groups

**Files:**
- Create: `lua/glab_review/ui/highlight.lua`
- Create: `tests/glab_review/ui/highlight_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/ui/highlight_spec.lua
local highlight = require("glab_review.ui.highlight")

describe("ui.highlight", function()
  it("defines all required highlight groups", function()
    highlight.setup()
    -- Check highlight groups exist
    local add = vim.api.nvim_get_hl(0, { name = "GlabReviewDiffAdd" })
    assert.truthy(add.bg)
    local del = vim.api.nvim_get_hl(0, { name = "GlabReviewDiffDelete" })
    assert.truthy(del.bg)
    local add_word = vim.api.nvim_get_hl(0, { name = "GlabReviewDiffAddWord" })
    assert.truthy(add_word.bg)
    local del_word = vim.api.nvim_get_hl(0, { name = "GlabReviewDiffDeleteWord" })
    assert.truthy(del_word.bg)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement highlight groups**

```lua
-- lua/glab_review/ui/highlight.lua
local M = {}

function M.setup()
  -- Line-level backgrounds (soft)
  vim.api.nvim_set_hl(0, "GlabReviewDiffAdd", { bg = "#2a4a2a", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewDiffDelete", { bg = "#4a2a2a", default = true })

  -- Word-level backgrounds (darker/more saturated)
  vim.api.nvim_set_hl(0, "GlabReviewDiffAddWord", { bg = "#3a6a3a", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewDiffDeleteWord", { bg = "#6a3a3a", default = true })

  -- Comment indicators
  vim.api.nvim_set_hl(0, "GlabReviewComment", { bg = "#2a2a3a", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewCommentUnresolved", { bg = "#3a2a2a", fg = "#ff9966", default = true })

  -- Sidebar
  vim.api.nvim_set_hl(0, "GlabReviewFileChanged", { fg = "#e0af68", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewFileAdded", { fg = "#9ece6a", default = true })
  vim.api.nvim_set_hl(0, "GlabReviewFileDeleted", { fg = "#f7768e", default = true })

  -- Hidden lines separator
  vim.api.nvim_set_hl(0, "GlabReviewHidden", { fg = "#565f89", italic = true, default = true })

  -- Sign column
  vim.fn.sign_define("GlabReviewCommentSign", { text = ">>", texthl = "GlabReviewComment" })
  vim.fn.sign_define("GlabReviewUnresolvedSign", { text = "!!", texthl = "GlabReviewCommentUnresolved" })
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/ui/highlight.lua tests/glab_review/ui/highlight_spec.lua
git commit -m "feat: define diff and comment highlight groups"
```

---

### Task 2: Diff Parser

**Files:**
- Create: `lua/glab_review/mr/diff_parser.lua`
- Create: `tests/glab_review/mr/diff_parser_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/mr/diff_parser_spec.lua
local parser = require("glab_review.mr.diff_parser")

describe("diff_parser", function()
  describe("parse_hunks", function()
    it("parses a simple unified diff into hunks", function()
      local diff_text = table.concat({
        "@@ -10,3 +10,4 @@",
        " context line",
        "-removed line",
        "+added line",
        "+another added",
        " trailing context",
      }, "\n")

      local hunks = parser.parse_hunks(diff_text)
      assert.equals(1, #hunks)
      assert.equals(10, hunks[1].old_start)
      assert.equals(10, hunks[1].new_start)
      assert.equals(5, #hunks[1].lines)
    end)

    it("classifies line types correctly", function()
      local diff_text = "@@ -1,3 +1,3 @@\n context\n-old\n+new\n"
      local hunks = parser.parse_hunks(diff_text)
      local lines = hunks[1].lines
      assert.equals("context", lines[1].type)
      assert.equals("delete", lines[2].type)
      assert.equals("add", lines[3].type)
    end)

    it("computes old_line and new_line for each line", function()
      local diff_text = "@@ -5,3 +5,4 @@\n ctx\n-del\n+add1\n+add2\n ctx2\n"
      local hunks = parser.parse_hunks(diff_text)
      local lines = hunks[1].lines
      -- context: old=5, new=5
      assert.equals(5, lines[1].old_line)
      assert.equals(5, lines[1].new_line)
      -- delete: old=6, new=nil
      assert.equals(6, lines[2].old_line)
      assert.is_nil(lines[2].new_line)
      -- add1: old=nil, new=6
      assert.is_nil(lines[3].old_line)
      assert.equals(6, lines[3].new_line)
      -- add2: old=nil, new=7
      assert.is_nil(lines[4].old_line)
      assert.equals(7, lines[4].new_line)
      -- context: old=7, new=8
      assert.equals(7, lines[5].old_line)
      assert.equals(8, lines[5].new_line)
    end)
  end)

  describe("word_diff", function()
    it("finds changed segments between two lines", function()
      local old = "local resp = curl.post(url, { body = token })"
      local new = "local resp, err = curl.post(url, {"
      local segments = parser.word_diff(old, new)
      assert.truthy(#segments > 0)
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement diff parser**

```lua
-- lua/glab_review/mr/diff_parser.lua
local M = {}

function M.parse_hunks(diff_text)
  local hunks = {}
  local current_hunk = nil
  local old_line, new_line

  for line in (diff_text .. "\n"):gmatch("(.-)\n") do
    local os, ns = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    if os then
      current_hunk = {
        old_start = tonumber(os),
        new_start = tonumber(ns),
        lines = {},
      }
      old_line = tonumber(os)
      new_line = tonumber(ns)
      table.insert(hunks, current_hunk)
    elseif current_hunk then
      local prefix = line:sub(1, 1)
      local content = line:sub(2)

      if prefix == "-" then
        table.insert(current_hunk.lines, {
          type = "delete",
          text = content,
          old_line = old_line,
          new_line = nil,
        })
        old_line = old_line + 1
      elseif prefix == "+" then
        table.insert(current_hunk.lines, {
          type = "add",
          text = content,
          old_line = nil,
          new_line = new_line,
        })
        new_line = new_line + 1
      elseif prefix == " " or line == "" then
        table.insert(current_hunk.lines, {
          type = "context",
          text = content,
          old_line = old_line,
          new_line = new_line,
        })
        old_line = old_line + 1
        new_line = new_line + 1
      end
    end
  end

  return hunks
end

--- Simple word-level diff: find common prefix/suffix, mark the middle as changed
function M.word_diff(old_text, new_text)
  if not old_text or not new_text then return {} end

  -- Find common prefix length
  local prefix_len = 0
  local max_prefix = math.min(#old_text, #new_text)
  while prefix_len < max_prefix and old_text:byte(prefix_len + 1) == new_text:byte(prefix_len + 1) do
    prefix_len = prefix_len + 1
  end

  -- Find common suffix length
  local suffix_len = 0
  local max_suffix = math.min(#old_text - prefix_len, #new_text - prefix_len)
  while suffix_len < max_suffix
    and old_text:byte(#old_text - suffix_len) == new_text:byte(#new_text - suffix_len) do
    suffix_len = suffix_len + 1
  end

  return {
    old_start = prefix_len,
    old_end = #old_text - suffix_len,
    new_start = prefix_len,
    new_end = #new_text - suffix_len,
  }
end

--- Build display lines for hunks with configurable context
function M.build_display(hunks, context_lines)
  context_lines = context_lines or 3
  local display = {}

  for hunk_idx, hunk in ipairs(hunks) do
    -- Determine which lines are within context of a change
    local change_indices = {}
    for i, line in ipairs(hunk.lines) do
      if line.type ~= "context" then
        table.insert(change_indices, i)
      end
    end

    local visible = {}
    for _, ci in ipairs(change_indices) do
      for i = math.max(1, ci - context_lines), math.min(#hunk.lines, ci + context_lines) do
        visible[i] = true
      end
    end

    local hidden_start = nil
    for i, line in ipairs(hunk.lines) do
      if not visible[i] then
        if not hidden_start then
          hidden_start = i
        end
      else
        if hidden_start then
          local hidden_count = i - hidden_start
          table.insert(display, {
            type = "hidden",
            count = hidden_count,
            expandable = true,
            hunk_idx = hunk_idx,
            start_idx = hidden_start,
            end_idx = i - 1,
          })
          hidden_start = nil
        end
        table.insert(display, vim.tbl_extend("force", line, { hunk_idx = hunk_idx, line_idx = i }))
      end
    end

    if hidden_start then
      local hidden_count = #hunk.lines - hidden_start + 1
      table.insert(display, {
        type = "hidden",
        count = hidden_count,
        expandable = true,
        hunk_idx = hunk_idx,
        start_idx = hidden_start,
        end_idx = #hunk.lines,
      })
    end
  end

  return display
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/mr/diff_parser.lua tests/glab_review/mr/diff_parser_spec.lua
git commit -m "feat: add unified diff parser with hunk extraction and word diff"
```

---

### Task 3: Split Layout Helper

**Files:**
- Create: `lua/glab_review/ui/split.lua`
- Create: `tests/glab_review/ui/split_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/ui/split_spec.lua
local split = require("glab_review.ui.split")

describe("ui.split", function()
  it("creates sidebar and main pane", function()
    local layout = split.create({ sidebar_width = 30 })
    assert.truthy(layout.sidebar_buf)
    assert.truthy(layout.main_buf)
    assert.truthy(layout.sidebar_win)
    assert.truthy(layout.main_win)

    -- Cleanup
    split.close(layout)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement split layout**

```lua
-- lua/glab_review/ui/split.lua
local M = {}

function M.create(opts)
  opts = opts or {}
  local sidebar_width = opts.sidebar_width or 30

  -- Create a new tab for the review
  vim.cmd("tabnew")

  -- Create sidebar buffer
  local sidebar_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[sidebar_buf].bufhidden = "wipe"
  vim.bo[sidebar_buf].buftype = "nofile"
  vim.bo[sidebar_buf].swapfile = false

  -- Create main buffer
  local main_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[main_buf].bufhidden = "wipe"
  vim.bo[main_buf].buftype = "nofile"
  vim.bo[main_buf].swapfile = false

  -- Set up layout: sidebar left, main right
  local main_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(main_win, main_buf)

  vim.cmd("topleft " .. sidebar_width .. "vnew")
  local sidebar_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(sidebar_win, sidebar_buf)

  -- Sidebar options
  vim.wo[sidebar_win].number = false
  vim.wo[sidebar_win].relativenumber = false
  vim.wo[sidebar_win].signcolumn = "no"
  vim.wo[sidebar_win].winfixwidth = true
  vim.wo[sidebar_win].wrap = false
  vim.wo[sidebar_win].cursorline = true

  -- Main pane options
  vim.wo[main_win].number = false
  vim.wo[main_win].relativenumber = false
  vim.wo[main_win].signcolumn = "yes"
  vim.wo[main_win].wrap = false

  -- Focus main pane
  vim.api.nvim_set_current_win(main_win)

  return {
    sidebar_buf = sidebar_buf,
    sidebar_win = sidebar_win,
    main_buf = main_buf,
    main_win = main_win,
    tab = vim.api.nvim_get_current_tabpage(),
  }
end

function M.close(layout)
  if layout and layout.tab then
    pcall(function()
      local tab_nr = vim.api.nvim_tabpage_get_number(layout.tab)
      vim.cmd("tabclose " .. tab_nr)
    end)
  end
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/ui/split.lua tests/glab_review/ui/split_spec.lua
git commit -m "feat: add sidebar+main split layout helper"
```

---

### Task 4: Inline Diff Renderer

**Files:**
- Create: `lua/glab_review/mr/diff.lua`
- Create: `tests/glab_review/mr/diff_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/mr/diff_spec.lua
local diff = require("glab_review.mr.diff")

describe("mr.diff", function()
  describe("format_line_number", function()
    it("formats dual line numbers", function()
      local text = diff.format_line_number(10, 12)
      assert.truthy(text:find("10"))
      assert.truthy(text:find("12"))
    end)

    it("shows only old line for deletes", function()
      local text = diff.format_line_number(10, nil)
      assert.truthy(text:find("10"))
    end)

    it("shows only new line for adds", function()
      local text = diff.format_line_number(nil, 12)
      assert.truthy(text:find("12"))
    end)
  end)

  describe("format_hidden_line", function()
    it("formats hidden line indicator", function()
      local text = diff.format_hidden_line(18)
      assert.truthy(text:find("18"))
      assert.truthy(text:find("hidden"))
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement diff renderer**

```lua
-- lua/glab_review/mr/diff.lua
local client = require("glab_review.api.client")
local endpoints = require("glab_review.api.endpoints")
local git = require("glab_review.git")
local parser = require("glab_review.mr.diff_parser")
local highlight = require("glab_review.ui.highlight")
local split = require("glab_review.ui.split")
local config = require("glab_review.config")
local M = {}

local LINE_NR_WIDTH = 12  -- "  10 | 12  "

function M.format_line_number(old_nr, new_nr)
  local old = old_nr and string.format("%4d", old_nr) or "    "
  local new = new_nr and string.format("%-4d", new_nr) or "    "
  return old .. " | " .. new .. "  "
end

function M.format_hidden_line(count)
  return string.format("        ... %d lines hidden (press <CR> to expand) ...", count)
end

function M.render_file_diff(buf, file_diff, mr, discussions)
  local cfg = config.get()
  local context = cfg.diff.context
  local hunks = parser.parse_hunks(file_diff.diff)
  local display = parser.build_display(hunks, context)

  highlight.setup()
  local ns = vim.api.nvim_create_namespace("glab_review_diff")

  -- Build buffer lines and track highlights
  local lines = {}
  local line_data = {}  -- metadata per buffer line

  -- File header
  table.insert(lines, file_diff.new_path or file_diff.old_path)
  table.insert(lines, string.rep("-", 70))
  table.insert(line_data, { type = "header" })
  table.insert(line_data, { type = "header" })

  for _, item in ipairs(display) do
    if item.type == "hidden" then
      table.insert(lines, M.format_hidden_line(item.count))
      table.insert(line_data, {
        type = "hidden",
        hunk_idx = item.hunk_idx,
        start_idx = item.start_idx,
        end_idx = item.end_idx,
      })
    else
      local prefix = M.format_line_number(item.old_line, item.new_line)
      table.insert(lines, prefix .. item.text)
      table.insert(line_data, {
        type = item.type,
        old_line = item.old_line,
        new_line = item.new_line,
        text = item.text,
        hunk_idx = item.hunk_idx,
      })
    end
  end

  -- Set buffer content
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Apply highlights
  for i, data in ipairs(line_data) do
    local line_idx = i - 1  -- 0-based
    if data.type == "add" then
      vim.api.nvim_buf_set_extmark(buf, ns, line_idx, 0, {
        line_hl_group = "GlabReviewDiffAdd",
        end_row = line_idx + 1,
      })
    elseif data.type == "delete" then
      vim.api.nvim_buf_set_extmark(buf, ns, line_idx, 0, {
        line_hl_group = "GlabReviewDiffDelete",
        end_row = line_idx + 1,
      })
    elseif data.type == "hidden" then
      vim.api.nvim_buf_set_extmark(buf, ns, line_idx, 0, {
        line_hl_group = "GlabReviewHidden",
        end_row = line_idx + 1,
      })
    end
  end

  -- Apply word-level highlights for adjacent add/delete pairs
  for i = 2, #line_data do
    if line_data[i].type == "add" and line_data[i - 1].type == "delete" then
      local seg = parser.word_diff(line_data[i - 1].text, line_data[i].text)
      if seg and seg.old_end > seg.old_start then
        local offset = LINE_NR_WIDTH
        -- Highlight changed words on delete line
        vim.api.nvim_buf_add_highlight(buf, ns, "GlabReviewDiffDeleteWord",
          i - 2, offset + seg.old_start, offset + seg.old_end)
        -- Highlight changed words on add line
        vim.api.nvim_buf_add_highlight(buf, ns, "GlabReviewDiffAddWord",
          i - 1, offset + seg.new_start, offset + seg.new_end)
      end
    end
  end

  -- Place comment signs
  if discussions then
    M.place_comment_signs(buf, line_data, discussions, file_diff)
  end

  return line_data
end

function M.place_comment_signs(buf, line_data, discussions, file_diff)
  for _, disc in ipairs(discussions) do
    local note = disc.notes and disc.notes[1]
    if not note or not note.position then goto continue end

    local pos = note.position
    if pos.new_path ~= file_diff.new_path and pos.old_path ~= file_diff.old_path then
      goto continue
    end

    -- Find the matching buffer line
    local target_line = pos.new_line or pos.old_line
    local target_type = pos.new_line and "new_line" or "old_line"

    for i, data in ipairs(line_data) do
      if data[target_type] == target_line then
        local is_resolved = true
        for _, n in ipairs(disc.notes) do
          if n.resolvable and not n.resolved then
            is_resolved = false
            break
          end
        end
        local sign = is_resolved and "GlabReviewCommentSign" or "GlabReviewUnresolvedSign"
        vim.fn.sign_place(0, "glab_review", sign, buf, { lnum = i })
        break
      end
    end
    ::continue::
  end
end

-- Main entry point: open diff view for an MR
function M.open(mr, discussions)
  local base_url, project = git.detect_project()
  if not base_url or not project then
    vim.notify("Could not detect GitLab project", vim.log.levels.ERROR)
    return
  end

  local encoded = client.encode_project(project)

  -- Fetch diffs
  local diffs = client.paginate_all(base_url, endpoints.mr_diffs(encoded, mr.iid))
  if not diffs then
    vim.notify("Failed to load diffs", vim.log.levels.ERROR)
    return
  end

  -- Fetch discussions if not provided
  if not discussions then
    discussions = client.paginate_all(base_url, endpoints.discussions(encoded, mr.iid)) or {}
  end

  -- Create split layout
  local layout = split.create({ sidebar_width = 30 })

  -- Store state
  local state = {
    layout = layout,
    mr = mr,
    diffs = diffs,
    discussions = discussions,
    current_file_idx = 1,
  }

  -- Build sidebar
  M.render_sidebar(layout.sidebar_buf, state)

  -- Render first file diff
  if #diffs > 0 then
    state.line_data = M.render_file_diff(layout.main_buf, diffs[1], mr, discussions)
  end

  -- Set up keymaps
  M.setup_keymaps(layout, state)

  return state
end

function M.render_sidebar(buf, state)
  local mr = state.mr
  local diffs = state.diffs
  local discussions = state.discussions
  local list_mod = require("glab_review.mr.list")

  local lines = {
    string.format("MR !%d", mr.iid),
    mr.title:sub(1, 28),
    "",
    string.format("Status: %s", mr.state),
    string.format("Pipeline: %s", list_mod.pipeline_icon(mr.head_pipeline and mr.head_pipeline.status)),
    "",
    "-- Files --",
  }

  for i, file in ipairs(diffs) do
    local prefix = i == state.current_file_idx and "> " or "  "
    local comment_count = 0
    for _, disc in ipairs(discussions) do
      local note = disc.notes and disc.notes[1]
      if note and note.position then
        if note.position.new_path == file.new_path or note.position.old_path == file.old_path then
          comment_count = comment_count + 1
        end
      end
    end
    local comment_str = comment_count > 0 and string.format(" [%d]", comment_count) or ""
    local stat = ""
    if file.new_file then stat = " (new)"
    elseif file.deleted_file then stat = " (del)"
    elseif file.renamed_file then stat = " (ren)"
    end
    table.insert(lines, string.format("%s%s%s%s", prefix, file.new_path or file.old_path, stat, comment_str))
  end

  table.insert(lines, "")
  table.insert(lines, "-- Actions --")
  table.insert(lines, "[a]pprove [A]I review")
  table.insert(lines, "[c]omment [p]ipeline")
  table.insert(lines, "[m]erge   [q]uit")

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M.setup_keymaps(layout, state)
  local opts = { nowait = true }

  -- Navigate files
  local function nav_file(direction)
    return function()
      local new_idx = state.current_file_idx + direction
      if new_idx >= 1 and new_idx <= #state.diffs then
        state.current_file_idx = new_idx
        M.render_sidebar(layout.sidebar_buf, state)
        state.line_data = M.render_file_diff(layout.main_buf, state.diffs[new_idx], state.mr, state.discussions)
      end
    end
  end

  -- Navigate comments
  local function nav_comment(direction)
    return function()
      local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
      local current_line = cursor[1]
      local signs = vim.fn.sign_getplaced(layout.main_buf, { group = "glab_review" })[1].signs

      if direction > 0 then
        for _, sign in ipairs(signs) do
          if sign.lnum > current_line then
            vim.api.nvim_win_set_cursor(layout.main_win, { sign.lnum, 0 })
            return
          end
        end
      else
        for i = #signs, 1, -1 do
          if signs[i].lnum < current_line then
            vim.api.nvim_win_set_cursor(layout.main_win, { signs[i].lnum, 0 })
            return
          end
        end
      end
    end
  end

  -- Main buffer keymaps
  for _, buf in ipairs({ layout.main_buf, layout.sidebar_buf }) do
    vim.keymap.set("n", "]f", nav_file(1), vim.tbl_extend("force", opts, { buffer = buf }))
    vim.keymap.set("n", "[f", nav_file(-1), vim.tbl_extend("force", opts, { buffer = buf }))
    vim.keymap.set("n", "]c", nav_comment(1), vim.tbl_extend("force", opts, { buffer = buf }))
    vim.keymap.set("n", "[c", nav_comment(-1), vim.tbl_extend("force", opts, { buffer = buf }))
    vim.keymap.set("n", "q", function() split.close(layout) end, vim.tbl_extend("force", opts, { buffer = buf }))
  end

  -- Comment creation on main buf
  vim.keymap.set("n", "cc", function()
    M.create_comment_at_cursor(layout, state)
  end, vim.tbl_extend("force", opts, { buffer = layout.main_buf }))

  -- Expand hidden lines
  vim.keymap.set("n", "<CR>", function()
    M.expand_hidden(layout, state)
  end, vim.tbl_extend("force", opts, { buffer = layout.main_buf }))
end

function M.create_comment_at_cursor(layout, state)
  -- Implemented in Task 6
  vim.notify("Comment creation (Task 6)", vim.log.levels.WARN)
end

function M.expand_hidden(layout, state)
  local cursor = vim.api.nvim_win_get_cursor(layout.main_win)
  local line_idx = cursor[1]
  if state.line_data and state.line_data[line_idx] and state.line_data[line_idx].type == "hidden" then
    -- Re-render with expanded lines
    -- For now, re-render with context = 999 (show all)
    vim.notify("Expand hidden lines (TODO: implement targeted expand)", vim.log.levels.INFO)
  end
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/mr/diff.lua tests/glab_review/mr/diff_spec.lua
git commit -m "feat: add inline diff renderer with colored backgrounds and word diff"
```

---

### Task 5: Comment Thread Display

**Files:**
- Create: `lua/glab_review/mr/comment.lua`
- Create: `tests/glab_review/mr/comment_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/mr/comment_spec.lua
local comment = require("glab_review.mr.comment")

describe("mr.comment", function()
  describe("build_thread_lines", function()
    it("formats a discussion thread", function()
      local disc = {
        id = "abc",
        notes = {
          {
            author = { username = "jan" },
            body = "Should we make this configurable?",
            created_at = "2026-02-20T10:00:00Z",
            resolvable = true,
            resolved = false,
          },
          {
            author = { username = "maria" },
            body = "Good point, will add.",
            created_at = "2026-02-20T11:00:00Z",
            resolvable = false,
            resolved = false,
          },
        },
      }
      local lines = comment.build_thread_lines(disc)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("jan"))
      assert.truthy(joined:find("configurable"))
      assert.truthy(joined:find("maria"))
    end)

    it("shows resolved status", function()
      local disc = {
        id = "def",
        notes = {
          {
            author = { username = "jan" },
            body = "LGTM",
            created_at = "2026-02-20T10:00:00Z",
            resolvable = true,
            resolved = true,
            resolved_by = { username = "jan" },
          },
        },
      }
      local lines = comment.build_thread_lines(disc)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("Resolved"))
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement comment module**

```lua
-- lua/glab_review/mr/comment.lua
local client = require("glab_review.api.client")
local endpoints = require("glab_review.api.endpoints")
local git = require("glab_review.git")
local float = require("glab_review.ui.float")
local markdown = require("glab_review.ui.markdown")
local detail = require("glab_review.mr.detail")
local M = {}

function M.build_thread_lines(disc)
  local lines = {}
  local first = disc.notes[1]
  local is_resolved = first.resolvable and first.resolved

  -- Header
  local status = is_resolved and " (Resolved)" or " (unresolved)"
  if not first.resolvable then status = "" end
  table.insert(lines, string.format("@%s (%s)%s",
    first.author.username,
    detail.format_time(first.created_at),
    status
  ))

  -- First note body
  for _, line in ipairs(markdown.to_lines(first.body)) do
    table.insert(lines, line)
  end

  -- Replies
  for i = 2, #disc.notes do
    local note = disc.notes[i]
    table.insert(lines, "")
    table.insert(lines, string.format("  -> @%s (%s)",
      note.author.username,
      detail.format_time(note.created_at)
    ))
    for _, line in ipairs(markdown.to_lines(note.body)) do
      table.insert(lines, "  " .. line)
    end
  end

  return lines
end

function M.show_thread(disc, mr)
  local lines = M.build_thread_lines(disc)

  table.insert(lines, "")
  table.insert(lines, string.rep("-", 50))
  table.insert(lines, "[r]eply  [R]esolve  [o]pen in browser")

  local width = math.min(60, vim.o.columns - 10)
  local height = math.min(#lines, vim.o.lines - 6)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  markdown.set_buf_markdown(buf)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    width = width,
    height = height,
    col = 2,
    row = 1,
    style = "minimal",
    border = "rounded",
    title = " Discussion ",
    title_pos = "center",
  })

  local map_opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, map_opts)

  vim.keymap.set("n", "r", function()
    vim.api.nvim_win_close(win, true)
    M.reply(disc, mr)
  end, map_opts)

  vim.keymap.set("n", "R", function()
    M.resolve_toggle(disc, mr, function()
      vim.api.nvim_win_close(win, true)
    end)
  end, map_opts)

  vim.keymap.set("n", "o", function()
    if mr and mr.web_url then
      vim.ui.open(mr.web_url)
    end
  end, map_opts)
end

function M.reply(disc, mr)
  vim.ui.input({ prompt = "Reply: " }, function(input)
    if not input or input == "" then return end

    local base_url, project = git.detect_project()
    if not base_url or not project then return end
    local encoded = client.encode_project(project)

    client.post(base_url, endpoints.discussion_notes(encoded, mr.iid, disc.id), {
      body = { body = input },
    })
    vim.notify("Reply posted", vim.log.levels.INFO)
  end)
end

function M.resolve_toggle(disc, mr, callback)
  local first = disc.notes[1]
  local new_resolved = not (first.resolved or false)

  local base_url, project = git.detect_project()
  if not base_url or not project then return end
  local encoded = client.encode_project(project)

  local _, err = client.put(base_url, endpoints.discussion(encoded, mr.iid, disc.id), {
    body = { resolved = new_resolved },
  })

  if err then
    vim.notify("Failed to toggle resolve: " .. err, vim.log.levels.ERROR)
    return
  end

  vim.notify(new_resolved and "Thread resolved" or "Thread reopened", vim.log.levels.INFO)
  if callback then callback() end
end

function M.create_inline(mr, file_path, old_line, new_line)
  vim.ui.input({ prompt = "Comment: " }, function(input)
    if not input or input == "" then return end

    local base_url, project = git.detect_project()
    if not base_url or not project then return end
    local encoded = client.encode_project(project)

    local position = {
      position_type = "text",
      base_sha = mr.diff_refs.base_sha,
      head_sha = mr.diff_refs.head_sha,
      start_sha = mr.diff_refs.start_sha,
      new_path = file_path,
      old_path = file_path,
    }
    if new_line then position.new_line = new_line end
    if old_line then position.old_line = old_line end

    local _, err = client.post(base_url, endpoints.discussions(encoded, mr.iid), {
      body = {
        body = input,
        position = position,
      },
    })

    if err then
      vim.notify("Failed to create comment: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify("Comment posted", vim.log.levels.INFO)
  end)
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/mr/comment.lua tests/glab_review/mr/comment_spec.lua
git commit -m "feat: add comment thread display, reply, resolve, and inline creation"
```

---

### Task 6: MR Actions (Approve, Merge, Close)

**Files:**
- Create: `lua/glab_review/mr/actions.lua`
- Create: `tests/glab_review/mr/actions_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/mr/actions_spec.lua
local actions = require("glab_review.mr.actions")

describe("mr.actions", function()
  describe("build_merge_params", function()
    it("builds default merge params", function()
      local params = actions.build_merge_params({})
      assert.is_nil(params.squash)
      assert.is_nil(params.should_remove_source_branch)
    end)

    it("includes squash when requested", function()
      local params = actions.build_merge_params({ squash = true })
      assert.is_true(params.squash)
    end)

    it("includes merge_when_pipeline_succeeds", function()
      local params = actions.build_merge_params({ auto_merge = true })
      assert.is_true(params.merge_when_pipeline_succeeds)
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement actions module**

```lua
-- lua/glab_review/mr/actions.lua
local client = require("glab_review.api.client")
local endpoints = require("glab_review.api.endpoints")
local git = require("glab_review.git")
local M = {}

function M.build_merge_params(opts)
  local params = {}
  if opts.squash then params.squash = true end
  if opts.remove_source then params.should_remove_source_branch = true end
  if opts.auto_merge then params.merge_when_pipeline_succeeds = true end
  if opts.sha then params.sha = opts.sha end
  return params
end

function M.approve(mr)
  local base_url, project = git.detect_project()
  if not base_url or not project then return end
  local encoded = client.encode_project(project)

  local body = {}
  if mr.diff_refs and mr.diff_refs.head_sha then
    body.sha = mr.diff_refs.head_sha
  end

  local _, err = client.post(base_url, endpoints.mr_approve(encoded, mr.iid), { body = body })
  if err then
    vim.notify("Approve failed: " .. err, vim.log.levels.ERROR)
    return
  end
  vim.notify(string.format("MR !%d approved", mr.iid), vim.log.levels.INFO)
end

function M.unapprove(mr)
  local base_url, project = git.detect_project()
  if not base_url or not project then return end
  local encoded = client.encode_project(project)

  local _, err = client.post(base_url, endpoints.mr_unapprove(encoded, mr.iid), {})
  if err then
    vim.notify("Unapprove failed: " .. err, vim.log.levels.ERROR)
    return
  end
  vim.notify(string.format("MR !%d unapproved", mr.iid), vim.log.levels.INFO)
end

function M.merge(mr, opts)
  opts = opts or {}
  local base_url, project = git.detect_project()
  if not base_url or not project then return end
  local encoded = client.encode_project(project)

  local params = M.build_merge_params(opts)
  local _, err = client.put(base_url, endpoints.mr_merge(encoded, mr.iid), { body = params })
  if err then
    vim.notify("Merge failed: " .. err, vim.log.levels.ERROR)
    return
  end
  vim.notify(string.format("MR !%d merged", mr.iid), vim.log.levels.INFO)
end

function M.close(mr)
  local base_url, project = git.detect_project()
  if not base_url or not project then return end
  local encoded = client.encode_project(project)

  local _, err = client.put(base_url, endpoints.mr_detail(encoded, mr.iid), {
    body = { state_event = "close" },
  })
  if err then
    vim.notify("Close failed: " .. err, vim.log.levels.ERROR)
    return
  end
  vim.notify(string.format("MR !%d closed", mr.iid), vim.log.levels.INFO)
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/mr/actions.lua tests/glab_review/mr/actions_spec.lua
git commit -m "feat: add MR actions (approve, merge, close)"
```

---

### Task 7: Wire Diff View into MR Detail

**Files:**
- Modify: `lua/glab_review/mr/detail.lua`
- Modify: `lua/glab_review/init.lua`

**Step 1: Connect the `d` keymap in detail.lua to open diff view**

In `detail.lua`, replace the `d` keymap stub:

```lua
vim.keymap.set("n", "d", function()
  vim.api.nvim_win_close(win, true)
  local diff = require("glab_review.mr.diff")
  diff.open(mr, discussions)
end, map_opts)
```

Replace the `a` keymap stub:

```lua
vim.keymap.set("n", "a", function()
  local actions = require("glab_review.mr.actions")
  actions.approve(mr)
end, map_opts)
```

**Step 2: Update init.lua approve function**

```lua
function M.approve()
  local buf = vim.api.nvim_get_current_buf()
  local mr = vim.b[buf].glab_review_mr
  if not mr then
    vim.notify("No MR context in current buffer", vim.log.levels.WARN)
    return
  end
  require("glab_review.mr.actions").approve(mr)
end
```

**Step 3: Manually test the full flow**

1. `:GlabReview` -> pick MR -> detail opens
2. Press `d` -> diff view opens with sidebar + colored diff
3. `]f`/`[f` -> navigate files
4. `]c`/`[c` -> navigate comments
5. Press `a` in detail -> approve MR

**Step 4: Commit**

```bash
git add lua/glab_review/mr/detail.lua lua/glab_review/init.lua
git commit -m "feat: wire diff view and approve into MR detail flow"
```

---

### Stage 3 Deliverable Checklist

- [ ] Highlight groups defined (add/delete line bg, word-level, comment, hidden)
- [ ] Diff parser extracts hunks with line types and line numbers
- [ ] Word-level diff highlights changed segments
- [ ] Split layout: file tree sidebar + diff pane in a new tab
- [ ] Inline diff: colored backgrounds (green=add, red=delete), no +/- prefixes
- [ ] Hunk-based display with configurable context (default 3)
- [ ] Hidden lines indicator with expand on `<CR>`
- [ ] Comment signs in gutter, thread display in floating window
- [ ] Create inline comment, reply, resolve/unresolve
- [ ] `]f`/`[f` file nav, `]c`/`[c` comment nav, `cc` new comment
- [ ] Approve, merge, close MR actions
- [ ] Full flow: `:GlabReview` -> pick -> detail -> diff -> comment -> approve
