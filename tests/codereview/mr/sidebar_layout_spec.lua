local function make_layout()
  package.loaded["codereview.mr.sidebar_layout"] = nil
  return require("codereview.mr.sidebar_layout")
end

describe("mr.sidebar_layout", function()
  before_each(function()
    package.loaded["codereview.review.session"] = {
      get = function() return { active = false } end,
    }
    package.loaded["codereview.mr.list"] = {
      pipeline_icon = function() return "●" end,
    }
  end)

  after_each(function()
    package.loaded["codereview.review.session"] = nil
    package.loaded["codereview.mr.list"] = nil
    package.loaded["codereview.mr.sidebar_layout"] = nil
  end)

  local function make_state()
    return {
      review = {
        id = 1,
        title = "Test MR",
        source_branch = "feature",
        target_branch = "main",
        pipeline_status = nil,
        approved_by = {},
        approvals_required = 0,
        merge_status = "can_be_merged",
      },
      files = {
        { new_path = "src/a.lua", old_path = "src/a.lua" },
        { new_path = "src/b.lua", old_path = "src/b.lua" },
      },
      discussions = {},
      file_review_status = {},
      collapsed_dirs = {},
      current_file = 1,
      view_mode = "diff",
    }
  end

  it("renders non-empty buffer content", function()
    local layout = make_layout()
    local buf = vim.api.nvim_create_buf(false, true)
    layout.render(buf, make_state())
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.truthy(#lines > 0)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("sets sidebar_component_ranges with all 5 component keys", function()
    local layout = make_layout()
    local buf = vim.api.nvim_create_buf(false, true)
    local state = make_state()
    layout.render(buf, state)
    local ranges = state.sidebar_component_ranges
    assert.truthy(ranges, "sidebar_component_ranges should be set")
    assert.truthy(ranges.header,         "should have header range")
    assert.truthy(ranges.status,         "should have status range (even if empty)")
    assert.truthy(ranges.summary_button, "should have summary_button range")
    assert.truthy(ranges.file_tree,      "should have file_tree range")
    assert.truthy(ranges.footer,         "should have footer range")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("populates sidebar_row_map with summary and file entries", function()
    local layout = make_layout()
    local buf = vim.api.nvim_create_buf(false, true)
    local state = make_state()
    layout.render(buf, state)
    local found_summary = false
    local found_file = false
    for _, entry in pairs(state.sidebar_row_map) do
      if entry.type == "summary" then found_summary = true end
      if entry.type == "file"    then found_file    = true end
    end
    assert.is_true(found_summary, "expected summary entry in sidebar_row_map")
    assert.is_true(found_file,    "expected file entry in sidebar_row_map")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("components appear in order: header before file_tree", function()
    local layout = make_layout()
    local buf = vim.api.nvim_create_buf(false, true)
    local state = make_state()
    layout.render(buf, state)
    local header_start    = state.sidebar_component_ranges.header.start
    local file_tree_start = state.sidebar_component_ranges.file_tree.start
    assert.truthy(header_start < file_tree_start, "header should come before file_tree")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("summary row is offset past the header lines", function()
    local layout = make_layout()
    local buf = vim.api.nvim_create_buf(false, true)
    local state = make_state()
    layout.render(buf, state)
    -- header renders 4 lines + 1 blank = 5 rows before summary_button
    local summary_row = nil
    for row, entry in pairs(state.sidebar_row_map) do
      if entry.type == "summary" then
        summary_row = row
        break
      end
    end
    assert.truthy(summary_row,       "expected a summary row in sidebar_row_map")
    assert.truthy(summary_row > 4,   "summary row should be offset past header")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("footer appears after file_tree", function()
    local layout = make_layout()
    local buf = vim.api.nvim_create_buf(false, true)
    local state = make_state()
    layout.render(buf, state)
    local footer_start    = state.sidebar_component_ranges.footer.start
    local file_tree_start = state.sidebar_component_ranges.file_tree.start
    assert.truthy(footer_start > file_tree_start, "footer should come after file_tree")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("header content is present at the expected buffer rows", function()
    local layout = make_layout()
    local buf = vim.api.nvim_create_buf(false, true)
    local state = make_state()
    layout.render(buf, state)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- header line 1 should contain the MR id
    assert.truthy(lines[1]:find("#1"), "first line should show MR id #1")
    -- header line 2 should show branch info
    assert.truthy(lines[2]:find("feature"), "second line should show source branch")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not error with active session and ai_suggestions", function()
    package.loaded["codereview.review.session"] = {
      get = function()
        return { active = true, ai_pending = true, ai_completed = 2, ai_total = 5 }
      end,
    }
    local layout = make_layout()
    local buf = vim.api.nvim_create_buf(false, true)
    local state = make_state()
    state.ai_suggestions = {
      { file = "src/a.lua", status = "pending" },
      { file = "src/b.lua", status = "accepted" },
    }
    assert.has_no_error(function()
      layout.render(buf, state)
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
