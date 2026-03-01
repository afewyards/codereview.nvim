local render = require("codereview.pipeline.render")

describe("pipeline.render", function()
  local pipeline = { id = 123, status = "running", duration = 222, web_url = "url" }
  local stages = {
    { name = "build", jobs = {
      { id = 1, name = "compile", status = "success", duration = 62, allow_failure = false },
      { id = 2, name = "lint", status = "failed", duration = 15, allow_failure = true },
    }},
    { name = "test", jobs = {
      { id = 3, name = "unit", status = "running", duration = 0, allow_failure = false },
    }},
    { name = "deploy", jobs = {
      { id = 4, name = "staging", status = "manual", duration = 0, allow_failure = false },
    }},
  }

  it("builds_lines returns lines and highlights", function()
    local result = render.build_lines(pipeline, stages, {})
    assert.truthy(result.lines)
    assert.truthy(result.highlights)
    assert.truthy(#result.lines > 0)
    -- Header line contains pipeline id and status
    assert.truthy(result.lines[1]:match("123"))
    assert.truthy(result.lines[1]:match("running"))
  end)

  it("includes stage headers", function()
    local result = render.build_lines(pipeline, stages, {})
    local has_build = false
    for _, line in ipairs(result.lines) do
      if line:match("build") then has_build = true end
    end
    assert.is_true(has_build)
  end)

  it("shows allow_failure tag", function()
    local result = render.build_lines(pipeline, stages, {})
    local has_af = false
    for _, line in ipairs(result.lines) do
      if line:match("allow failure") then has_af = true end
    end
    assert.is_true(has_af)
  end)

  it("collapses stages when collapsed table has the stage name", function()
    local result = render.build_lines(pipeline, stages, { build = true })
    -- Jobs under "build" should not appear
    local has_compile = false
    for _, line in ipairs(result.lines) do
      if line:match("compile") then has_compile = true end
    end
    assert.is_false(has_compile)
  end)

  it("row_map maps line numbers to stage/job", function()
    local result = render.build_lines(pipeline, stages, {})
    assert.truthy(result.row_map)
    -- At least one row should map to a job
    local has_job = false
    for _, entry in pairs(result.row_map) do
      if entry.job then has_job = true end
    end
    assert.is_true(has_job)
  end)
end)
