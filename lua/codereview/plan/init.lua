local M = {}
local git = require("codereview.git")
local ai_providers = require("codereview.ai.providers")
local ai_prompt = require("codereview.ai.prompt")
local plan_prompt = require("codereview.plan.prompt")
local spinner = require("codereview.ui.spinner")
local log = require("codereview.log")

function M.resolve_base(arg)
  if arg and arg ~= "" then
    if git.branch_exists(arg) then
      return arg, nil
    end
    return nil, "Branch '" .. arg .. "' does not exist"
  end

  local default = git.get_default_base()
  if default then
    return default, nil
  end
  return nil, "No main/master branch found. Specify base: :CodeReviewPlan <base>"
end

function M.get_output_path(branch)
  local date = os.date("%Y-%m-%d")
  local sanitized = git.sanitize_branch_name(branch)
  local root = git.get_repo_root() or "."
  return root .. "/docs/plans/" .. date .. "-" .. sanitized .. "-plan.md"
end

function M.start(base_arg)
  local base, err = M.resolve_base(base_arg)
  if err then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  local branch = git.get_current_branch()
  if not branch then
    vim.notify("Could not determine current branch", vim.log.levels.ERROR)
    return
  end

  if branch == base then
    vim.notify("Current branch is the same as base (" .. base .. ")", vim.log.levels.WARN)
    return
  end

  local diffs = git.diff_against_base(base)
  if #diffs == 0 then
    vim.notify("No changes found between " .. base .. " and " .. branch, vim.log.levels.INFO)
    return
  end

  vim.notify(string.format("Generating plan: %s → %s (%d files)", base, branch, #diffs), vim.log.levels.INFO)
  spinner.start(" Summarizing files… ")

  -- Phase 1: Summary
  local summary_prompt = ai_prompt.build_summary_prompt({ title = branch, description = "" }, diffs)
  ai_providers.get().run(summary_prompt, function(output, ai_err)
    if ai_err then
      spinner.stop()
      vim.notify("Summary failed: " .. ai_err, vim.log.levels.ERROR)
      return
    end

    local summaries = ai_prompt.parse_summary_output(output)
    M._run_phase2(branch, base, diffs, summaries)
  end, { skip_agent = true })
end

function M._run_phase2(branch, base, diffs, summaries)
  local all_tasks = {}
  local completed = 0
  local total = #diffs

  spinner.set_label(string.format(" Planning 0/%d files… ", total))

  for _, file in ipairs(diffs) do
    local file_prompt = plan_prompt.build_file_plan_prompt(file, summaries)

    ai_providers.get().run(file_prompt, function(output, ai_err)
      completed = completed + 1
      spinner.set_label(string.format(" Planning %d/%d files… ", completed, total))

      if ai_err then
        local path = file.new_path or file.old_path
        log.warn("Plan failed for " .. path .. ": " .. ai_err)
      else
        local tasks = plan_prompt.parse_file_plan_output(output)
        for _, t in ipairs(tasks) do
          table.insert(all_tasks, t)
        end
      end

      if completed >= total then
        M._run_phase3(branch, base, all_tasks)
      end
    end, { skip_agent = true })
  end
end

function M._run_phase3(branch, base, tasks)
  if #tasks == 0 then
    spinner.stop()
    vim.notify("No tasks identified — code looks complete!", vim.log.levels.INFO)
    return
  end

  spinner.set_label(" Writing plan… ")

  local combine_prompt = plan_prompt.build_combine_prompt(branch, base, tasks)
  ai_providers.get().run(combine_prompt, function(output, ai_err)
    spinner.stop()

    local summary = ""
    if ai_err then
      log.warn("Summary generation failed: " .. ai_err)
    else
      summary = plan_prompt.parse_summary(output)
    end

    local markdown = plan_prompt.format_plan_markdown(branch, base, summary, tasks)
    local path = M.get_output_path(branch)

    -- Ensure directory exists
    local dir = path:match("(.+)/[^/]+$")
    if dir then
      vim.fn.mkdir(dir, "p")
    end

    local file = io.open(path, "w")
    if file then
      file:write(markdown)
      file:close()
      vim.notify("Plan written to " .. path, vim.log.levels.INFO)
      vim.schedule(function()
        vim.cmd("edit " .. path)
      end)
    else
      vim.notify("Failed to write plan to " .. path, vim.log.levels.ERROR)
    end
  end, { skip_agent = true })
end

return M
