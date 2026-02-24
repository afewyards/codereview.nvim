-- lua/codereview/review/init.lua
local ai_sub = require("codereview.ai.subprocess")
local prompt_mod = require("codereview.ai.prompt")
local M = {}

function M.start(review, diff_state, layout)
  local diffs = diff_state.files
  local discussions = diff_state.discussions

  local review_prompt
  local use_orchestrator = #diffs > 1
  if use_orchestrator then
    review_prompt = prompt_mod.build_orchestrator_prompt(review, diffs)
  else
    review_prompt = prompt_mod.build_review_prompt(review, diffs)
  end

  local session = require("codereview.review.session")
  session.start()

  local job_id = ai_sub.run(review_prompt, function(output, ai_err)
    session.ai_finish()

    if ai_err then
      vim.notify("AI review failed: " .. ai_err, vim.log.levels.ERROR)
      return
    end

    local suggestions = prompt_mod.parse_review_output(output)
    if #suggestions == 0 then
      vim.notify("AI review: no issues found!", vim.log.levels.INFO)
      return
    end

    vim.notify(string.format("AI review: %d suggestions found", #suggestions), vim.log.levels.INFO)

    vim.schedule(function()
      diff_state.ai_suggestions = suggestions

      local diff_mod = require("codereview.mr.diff")

      -- Switch to diff view if currently in summary mode
      if diff_state.view_mode ~= "diff" then
        diff_state.view_mode = "diff"
        diff_state.current_file = diff_state.current_file or 1
      end

      if diff_state.scroll_mode then
        local result = diff_mod.render_all_files(
          layout.main_buf, diff_state.files, diff_state.review,
          diff_state.discussions, diff_state.context,
          diff_state.file_contexts, suggestions
        )
        diff_state.file_sections = result.file_sections
        diff_state.scroll_line_data = result.line_data
        diff_state.scroll_row_disc = result.row_discussions
        diff_state.scroll_row_ai = result.row_ai
      else
        local file = diff_state.files and diff_state.files[diff_state.current_file]
        if file then
          local ld, rd, ra = diff_mod.render_file_diff(
            layout.main_buf, file, diff_state.review,
            diff_state.discussions, diff_state.context, suggestions
          )
          diff_state.line_data_cache[diff_state.current_file] = ld
          diff_state.row_disc_cache[diff_state.current_file] = rd
          diff_state.row_ai_cache[diff_state.current_file] = ra
        end
      end
      diff_mod.render_sidebar(layout.sidebar_buf, diff_state)
      vim.api.nvim_set_current_win(layout.main_win)
    end)
  end, { skip_agent = use_orchestrator })

  if job_id and job_id > 0 then
    session.ai_start(job_id)
    vim.notify("AI review started…", vim.log.levels.INFO)
  end
end

return M
