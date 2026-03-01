-- lua/codereview/review/init.lua
local ai_providers = require("codereview.ai.providers")
local prompt_mod = require("codereview.ai.prompt")
local diff_state_mod = require("codereview.mr.diff_state")
local log = require("codereview.log")
local M = {}

--- Generate AI summary with callback tracking.
--- Sets ai_summary_pending, calls summary_mod.generate, fires ai_summary_callbacks on completion.
local function generate_summary_with_callbacks(diff_state, review, diffs)
  diff_state.ai_summary_pending = true
  local summary_mod = require("codereview.ai.summary")
  summary_mod.generate(review, diffs, diff_state.ai_suggestions, function(text, gen_err)
    vim.schedule(function()
      if gen_err then
        vim.notify("AI summary failed: " .. gen_err, vim.log.levels.WARN)
      else
        diff_state.ai_review_summary = text
      end
      diff_state.ai_summary_pending = false
      for _, cb in ipairs(diff_state.ai_summary_callbacks or {}) do
        cb(gen_err and nil or text)
      end
      diff_state.ai_summary_callbacks = {}
    end)
  end)
end

--- Render suggestions for a single file into the diff view.
local function render_file_suggestions(diff_state, layout, suggestions)
  vim.schedule(function()
    -- Merge new suggestions into existing list
    diff_state.ai_suggestions = diff_state.ai_suggestions or {}
    for _, s in ipairs(suggestions) do
      table.insert(diff_state.ai_suggestions, s)
    end

    local diff_mod = require("codereview.mr.diff")

    -- Re-render current view to show new suggestions
    if diff_state.scroll_mode then
      local result = diff_mod.render_all_files(
        layout.main_buf, diff_state.files, diff_state.review,
        diff_state.discussions, diff_state.context,
        diff_state.file_contexts, diff_state.ai_suggestions,
        diff_state.row_selection, diff_state.current_user
      )
      diff_state_mod.apply_scroll_result(diff_state, result)
    else
      local file = diff_state.files and diff_state.files[diff_state.current_file]
      if file then
        local ld, rd, ra = diff_mod.render_file_diff(
          layout.main_buf, file, diff_state.review,
          diff_state.discussions, diff_state.context,
          diff_state.ai_suggestions,
          diff_state.row_selection, diff_state.current_user
        )
        diff_state_mod.apply_file_result(diff_state, diff_state.current_file, ld, rd, ra)
      end
    end
    diff_mod.render_sidebar(layout.sidebar_buf, diff_state)
    local cur_win = vim.api.nvim_get_current_win()
    if cur_win == layout.main_win or cur_win == layout.sidebar_win then
      vim.api.nvim_set_current_win(layout.main_win)
    end
  end)
end

--- Fetch file content if available, respecting max_file_size.
--- Returns content string or nil.
local function fetch_file_content(diff_state, review, path, deleted)
  if deleted then return nil end
  local provider = diff_state.provider
  local ctx = diff_state.ctx
  if not provider or not provider.get_file_content or not ctx then return nil end

  local cfg = require("codereview.config").get()
  local max_size = cfg.ai.max_file_size or 500
  if max_size == 0 then return nil end

  local client = require("codereview.api.client")
  local content, err = provider.get_file_content(client, ctx, review.head_sha, path)
  if not content then
    if err then log.debug("AI: could not fetch content for " .. path .. ": " .. err) end
    return nil
  end

  -- Check line count
  local line_count = 1
  for _ in content:gmatch("\n") do line_count = line_count + 1 end
  if line_count > max_size then
    log.debug(string.format("AI: skipping content for %s (%d lines > %d max)", path, line_count, max_size))
    return nil
  end

  return content
end

