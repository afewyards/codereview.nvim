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
}

-- Stub subprocess to capture prompt and opts
local captured_prompt = nil
local captured_opts = nil
package.loaded["codereview.ai.subprocess"] = {
  run = function(prompt, callback, opts)
    captured_prompt = prompt
    captured_opts = opts
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
  stop = function() end,
  reset = function() end,
  get = function() return { active = false, ai_pending = false } end,
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
    captured_prompt = nil
    captured_opts = nil
  end)

  it("uses orchestrator prompt for multi-file MRs", function()
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
    assert.truthy(captured_prompt:find("orchestrat"), "prompt should contain orchestrator instructions")
    assert.truthy(captured_opts and captured_opts.skip_agent, "should skip agent for orchestrator")
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
    assert.falsy(captured_prompt:find("orchestrat"), "single-file should NOT use orchestrator")
    assert.truthy(captured_prompt:find("JSON"), "single-file should use direct review prompt")
    assert.falsy(captured_opts and captured_opts.skip_agent, "should NOT skip agent for direct review")
  end)
end)
