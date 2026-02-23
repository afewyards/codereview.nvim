local M = {}

function M.setup(opts)
  require("codereview.config").setup(opts)
  require("codereview.ui.highlight").setup()
  vim.api.nvim_create_autocmd("ColorScheme", {
    callback = function()
      require("codereview.ui.highlight").setup()
    end,
  })
end

-- Stubs for later stages
function M.open()
  local mr_list = require("codereview.mr.list")
  local picker = require("codereview.picker")
  local detail = require("codereview.mr.detail")

  mr_list.fetch({}, function(entries, err)
    if err then
      vim.notify("Failed to load reviews: " .. err, vim.log.levels.ERROR)
      return
    end
    if not entries or #entries == 0 then
      vim.notify("No open reviews found", vim.log.levels.INFO)
      return
    end

    vim.schedule(function()
      picker.pick_mr(entries, function(selected)
        detail.open(selected)
      end)
    end)
  end)
end
function M.pipeline() vim.notify("Pipeline not yet implemented (Stage 4)", vim.log.levels.WARN) end
function M.ai_review()
  local buf = vim.api.nvim_get_current_buf()
  local diff_mod = require("codereview.mr.diff")
  local active = diff_mod.get_state(buf)
  if active then
    -- Called from diff view: use inline mode
    require("codereview.review").start(active.state.review, active.state, active.layout)
    return
  end
  -- Fallback: try buffer-local review variable
  local review = vim.b[buf].codereview_review
  if not review then
    vim.notify("No review context. Open a review first with :CodeReview", vim.log.levels.WARN)
    return
  end
  require("codereview.review").start(review)
end

function M.submit()
  local buf = vim.api.nvim_get_current_buf()
  local diff_mod = require("codereview.mr.diff")
  local active = diff_mod.get_state(buf)
  local session = require("codereview.review.session")
  local submit_mod = require("codereview.review.submit")
  if active then
    local state = active.state
    local layout = active.layout
    -- Warn if AI still running
    if session.get().ai_pending then
      vim.notify("AI review still running — publishing available drafts", vim.log.levels.WARN)
    end
    -- Post remaining accepted AI suggestions as drafts
    if state.ai_suggestions then
      local accepted = submit_mod.filter_accepted(state.ai_suggestions)
      if #accepted > 0 then
        local client_mod = require("codereview.api.client")
        local provider, ctx, err = require("codereview.providers").detect()
        if provider then
          for _, suggestion in ipairs(accepted) do
            local _, post_err = provider.create_draft_comment(client_mod, ctx, state.review, {
              body = suggestion.comment,
              path = suggestion.file,
              line = suggestion.line,
            })
            if not post_err then suggestion.drafted = true end
          end
        else
          vim.notify("Could not detect platform: " .. (err or ""), vim.log.levels.ERROR)
        end
      end
    end
    -- Publish all drafts (human + AI)
    submit_mod.bulk_publish(state.review)
    -- End review session and re-render sidebar
    session.stop()
    diff_mod.render_sidebar(layout.sidebar_buf, state)
    return
  end
  -- Fallback: buffer-local review
  local review = vim.b[buf].codereview_review
  if not review then
    vim.notify("No review context. Open a review first with :CodeReview", vim.log.levels.WARN)
    return
  end
  submit_mod.bulk_publish(review)
  session.stop()
end
function M.approve()
  local buf = vim.api.nvim_get_current_buf()
  local mr = vim.b[buf].codereview_review
  if not mr then
    vim.notify("No review context in current buffer", vim.log.levels.WARN)
    return
  end
  require("codereview.mr.actions").approve(mr)
end
function M.create_mr()
  require("codereview.mr.create").create()
end

function M.start_review()
  local session = require("codereview.review.session")
  if session.get().active then
    vim.notify("Review already in progress", vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local diff_mod = require("codereview.mr.diff")
  local active = diff_mod.get_state(buf)
  if not active then
    vim.notify("Open a diff view first", vim.log.levels.WARN)
    return
  end
  session.start()
  diff_mod.render_sidebar(active.layout.sidebar_buf, active.state)
  vim.notify("Review started — comments will be drafts until published", vim.log.levels.INFO)
end

return M
