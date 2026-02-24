-- lua/codereview/review/session.lua
-- Review session state machine.
--
-- States:
--   active=false                       → IDLE: comments post immediately
--   active=true, ai_pending=false      → REVIEWING: comments accumulate as drafts
--   active=true, ai_pending=true       → REVIEWING+AI: same, AI processing in background

local M = {}

local _state = {
  active = false,
  ai_pending = false,
  ai_job_ids = {},
  ai_total = 0,
  ai_completed = 0,
}

--- Return a copy of the current session state.
function M.get()
  return {
    active = _state.active,
    ai_pending = _state.ai_pending,
    ai_job_id = _state.ai_job_ids[1], -- backwards compat
    ai_job_ids = _state.ai_job_ids,
    ai_total = _state.ai_total,
    ai_completed = _state.ai_completed,
  }
end

--- Enter review mode. Comments will accumulate as drafts.
function M.start()
  _state.active = true
end

--- Exit review mode.
function M.stop()
  _state.active = false
  _state.ai_pending = false
  _state.ai_job_ids = {}
  _state.ai_total = 0
  _state.ai_completed = 0
  require("codereview.ui.spinner").close()
end

--- Record that AI subprocess(es) have started.
---@param job_ids number|number[] jobstart() handle(s) for cancellation
---@param total? number total file count (defaults to #job_ids)
function M.ai_start(job_ids, total)
  if type(job_ids) == "number" then
    job_ids = { job_ids }
  end
  _state.ai_pending = true
  _state.ai_job_ids = job_ids
  _state.ai_total = total or #job_ids
  _state.ai_completed = 0
  require("codereview.ui.spinner").open()
end

--- Record that one file's AI review completed. Auto-finishes when all done.
function M.ai_file_done()
  _state.ai_completed = _state.ai_completed + 1
  if _state.ai_completed >= _state.ai_total then
    M.ai_finish()
  end
end

--- Record that the AI subprocess has finished (success or error).
function M.ai_finish()
  _state.ai_pending = false
  _state.ai_job_ids = {}
  require("codereview.ui.spinner").close()
end

--- Reset to idle state.
function M.reset()
  _state.active = false
  _state.ai_pending = false
  _state.ai_job_ids = {}
  _state.ai_total = 0
  _state.ai_completed = 0
end

return M
