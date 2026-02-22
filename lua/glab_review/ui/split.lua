local M = {}

function M.create(opts)
  opts = opts or {}
  local sidebar_width = opts.sidebar_width or 30

  -- Create a new tab for the review
  vim.cmd("tabnew")

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

  -- Set up layout: sidebar left, main right
  local main_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(main_win, main_buf)

  vim.cmd("topleft " .. sidebar_width .. "vnew")
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

  -- Focus main pane
  vim.api.nvim_set_current_win(main_win)

  return {
    sidebar_buf = sidebar_buf,
    sidebar_win = sidebar_win,
    main_buf = main_buf,
    main_win = main_win,
    tab = vim.api.nvim_get_current_tabpage(),
  }
end

function M.close(layout)
  if layout and layout.tab then
    pcall(function()
      local tab_nr = vim.api.nvim_tabpage_get_number(layout.tab)
      vim.cmd("tabclose " .. tab_nr)
    end)
  end
end

return M
