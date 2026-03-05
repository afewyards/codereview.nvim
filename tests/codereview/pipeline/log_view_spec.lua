local log_view = require("codereview.pipeline.log_view")

describe("pipeline.log_view", function()
  it("exports open and close functions", function()
    assert.is_function(log_view.open)
    assert.is_function(log_view.close)
  end)

  describe("build_display", function()
    it("renders collapsed sections with line count", function()
      local parsed = {
        prefix = {},
        sections = {
          { title = "Build", lines = { "line1", "line2", "line3" }, collapsed = true, has_errors = false },
          { title = "Test", lines = { "output" }, collapsed = true, has_errors = false },
        },
      }
      local display = log_view.build_display(parsed)
      assert.equal(2, #display.lines)
      assert.truthy(display.lines[1]:find("▸"))
      assert.truthy(display.lines[1]:find("Build"))
      assert.truthy(display.lines[1]:find("3 lines"))
      assert.equal(1, display.section_map[1])
      assert.equal(2, display.section_map[2])
    end)

    it("renders expanded sections with indented content", function()
      local parsed = {
        prefix = {},
        sections = {
          { title = "Build", lines = { "compiling..." }, collapsed = false, has_errors = false },
        },
      }
      local display = log_view.build_display(parsed)
      assert.equal(2, #display.lines) -- header + 1 content line
      assert.truthy(display.lines[1]:find("▾"))
      assert.truthy(display.lines[1]:find("Build"))
      assert.truthy(display.lines[2]:find("^  ")) -- 2-space indent
    end)

    it("renders prefix lines before sections", function()
      local parsed = {
        prefix = { "preamble line" },
        sections = {
          { title = "Step", lines = { "x" }, collapsed = true, has_errors = false },
        },
      }
      local display = log_view.build_display(parsed)
      assert.equal(2, #display.lines)
      assert.equal("preamble line", display.lines[1])
      assert.is_nil(display.section_map[1]) -- prefix row, not a section
      assert.equal(1, display.section_map[2])
    end)

    it("respects max_lines truncation", function()
      local lines = {}
      for i = 1, 100 do
        table.insert(lines, "line " .. i)
      end
      local parsed = {
        prefix = {},
        sections = {
          { title = "Big", lines = lines, collapsed = false, has_errors = false },
        },
      }
      local display = log_view.build_display(parsed, 10)
      assert.truthy(#display.lines <= 10)
    end)
  end)
end)
