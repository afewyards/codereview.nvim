-- lua/codereview/pipeline/render.lua
-- Build pipeline float buffer content: header, stage groups, job rows.
local M = {}

local pipeline_state = require("codereview.pipeline.state")

local STATUS_ICONS = {
  success = "✓", failed = "✗", running = "◷", pending = "○",
  canceled = "⊘", skipped = "⊘", manual = "○", created = "○",
  -- GitHub-specific conclusions
  neutral = "○", action_required = "⚠",
  in_progress = "◷", queued = "○", timed_out = "✗",
}

local STAGE_ICONS = { expanded = "▾", collapsed = "▸" }

--- Build displayable lines for the pipeline float.
--- @param pipeline table  normalized pipeline
--- @param stages table[]  from state.group_by_stage()
--- @param collapsed table  { [stage_name] = true }
--- @return table  { lines, highlights, row_map }
function M.build_lines(pipeline, stages, collapsed)
  local lines = {}
  local highlights = {}
  local row_map = {}

  -- Header
  local dur = pipeline_state.format_duration(pipeline.duration)
  local header = string.format("Pipeline #%s · %s · %s", tostring(pipeline.id), pipeline.status, dur)
  table.insert(lines, header)
  table.insert(lines, string.rep("─", math.max(40, #header)))

  for _, stage in ipairs(stages) do
    local row = #lines + 1
    local is_collapsed = collapsed[stage.name] == true
    local icon = is_collapsed and STAGE_ICONS.collapsed or STAGE_ICONS.expanded

    -- Count job statuses for summary
    local passed, total = 0, #stage.jobs
    for _, j in ipairs(stage.jobs) do
      if j.status == "success" then passed = passed + 1 end
    end
    local summary = total > 0 and string.format(" (%d/%d passed)", passed, total) or ""

    table.insert(lines, string.format("%s %s%s", icon, stage.name, summary))
    row_map[row] = { stage = stage.name }

    if not is_collapsed then
      for _, job in ipairs(stage.jobs) do
        local jrow = #lines + 1
        local job_icon = STATUS_ICONS[job.status] or "?"
        local job_dur = pipeline_state.format_duration(job.duration)
        local af = job.allow_failure and "  [allow failure]" or ""
        local status_text = (job.status == "running" or job.status == "in_progress" or job.status == "pending")
          and job.status or ""

        local line = string.format("  %s %-20s %s%s%s", job_icon, job.name, job_dur, af,
          status_text ~= "" and ("  " .. status_text) or "")
        table.insert(lines, line)
        row_map[jrow] = { stage = stage.name, job = job }
      end
    end
  end

  return { lines = lines, highlights = highlights, row_map = row_map }
end

return M
