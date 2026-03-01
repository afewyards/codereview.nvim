-- lua/codereview/pipeline/init.lua
-- Entry point for the pipeline view.
local M = {}

local pipeline_state = require("codereview.pipeline.state")
local render = require("codereview.pipeline.render")
local keymaps = require("codereview.pipeline.keymaps")
local log_view = require("codereview.pipeline.log_view")

local current_handle = nil
local current_pstate = nil

--- Open the pipeline view for a review.
--- @param diff_state table  active diff state (from diff.get_state)
function M.open(diff_state)
  if not diff_state then
    vim.notify("Open a review first", vim.log.levels.WARN)
    return
  end

  M.close()

  local cfg = require("codereview.config").get()
  local poll_interval = cfg.pipeline and cfg.pipeline.poll_interval or 10000

  local pstate = pipeline_state.create({
    review = diff_state.review,
    provider = diff_state.provider,
    client = require("codereview.api.client"),
    ctx = diff_state.ctx,
  })

  -- Initial fetch
  pipeline_state.fetch(pstate)
  if not pstate.pipeline then
    vim.notify("No pipeline found for this review", vim.log.levels.WARN)
    return
  end

  current_pstate = pstate

  -- Build content
  local content = render.build_lines(pstate.pipeline, pstate.stages, pstate.collapsed)

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
  vim.bo[buf].modifiable = false

  -- Create float
  local width = math.min(80, math.floor(vim.o.columns * 0.6))
  local height = math.min(#content.lines + 2, math.floor(vim.o.lines * 0.7))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local title = string.format(" Pipeline #%s ", tostring(pstate.pipeline.id))

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = {{ title, "CodeReviewFloatTitle" }},
    title_pos = "center",
    footer = {{ " q:close  r:retry  c:cancel  p:play  o:browser  R:refresh ", "CodeReviewFloatFooterText" }},
    footer_pos = "center",
    zindex = 45,
  })

  current_handle = { buf = buf, win = win, closed = false, row_map = content.row_map }

  function current_handle.close()
    if current_handle.closed then return end
    current_handle.closed = true
    pipeline_state.stop_polling(pstate)
    log_view.close()
    pcall(vim.api.nvim_win_close, win, true)
    current_handle = nil
    current_pstate = nil
  end

  -- Redraw helper
  local function redraw()
    if current_handle and current_handle.closed then return end
    local c = render.build_lines(pstate.pipeline, pstate.stages, pstate.collapsed)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, c.lines)
      vim.bo[buf].modifiable = false
    end
    if current_handle then current_handle.row_map = c.row_map end
  end

  -- Keymaps
  keymaps.setup(buf, pstate, current_handle, {
    on_refresh = function()
      pipeline_state.fetch(pstate)
      redraw()
    end,

    on_toggle = function(row)
      local entry = current_handle.row_map[row]
      if not entry then return end
      if entry.job then
        -- Open log for this job
        local trace, err = pstate.provider.get_job_trace(pstate.client, pstate.ctx, pstate.review, entry.job.id)
        if not trace then
          vim.notify("Failed to fetch log: " .. (err or "unknown"), vim.log.levels.ERROR)
          return
        end
        local max_lines = cfg.pipeline and cfg.pipeline.log_max_lines or 5000
        log_view.open(entry.job, trace, max_lines)
      elseif entry.stage then
        pstate.collapsed[entry.stage] = not pstate.collapsed[entry.stage]
        redraw()
      end
    end,

    on_retry = function(row)
      local entry = current_handle.row_map[row]
      if not entry or not entry.job then return end
      local _, err = pstate.provider.retry_job(pstate.client, pstate.ctx, pstate.review, entry.job.id)
      if err then
        vim.notify("Retry failed: " .. err, vim.log.levels.ERROR)
      else
        vim.notify("Job retried: " .. entry.job.name, vim.log.levels.INFO)
        pipeline_state.fetch(pstate)
        redraw()
      end
    end,

    on_cancel = function(row)
      local entry = current_handle.row_map[row]
      if not entry or not entry.job then return end
      local _, err = pstate.provider.cancel_job(pstate.client, pstate.ctx, pstate.review, entry.job.id)
      if err then
        vim.notify("Cancel failed: " .. err, vim.log.levels.ERROR)
      else
        vim.notify("Job cancelled: " .. entry.job.name, vim.log.levels.INFO)
        pipeline_state.fetch(pstate)
        redraw()
      end
    end,

    on_play = function(row)
      local entry = current_handle.row_map[row]
      if not entry or not entry.job then return end
      local _, err = pstate.provider.play_job(pstate.client, pstate.ctx, pstate.review, entry.job.id)
      if err then
        vim.notify("Play failed: " .. err, vim.log.levels.ERROR)
      else
        vim.notify("Job triggered: " .. entry.job.name, vim.log.levels.INFO)
        pipeline_state.fetch(pstate)
        redraw()
      end
    end,

    on_browser = function(row)
      local entry = current_handle.row_map[row]
      local url
      if entry and entry.job then
        url = entry.job.web_url
      elseif pstate.pipeline then
        url = pstate.pipeline.web_url
      end
      if url and url ~= "" then
        vim.ui.open(url)
      else
        vim.notify("No URL available", vim.log.levels.WARN)
      end
    end,
  })

  -- Auto-close on WinClosed
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() current_handle.close() end,
  })

  -- Start polling if pipeline is not terminal
  if not pipeline_state.is_terminal(pstate.pipeline.status) then
    pipeline_state.start_polling(pstate, poll_interval, function()
      vim.schedule(redraw)
    end)
  end
end

--- Close the pipeline view if open.
function M.close()
  if current_handle and not current_handle.closed then
    current_handle.close()
  end
end

--- Check if the pipeline view is currently open.
--- @return boolean
function M.is_open()
  return current_handle ~= nil and not current_handle.closed
end

return M
