-- lua/codereview/review/init.lua
local providers = require("codereview.providers")
local client = require("codereview.api.client")
local ai_sub = require("codereview.ai.subprocess")
local prompt_mod = require("codereview.ai.prompt")
local triage = require("codereview.review.triage")
local M = {}

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Open a small floating window with an animated spinner.
--- Returns a handle table with :stop() and :close() methods.
local function open_progress_float()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"

  local width = 36
  local height = 1
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " AI Review ",
    title_pos = "center",
    noautocmd = true,
  })

  local frame_idx = 1
  local timer = vim.uv.new_timer()
  timer:start(0, 80, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(buf) then
      timer:stop()
      timer:close()
      return
    end
    local icon = FRAMES[frame_idx]
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, {
      "  " .. icon .. "  Running AI review...",
    })
    frame_idx = frame_idx % #FRAMES + 1
  end))

  return {
    buf = buf,
    win = win,
    stop = function()
      timer:stop()
      timer:close()
    end,
    close = function()
      timer:stop()
      timer:close()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  }
end

function M.start(review, diff_state, layout)
  local diffs, discussions

  if diff_state then
    -- Inline mode: use existing data from diff view
    diffs = diff_state.files
    discussions = diff_state.discussions
  else
    -- Standalone mode: fetch fresh data
    local provider, ctx, err = providers.detect()
    if not provider then
      vim.notify("Could not detect platform: " .. (err or ""), vim.log.levels.ERROR)
      return
    end

    local diffs_err
    diffs, diffs_err = provider.get_diffs(client, ctx, review)
    if not diffs or #diffs == 0 then
      vim.notify("No diffs found: " .. (diffs_err or ""), vim.log.levels.WARN)
      return
    end

    discussions = provider.get_discussions(client, ctx, review) or {}
  end

  local review_prompt = prompt_mod.build_review_prompt(review, diffs)

  -- Show progress float with spinner
  local progress = open_progress_float()

  ai_sub.run(review_prompt, function(output, ai_err)
    progress.close()

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

    if diff_state then
      -- Inline mode: render suggestions directly in diff view
      vim.schedule(function()
        diff_state.ai_suggestions = suggestions

        local diff_mod = require("codereview.mr.diff")
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
          local file = diff_state.files[diff_state.current_file]
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
      end)
    else
      -- Standalone mode: open triage view
      triage.open(review, diffs, discussions, suggestions)
    end
  end)
end

return M
