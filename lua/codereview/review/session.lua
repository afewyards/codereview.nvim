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
  ai_job_id = nil,
}

--- Return a copy of the current session state.
function M.get()
  return {
    active = _state.active,
    ai_pending = _state.ai_pending,
    ai_job_id = _state.ai_job_id,
  }
end

--- Enter review mode. Comments will accumulate as drafts.
function M.start()
  _state.active = true
end

--- Exit review mode.
function M.stop()
  _state.active = false
end

--- Record that an AI subprocess has started.
---@param job_id number jobstart() handle for cancellation
function M.ai_start(job_id)
  _state.ai_pending = true
  _state.ai_job_id = job_id
end

--- Record that the AI subprocess has finished (success or error).
function M.ai_finish()
  _state.ai_pending = false
  _state.ai_job_id = nil
end

--- Reset to idle state.
function M.reset()
  _state.active = false
  _state.ai_pending = false
  _state.ai_job_id = nil
end

return M
