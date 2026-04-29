describe("CodeReviewPlan integration", function()
  it("plan module loads without error", function()
    local ok, plan = pcall(require, "codereview.plan")
    assert.is_true(ok)
    assert.is_table(plan)
    assert.is_function(plan.start)
    assert.is_function(plan.resolve_base)
    assert.is_function(plan.get_output_path)
  end)

  it("prompt module loads without error", function()
    local ok, prompt = pcall(require, "codereview.plan.prompt")
    assert.is_true(ok)
    assert.is_function(prompt.build_file_plan_prompt)
    assert.is_function(prompt.build_batch_plan_prompt)
    assert.is_function(prompt.parse_file_plan_output)
    assert.is_function(prompt.build_combine_prompt)
    assert.is_function(prompt.parse_summary)
    assert.is_function(prompt.format_plan_markdown)
  end)

  it("git utilities are available", function()
    local git = require("codereview.git")
    assert.is_function(git.get_current_branch)
    assert.is_function(git.branch_exists)
    assert.is_function(git.get_default_base)
    assert.is_function(git.sanitize_branch_name)
    assert.is_function(git.diff_against_base)
  end)

  it("5 small files fit in 1 batch at default budget", function()
    local batch = require("codereview.ai.batch")
    local diffs = {}
    for i = 1, 5 do
      diffs[i] = { new_path = "file" .. i .. ".lua", diff = string.rep("+line\n", 10) }
    end
    -- 5 files × ~60 chars each = ~300 chars, well under default 80 000 budget
    local batches = batch.build(diffs, { char_budget = 80000, max_files = 15 })
    assert.are.equal(1, #batches)
    assert.are.equal(5, #batches[1])
  end)
end)
