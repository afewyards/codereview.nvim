-- Stub vim globals for busted
_G.vim = _G.vim or {}
vim.fn = vim.fn or {}
vim.fn.jobstart = vim.fn.jobstart or function() return 1 end
vim.fn.chansend = vim.fn.chansend or function() end
vim.fn.chanclose = vim.fn.chanclose or function() end
vim.notify = vim.notify or function() end
vim.schedule = vim.schedule or function(fn) fn() end
vim.log = vim.log or { levels = { INFO = 1, ERROR = 2, WARN = 3 } }
vim.api = vim.api or {}
vim.api.nvim_set_current_win = vim.api.nvim_set_current_win or function() end
vim.json = vim.json or {}
vim.json.decode = vim.json.decode or function() return {} end

-- Stub config
package.loaded["codereview.config"] = {
  get = function()
    return { ai = { enabled = true, claude_cmd = "claude", agent = "code-review" } }
  end,
}

-- Stub log
package.loaded["codereview.log"] = {
  debug = function() end,
  warn = function() end,
  error = function() end,
}

-- Stub spinner
package.loaded["codereview.ui.spinner"] = {
  open = function() end,
  close = function() end,
  set_label = function() end,
}

-- Stub subprocess to capture all calls
local captured_calls = {}
package.loaded["codereview.ai.subprocess"] = {
  run = function(prompt, callback, opts)
    table.insert(captured_calls, { prompt = prompt, opts = opts })
    callback('```json\n[]\n```')
    return 1
  end,
  build_cmd = function(cmd, agent)
    local t = { cmd, "-p" }
    if agent then
      table.insert(t, "--agent")
      table.insert(t, agent)
    end
    return t
  end,
}

-- Stub session
package.loaded["codereview.review.session"] = {
  start = function() end,
  ai_start = function() end,
  ai_finish = function() end,
  ai_file_done = function() end,
  stop = function() end,
  reset = function() end,
  get = function()
    return { active = false, ai_pending = false, ai_job_ids = {}, ai_total = 0, ai_completed = 0 }
  end,
}

-- Stub diff module
package.loaded["codereview.mr.diff"] = {
  render_file_diff = function() return {}, {}, {} end,
  render_all_files = function() return { file_sections = {}, line_data = {}, row_discussions = {}, row_ai = {} } end,
  render_sidebar = function() end,
}

-- Now require the modules under test
local review_mod = require("codereview.review")

describe("review.init routing", function()
  before_each(function()
    captured_calls = {}
  end)

  it("uses summary prompt then per-file prompts for multi-file MRs", function()
    local review = { title = "Multi", description = "desc" }
    local diff_state = {
      files = {
        { new_path = "a.lua", diff = "diff-a" },
        { new_path = "b.lua", diff = "diff-b" },
      },
      discussions = {},
      ai_suggestions = {},
      view_mode = "diff",
      current_file = 1,
      scroll_mode = false,
      line_data_cache = {},
      row_disc_cache = {},
      row_ai_cache = {},
    }
    review_mod.start(review, diff_state, { main_buf = 0, sidebar_buf = 0, main_win = 0 })
    -- Phase 1: summary call with skip_agent
    assert.truthy(#captured_calls >= 1, "should have at least one subprocess call")
    local first = captured_calls[1]
    assert.truthy(first.opts and first.opts.skip_agent, "summary call should skip agent")
    assert.truthy(first.prompt:find("summariz"), "first prompt should be summary prompt")
    -- Phase 2: per-file calls (one per file)
    assert.truthy(#captured_calls >= 3, "should have summary + 2 file calls")
    assert.truthy(captured_calls[2].prompt:find("a.lua") or captured_calls[3].prompt:find("a.lua"),
      "per-file prompts should reference file paths")
  end)

  it("uses direct review prompt for single-file MRs", function()
    local review = { title = "Single", description = "desc" }
    local diff_state = {
      files = {
        { new_path = "a.lua", diff = "diff-a" },
      },
      discussions = {},
      ai_suggestions = {},
      view_mode = "diff",
      current_file = 1,
      scroll_mode = false,
      line_data_cache = {},
      row_disc_cache = {},
      row_ai_cache = {},
    }
    review_mod.start(review, diff_state, { main_buf = 0, sidebar_buf = 0, main_win = 0 })
    assert.equals(1, #captured_calls, "single-file should make exactly one subprocess call")
    local first = captured_calls[1]
    assert.falsy(first.opts and first.opts.skip_agent, "should NOT skip agent for direct review")
    assert.truthy(first.prompt:find("JSON"), "single-file should use direct review prompt")
    assert.falsy(first.prompt:find("orchestrat"), "single-file should NOT use orchestrator prompt")
  end)
end)
