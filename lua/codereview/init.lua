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
  if not active then
    vim.notify("Open a diff view first with :CodeReview", vim.log.levels.WARN)
    return
  end
  require("codereview.review").start(active.state.review, active.state, active.layout)
end

function M.submit()
  local session = require("codereview.review.session")
  local buf = vim.api.nvim_get_current_buf()
  local diff_mod = require("codereview.mr.diff")
  local active = diff_mod.get_state(buf)

  if active then
    local submit_mod = require("codereview.review.submit")
    if session.get().ai_pending then
      vim.notify("AI review still running — publishing available drafts", vim.log.levels.WARN)
    end
    submit_mod.submit_and_publish(active.state.review, active.state.ai_suggestions)
    session.stop()
    diff_mod.render_sidebar(active.layout.sidebar_buf, active.state)
    return
  end

  local review = vim.b[buf].codereview_review
  if not review then
    vim.notify("No review context. Open a review first with :CodeReview", vim.log.levels.WARN)
    return
  end
  require("codereview.review.submit").bulk_publish(review)
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
