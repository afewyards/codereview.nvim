# Block-Level Markdown Rendering Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Render full markdown (headers, lists, code blocks, blockquotes, tables, HRs) in the summary view using the existing extmark pipeline.

**Architecture:** Extend `markdown.lua` with `parse_blocks(text, base_hl, opts)` — a multiline state machine that classifies lines into block types, renders each block (calling `parse_inline` for inline content), and returns `{ lines, highlights, code_blocks }`. Consumers in `detail.lua` replace their per-line `parse_inline` loops with a single `parse_blocks` call.

**Tech Stack:** Lua, Neovim API (extmarks), busted (tests). Run tests: `busted --run unit tests/codereview/ui/markdown_spec.lua`

**Design doc:** `docs/plans/2026-02-24-block-markdown-rendering-design.md`

---

### Task 1: Add block-level highlight groups

**Files:**
- Modify: `lua/codereview/ui/highlight.lua:3-55`
- Test: `tests/codereview/ui/markdown_spec.lua`

**TEST:** Add test verifying new hl groups exist after setup:

```lua
describe("block-level highlight groups", function()
  it("defines all markdown block highlight groups", function()
    local hl = require("codereview.ui.highlight")
    hl.setup()
    local groups = {
      "CodeReviewMdH1", "CodeReviewMdH2", "CodeReviewMdH3",
      "CodeReviewMdH4", "CodeReviewMdH5", "CodeReviewMdH6",
      "CodeReviewMdCodeBlock", "CodeReviewMdBlockquote",
      "CodeReviewMdBlockquoteBorder", "CodeReviewMdTableHeader",
      "CodeReviewMdTableBorder", "CodeReviewMdHr", "CodeReviewMdListBullet",
    }
    for _, name in ipairs(groups) do
      local def = vim.api.nvim_get_hl(0, { name = name })
      assert.is_table(def, "missing hl group: " .. name)
    end
  end)
end)
```

**IMPL:** Add to `highlight.lua` setup() before the sign_define calls:

```lua
  -- Block-level markdown
  vim.api.nvim_set_hl(0, "CodeReviewMdH1", { fg = "#c8d3f5", bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewMdH2", { fg = "#c8d3f5", bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewMdH3", { fg = "#a9b1d6", bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewMdH4", { fg = "#a9b1d6", bold = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewMdH5", { fg = "#828bb8", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewMdH6", { fg = "#828bb8", italic = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewMdCodeBlock", { bg = "#1a1b26", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewMdBlockquote", { bg = "#2a2a3a", fg = "#828bb8", italic = true, default = true })
  vim.api.nvim_set_hl(0, "CodeReviewMdBlockquoteBorder", { fg = "#565f89", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewMdTableHeader", { bold = true, bg = "#1e2030", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewMdTableBorder", { fg = "#565f89", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewMdHr", { fg = "#565f89", default = true })
  vim.api.nvim_set_hl(0, "CodeReviewMdListBullet", { fg = "#7aa2f7", default = true })
```

**VERIFY:** `busted --run unit tests/codereview/ui/markdown_spec.lua`

**COMMIT:** `feat(markdown): add block-level highlight groups`

---

### Task 2: parse_blocks skeleton + paragraph passthrough

**Files:**
- Modify: `lua/codereview/ui/markdown.lua`
- Test: `tests/codereview/ui/markdown_spec.lua`

**TEST:** Add `parse_blocks` tests:

```lua
describe("parse_blocks", function()
  it("returns struct with lines, highlights, code_blocks", function()
    local result = markdown.parse_blocks("hello world", "CodeReviewComment", {})
    assert.is_table(result.lines)
    assert.is_table(result.highlights)
    assert.is_table(result.code_blocks)
  end)

  it("passes plain text through with inline markdown", function()
    local result = markdown.parse_blocks("a **bold** line", "CodeReviewComment", {})
    assert.equals(1, #result.lines)
    assert.equals("a bold line", result.lines[1])
    assert.truthy(#result.highlights > 0)
    assert.equals("CodeReviewCommentBold", result.highlights[1][4])
  end)

  it("handles multiline paragraphs", function()
    local result = markdown.parse_blocks("line one\nline two", "CodeReviewComment", {})
    assert.equals(2, #result.lines)
    assert.equals("line one", result.lines[1])
    assert.equals("line two", result.lines[2])
  end)

  it("handles nil/empty input", function()
    local r1 = markdown.parse_blocks(nil, "CodeReviewComment", {})
    assert.same({}, r1.lines)
    local r2 = markdown.parse_blocks("", "CodeReviewComment", {})
    assert.same({}, r2.lines)
  end)

  it("preserves blank lines between paragraphs", function()
    local result = markdown.parse_blocks("para one\n\npara two", "CodeReviewComment", {})
    assert.equals(3, #result.lines)
    assert.equals("", result.lines[2])
  end)
end)
```