--- Single-file review (unchanged behavior).
local function start_single(review, diff_state, layout)
  local diffs = diff_state.files
  local review_prompt = prompt_mod.build_review_prompt(review, diffs)
  local session = require("codereview.review.session")
  session.start()

  local job_id = ai_providers.get().run(review_prompt, function(output, ai_err)
    session.ai_finish()

    if ai_err then
      vim.notify("AI review failed: " .. ai_err, vim.log.levels.ERROR)
      return
    end

    local suggestions = prompt_mod.parse_review_output(output)
    suggestions = prompt_mod.filter_unchanged_lines(suggestions, diffs)
    if #suggestions == 0 then
      vim.notify("AI review: no issues found!", vim.log.levels.INFO)
      return
    end

    vim.notify(string.format("AI review: %d suggestions found", #suggestions), vim.log.levels.INFO)

    diff_state.ai_suggestions = {}

    vim.schedule(function()
      if diff_state.view_mode ~= "diff" then
        diff_state.view_mode = "diff"
        diff_state.current_file = diff_state.current_file or 1
      end
    end)

    render_file_suggestions(diff_state, layout, suggestions)

    generate_summary_with_callbacks(diff_state, review, diffs)
  end)

  if job_id and job_id > 0 then
    session.ai_start(job_id)
    vim.notify("AI review started…", vim.log.levels.INFO)
  end
end

--- Multi-file review: Phase 1 (summary) then Phase 2 (parallel per-file).
local function start_multi(review, diff_state, layout)
  local diffs = diff_state.files
  local session = require("codereview.review.session")
  local spinner = require("codereview.ui.spinner")
  session.start()

  diff_state.ai_suggestions = {}

  -- Switch to diff view
  if diff_state.view_mode ~= "diff" then
    diff_state.view_mode = "diff"
    diff_state.current_file = diff_state.current_file or 1
  end

  -- Phase 1: summary pre-pass
  local summary_prompt = prompt_mod.build_summary_prompt(review, diffs)
  local summary_job = ai_providers.get().run(summary_prompt, function(output, ai_err)
    if ai_err then
      session.ai_finish()
      vim.notify("AI summary failed: " .. ai_err, vim.log.levels.ERROR)
      return
    end

    local summaries = prompt_mod.parse_summary_output(output)

    -- Phase 2: parallel per-file reviews
    local total = #diffs
    local job_ids = {}

    for _, file in ipairs(diffs) do
      local path = file.new_path or file.old_path
      local content = fetch_file_content(diff_state, review, path, file.deleted_file)
      local file_prompt = prompt_mod.build_file_review_prompt(review, file, summaries, content)

      local file_job = ai_providers.get().run(file_prompt, function(file_output, file_err)
        if file_err then
          vim.notify("AI review failed for " .. path .. ": " .. file_err, vim.log.levels.WARN)
        else
          local suggestions = prompt_mod.parse_review_output(file_output)
          suggestions = prompt_mod.filter_unchanged_lines(suggestions, { file })
          if #suggestions > 0 then
            render_file_suggestions(diff_state, layout, suggestions)
          end
        end

        -- Update progress
        local s = session.get()
        spinner.set_label(string.format(" AI reviewing… %d/%d files ", s.ai_completed + 1, s.ai_total))

        vim.schedule(function()
          local diff_mod = require("codereview.mr.diff")
          diff_mod.render_sidebar(layout.sidebar_buf, diff_state)
        end)

        session.ai_file_done()

        -- All done?
        if not session.get().ai_pending then
          local count = #(diff_state.ai_suggestions or {})
          if count == 0 then
            vim.schedule(function()
              vim.notify("AI review: no issues found!", vim.log.levels.INFO)
            end)
          else
            vim.schedule(function()
              vim.notify(string.format("AI review: %d suggestions found", count), vim.log.levels.INFO)
            end)
          end
          generate_summary_with_callbacks(diff_state, review, diffs)
        end
      end)

      if file_job and file_job > 0 then
        table.insert(job_ids, file_job)
      end
    end

    -- Store all job IDs for cancellation; update session with real counts
    session.ai_start(job_ids, total)
    spinner.set_label(string.format(" AI reviewing… 0/%d files ", total))
  end, { skip_agent = true }) -- no --agent for summary call

  if summary_job and summary_job > 0 then
    -- Use summary job as initial tracking; will be replaced in Phase 2
    session.ai_start(summary_job)
    spinner.set_label(" AI summarizing… ")
    vim.notify("AI review started (summarizing files)…", vim.log.levels.INFO)
  end
end

--- Single-file AI review: summarize all files, then review only the current file.
function M.start_file(review, diff_state, layout)
  local diffs = diff_state.files
  local file_idx = diff_state.current_file or 1
  local target = diffs[file_idx]
  if not target then
    vim.notify("No file selected for AI review", vim.log.levels.WARN)
    return
  end

  local target_path = target.new_path or target.old_path
  local session = require("codereview.review.session")
  local spinner = require("codereview.ui.spinner")
  session.start()

  -- Phase 1: summary pre-pass
  local summary_prompt = prompt_mod.build_summary_prompt(review, diffs)
  local summary_job = ai_providers.get().run(summary_prompt, function(output, ai_err)
    if ai_err then
      session.ai_finish()
      vim.notify("AI summary failed: " .. ai_err, vim.log.levels.ERROR)
      return
    end

    local summaries = prompt_mod.parse_summary_output(output)

    -- Phase 2: review the single target file
    local content = fetch_file_content(diff_state, review, target_path, target.deleted_file)
    local file_prompt = prompt_mod.build_file_review_prompt(review, target, summaries, content)
    local file_job = ai_providers.get().run(file_prompt, function(file_output, file_err)
      session.ai_finish()

      if file_err then
        vim.notify("AI review failed for " .. target_path .. ": " .. file_err, vim.log.levels.ERROR)
        return
      end

      local suggestions = prompt_mod.parse_review_output(file_output)
      suggestions = prompt_mod.filter_unchanged_lines(suggestions, { target })
      if #suggestions == 0 then
        vim.notify("AI review: no issues found in " .. target_path, vim.log.levels.INFO)
        return
      end

      vim.notify(string.format("AI review: %d suggestions for %s", #suggestions, target_path), vim.log.levels.INFO)

      -- Replace only this file's suggestions (preserve others)
      local kept = {}
      for _, s in ipairs(diff_state.ai_suggestions or {}) do
        if s.file ~= target_path then
          table.insert(kept, s)
        end
      end
      diff_state.ai_suggestions = kept

      render_file_suggestions(diff_state, layout, suggestions)

      generate_summary_with_callbacks(diff_state, review, diffs)
    end)

    if file_job and file_job > 0 then
      session.ai_start(file_job)
      spinner.set_label(string.format(" AI reviewing %s… ", target_path))
    end
  end, { skip_agent = true })

  if summary_job and summary_job > 0 then
    session.ai_start(summary_job)
    spinner.set_label(" AI summarizing… ")
    vim.notify(string.format("AI file review started for %s…", target_path), vim.log.levels.INFO)
  end
end

function M.start(review, diff_state, layout)
  local diffs = diff_state.files
  if #diffs <= 1 then
    start_single(review, diff_state, layout)
  else
    start_multi(review, diff_state, layout)
  end
end

return M
