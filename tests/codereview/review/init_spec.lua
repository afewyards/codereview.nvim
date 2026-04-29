-- Stub vim globals for busted
_G.vim = _G.vim or {}
vim.fn = vim.fn or {}
vim.fn.jobstart = vim.fn.jobstart or function()
  return 1
end
vim.fn.chansend = vim.fn.chansend or function() end
vim.fn.chanclose = vim.fn.chanclose or function() end
vim.notify = vim.notify or function() end
vim.schedule = vim.schedule or function(fn)
  fn()
end
vim.log = vim.log or { levels = { INFO = 1, ERROR = 2, WARN = 3 } }
vim.api = vim.api or {}
vim.api.nvim_set_current_win = vim.api.nvim_set_current_win or function() end
vim.json = vim.json or {}
vim.json.decode = vim.json.decode or function()
  return {}
end

-- Stub config
package.loaded["codereview.config"] = {
  get = function()
    return { ai = { enabled = true, claude_cmd = "claude", agent = "code-review", max_file_size = 500 } }
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

-- Stub provider to capture all calls
local captured_calls = {}
local mock_provider = {
  run = function(prompt, callback, opts)
    table.insert(captured_calls, { prompt = prompt, opts = opts })
    callback("```json\n[]\n```")
    return 1
  end,
}
package.loaded["codereview.ai.providers"] = {
  get = function()
    return mock_provider
  end,
}
-- Keep subprocess stub for backward compat (same table so mutations propagate)
package.loaded["codereview.ai.subprocess"] = mock_provider

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
  render_file_diff = function()
    return {}, {}, {}
  end,
  render_all_files = function()
    return { file_sections = {}, line_data = {}, row_discussions = {}, row_ai = {} }
  end,
  render_sidebar = function() end,
}

-- Now require the modules under test
local review_mod = require("codereview.review")