**IMPL:** Add `parse_blocks` to `markdown.lua`. State machine skeleton that classifies each line. In this task, only implement the `paragraph` branch — all unrecognized lines go through `parse_inline` + `segments_to_extmarks`:

```lua
function M.parse_blocks(text, base_hl, opts)
  opts = opts or {}
  local result = { lines = {}, highlights = {}, code_blocks = {} }
  if not text or text == "" then return result end

  local raw_lines = M.to_lines(text)
  local i = 1
  local state = "normal"

  while i <= #raw_lines do
    local line = raw_lines[i]

    if state == "normal" then
      -- TODO: header, code fence, blockquote, list, table, hr detection here
      -- Default: paragraph line -> parse_inline
      local row = #result.lines
      local segs = M.parse_inline(line, base_hl)
      local stripped, hls = M.segments_to_extmarks(segs, row, base_hl)
      table.insert(result.lines, stripped)
      for _, h in ipairs(hls) do table.insert(result.highlights, h) end
    end

    i = i + 1
  end

  return result
end
```

**VERIFY:** `busted --run unit tests/codereview/ui/markdown_spec.lua`

**COMMIT:** `feat(markdown): add parse_blocks skeleton with paragraph passthrough`

---

### Task 3: Headers

**Files:**
- Modify: `lua/codereview/ui/markdown.lua`
- Test: `tests/codereview/ui/markdown_spec.lua`

**TEST:**

```lua
describe("parse_blocks headers", function()
  it("renders H1", function()
    local r = markdown.parse_blocks("# Title", "CodeReviewComment", {})
    assert.equals(1, #r.lines)
    assert.equals("Title", r.lines[1])
    assert.equals("CodeReviewMdH1", r.highlights[1][4])
  end)

  it("renders H3", function()
    local r = markdown.parse_blocks("### Sub", "CodeReviewComment", {})
    assert.equals("Sub", r.lines[1])
    assert.equals("CodeReviewMdH3", r.highlights[1][4])
  end)

  it("renders header with inline markdown", function()
    local r = markdown.parse_blocks("## **Bold** title", "CodeReviewComment", {})
    assert.equals("Bold title", r.lines[1])
    -- Should have both H2 full-line hl and Bold hl
  end)

  it("does not treat # inside text as header", function()
    local r = markdown.parse_blocks("issue #42 is fixed", "CodeReviewComment", {})
    assert.equals("issue #42 is fixed", r.lines[1])
  end)
end)
```

**IMPL:** In the `state == "normal"` branch, before the paragraph fallback, add header detection:

```lua
local h_prefix, h_content = line:match("^(#{1,6}) (.+)")
if h_prefix then
  local level = #h_prefix
  local hl_group = "CodeReviewMdH" .. level
  local row = #result.lines
  local segs = M.parse_inline(h_content, base_hl)
  local stripped, hls = M.segments_to_extmarks(segs, row, base_hl)
  table.insert(result.lines, stripped)
  -- Full-line header highlight
  table.insert(result.highlights, { row, 0, #stripped, hl_group })
  -- Overlay inline highlights
  for _, h in ipairs(hls) do table.insert(result.highlights, h) end
  i = i + 1
  goto continue
end
```

Use `goto continue` pattern with `::continue::` at end of while loop to skip the paragraph fallback.

**VERIFY:** `busted --run unit tests/codereview/ui/markdown_spec.lua`

**COMMIT:** `feat(markdown): render headers in parse_blocks`

---

### Task 4: Horizontal rules

**Files:**
- Modify: `lua/codereview/ui/markdown.lua`
- Test: `tests/codereview/ui/markdown_spec.lua`

**TEST:**

```lua
describe("parse_blocks horizontal rules", function()
  it("renders --- as full-width rule", function()
    local r = markdown.parse_blocks("---", "CodeReviewComment", { width = 40 })
    assert.equals(1, #r.lines)
    assert.equals(string.rep("─", 40), r.lines[1])
    assert.equals("CodeReviewMdHr", r.highlights[1][4])
  end)

  it("renders *** as rule", function()
    local r = markdown.parse_blocks("***", "CodeReviewComment", { width = 20 })
    assert.equals(string.rep("─", 20), r.lines[1])
  end)

  it("renders ___ as rule", function()
    local r = markdown.parse_blocks("___", "CodeReviewComment", { width = 20 })
    assert.equals(string.rep("─", 20), r.lines[1])
  end)

  it("defaults width to 70", function()
    local r = markdown.parse_blocks("---", "CodeReviewComment", {})
    assert.equals(string.rep("─", 70), r.lines[1])
  end)
end)
```

