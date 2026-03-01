-- lua/codereview/pipeline/state.lua
-- Pipeline state factory, grouping, and polling helpers.
local M = {}

local TERMINAL_STATUSES = {
  success = true, failed = true, canceled = true, skipped = true,
  -- GitHub conclusions
  action_required = true, timed_out = true, stale = true,
}

--- Create a new pipeline state.
--- @param opts table { review, provider, client, ctx }
--- @return table
function M.create(opts)
  return {
    review = opts.review,
    provider = opts.provider,
    client = opts.client,
    ctx = opts.ctx,
    pipeline = nil,
    jobs = {},
    stages = {},
    collapsed = {},
    poll_timer = nil,
    poll_failures = 0,
    handle = nil,
  }
end

--- Group jobs by stage, preserving encounter order.
--- @param jobs table[]
--- @return table[] stages  { { name, jobs } }
function M.group_by_stage(jobs)
  local stages = {}
  local index = {}
  for _, job in ipairs(jobs) do
    local stage_name = job.stage or "unknown"
    if not index[stage_name] then
      local stage = { name = stage_name, jobs = {} }
      table.insert(stages, stage)
      index[stage_name] = stage
    end
    table.insert(index[stage_name].jobs, job)
  end
  return stages
end

--- Check if a pipeline status is terminal (no more updates expected).
--- @param status string
--- @return boolean
function M.is_terminal(status)
  return TERMINAL_STATUSES[status] == true
end

--- Format duration in seconds to human-readable string.
--- @param seconds number
--- @return string
function M.format_duration(seconds)
  seconds = math.floor(seconds or 0)
  if seconds >= 3600 then
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    return string.format("%dh %02dm", h, m)
  end
  local m = math.floor(seconds / 60)
  local s = seconds % 60
  return string.format("%dm %02ds", m, s)
end

--- Fetch pipeline + jobs from provider, update state.
--- @param pstate table  pipeline state from create()
--- @return boolean changed  whether data changed
function M.fetch(pstate)
  local pipeline, _ = pstate.provider.get_pipeline(pstate.client, pstate.ctx, pstate.review)
  if not pipeline then
    pstate.poll_failures = pstate.poll_failures + 1
    return false
  end
  pstate.poll_failures = 0

  local jobs, _ = pstate.provider.get_pipeline_jobs(pstate.client, pstate.ctx, pstate.review, pipeline.id)
  if not jobs then
    jobs = {}
  end

  local changed = not pstate.pipeline or pstate.pipeline.status ~= pipeline.status or #jobs ~= #pstate.jobs
  pstate.pipeline = pipeline
  pstate.jobs = jobs
  pstate.stages = M.group_by_stage(jobs)
  return changed
end

--- Start polling for pipeline updates.
--- @param pstate table
--- @param interval_ms number
--- @param on_update function  called when data changes
function M.start_polling(pstate, interval_ms, on_update)
  if pstate.poll_timer then return end
  pstate.poll_timer = vim.fn.timer_start(interval_ms, function()
    vim.schedule(function()
      if not pstate.poll_timer then return end
      if pstate.poll_failures >= 3 then
        M.stop_polling(pstate)
        return
      end
      local changed = M.fetch(pstate)
      if changed then
        on_update(pstate)
      end
      if pstate.pipeline and M.is_terminal(pstate.pipeline.status) then
        M.stop_polling(pstate)
      end
    end)
  end, { ["repeat"] = -1 })
end

--- Stop polling.
--- @param pstate table
function M.stop_polling(pstate)
  if pstate.poll_timer then
    vim.fn.timer_stop(pstate.poll_timer)
    pstate.poll_timer = nil
  end
end

return M
