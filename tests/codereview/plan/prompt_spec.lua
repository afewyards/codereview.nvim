local prompt = require("codereview.plan.prompt")

describe("plan.prompt.build_file_plan_prompt", function()
  it("includes file path and diff", function()
    local file = {
      new_path = "lua/test.lua",
      diff = "+local x = 1",
    }
    local result = prompt.build_file_plan_prompt(file)
    assert.is_string(result)
    assert.matches("lua/test.lua", result)
    assert.matches("local x = 1", result)
  end)

  it("plan prompt has no Branch Context", function()
    local p = prompt.build_file_plan_prompt({ new_path = "a", diff = "" })
    assert.is_nil(p:find("Branch Context"))
  end)

  it("plan prompt: instructions before diff", function()
    local p = prompt.build_file_plan_prompt({ new_path = "a", diff = "@@\n+UNIQUE_TOKEN_XYZ" })
    local i_instr = p:find("Instructions") or 0
    local i_diff = p:find("UNIQUE_TOKEN_XYZ") or 0
    assert.is_true(i_instr > 0 and i_diff > i_instr)
  end)
end)

describe("plan.prompt.parse_file_plan_output", function()
  it("parses JSON task array", function()
    local output = [[
```json
[{"file": "a.lua", "line": 10, "task": "Add validation", "reason": "Missing check"}]
```
]]
    local tasks = prompt.parse_file_plan_output(output)
    assert.equals(1, #tasks)
    assert.equals("a.lua", tasks[1].file)
    assert.equals(10, tasks[1].line)
    assert.equals("Add validation", tasks[1].task)
  end)

  it("returns empty array for no issues", function()
    local output = "```json\n[]\n```"
    local tasks = prompt.parse_file_plan_output(output)
    assert.equals(0, #tasks)
  end)
end)

describe("plan.prompt.build_combine_prompt", function()
  it("includes all tasks", function()
    local tasks = {
      { file = "a.lua", line = 10, task = "Do X", reason = "Because Y" },
    }
    local result = prompt.build_combine_prompt("feat-test", "main", tasks)
    assert.matches("a.lua", result)
    assert.matches("Do X", result)
  end)
end)

describe("plan.prompt.parse_summary", function()
  it("extracts markdown block", function()
    local output = "```markdown\nThis is a summary.\n```"
    local result = prompt.parse_summary(output)
    assert.equals("This is a summary.", result)
  end)

  it("falls back to trimmed output", function()
    local output = "  Just plain text  "
    local result = prompt.parse_summary(output)
    assert.equals("Just plain text", result)
  end)
end)

describe("plan.prompt.format_plan_markdown", function()
  it("formats tasks as markdown", function()
    local tasks = {
      { file = "a.lua", line = 10, task = "Add validation", reason = "Missing" },
    }
    local result = prompt.format_plan_markdown("feat-test", "main", "Summary here", tasks)
    assert.matches("# Implementation Plan", result)
    assert.matches("a.lua:10", result)
    assert.matches("Add validation", result)
    assert.matches("Summary here", result)
  end)

  it("handles tasks without line numbers", function()
    local tasks = {
      { file = "b.lua", task = "Refactor module", reason = "Complexity" },
    }
    local result = prompt.format_plan_markdown("fix-bug", "main", "Fix summary", tasks)
    assert.matches("b.lua", result)
    assert.matches("Refactor module", result)
  end)
end)
