local M = {}
local git = require("codereview.git")
local ai_providers = require("codereview.ai.providers")
local plan_prompt = require("codereview.plan.prompt")
local orchestrator = require("codereview.ai.orchestrator")
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
  spinner.start(" Planning files… ")

  M._run_phase2(branch, base, diffs)
end

function M._run_phase2(branch, base, diffs)
  local total = #diffs
  local completed_count = 0
  spinner.set_label(string.format(" Planning 0/%d files… ", total))

  orchestrator.run({
    diffs = diffs,
    cacheable = true,
    build_prompt = function(batch)
      return plan_prompt.build_file_plan_prompt(batch[1])
    end,
    parse_output = plan_prompt.parse_file_plan_output,
    on_result = function() end,
    on_batch_complete = function()
      completed_count = completed_count + 1
      spinner.set_label(string.format(" Planning %d/%d files… ", completed_count, total))
    end,
    on_error = function(err, batch)
      local p = batch[1].new_path or batch[1].old_path
      log.warn("Plan failed for " .. (p or "?") .. ": " .. err)
      completed_count = completed_count + 1
      spinner.set_label(string.format(" Planning %d/%d files… ", completed_count, total))
    end,
    on_complete = function(all_tasks)
      M._run_phase3(branch, base, all_tasks)
    end,
    provider_opts = { skip_agent = true },
  })
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
