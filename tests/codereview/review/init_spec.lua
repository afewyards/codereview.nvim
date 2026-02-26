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

-- Stub api client
package.loaded["codereview.api.client"] = {}

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

describe("render_file_suggestions focus guard", function()
  local orig_run, orig_get_current_win, orig_set_current_win

  before_each(function()
    orig_run = package.loaded["codereview.ai.subprocess"].run
    orig_get_current_win = vim.api.nvim_get_current_win
    orig_set_current_win = vim.api.nvim_set_current_win
    package.loaded["codereview.ai.subprocess"].run = function(prompt, callback)
      callback('```json\n[{"file":"a.lua","line":1,"severity":"suggestion","comment":"test note"}]\n```')
      return 1
    end
  end)

  after_each(function()
    package.loaded["codereview.ai.subprocess"].run = orig_run
    vim.api.nvim_get_current_win = orig_get_current_win
    vim.api.nvim_set_current_win = orig_set_current_win
  end)

  it("skips set_current_win when current window is a float", function()
    local set_win_calls = {}
    vim.api.nvim_set_current_win = function(w) table.insert(set_win_calls, w) end
    vim.api.nvim_get_current_win = function() return 999 end
    local diff_state = {
      files = { { new_path = "a.lua", diff = "diff-a" } },
      discussions = {}, ai_suggestions = {}, view_mode = "diff",
      current_file = 1, scroll_mode = false,
      line_data_cache = {}, row_disc_cache = {}, row_ai_cache = {},
    }
    local layout = { main_buf = 0, sidebar_buf = 0, main_win = 1, sidebar_win = 2 }
    review_mod.start({ title = "T", description = "d" }, diff_state, layout)
    assert.equals(0, #set_win_calls, "set_current_win should not be called when a float is active")
  end)

  it("calls set_current_win when current window is main_win", function()
    local set_win_calls = {}
    vim.api.nvim_set_current_win = function(w) table.insert(set_win_calls, w) end
    vim.api.nvim_get_current_win = function() return 1 end
    local diff_state = {
      files = { { new_path = "a.lua", diff = "diff-a" } },
      discussions = {}, ai_suggestions = {}, view_mode = "diff",
      current_file = 1, scroll_mode = false,
      line_data_cache = {}, row_disc_cache = {}, row_ai_cache = {},
    }
    local layout = { main_buf = 0, sidebar_buf = 0, main_win = 1, sidebar_win = 2 }
    review_mod.start({ title = "T", description = "d" }, diff_state, layout)
    assert.truthy(#set_win_calls > 0, "set_current_win should be called when main_win is active")
  end)
end)

describe("review.start_file", function()
  before_each(function()
    captured_calls = {}
  end)

  it("runs summary then single-file review with cross-file context", function()
    local review = { title = "MR", description = "desc" }
    local diff_state = {
      files = {
        { new_path = "a.lua", diff = "diff-a" },
        { new_path = "b.lua", diff = "diff-b" },
        { new_path = "c.lua", diff = "diff-c" },
      },
      discussions = {},
      ai_suggestions = {},
      view_mode = "diff",
      current_file = 2, -- target is b.lua
      scroll_mode = false,
      line_data_cache = {},
      row_disc_cache = {},
      row_ai_cache = {},
    }
    local layout = { main_buf = 0, sidebar_buf = 0, main_win = 0 }

    review_mod.start_file(review, diff_state, layout)

    -- Phase 1: summary call
    assert.truthy(#captured_calls >= 1)
    assert.truthy(captured_calls[1].opts and captured_calls[1].opts.skip_agent)
    assert.truthy(captured_calls[1].prompt:find("summariz"))

    -- Phase 2: single file review (NOT 3 per-file calls)
    assert.equals(2, #captured_calls, "should be exactly 2 calls: summary + 1 file")
    assert.truthy(captured_calls[2].prompt:find("b.lua"), "should review the target file b.lua")
  end)

  it("replaces only the target file's suggestions", function()
    local diff_state = {
      files = {
        { new_path = "a.lua", diff = "diff-a" },
        { new_path = "b.lua", diff = "diff-b" },
      },
      discussions = {},
      ai_suggestions = {
        { file = "a.lua", line = 1, severity = "info", comment = "old a", status = "pending" },
        { file = "b.lua", line = 5, severity = "info", comment = "old b", status = "pending" },
      },
      view_mode = "diff",
      current_file = 1, -- re-review a.lua
      scroll_mode = false,
      line_data_cache = {},
      row_disc_cache = {},
      row_ai_cache = {},
    }

    local orig_run = package.loaded["codereview.ai.subprocess"].run
    local call_count = 0
    package.loaded["codereview.ai.subprocess"].run = function(prompt, callback, opts)
      call_count = call_count + 1
      if call_count == 1 then
        callback('```json\n[{"file":"a.lua","summary":"does a"},{"file":"b.lua","summary":"does b"}]\n```')
      else
        callback('```json\n[{"file":"a.lua","line":10,"severity":"warning","comment":"new a"}]\n```')
      end
      return 1
    end

    local layout = { main_buf = 0, sidebar_buf = 0, main_win = 0 }
    review_mod.start_file({ title = "T", description = "d" }, diff_state, layout)

    package.loaded["codereview.ai.subprocess"].run = orig_run

    assert.equals(2, #diff_state.ai_suggestions)
    local files_seen = {}
    for _, s in ipairs(diff_state.ai_suggestions) do
      files_seen[s.file] = s.comment
    end
    assert.equals("new a", files_seen["a.lua"])
    assert.equals("old b", files_seen["b.lua"])
  end)
end)

describe("file content in per-file review", function()
  before_each(function()
    captured_calls = {}
  end)

  it("includes full file content in per-file prompt for multi-file review", function()
    local content_fetch_calls = {}
    local mock_provider = {
      get_file_content = function(client, ctx, ref, path)
        table.insert(content_fetch_calls, path)
        return "-- full content of " .. path
      end,
    }
    local review = { title = "Multi", description = "desc", head_sha = "abc123" }
    local diff_state = {
      files = {
        { new_path = "a.lua", diff = "@@ -1,1 +1,1 @@\n-old\n+new\n" },
        { new_path = "b.lua", diff = "@@ -1,1 +1,1 @@\n-old\n+new\n" },
      },
      discussions = {},
      ai_suggestions = {},
      view_mode = "diff",
      current_file = 1,
      scroll_mode = false,
      line_data_cache = {},
      row_disc_cache = {},
      row_ai_cache = {},
      provider = mock_provider,
      ctx = { base_url = "https://api.github.com", project = "owner/repo" },
    }
    review_mod.start(review, diff_state, { main_buf = 0, sidebar_buf = 0, main_win = 0 })

    -- Should have fetched content for both files
    assert.equals(2, #content_fetch_calls)
    -- Per-file prompts (calls 2 and 3) should contain full file content
    assert.truthy(captured_calls[2].prompt:find("Full File Content") or
                  captured_calls[3].prompt:find("Full File Content"),
      "per-file prompts should include full file content")
  end)

  it("skips content fetch for deleted files", function()
    local content_fetch_calls = {}
    local mock_provider = {
      get_file_content = function(client, ctx, ref, path)
        table.insert(content_fetch_calls, path)
        return "content"
      end,
    }
    local review = { title = "Multi", description = "desc", head_sha = "abc123" }
    local diff_state = {
      files = {
        { new_path = "a.lua", diff = "@@ -1,1 +1,1 @@\n-old\n+new\n" },
        { new_path = "deleted.lua", old_path = "deleted.lua", deleted_file = true, diff = "@@ -1,1 +0,0 @@\n-gone\n" },
      },
      discussions = {},
      ai_suggestions = {},
      view_mode = "diff",
      current_file = 1,
      scroll_mode = false,
      line_data_cache = {},
      row_disc_cache = {},
      row_ai_cache = {},
      provider = mock_provider,
      ctx = { base_url = "https://api.github.com", project = "owner/repo" },
    }
    review_mod.start(review, diff_state, { main_buf = 0, sidebar_buf = 0, main_win = 0 })

    -- Should only fetch content for a.lua, not deleted.lua
    assert.equals(1, #content_fetch_calls)
    assert.equals("a.lua", content_fetch_calls[1])
  end)
end)
