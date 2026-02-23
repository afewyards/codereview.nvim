local M = {}

function M.create(opts)
  opts = opts or {}
  local sidebar_width = opts.sidebar_width or 30

  -- Create sidebar buffer
  local sidebar_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[sidebar_buf].bufhidden = "wipe"
  vim.bo[sidebar_buf].buftype = "nofile"
  vim.bo[sidebar_buf].swapfile = false

  -- Create main buffer
  local main_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[main_buf].bufhidden = "wipe"
  vim.bo[main_buf].buftype = "nofile"
  vim.bo[main_buf].swapfile = false

  -- Use current window as main
  local main_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(main_win, main_buf)

  -- Create sidebar split to the left
  vim.cmd("topleft " .. sidebar_width .. "vsplit")
  local sidebar_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(sidebar_win, sidebar_buf)

  -- Sidebar options
  vim.wo[sidebar_win].number = false
  vim.wo[sidebar_win].relativenumber = false
  vim.wo[sidebar_win].signcolumn = "no"
  vim.wo[sidebar_win].winfixwidth = true
  vim.wo[sidebar_win].wrap = false
  vim.wo[sidebar_win].cursorline = true

  -- Main pane options
  vim.wo[main_win].number = false
  vim.wo[main_win].relativenumber = false
  vim.wo[main_win].signcolumn = "yes"
  vim.wo[main_win].wrap = false

  -- Override Visual highlight when in the diff buffer
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = main_buf,
    callback = function()
      M.saved_visual = vim.api.nvim_get_hl(0, { name = "Visual" })
      vim.api.nvim_set_hl(0, "Visual", { bg = "#1e2030", fg = "#565f89", italic = true })
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = main_buf,
    callback = function()
      if M.saved_visual then
        vim.api.nvim_set_hl(0, "Visual", M.saved_visual)
      end
    end,
  })

  -- Focus main pane
  vim.api.nvim_set_current_win(main_win)

  return {
    sidebar_buf = sidebar_buf,
    sidebar_win = sidebar_win,
    main_buf = main_buf,
    main_win = main_win,
  }
end

function M.close(layout)
  if not layout then return end
  if M.saved_visual then
    vim.api.nvim_set_hl(0, "Visual", M.saved_visual)
    M.saved_visual = nil
  end
  pcall(vim.api.nvim_set_current_win, layout.main_win)
  pcall(vim.api.nvim_win_close, layout.sidebar_win, true)
end

return M