describe("review.init routing", function()
  before_each(function()
    captured_calls = {}
  end)

  it("uses per-file prompts for multi-file MRs", function()
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
    -- Per-file calls (one per file, no summary pre-pass)
    assert.truthy(#captured_calls >= 2, "should have 2 per-file calls")
    assert.truthy(
      captured_calls[1].prompt:find("a.lua") or captured_calls[2].prompt:find("a.lua"),
      "per-file prompts should reference file paths"
    )
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

describe("review.start_multi filtered-file count", function()
  local orig_ai_start, orig_filter

  before_each(function()
    captured_calls = {}
    orig_ai_start = package.loaded["codereview.review.session"].ai_start
    orig_filter = package.loaded["codereview.ai.file_filter"]
  end)

  after_each(function()
    package.loaded["codereview.review.session"].ai_start = orig_ai_start
    package.loaded["codereview.ai.file_filter"] = orig_filter
  end)

  it("ai_start total uses post-filter count when file_filter drops files", function()
    local ai_start_calls = {}
    package.loaded["codereview.review.session"].ai_start = function(ids, total)
      table.insert(ai_start_calls, { ids = ids, total = total })
    end

    -- Filter that keeps only the first file
    package.loaded["codereview.ai.file_filter"] = {
      apply = function(diffs, _)
        return { diffs[1] }
      end,
    }

    local review = { title = "Multi", description = "desc" }
    local diff_state = {
      files = {
        { new_path = "a.lua", diff = "diff-a" },
        { new_path = "package-lock.json", diff = "diff-lock" },
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

    assert.equals(1, #ai_start_calls, "ai_start should be called once")
    assert.equals(1, ai_start_calls[1].total, "ai_start total should equal filtered count (1), not original (2)")
  end)
end)

describe("render_file_suggestions focus guard", function()
  local orig_run, orig_get_current_win, orig_set_current_win, orig_schedule

  before_each(function()
    orig_run = package.loaded["codereview.ai.subprocess"].run
    orig_get_current_win = vim.api.nvim_get_current_win
    orig_set_current_win = vim.api.nvim_set_current_win
    orig_schedule = vim.schedule
    -- Run scheduled callbacks immediately so assertions see their effects synchronously
    vim.schedule = function(fn)
      fn()
    end
    package.loaded["codereview.ai.subprocess"].run = function(prompt, callback)
      callback('```json\n[{"file":"a.lua","line":1,"severity":"suggestion","comment":"test note"}]\n```')
      return 1
    end
  end)

  after_each(function()
    package.loaded["codereview.ai.subprocess"].run = orig_run
    vim.api.nvim_get_current_win = orig_get_current_win
    vim.api.nvim_set_current_win = orig_set_current_win
    vim.schedule = orig_schedule
  end)

  it("skips set_current_win when current window is a float", function()
    local set_win_calls = {}
    vim.api.nvim_set_current_win = function(w)
      table.insert(set_win_calls, w)
    end
    vim.api.nvim_get_current_win = function()
      return 999
    end
    local diff_state = {
      files = { { new_path = "a.lua", diff = "@@ -0,0 +1 @@\n+test note\n" } },
      discussions = {},
      ai_suggestions = {},
      view_mode = "diff",
      current_file = 1,
      scroll_mode = false,
      line_data_cache = {},
      row_disc_cache = {},
      row_ai_cache = {},
    }
    local layout = { main_buf = 0, sidebar_buf = 0, main_win = 1, sidebar_win = 2 }
    review_mod.start({ title = "T", description = "d" }, diff_state, layout)
    assert.equals(0, #set_win_calls, "set_current_win should not be called when a float is active")
  end)

  it("calls set_current_win when current window is main_win", function()
    local set_win_calls = {}
    vim.api.nvim_set_current_win = function(w)
      table.insert(set_win_calls, w)
    end
    vim.api.nvim_get_current_win = function()
      return 1
    end
    local diff_state = {
      files = { { new_path = "a.lua", diff = "@@ -0,0 +1 @@\n+test note\n" } },
      discussions = {},
      ai_suggestions = {},
      view_mode = "diff",
      current_file = 1,
      scroll_mode = false,
      line_data_cache = {},
      row_disc_cache = {},
      row_ai_cache = {},
    }
    local layout = { main_buf = 0, sidebar_buf = 0, main_win = 1, sidebar_win = 2 }
    review_mod.start({ title = "T", description = "d" }, diff_state, layout)
    assert.truthy(#set_win_calls > 0, "set_current_win should be called when main_win is active")
  end)
end)

describe("review.start_file", function()
  local orig_schedule_sf

  before_each(function()
    captured_calls = {}
    orig_schedule_sf = vim.schedule
    -- Run scheduled callbacks immediately so assertions see their effects synchronously
    vim.schedule = function(fn)
      fn()
    end
  end)

  after_each(function()
    vim.schedule = orig_schedule_sf
  end)

  it("reviews single target file without a summary pre-pass", function()
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

    -- Single file review only (no summary pre-pass)
    assert.equals(1, #captured_calls, "should be exactly 1 call: the file review")
    assert.truthy(captured_calls[1].prompt:find("b.lua"), "should review the target file b.lua")
  end)

  it("replaces only the target file's suggestions", function()
    local diff_state = {
      files = {
        { new_path = "a.lua", diff = "@@ -9,1 +10,1 @@\n+new a\n" },
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
    package.loaded["codereview.ai.subprocess"].run = function(prompt, callback, opts)
      callback('```json\n[{"file":"a.lua","line":10,"severity":"warning","comment":"new a"}]\n```')
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
    local local_mock_provider = {
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
      provider = local_mock_provider,
      ctx = { base_url = "https://api.github.com", project = "owner/repo" },
    }
    review_mod.start(review, diff_state, { main_buf = 0, sidebar_buf = 0, main_win = 0 })

    -- Should have fetched content for both files
    assert.equals(2, #content_fetch_calls)
    -- Per-file prompts (calls 1 and 2) should contain full file content
    assert.truthy(
      captured_calls[1].prompt:find("Full File Content") or captured_calls[2].prompt:find("Full File Content"),
      "per-file prompts should include full file content"
    )
  end)

  it("skips content fetch for deleted files", function()
    local content_fetch_calls = {}
    local local_mock_provider = {
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
      provider = local_mock_provider,
      ctx = { base_url = "https://api.github.com", project = "owner/repo" },
    }
    review_mod.start(review, diff_state, { main_buf = 0, sidebar_buf = 0, main_win = 0 })

    -- Should only fetch content for a.lua, not deleted.lua
    assert.equals(1, #content_fetch_calls)
    assert.equals("a.lua", content_fetch_calls[1])
  end)

  it("skips content when file exceeds max_file_size", function()
    local content_fetch_calls = {}
    local local_mock_provider = {
      get_file_content = function(client, ctx, ref, path)
        table.insert(content_fetch_calls, path)
        -- Return content with many lines (exceeds default 500)
        local lines = {}
        for i = 1, 501 do
          lines[i] = "line " .. i
        end
        return table.concat(lines, "\n")
      end,
    }
    local review = { title = "Multi", description = "desc", head_sha = "abc123" }
    local diff_state = {
      files = {
        { new_path = "big.lua", diff = "@@ -1,1 +1,1 @@\n-old\n+new\n" },
        { new_path = "small.lua", diff = "@@ -1,1 +1,1 @@\n-old\n+new\n" },
      },
      discussions = {},
      ai_suggestions = {},
      view_mode = "diff",
      current_file = 1,
      scroll_mode = false,
      line_data_cache = {},
      row_disc_cache = {},
      row_ai_cache = {},
      provider = local_mock_provider,
      ctx = { base_url = "https://api.github.com", project = "owner/repo" },
    }
    review_mod.start(review, diff_state, { main_buf = 0, sidebar_buf = 0, main_win = 0 })

    -- Content was fetched for both files
    assert.equals(2, #content_fetch_calls)
    -- But the per-file prompts should NOT have Full File Content for big files
    -- (both files return 501 lines which exceeds default 500)
    for i = 1, #captured_calls do
      assert.falsy(
        captured_calls[i].prompt:find("Full File Content"),
        "per-file prompt should not include full file content for files exceeding max_file_size"
      )
    end
  end)
end)
