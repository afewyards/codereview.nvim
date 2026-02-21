# Stage 2: MR Browsing — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Browse and view MRs from Neovim — pick an MR from a fuzzy finder, see its details, description, activity feed, and general discussion threads with rendered markdown.

**Architecture:** Picker adapter pattern (Telescope/fzf-lua/snacks). MR data fetched via Stage 1 API client. Detail view in floating windows. Markdown rendered via treesitter injections in scratch buffers.

**Tech Stack:** Lua, Neovim API, plenary.nvim, telescope.nvim/fzf-lua/snacks.nvim (optional)

**Depends on:** Stage 1 (API client, auth, config, endpoints, git detection)

---

### Task 1: MR List Fetching

**Files:**
- Create: `lua/glab_review/mr/list.lua`
- Create: `tests/glab_review/mr/list_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/mr/list_spec.lua
local list = require("glab_review.mr.list")

describe("mr.list", function()
  describe("format_mr_entry", function()
    it("formats MR for picker display", function()
      local mr = {
        iid = 42,
        title = "Fix auth",
        author = { username = "maria" },
        source_branch = "fix/auth",
        head_pipeline = { status = "success" },
        upvotes = 1,
        approvals_required = 2,
      }
      local entry = list.format_mr_entry(mr)
      assert.truthy(entry.display:find("!42"))
      assert.truthy(entry.display:find("Fix auth"))
      assert.truthy(entry.display:find("maria"))
      assert.equals(42, entry.iid)
    end)

    it("handles MR without pipeline", function()
      local mr = {
        iid = 10,
        title = "Draft: WIP",
        author = { username = "jan" },
        source_branch = "wip",
        head_pipeline = nil,
      }
      local entry = list.format_mr_entry(mr)
      assert.truthy(entry.display:find("!10"))
    end)
  end)

  describe("pipeline_icon", function()
    it("returns check for success", function()
      assert.equals("[ok]", list.pipeline_icon("success"))
    end)
    it("returns x for failed", function()
      assert.equals("[fail]", list.pipeline_icon("failed"))
    end)
    it("returns ... for running", function()
      assert.equals("[..]", list.pipeline_icon("running"))
    end)
    it("returns ? for nil", function()
      assert.equals("[--]", list.pipeline_icon(nil))
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement MR list module**

```lua
-- lua/glab_review/mr/list.lua
local client = require("glab_review.api.client")
local endpoints = require("glab_review.api.endpoints")
local git = require("glab_review.git")
local M = {}

local PIPELINE_ICONS = {
  success = "[ok]",
  failed = "[fail]",
  running = "[..]",
  pending = "[..]",
  canceled = "[--]",
  skipped = "[--]",
  manual = "[||]",
  created = "[..]",
}

function M.pipeline_icon(status)
  if not status then return "[--]" end
  return PIPELINE_ICONS[status] or "[??]"
end

function M.format_mr_entry(mr)
  local pipeline_status = mr.head_pipeline and mr.head_pipeline.status or nil
  local icon = M.pipeline_icon(pipeline_status)
  local display = string.format(
    "%s !%-4d %-50s @%-15s %s",
    icon,
    mr.iid,
    mr.title:sub(1, 50),
    mr.author.username,
    mr.source_branch
  )

  return {
    display = display,
    iid = mr.iid,
    title = mr.title,
    author = mr.author.username,
    source_branch = mr.source_branch,
    target_branch = mr.target_branch,
    web_url = mr.web_url,
    mr = mr,
  }
end

function M.fetch(opts, callback)
  opts = opts or {}
  local base_url, project = git.detect_project()
  if not base_url or not project then
    callback(nil, "Could not detect GitLab project")
    return
  end

  local encoded = client.encode_project(project)
  local query = {
    state = opts.state or "opened",
    scope = opts.scope or "all",
    per_page = opts.per_page or 50,
  }

  -- Use plenary async for non-blocking
  local result, err = client.get(base_url, endpoints.mr_list(encoded), { query = query })
  if not result then
    callback(nil, err)
    return
  end

  local entries = {}
  for _, mr in ipairs(result.data) do
    table.insert(entries, M.format_mr_entry(mr))
  end

  callback(entries)
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/mr/list.lua tests/glab_review/mr/list_spec.lua
git commit -m "feat: add MR list fetching with display formatting"
```

---

### Task 2: Picker Adapter Interface

**Files:**
- Create: `lua/glab_review/picker/init.lua`
- Create: `tests/glab_review/picker/init_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/picker/init_spec.lua
local picker = require("glab_review.picker")

