# Stage 4: Pipeline — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** View pipeline status, jobs grouped by stage, and job logs from within Neovim.

**Architecture:** Floating window for pipeline overview. Job logs in a scrollable scratch buffer. ANSI escape codes stripped from job output.

**Tech Stack:** Lua, Neovim API, plenary.nvim

**Depends on:** Stage 1 (API client, endpoints), Stage 2 (float helpers)

---

### Task 1: ANSI Stripping Utility

**Files:**
- Create: `lua/glab_review/ui/ansi.lua`
- Create: `tests/glab_review/ui/ansi_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/ui/ansi_spec.lua
local ansi = require("glab_review.ui.ansi")

describe("ui.ansi", function()
  it("strips basic color codes", function()
    local input = "\27[32mPASSED\27[0m test_auth"
    local output = ansi.strip(input)
    assert.equals("PASSED test_auth", output)
  end)

  it("strips multiple codes on one line", function()
    local input = "\27[1m\27[31mERROR\27[0m: \27[33mwarning\27[0m"
    local output = ansi.strip(input)
    assert.equals("ERROR: warning", output)
  end)

  it("strips section markers", function()
    local input = "section_start:12345:step_name\r\27[0K"
    local output = ansi.strip(input)
    assert.equals("", output)
  end)

  it("handles plain text unchanged", function()
    local input = "plain text with no codes"
    assert.equals(input, ansi.strip(input))
  end)

  it("strips from multiline text", function()
    local input = "\27[32mline1\27[0m\nline2\n\27[31mline3\27[0m"
    local lines = ansi.strip_lines(input)
    assert.equals(3, #lines)
    assert.equals("line1", lines[1])
    assert.equals("line2", lines[2])
    assert.equals("line3", lines[3])
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement ANSI stripping**

```lua
-- lua/glab_review/ui/ansi.lua
local M = {}