**IMPL:** Add HR detection before paragraph fallback:

```lua
if line:match("^%-%-%-$") or line:match("^%*%*%*$") or line:match("^___$") then
  local width = opts.width or 70
  local row = #result.lines
  local rule = string.rep("─", width)
  table.insert(result.lines, rule)
  table.insert(result.highlights, { row, 0, #rule, "CodeReviewMdHr" })
  i = i + 1
  goto continue
end
```

**VERIFY:** `busted --run unit tests/codereview/ui/markdown_spec.lua`

**COMMIT:** `feat(markdown): render horizontal rules in parse_blocks`

---

### Task 5: Fenced code blocks

**Files:**
- Modify: `lua/codereview/ui/markdown.lua`
- Test: `tests/codereview/ui/markdown_spec.lua`

**TEST:**

```lua
describe("parse_blocks code blocks", function()
  it("renders fenced code block with background", function()
    local r = markdown.parse_blocks("```lua\nlocal x = 1\n```", "CodeReviewComment", {})
    assert.equals(1, #r.lines)
    assert.equals("  local x = 1", r.lines[1])  -- 2-space indent
    -- Background highlight on code line
    local found_cb = false
    for _, h in ipairs(r.highlights) do
      if h[4] == "CodeReviewMdCodeBlock" then found_cb = true end
    end
    assert.is_true(found_cb)
  end)

  it("captures language in code_blocks", function()
    local r = markdown.parse_blocks("```python\nprint('hi')\n```", "CodeReviewComment", {})
    assert.equals(1, #r.code_blocks)
    assert.equals("python", r.code_blocks[1].lang)
    assert.equals("print('hi')", r.code_blocks[1].text)
  end)

  it("handles multi-line code block", function()
    local r = markdown.parse_blocks("```\na\nb\nc\n```", "CodeReviewComment", {})
    assert.equals(3, #r.lines)
    assert.equals("  a", r.lines[1])
    assert.equals("  b", r.lines[2])
    assert.equals("  c", r.lines[3])
  end)

  it("handles unclosed code fence", function()
    local r = markdown.parse_blocks("```lua\nlocal x = 1", "CodeReviewComment", {})
    assert.equals(1, #r.lines)
    assert.equals("  local x = 1", r.lines[1])
  end)

  it("does not parse inline markdown inside code blocks", function()
    local r = markdown.parse_blocks("```\n**not bold**\n```", "CodeReviewComment", {})
    assert.equals("  **not bold**", r.lines[1])
    -- Should NOT have a Bold highlight
    for _, h in ipairs(r.highlights) do
      assert.is_not.equals("CodeReviewCommentBold", h[4])
    end
  end)
end)
```

**IMPL:** Add code fence detection + `in_code_block` state:

```lua
-- Code fence open
local fence_lang = line:match("^```(.*)")
if fence_lang and state == "normal" then
  state = "in_code_block"
  code_lang = fence_lang ~= "" and fence_lang or nil
  code_lines = {}
  i = i + 1
  goto continue
end