describe("picker", function()
  describe("detect", function()
    it("returns nil when no picker is available", function()
      -- In test env, no pickers are loaded
      local name = picker.detect()
      -- Could be nil or could find one depending on test env
      assert.is_true(name == nil or type(name) == "string")
    end)
  end)

  describe("get_adapter", function()
    it("errors for unknown picker", function()
      assert.has_error(function()
        picker.get_adapter("nonexistent_picker")
      end)
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement picker dispatcher**

```lua
-- lua/glab_review/picker/init.lua
local config = require("glab_review.config")
local M = {}

local adapters = {
  telescope = "glab_review.picker.telescope",
  fzf = "glab_review.picker.fzf",
  snacks = "glab_review.picker.snacks",
}

function M.detect()
  local cfg = config.get()
  if cfg.picker and adapters[cfg.picker] then
    return cfg.picker
  end

  -- Auto-detect in priority order
  local ok
  ok, _ = pcall(require, "telescope")
  if ok then return "telescope" end

  ok, _ = pcall(require, "fzf-lua")
  if ok then return "fzf" end

  ok, _ = pcall(require, "snacks")
  if ok then return "snacks" end

  return nil
end

function M.get_adapter(name)
  local mod_path = adapters[name]
  if not mod_path then
    error("Unknown picker: " .. tostring(name) .. ". Use telescope, fzf, or snacks.")
  end
  return require(mod_path)
end

function M.pick_mr(entries, on_select)
  local name = M.detect()
  if not name then
    vim.notify("No picker found. Install telescope.nvim, fzf-lua, or snacks.nvim", vim.log.levels.ERROR)
    return
  end

  local adapter = M.get_adapter(name)
  adapter.pick_mr(entries, on_select)
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/picker/init.lua tests/glab_review/picker/init_spec.lua
git commit -m "feat: add picker adapter dispatcher with auto-detection"
```

---

### Task 3: Telescope Adapter

**Files:**
- Create: `lua/glab_review/picker/telescope.lua`

**Step 1: Implement Telescope adapter**

```lua
-- lua/glab_review/picker/telescope.lua
local M = {}

function M.pick_mr(entries, on_select)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = "GitLab Merge Requests",
      finder = finders.new_table({
        results = entries,
        entry_maker = function(entry)
          return {
            value = entry,
            display = entry.display,
            ordinal = entry.title .. " " .. entry.author .. " " .. tostring(entry.iid),
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection then
            on_select(selection.value)
          end
        end)
        return true
      end,
    })
    :find()
end

return M
```

**Step 2: Commit**

```bash
git add lua/glab_review/picker/telescope.lua
git commit -m "feat: add Telescope picker adapter"
```

---

### Task 4: fzf-lua Adapter

**Files:**
- Create: `lua/glab_review/picker/fzf.lua`

**Step 1: Implement fzf-lua adapter**

```lua
-- lua/glab_review/picker/fzf.lua
local M = {}

function M.pick_mr(entries, on_select)
  local fzf = require("fzf-lua")

  local display_to_entry = {}
  local display_list = {}
  for _, entry in ipairs(entries) do
    table.insert(display_list, entry.display)
    display_to_entry[entry.display] = entry
  end

  fzf.fzf_exec(display_list, {
    prompt = "GitLab MRs> ",
    actions = {
      ["default"] = function(selected)
        if selected and selected[1] then
          local entry = display_to_entry[selected[1]]
          if entry then
            on_select(entry)
          end
        end
      end,
    },
  })
end

return M
```

**Step 2: Commit**

```bash
git add lua/glab_review/picker/fzf.lua
git commit -m "feat: add fzf-lua picker adapter"
```

---

### Task 5: snacks.picker Adapter

**Files:**
- Create: `lua/glab_review/picker/snacks.lua`

**Step 1: Implement snacks adapter**

```lua
-- lua/glab_review/picker/snacks.lua
local M = {}

function M.pick_mr(entries, on_select)
  local snacks = require("snacks")

  local items = {}
  for _, entry in ipairs(entries) do
    table.insert(items, {
      text = entry.display,
      data = entry,
    })
  end

  snacks.picker({
    title = "GitLab Merge Requests",
    items = items,
    format = function(item)
      return item.text
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        on_select(item.data)
      end
    end,
  })
end

return M
```

**Step 2: Commit**

```bash
git add lua/glab_review/picker/snacks.lua
git commit -m "feat: add snacks.picker adapter"
```

---

### Task 6: Markdown Rendering

**Files:**
- Create: `lua/glab_review/ui/markdown.lua`
- Create: `tests/glab_review/ui/markdown_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/ui/markdown_spec.lua
local markdown = require("glab_review.ui.markdown")

describe("ui.markdown", function()
  it("renders plain text lines", function()
    local lines = markdown.to_lines("Hello world\nSecond line")
    assert.equals(2, #lines)
    assert.equals("Hello world", lines[1])
    assert.equals("Second line", lines[2])
  end)

  it("preserves code blocks", function()
    local text = "Before\n```lua\nlocal x = 1\n```\nAfter"
    local lines = markdown.to_lines(text)
    assert.equals(5, #lines)
    assert.equals("```lua", lines[2])
  end)

  it("converts bullet lists", function()
    local text = "- item one\n- item two"
    local lines = markdown.to_lines(text)
    assert.equals(2, #lines)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement markdown module**

The rendering strategy: write markdown content into a scratch buffer and set the buffer filetype to `markdown`, which lets treesitter handle syntax highlighting. We just need to split lines and track highlight regions for inline elements.

```lua
-- lua/glab_review/ui/markdown.lua
local M = {}

function M.to_lines(text)
  if not text then return {} end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  -- Remove trailing empty line from our split
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

function M.render_to_buf(buf, text, start_line)
  start_line = start_line or 0
  local lines = M.to_lines(text)
  vim.api.nvim_buf_set_lines(buf, start_line, start_line, false, lines)
  -- Set filetype for treesitter markdown highlighting
  vim.bo[buf].filetype = "markdown"
  return #lines
end

function M.set_buf_markdown(buf)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].syntax = "markdown"
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/ui/markdown.lua tests/glab_review/ui/markdown_spec.lua
git commit -m "feat: add markdown line splitting and buffer rendering"
```

---

### Task 7: MR Detail Floating Window

**Files:**
- Create: `lua/glab_review/mr/detail.lua`
- Create: `tests/glab_review/mr/detail_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/mr/detail_spec.lua
local detail = require("glab_review.mr.detail")

describe("mr.detail", function()
  describe("build_header_lines", function()
    it("builds header from MR data", function()
      local mr = {
        iid = 42,
        title = "Fix auth token refresh",
        author = { username = "maria" },
        source_branch = "fix/token-refresh",
        target_branch = "main",
        state = "opened",
        head_pipeline = { status = "success" },
        description = "Fixes the bug",
        web_url = "https://gitlab.com/group/project/-/merge_requests/42",
      }
      local lines = detail.build_header_lines(mr)
      assert.truthy(#lines > 0)
      -- Should contain title
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("!42"))
      assert.truthy(joined:find("Fix auth token refresh"))
      assert.truthy(joined:find("maria"))
    end)
  end)

  describe("build_activity_lines", function()
    it("formats general discussion threads", function()
      local discussions = {
        {
          id = "abc",
          individual_note = true,
          notes = {
            {
              id = 1,
              body = "Looks good!",
              author = { username = "jan" },
              created_at = "2026-02-20T10:00:00Z",
              system = false,
            },
          },
        },
      }
      local lines = detail.build_activity_lines(discussions)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("jan"))
      assert.truthy(joined:find("Looks good"))
    end)

    it("formats system notes as compact lines", function()
      local discussions = {
        {
          id = "def",
          individual_note = true,
          notes = {
            {
              id = 2,
              body = "approved this merge request",
              author = { username = "jan" },
              created_at = "2026-02-20T11:00:00Z",
              system = true,
            },
          },
        },
      }
      local lines = detail.build_activity_lines(discussions)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("jan"))
      assert.truthy(joined:find("approved"))
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement MR detail module**

```lua
-- lua/glab_review/mr/detail.lua
local client = require("glab_review.api.client")
local endpoints = require("glab_review.api.endpoints")
local git = require("glab_review.git")
local float = require("glab_review.ui.float")
local markdown = require("glab_review.ui.markdown")
local list_mod = require("glab_review.mr.list")
local M = {}

function M.format_time(iso_str)
  if not iso_str then return "" end
  -- Simple relative time from ISO 8601
  local y, mo, d, h, mi = iso_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+)")
  if not y then return iso_str end
  return string.format("%s-%s-%s %s:%s", y, mo, d, h, mi)
end

function M.build_header_lines(mr)
  local pipeline_icon = list_mod.pipeline_icon(mr.head_pipeline and mr.head_pipeline.status)
  local lines = {
    string.format("MR !%d: %s", mr.iid, mr.title),
    "",
    string.format("Author: @%s   Branch: %s -> %s", mr.author.username, mr.source_branch, mr.target_branch or "main"),
    string.format("Status: %s   Pipeline: %s", mr.state, pipeline_icon),
    string.rep("-", 70),
  }

  if mr.description and mr.description ~= "" then
    table.insert(lines, "")
    for _, line in ipairs(markdown.to_lines(mr.description)) do
      table.insert(lines, line)
    end
  end

  return lines
end

function M.build_activity_lines(discussions)
  local lines = {}

  if not discussions or #discussions == 0 then
    return lines
  end

  table.insert(lines, "")
  table.insert(lines, "-- Activity " .. string.rep("-", 58))
  table.insert(lines, "")

  for _, disc in ipairs(discussions) do
    local first_note = disc.notes and disc.notes[1]
    if not first_note then goto continue end

    -- Skip inline diff comments (they have position data)
    if first_note.position then goto continue end

    if first_note.system then
      -- System note: compact one-liner
      table.insert(lines, string.format(
        "  - @%s %s (%s)",
        first_note.author.username,
        first_note.body,
        M.format_time(first_note.created_at)
      ))
    else
      -- Discussion thread
      table.insert(lines, string.format(
        "  @%s (%s)",
        first_note.author.username,
        M.format_time(first_note.created_at)
      ))
      for _, body_line in ipairs(markdown.to_lines(first_note.body)) do
        table.insert(lines, "  " .. body_line)
      end

      -- Replies
      for i = 2, #disc.notes do
        local reply = disc.notes[i]
        if not reply.system then
          table.insert(lines, string.format(
            "    -> @%s: %s",
            reply.author.username,
            reply.body:gsub("\n", " "):sub(1, 80)
          ))
        end
      end

      table.insert(lines, "")
    end

    ::continue::
  end

  return lines
end

function M.count_discussions(discussions)
  local total = 0
  local unresolved = 0
  for _, disc in ipairs(discussions or {}) do
    if disc.notes and disc.notes[1] and not disc.notes[1].system then
      total = total + 1
      for _, note in ipairs(disc.notes) do
        if note.resolvable and not note.resolved then
          unresolved = unresolved + 1
          break
        end
      end
    end
  end
  return total, unresolved
end

function M.open(mr_entry)
  local base_url, project = git.detect_project()
  if not base_url or not project then
    vim.notify("Could not detect GitLab project", vim.log.levels.ERROR)
    return
  end

  local encoded = client.encode_project(project)

  -- Fetch full MR details
  local mr_result, err = client.get(base_url, endpoints.mr_detail(encoded, mr_entry.iid))
  if not mr_result then
    vim.notify("Failed to load MR: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return
  end
  local mr = mr_result.data

  -- Fetch discussions
  local discussions = client.paginate_all(base_url, endpoints.discussions(encoded, mr_entry.iid)) or {}

  -- Build content
  local lines = M.build_header_lines(mr)
  local activity_lines = M.build_activity_lines(discussions)
  for _, line in ipairs(activity_lines) do
    table.insert(lines, line)
  end

  -- Footer
  local total, unresolved = M.count_discussions(discussions)
  table.insert(lines, "")
  table.insert(lines, string.rep("-", 70))
  table.insert(lines, string.format(
    "  %d discussions (%d unresolved)",
    total, unresolved
  ))
  table.insert(lines, "")
  table.insert(lines, "  [d]iff  [c]omment  [a]pprove  [A]I review  [p]ipeline  [m]erge  [q]uit")

  -- Open floating window
  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(#lines, vim.o.lines - 6)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  markdown.set_buf_markdown(buf)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = string.format(" MR !%d ", mr.iid),
    title_pos = "center",
  })

  -- Store MR data on buffer for downstream commands
  vim.b[buf].glab_review_mr = mr
  vim.b[buf].glab_review_discussions = discussions

  -- Keymaps
  local map_opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, map_opts)
  vim.keymap.set("n", "d", function()
    vim.api.nvim_win_close(win, true)
    -- Stage 3: open diff view
    vim.notify("Diff view (Stage 3)", vim.log.levels.WARN)
  end, map_opts)
  vim.keymap.set("n", "p", function()
    -- Stage 4: open pipeline
    vim.notify("Pipeline view (Stage 4)", vim.log.levels.WARN)
  end, map_opts)
  vim.keymap.set("n", "A", function()
    -- Stage 5: AI review
    vim.notify("AI review (Stage 5)", vim.log.levels.WARN)
  end, map_opts)
  vim.keymap.set("n", "a", function()
    -- Stage 3: approve
    vim.notify("Approve (Stage 3)", vim.log.levels.WARN)
  end, map_opts)
  vim.keymap.set("n", "o", function()
    -- Open in browser
    if mr.web_url then
      vim.ui.open(mr.web_url)
    end
  end, map_opts)
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/mr/detail.lua tests/glab_review/mr/detail_spec.lua
git commit -m "feat: add MR detail floating window with activity feed"
```

---

### Task 8: Wire Up :GlabReview Command

**Files:**
- Modify: `lua/glab_review/init.lua`

**Step 1: Replace the open() stub**

Replace the `M.open` function in `lua/glab_review/init.lua`:

```lua
function M.open()
  local mr_list = require("glab_review.mr.list")
  local picker = require("glab_review.picker")
  local detail = require("glab_review.mr.detail")

  mr_list.fetch({}, function(entries, err)
    if err then
      vim.notify("Failed to load MRs: " .. err, vim.log.levels.ERROR)
      return
    end
    if not entries or #entries == 0 then
      vim.notify("No open merge requests found", vim.log.levels.INFO)
      return
    end

    vim.schedule(function()
      picker.pick_mr(entries, function(selected)
        detail.open(selected)
      end)
    end)
  end)
end
```

**Step 2: Manually test**

In a repo with GitLab remote and valid auth:
1. `:GlabReview` — should open picker with MR list
2. Select an MR — should open detail floating window
3. `q` — should close the window
4. `o` — should open MR in browser

**Step 3: Commit**

```bash
git add lua/glab_review/init.lua
git commit -m "feat: wire up :GlabReview with picker and detail view"
```

---

### Stage 2 Deliverable Checklist

- [ ] `:GlabReview` opens a picker (Telescope, fzf-lua, or snacks depending on what's installed)
- [ ] MR list shows title, author, branch, pipeline status
- [ ] Selecting an MR opens a floating detail window
- [ ] Detail window shows: title, author, branch, pipeline, description (markdown rendered)
- [ ] Activity feed shows general discussion threads with replies
- [ ] System notes (approvals, labels, etc.) shown as compact one-liners
- [ ] `q` closes, `o` opens in browser
- [ ] Stub keymaps for `d`, `p`, `A`, `a` ready for later stages
