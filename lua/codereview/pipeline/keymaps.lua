-- lua/codereview/pipeline/keymaps.lua
-- Keymap bindings for the pipeline float buffer.
local M = {}

M.KEYS = {
  toggle       = { "<CR>", "l" },
  retry        = { "r" },
  cancel       = { "c" },
  play         = { "p" },
  open_browser = { "o" },
  refresh      = { "R" },
  close        = { "q", "<Esc>" },
  view_log     = { "<CR>" },
}

--- Set up keymaps on a pipeline float buffer.
--- @param buf number  buffer handle
--- @param pstate table  pipeline state
--- @param handle table  float handle { close }
--- @param callbacks table  { on_refresh, on_toggle, on_log, on_retry, on_cancel, on_play, on_browser }
function M.setup(buf, pstate, handle, callbacks)
  local opts = { noremap = true, silent = true, nowait = true, buffer = buf }

  -- Close
  for _, key in ipairs(M.KEYS.close) do
    vim.keymap.set("n", key, function()
      handle.close()
    end, vim.tbl_extend("force", opts, { desc = "Close pipeline" }))
  end

  -- Toggle expand/collapse or open log
  for _, key in ipairs(M.KEYS.toggle) do
    vim.keymap.set("n", key, function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      if callbacks.on_toggle then callbacks.on_toggle(row) end
    end, vim.tbl_extend("force", opts, { desc = "Toggle stage / View log" }))
  end

  -- Retry
  for _, key in ipairs(M.KEYS.retry) do
    vim.keymap.set("n", key, function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      if callbacks.on_retry then callbacks.on_retry(row) end
    end, vim.tbl_extend("force", opts, { desc = "Retry job" }))
  end

  -- Cancel
  for _, key in ipairs(M.KEYS.cancel) do
    vim.keymap.set("n", key, function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      if callbacks.on_cancel then callbacks.on_cancel(row) end
    end, vim.tbl_extend("force", opts, { desc = "Cancel job" }))
  end

  -- Play (manual)
  for _, key in ipairs(M.KEYS.play) do
    vim.keymap.set("n", key, function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      if callbacks.on_play then callbacks.on_play(row) end
    end, vim.tbl_extend("force", opts, { desc = "Play manual job" }))
  end

  -- Open in browser
  for _, key in ipairs(M.KEYS.open_browser) do
    vim.keymap.set("n", key, function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      if callbacks.on_browser then callbacks.on_browser(row) end
    end, vim.tbl_extend("force", opts, { desc = "Open in browser" }))
  end

  -- Force refresh
  for _, key in ipairs(M.KEYS.refresh) do
    vim.keymap.set("n", key, function()
      if callbacks.on_refresh then callbacks.on_refresh() end
    end, vim.tbl_extend("force", opts, { desc = "Force refresh" }))
  end
end

return M