-- In code_block state (before the normal state branch)
if state == "in_code_block" then
  if line:match("^```$") then
    -- Emit collected code lines
    local code_text = table.concat(code_lines, "\n")
    local code_start_row = #result.lines
    for _, cl in ipairs(code_lines) do
      local row = #result.lines
      local padded = "  " .. cl
      table.insert(result.lines, padded)
      table.insert(result.highlights, { row, 0, #padded, "CodeReviewMdCodeBlock" })
    end
    if #code_lines > 0 then
      table.insert(result.code_blocks, {
        start_row = code_start_row,
        end_row = code_start_row + #code_lines - 1,
        lang = code_lang,
        text = code_text,
        indent = 2,
      })
    end
    state = "normal"
    code_lang = nil
    code_lines = nil
  else
    table.insert(code_lines, line)
  end
  i = i + 1
  goto continue
end
```

Add variables `code_lang`, `code_lines` at top of function (local, nil initially).

Handle unclosed fence: after the while loop, if `state == "in_code_block"`, flush remaining `code_lines` the same way.

**VERIFY:** `busted --run unit tests/codereview/ui/markdown_spec.lua`

**COMMIT:** `feat(markdown): render fenced code blocks in parse_blocks`

---

### Task 6: Unordered lists

**Files:**
- Modify: `lua/codereview/ui/markdown.lua`
- Test: `tests/codereview/ui/markdown_spec.lua`

**TEST:**

```lua
describe("parse_blocks unordered lists", function()
  it("renders bullet list items", function()
    local r = markdown.parse_blocks("- item one\n- item two", "CodeReviewComment", {})
    assert.equals(2, #r.lines)
    assert.equals("• item one", r.lines[1])
    assert.equals("• item two", r.lines[2])
  end)

  it("applies bullet highlight", function()
    local r = markdown.parse_blocks("- test", "CodeReviewComment", {})
    local found = false
    for _, h in ipairs(r.highlights) do
      if h[4] == "CodeReviewMdListBullet" then found = true end
    end
    assert.is_true(found)
  end)

  it("handles * and + markers", function()
    local r = markdown.parse_blocks("* star\n+ plus", "CodeReviewComment", {})
    assert.truthy(r.lines[1]:find("•"))
    assert.truthy(r.lines[2]:find("•"))
  end)

  it("parses inline markdown in list items", function()
    local r = markdown.parse_blocks("- **bold** item", "CodeReviewComment", {})
    assert.equals("• bold item", r.lines[1])
    local has_bold = false
    for _, h in ipairs(r.highlights) do
      if h[4] == "CodeReviewCommentBold" then has_bold = true end
    end
    assert.is_true(has_bold)
  end)

  it("renders nested list items", function()
    local r = markdown.parse_blocks("- top\n  - nested\n    - deep", "CodeReviewComment", {})
    assert.equals(3, #r.lines)
    assert.equals("• top", r.lines[1])
    assert.equals("  ◦ nested", r.lines[2])
    assert.equals("    ▪ deep", r.lines[3])
  end)
end)
```

**IMPL:** Add list detection before paragraph fallback. Detect indent level and marker:

```lua
local list_indent, list_marker, list_content = line:match("^(%s*)([-*+]) (.+)")
if list_content then
  local indent_level = math.floor(#list_indent / 2)
  local bullets = { "•", "◦", "▪" }
  local bullet = bullets[math.min(indent_level + 1, #bullets)]
  local prefix = string.rep("  ", indent_level) .. bullet .. " "
  local row = #result.lines
  local segs = M.parse_inline(list_content, base_hl)
  local stripped, hls = M.segments_to_extmarks(segs, row, base_hl)
  table.insert(result.lines, prefix .. stripped)
  -- Bullet highlight
  local bullet_start = #string.rep("  ", indent_level)
  -- bullet char is multi-byte (3 bytes for •/◦/▪)
  local bullet_end = bullet_start + #bullet
  table.insert(result.highlights, { row, bullet_start, bullet_end, "CodeReviewMdListBullet" })
  -- Shift inline highlights by prefix length
  local offset = #prefix
  for _, h in ipairs(hls) do
    table.insert(result.highlights, { h[1], h[2] + offset, h[3] + offset, h[4] })
  end
  i = i + 1
  goto continue
end
```

**VERIFY:** `busted --run unit tests/codereview/ui/markdown_spec.lua`

**COMMIT:** `feat(markdown): render unordered lists in parse_blocks`

---

### Task 7: Ordered lists

**Files:**
- Modify: `lua/codereview/ui/markdown.lua`
- Test: `tests/codereview/ui/markdown_spec.lua`

**TEST:**

```lua
describe("parse_blocks ordered lists", function()
  it("renders numbered list items", function()
    local r = markdown.parse_blocks("1. first\n2. second\n3. third", "CodeReviewComment", {})
    assert.equals(3, #r.lines)
    assert.equals("1. first", r.lines[1])
    assert.equals("2. second", r.lines[2])
    assert.equals("3. third", r.lines[3])
  end)

  it("parses inline markdown in ordered list items", function()
    local r = markdown.parse_blocks("1. **bold** item", "CodeReviewComment", {})
    assert.equals("1. bold item", r.lines[1])
  end)

  it("handles nested ordered lists", function()
    local r = markdown.parse_blocks("1. top\n   1. nested", "CodeReviewComment", {})
    assert.equals(2, #r.lines)
    assert.equals("1. top", r.lines[1])
    assert.equals("   1. nested", r.lines[2])
  end)
end)
```

**IMPL:** Add ordered list detection after unordered list detection:

```lua
local ol_indent, ol_num, ol_content = line:match("^(%s*)(%d+)%. (.+)")
if ol_content then
  local prefix = ol_indent .. ol_num .. ". "
  local row = #result.lines
  local segs = M.parse_inline(ol_content, base_hl)
  local stripped, hls = M.segments_to_extmarks(segs, row, base_hl)
  table.insert(result.lines, prefix .. stripped)
  local offset = #prefix
  for _, h in ipairs(hls) do
    table.insert(result.highlights, { h[1], h[2] + offset, h[3] + offset, h[4] })
  end
  i = i + 1
  goto continue
end
```

**VERIFY:** `busted --run unit tests/codereview/ui/markdown_spec.lua`

**COMMIT:** `feat(markdown): render ordered lists in parse_blocks`

---

### Task 8: Blockquotes

**Files:**
- Modify: `lua/codereview/ui/markdown.lua`
- Test: `tests/codereview/ui/markdown_spec.lua`

**TEST:**

```lua
describe("parse_blocks blockquotes", function()
  it("renders single-line blockquote", function()
    local r = markdown.parse_blocks("> quoted text", "CodeReviewComment", {})
    assert.equals(1, #r.lines)
    assert.equals("  quoted text", r.lines[1])
    -- Should have blockquote highlight
    local found_bq = false
    for _, h in ipairs(r.highlights) do
      if h[4] == "CodeReviewMdBlockquote" then found_bq = true end
    end
    assert.is_true(found_bq)
  end)

  it("renders multi-line blockquote", function()
    local r = markdown.parse_blocks("> line one\n> line two", "CodeReviewComment", {})
    assert.equals(2, #r.lines)
    assert.equals("  line one", r.lines[1])
    assert.equals("  line two", r.lines[2])
  end)

  it("renders nested blockquote", function()
    local r = markdown.parse_blocks("> > nested", "CodeReviewComment", {})
    assert.equals(1, #r.lines)
    assert.equals("    nested", r.lines[1])
  end)

  it("renders blockquote with inline markdown", function()
    local r = markdown.parse_blocks("> **bold** text", "CodeReviewComment", {})
    assert.equals("  bold text", r.lines[1])
  end)

  it("renders blockquote containing code block", function()
    local r = markdown.parse_blocks("> ```lua\n> local x = 1\n> ```", "CodeReviewComment", {})
    assert.truthy(#r.lines > 0)
    -- Code line should have code block highlight
    local found_cb = false
    for _, h in ipairs(r.highlights) do
      if h[4] == "CodeReviewMdCodeBlock" then found_cb = true end
    end
    assert.is_true(found_cb)
  end)
end)
```

**IMPL:** Collect consecutive `> ` lines, strip the `> ` prefix, recursively call `parse_blocks` on inner content. Then offset all returned rows/highlights by the blockquote indent and add blockquote highlight:

```lua
if line:match("^> ") or line == ">" then
  -- Collect all consecutive blockquote lines
  local bq_lines = {}
  while i <= #raw_lines and (raw_lines[i]:match("^> ") or raw_lines[i] == ">") do
    local inner = raw_lines[i]:match("^> ?(.*)") or ""
    table.insert(bq_lines, inner)
    i = i + 1
  end
  local inner_text = table.concat(bq_lines, "\n")
  local inner_result = M.parse_blocks(inner_text, base_hl, opts)
  local bq_indent = "  "
  local start_row = #result.lines
  for ri, rl in ipairs(inner_result.lines) do
    local row = #result.lines
    local padded = bq_indent .. rl
    table.insert(result.lines, padded)
    table.insert(result.highlights, { row, 0, #padded, "CodeReviewMdBlockquote" })
  end
  -- Offset inner highlights
  local offset = #bq_indent
  for _, h in ipairs(inner_result.highlights) do
    table.insert(result.highlights, { start_row + h[1], h[2] + offset, h[3] + offset, h[4] })
  end
  -- Offset inner code_blocks
  for _, cb in ipairs(inner_result.code_blocks) do
    table.insert(result.code_blocks, {
      start_row = start_row + cb.start_row,
      end_row = start_row + cb.end_row,
      lang = cb.lang,
      text = cb.text,
      indent = cb.indent + offset,
    })
  end
  goto continue
end
```

Note: no `i = i + 1` at end because the while loop already advanced `i`.

**VERIFY:** `busted --run unit tests/codereview/ui/markdown_spec.lua`

**COMMIT:** `feat(markdown): render blockquotes in parse_blocks`

---

### Task 9: Tables (basic rendering)

**Files:**
- Modify: `lua/codereview/ui/markdown.lua`
- Test: `tests/codereview/ui/markdown_spec.lua`

**TEST:**

```lua
describe("parse_blocks tables", function()
  it("renders basic pipe table with box-drawing", function()
    local text = "| Name | Age |\n| --- | --- |\n| Alice | 30 |"
    local r = markdown.parse_blocks(text, "CodeReviewComment", {})
    -- Should have: top border, header row, separator, data row, bottom border
    assert.truthy(#r.lines >= 5)
    -- Top border uses box-drawing
    assert.truthy(r.lines[1]:find("┌"))
    assert.truthy(r.lines[1]:find("┬"))
    -- Header row uses │
    assert.truthy(r.lines[2]:find("│"))
    assert.truthy(r.lines[2]:find("Name"))
    -- Separator
    assert.truthy(r.lines[3]:find("├"))
    -- Data row
    assert.truthy(r.lines[4]:find("Alice"))
    -- Bottom border
    assert.truthy(r.lines[5]:find("└"))
  end)

  it("renders table header with bold highlight", function()
    local text = "| Col |\n| --- |\n| val |"
    local r = markdown.parse_blocks(text, "CodeReviewComment", {})
    local found_th = false
    for _, h in ipairs(r.highlights) do
      if h[4] == "CodeReviewMdTableHeader" then found_th = true end
    end
    assert.is_true(found_th)
  end)

  it("handles empty table", function()
    local text = "| |\n| --- |"
    local r = markdown.parse_blocks(text, "CodeReviewComment", {})
    assert.truthy(#r.lines > 0)
  end)

  it("pads short rows with empty cells", function()
    local text = "| A | B | C |\n| --- | --- | --- |\n| 1 |"
    local r = markdown.parse_blocks(text, "CodeReviewComment", {})
    -- Data row should have 3 cells even though source only has 1
    local data_line = r.lines[4]
    local pipe_count = 0
    for _ in data_line:gmatch("│") do pipe_count = pipe_count + 1 end
    assert.equals(4, pipe_count)  -- start + 2 separators + end
  end)
end)
```

**IMPL:** Add table detection. Collect consecutive pipe-table lines. Parse into cells. Calculate column widths. Render with box-drawing characters.

Key helper: `parse_table_row(line)` splits by `|`, trims cells. `render_table(header_cells, alignments, data_rows, base_hl, start_row)` builds the box-drawing output.

Table detection: a line matching `^|.*|$` followed by a separator line matching `^|[-: ]+|$`.

```lua
-- Table detection (look ahead for separator line)
if line:match("^|.+|%s*$") and i + 1 <= #raw_lines and raw_lines[i + 1]:match("^|[-:| ]+|%s*$") then
  -- Collect all table lines
  local tbl_lines = {}
  while i <= #raw_lines and raw_lines[i]:match("^|.+|%s*$") do
    table.insert(tbl_lines, raw_lines[i])
    i = i + 1
  end
  -- Parse and render table (helper function)
  local tbl_result = render_table(tbl_lines, base_hl, #result.lines, opts)
  for _, l in ipairs(tbl_result.lines) do table.insert(result.lines, l) end
  for _, h in ipairs(tbl_result.highlights) do table.insert(result.highlights, h) end
  goto continue
end
```

The `render_table` helper (local function above `parse_blocks`):
1. Parse header row into cells
2. Parse separator row for alignments (`:---` left, `:---:` center, `---:` right)
3. Parse data rows into cells
4. Calculate max width per column
5. Build box-drawing lines: `┌─┬─┐` top, `│ cell │` rows, `├─┼─┤` separator, `└─┴─┘` bottom
6. Apply `CodeReviewMdTableHeader` to header row, `CodeReviewMdTableBorder` to borders

**VERIFY:** `busted --run unit tests/codereview/ui/markdown_spec.lua`

**COMMIT:** `feat(markdown): render basic tables in parse_blocks`

---

### Task 10: Table cell wrapping + alignment

**Files:**
- Modify: `lua/codereview/ui/markdown.lua`
- Test: `tests/codereview/ui/markdown_spec.lua`

**TEST:**

```lua
describe("parse_blocks table wrapping", function()
  it("wraps long cell text", function()
    local long = string.rep("word ", 20)  -- 100 chars
    local text = "| Header |\n| --- |\n| " .. long .. "|"
    local r = markdown.parse_blocks(text, "CodeReviewComment", { width = 40 })
    -- Should produce multiple buffer lines for the data row
    local data_lines = 0
    for _, l in ipairs(r.lines) do
      if l:find("word") then data_lines = data_lines + 1 end
    end
    assert.truthy(data_lines > 1)
  end)

  it("right-aligns cells per separator", function()
    local text = "| Num |\n| ---: |\n| 42 |"
    local r = markdown.parse_blocks(text, "CodeReviewComment", { width = 40 })
    -- "42" should be right-padded (spaces before the value)
    local data_line = nil
    for _, l in ipairs(r.lines) do
      if l:find("42") then data_line = l; break end
    end
    assert.truthy(data_line)
    -- Right align: spaces before 42
    local before_42 = data_line:match("│(.-)42")
    assert.truthy(before_42 and #before_42 > 1)
  end)

  it("center-aligns cells per separator", function()
    local text = "| Col |\n| :---: |\n| hi |"
    local r = markdown.parse_blocks(text, "CodeReviewComment", { width = 40 })
    local data_line = nil
    for _, l in ipairs(r.lines) do
      if l:find("hi") then data_line = l; break end
    end
    assert.truthy(data_line)
  end)
end)
```

**IMPL:** Extend `render_table` helper:
1. Cap column widths: `max_col_width = math.max(5, math.floor((opts.width or 70) / num_cols) - 3)`. If a cell's text exceeds this, wrap it.
2. Cell wrapping: split cell text into lines of `max_col_width` using word-break. Each wrapped cell creates multiple buffer rows for that table row.
3. Alignment: when padding a cell value into its column width, use left-pad for right-align, equal pad for center-align, right-pad for left-align (default).

**VERIFY:** `busted --run unit tests/codereview/ui/markdown_spec.lua`

**COMMIT:** `feat(markdown): add table cell wrapping and alignment`

---

### Task 11: Integrate parse_blocks into detail.lua (description)

**Files:**
- Modify: `lua/codereview/mr/detail.lua:42-53`
- Test: `tests/codereview/mr/detail_spec.lua`

**TEST:** Update existing detail_spec tests to verify block-level rendering in descriptions:

```lua
it("renders markdown headers in description", function()
  local review = {
    id = 1, title = "Test", author = "me",
    source_branch = "feat", target_branch = "main",
    state = "opened", pipeline_status = "success",
    description = "## Summary\n\nThis fixes a bug",
    approved_by = {}, approvals_required = 0,
  }
  local result = detail.build_header_lines(review)
  local joined = table.concat(result.lines, "\n")
  assert.truthy(joined:find("Summary"))
  -- Should have H2 highlight
  local has_h2 = false
  for _, h in ipairs(result.highlights) do
    if h[4] == "CodeReviewMdH2" then has_h2 = true end
  end
  assert.is_true(has_h2)
end)

it("renders code blocks in description", function()
  local review = {
    id = 1, title = "Test", author = "me",
    source_branch = "feat", target_branch = "main",
    state = "opened", pipeline_status = "success",
    description = "```lua\nlocal x = 1\n```",
    approved_by = {}, approvals_required = 0,
  }
  local result = detail.build_header_lines(review)
  local joined = table.concat(result.lines, "\n")
  assert.truthy(joined:find("local x = 1"))
  local has_cb = false
  for _, h in ipairs(result.highlights) do
    if h[4] == "CodeReviewMdCodeBlock" then has_cb = true end
  end
  assert.is_true(has_cb)
end)
```

**IMPL:** In `build_header_lines`, replace lines 43-53 (the per-line `parse_inline` loop for description) with:

```lua
if review.description and review.description ~= "" then
  table.insert(lines, "")
  local desc_start = #lines  -- 0-indexed row offset
  local block_result = markdown.parse_blocks(review.description, "CodeReviewComment", { width = 70 })
  for _, bl in ipairs(block_result.lines) do
    table.insert(lines, bl)
  end
  -- Offset block highlights by desc_start
  for _, h in ipairs(block_result.highlights) do
    table.insert(highlights, { desc_start + h[1], h[2], h[3], h[4] })
  end
end
```

Also store `code_blocks` in the return struct: `return { lines = lines, highlights = highlights, code_blocks = block_result and block_result.code_blocks or {} }`.

**VERIFY:** `busted --run unit tests/codereview/mr/detail_spec.lua`

**COMMIT:** `refactor(detail): use parse_blocks for description rendering`

---

### Task 12: Integrate parse_blocks into detail.lua (activity bodies)

**Files:**
- Modify: `lua/codereview/mr/detail.lua:170-177` and `201-208`
- Test: `tests/codereview/mr/detail_spec.lua`

**TEST:** Add test for block-level markdown in comment bodies:

```lua
it("renders code blocks in comment body", function()
  local discussions = {
    {
      id = "cb",
      notes = {
        {
          id = 1,
          body = "```lua\nlocal x = 1\n```",
          author = "jan",
          created_at = "2026-02-20T10:00:00Z",
          system = false,
        },
      },
    },
  }
  local result = detail.build_activity_lines(discussions)
  local joined = table.concat(result.lines, "\n")
  assert.truthy(joined:find("local x = 1"))
  local has_cb = false
  for _, h in ipairs(result.highlights) do
    if h[4] == "CodeReviewMdCodeBlock" then has_cb = true end
  end
  assert.is_true(has_cb)
end)
```

**IMPL:** Replace the two per-line `parse_inline` loops in `build_activity_lines`:

First note body (lines 170-177): replace with:
```lua
local body_start = #lines
local body_result = markdown.parse_blocks(first_note.body or "", "CodeReviewComment", { width = 60 })
for _, bl in ipairs(body_result.lines) do
  local row = #lines
  table.insert(lines, bl)
  row_map[row] = { type = "thread", discussion = disc }
end
for _, h in ipairs(body_result.highlights) do
  table.insert(highlights, { body_start + h[1], h[2], h[3], h[4] })
end
```

Reply body (lines 201-208): same pattern.

Store code_blocks from activity on result: `result.code_blocks = result.code_blocks or {}`. Merge block_result.code_blocks with row offsets.

**VERIFY:** `busted --run unit tests/codereview/mr/detail_spec.lua`

**COMMIT:** `refactor(detail): use parse_blocks for activity body rendering`

---

### Task 13: Treesitter code block highlighting in diff.lua

**Files:**
- Modify: `lua/codereview/mr/diff.lua:899-955`
- Test: manual testing (treesitter not available in unit test env)

**IMPL:** After the extmark application loop in `render_summary`, add code block treesitter highlighting:

```lua
-- Apply treesitter syntax highlighting to code blocks
local all_code_blocks = {}
-- Collect from header
if header.code_blocks then
  for _, cb in ipairs(header.code_blocks) do
    table.insert(all_code_blocks, cb)
  end
end
-- Collect from activity (offset by header_count)
if activity.code_blocks then
  for _, cb in ipairs(activity.code_blocks) do
    table.insert(all_code_blocks, {
      start_row = header_count + cb.start_row,
      end_row = header_count + cb.end_row,
      lang = cb.lang,
      text = cb.text,
      indent = cb.indent,
    })
  end
end

for _, cb in ipairs(all_code_blocks) do
  if cb.lang then
    local ok, parser = pcall(vim.treesitter.get_string_parser, cb.text, cb.lang)
    if ok and parser then
      local tree = parser:parse()[1]
      if tree then
        local root = tree:root()
        local query_ok, query = pcall(vim.treesitter.query.get, cb.lang, "highlights")
        if query_ok and query then
          for id, node, _ in query:iter_captures(root, cb.text, 0, -1) do
            local name = query.captures[id]
            local sr, sc, er, ec = node:range()
            -- Map to buffer coordinates (add row offset + indent offset)
            pcall(vim.api.nvim_buf_set_extmark, buf, SUMMARY_NS,
              cb.start_row + sr, sc + cb.indent,
              { end_row = cb.start_row + er, end_col = ec + cb.indent, hl_group = "@" .. name })
          end
        end
      end
    end
  end
end
```

**VERIFY:** Manual test by opening a real MR with code blocks in the description. Treesitter parsers must be installed for the target language.

**COMMIT:** `feat(diff): apply treesitter highlighting to code blocks in summary`

---

### Task 14: Fix existing tests

**Files:**
- Modify: `tests/codereview/mr/detail_spec.lua`
- Modify: `tests/codereview/ui/markdown_spec.lua`

**IMPL:** Some existing tests may break due to the new block-level rendering (e.g., description lines now go through `parse_blocks` which may add spacing). Run full test suite, fix any assertions that changed:

```
busted --run unit
```

Common fixes:
- `build_header_lines` now returns `code_blocks` field — update assertions that check exact struct shape
- Description text may have different line counts if headers/blocks are detected
- The `to_lines` tests in markdown_spec shouldn't change (they test raw splitting, not rendering)

**VERIFY:** `busted --run unit` — all tests pass

**COMMIT:** `test: update tests for block-level markdown rendering`

---

## Unresolved questions

None — design was approved in brainstorming.