function M.strip(text)
  if not text then return "" end
  -- Remove ANSI escape sequences
  local result = text:gsub("\27%[[%d;]*[A-Za-z]", "")
  -- Remove carriage returns
  result = result:gsub("\r", "")
  -- Remove GitLab CI section markers
  result = result:gsub("section_start:%d+:[^\n]*\n?", "")
  result = result:gsub("section_end:%d+:[^\n]*\n?", "")
  -- Remove \27[0K (erase in line)
  result = result:gsub("\27%[%d*K", "")
  return result
end

function M.strip_lines(text)
  local stripped = M.strip(text)
  local lines = {}
  for line in (stripped .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/ui/ansi.lua tests/glab_review/ui/ansi_spec.lua
git commit -m "feat: add ANSI escape code stripping for job logs"
```

---

### Task 2: Pipeline Status Module

**Files:**
- Create: `lua/glab_review/pipeline/status.lua`
- Create: `tests/glab_review/pipeline/status_spec.lua`

**Step 1: Write failing test**

```lua
-- tests/glab_review/pipeline/status_spec.lua
local status = require("glab_review.pipeline.status")

describe("pipeline.status", function()
  describe("format_duration", function()
    it("formats seconds into human readable", function()
      assert.equals("45s", status.format_duration(45))
      assert.equals("2m 30s", status.format_duration(150))
      assert.equals("1h 5m", status.format_duration(3900))
    end)

    it("handles nil", function()
      assert.equals("--", status.format_duration(nil))
    end)
  end)

  describe("status_icon", function()
    it("returns icons for all statuses", function()
      assert.equals("[ok]", status.status_icon("success"))
      assert.equals("[!!]", status.status_icon("failed"))
      assert.equals("[..]", status.status_icon("running"))
      assert.equals("[..]", status.status_icon("pending"))
      assert.equals("[--]", status.status_icon("canceled"))
      assert.equals("[||]", status.status_icon("manual"))
      assert.equals("[??]", status.status_icon("unknown_thing"))
    end)
  end)

  describe("group_jobs_by_stage", function()
    it("groups jobs into stages", function()
      local jobs = {
        { name = "compile", stage = "build", status = "success", duration = 23 },
        { name = "unit", stage = "test", status = "success", duration = 72 },
        { name = "lint", stage = "test", status = "failed", duration = 18 },
      }
      local stages = status.group_jobs_by_stage(jobs)
      assert.equals(2, #stages)
      assert.equals("build", stages[1].name)
      assert.equals(1, #stages[1].jobs)
      assert.equals("test", stages[2].name)
      assert.equals(2, #stages[2].jobs)
    end)
  end)

  describe("build_pipeline_lines", function()
    it("builds display lines for a pipeline", function()
      local pipeline = { id = 100, status = "success", duration = 272 }
      local jobs = {
        { name = "compile", stage = "build", status = "success", duration = 23 },
        { name = "unit", stage = "test", status = "success", duration = 72 },
      }
      local lines = status.build_pipeline_lines(pipeline, jobs)
      local joined = table.concat(lines, "\n")
      assert.truthy(joined:find("100"))
      assert.truthy(joined:find("build"))
      assert.truthy(joined:find("compile"))
    end)
  end)
end)
```

**Step 2: Run test to verify it fails**

Expected: FAIL

**Step 3: Implement pipeline status**

```lua
-- lua/glab_review/pipeline/status.lua
local M = {}

local STATUS_ICONS = {
  success = "[ok]",
  failed = "[!!]",
  running = "[..]",
  pending = "[..]",
  canceled = "[--]",
  skipped = "[--]",
  manual = "[||]",
  created = "[..]",
  scheduled = "[..]",
}

function M.status_icon(s)
  return STATUS_ICONS[s] or "[??]"
end

function M.format_duration(seconds)
  if not seconds then return "--" end
  if seconds < 60 then
    return string.format("%ds", seconds)
  elseif seconds < 3600 then
    return string.format("%dm %ds", math.floor(seconds / 60), seconds % 60)
  else
    return string.format("%dh %dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
  end
end

function M.group_jobs_by_stage(jobs)
  local stage_order = {}
  local stage_map = {}

  for _, job in ipairs(jobs) do
    if not stage_map[job.stage] then
      stage_map[job.stage] = { name = job.stage, jobs = {} }
      table.insert(stage_order, stage_map[job.stage])
    end
    table.insert(stage_map[job.stage].jobs, job)
  end

  return stage_order
end

function M.build_pipeline_lines(pipeline, jobs)
  local lines = {}

  -- Header
  table.insert(lines, string.format(
    "Pipeline #%d  %s  %s",
    pipeline.id,
    M.status_icon(pipeline.status),
    M.format_duration(pipeline.duration)
  ))
  table.insert(lines, "")

  -- Stage summary line
  local stages = M.group_jobs_by_stage(jobs)
  local stage_names = {}
  for _, stage in ipairs(stages) do
    table.insert(stage_names, stage.name)
  end
  table.insert(lines, "Stages: " .. table.concat(stage_names, " -> "))
  table.insert(lines, "")

  -- Jobs grouped by stage
  for _, stage in ipairs(stages) do
    table.insert(lines, "-- " .. stage.name .. " " .. string.rep("-", 50 - #stage.name))
    for _, job in ipairs(stage.jobs) do
      table.insert(lines, string.format(
        "  %s  %-30s %s",
        M.status_icon(job.status),
        job.name,
        M.format_duration(job.duration)
      ))
    end
    table.insert(lines, "")
  end

  -- Footer
  table.insert(lines, string.rep("-", 55))
  table.insert(lines, "<CR> view job log  |  [r]etry failed  |  [o]pen in browser")
  table.insert(lines, "[q]uit")

  return lines
end

return M
```

**Step 4: Run test to verify it passes**

Expected: PASS

**Step 5: Commit**

```bash
git add lua/glab_review/pipeline/status.lua tests/glab_review/pipeline/status_spec.lua
git commit -m "feat: add pipeline status display with job grouping"
```

---

### Task 3: Job Log Viewer

**Files:**
- Create: `lua/glab_review/pipeline/jobs.lua`

**Step 1: Implement job log viewer**

```lua
-- lua/glab_review/pipeline/jobs.lua
local client = require("glab_review.api.client")
local endpoints = require("glab_review.api.endpoints")
local git = require("glab_review.git")
local ansi = require("glab_review.ui.ansi")
local float = require("glab_review.ui.float")
local M = {}

function M.view_log(job)
  local base_url, project = git.detect_project()
  if not base_url or not project then return end
  local encoded = client.encode_project(project)

  local result, err = client.get(base_url, endpoints.job_trace(encoded, job.id))
  if not result then
    vim.notify("Failed to load job log: " .. (err or ""), vim.log.levels.ERROR)
    return
  end

  local raw = type(result.data) == "string" and result.data or (result.data and vim.json.encode(result.data) or "")
  local lines = ansi.strip_lines(raw)

  if #lines == 0 then
    lines = { "(no log output)" }
  end

  local width = math.min(100, vim.o.columns - 10)
  local height = math.min(30, vim.o.lines - 6)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
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
    title = string.format(" Job: %s ", job.name),
    title_pos = "center",
  })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
end

function M.retry_failed(pipeline_id)
  local base_url, project = git.detect_project()
  if not base_url or not project then return end
  local encoded = client.encode_project(project)

  -- GitLab API: retry all failed jobs in a pipeline
  local _, err = client.post(base_url,
    string.format("/projects/%s/pipelines/%d/retry", encoded, pipeline_id), {})

  if err then
    vim.notify("Retry failed: " .. err, vim.log.levels.ERROR)
    return
  end
  vim.notify("Failed jobs retried", vim.log.levels.INFO)
end

return M
```

**Step 2: Commit**

```bash
git add lua/glab_review/pipeline/jobs.lua
git commit -m "feat: add job log viewer and retry"
```

---

### Task 4: Pipeline Floating Window + :GlabReviewPipeline

**Files:**
- Create: `lua/glab_review/pipeline/init.lua`
- Modify: `lua/glab_review/init.lua`
- Modify: `lua/glab_review/mr/detail.lua`

**Step 1: Implement pipeline entry point**

```lua
-- lua/glab_review/pipeline/init.lua
local client = require("glab_review.api.client")
local endpoints = require("glab_review.api.endpoints")
local git = require("glab_review.git")
local status = require("glab_review.pipeline.status")
local jobs_mod = require("glab_review.pipeline.jobs")
local M = {}

function M.open(mr)
  local base_url, project = git.detect_project()
  if not base_url or not project then
    vim.notify("Could not detect GitLab project", vim.log.levels.ERROR)
    return
  end
  local encoded = client.encode_project(project)

  -- Get pipeline ID from MR
  local pipeline = mr.head_pipeline
  if not pipeline then
    vim.notify("No pipeline found for this MR", vim.log.levels.WARN)
    return
  end

  -- Fetch full pipeline details
  local pipe_result, err = client.get(base_url, endpoints.pipeline(encoded, pipeline.id))
  if not pipe_result then
    vim.notify("Failed to load pipeline: " .. (err or ""), vim.log.levels.ERROR)
    return
  end

  -- Fetch jobs
  local jobs = client.paginate_all(base_url, endpoints.pipeline_jobs(encoded, pipeline.id))
  if not jobs then
    vim.notify("Failed to load jobs", vim.log.levels.ERROR)
    return
  end

  -- Build and display
  local lines = status.build_pipeline_lines(pipe_result.data, jobs)
  local width = math.min(70, vim.o.columns - 10)
  local height = math.min(#lines, vim.o.lines - 6)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
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
    title = string.format(" Pipeline #%d ", pipeline.id),
    title_pos = "center",
  })

  -- Store job data for keymaps
  local stages = status.group_jobs_by_stage(jobs)
  local job_line_map = {}  -- map buffer line -> job

  -- Build line-to-job mapping (count lines matching job format)
  local line_num = 0
  for _, line in ipairs(lines) do
    line_num = line_num + 1
    for _, stage in ipairs(stages) do
      for _, job in ipairs(stage.jobs) do
        if line:find(job.name, 1, true) then
          job_line_map[line_num] = job
        end
      end
    end
  end

  local map_opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, map_opts)

  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local job = job_line_map[cursor[1]]
    if job then
      jobs_mod.view_log(job)
    end
  end, map_opts)

  vim.keymap.set("n", "r", function()
    jobs_mod.retry_failed(pipeline.id)
  end, map_opts)

  vim.keymap.set("n", "o", function()
    if pipe_result.data.web_url then
      vim.ui.open(pipe_result.data.web_url)
    end
  end, map_opts)
end

return M
```

**Step 2: Wire into init.lua**

Replace the `M.pipeline` stub in `lua/glab_review/init.lua`:

```lua
function M.pipeline()
  local buf = vim.api.nvim_get_current_buf()
  local mr = vim.b[buf].glab_review_mr
  if not mr then
    vim.notify("No MR context in current buffer", vim.log.levels.WARN)
    return
  end
  require("glab_review.pipeline").open(mr)
end
```

**Step 3: Wire `p` keymap in detail.lua**

In `detail.lua`, replace the `p` keymap stub:

```lua
vim.keymap.set("n", "p", function()
  require("glab_review.pipeline").open(mr)
end, map_opts)
```

**Step 4: Manually test**

1. `:GlabReview` -> pick MR -> detail
2. Press `p` -> pipeline floating window
3. Navigate to a job line, press `<CR>` -> job log viewer
4. Press `r` -> retry failed jobs
5. Press `o` -> open in browser

**Step 5: Commit**

```bash
git add lua/glab_review/pipeline/init.lua lua/glab_review/init.lua lua/glab_review/mr/detail.lua
git commit -m "feat: add pipeline view with job logs and retry"
```

---

### Stage 4 Deliverable Checklist

- [ ] ANSI escape code stripping works on CI log output
- [ ] Pipeline floating window shows status, duration, stages
- [ ] Jobs grouped by stage with status icons
- [ ] `<CR>` on a job opens log in scrollable float
- [ ] Job logs have ANSI codes stripped
- [ ] `r` retries failed jobs
- [ ] `o` opens pipeline in browser
- [ ] `:GlabReviewPipeline` command works
- [ ] `p` from MR detail opens pipeline view
