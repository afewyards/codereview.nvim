-- lua/codereview/mr/diff_sidebar.lua
-- Sidebar and summary rendering for the diff viewer.
-- Handles the file-list sidebar, session stats, and MR summary view.

local M = {}

-- nvim_create_namespace returns the same ID for the same name — safe to declare
-- in multiple modules.
local SUMMARY_NS = vim.api.nvim_create_namespace("codereview_summary")

-- ─── Sidebar rendering ────────────────────────────────────────────────────────

function M.render_sidebar(buf, state)
  local sidebar_layout = require("codereview.mr.sidebar_layout")
  sidebar_layout.render(buf, state)
end

-- ─── Summary rendering ────────────────────────────────────────────────────────

function M.render_summary(buf, state)
  vim.schedule(function()
    local split = require("codereview.ui.split")
    if split.saved_visual then
      vim.api.nvim_set_hl(0, "Visual", split.saved_visual)
    end
  end)
  local detail = require("codereview.mr.detail")
  local win_width = (state.layout and state.layout.main_win)
    and vim.api.nvim_win_get_width(state.layout.main_win)
    or tonumber(vim.o.columns) or 80
  local pane_width = math.floor(win_width * 0.8)

  local header = detail.build_header_lines(state.review, pane_width)
  local lines = {}
  for _, l in ipairs(header.lines) do table.insert(lines, l) end

  local activity = detail.build_activity_lines(state.discussions, pane_width)
  for _, line in ipairs(activity.lines) do
    table.insert(lines, line)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Clear old summary highlights
  vim.api.nvim_buf_clear_namespace(buf, SUMMARY_NS, 0, -1)

  local header_count = #header.lines

  -- Apply header (description) highlights
  for _, hl in ipairs(header.highlights) do
    pcall(vim.api.nvim_buf_set_extmark, buf, SUMMARY_NS, hl[1], hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
    })
  end

  -- Activity lines start after header
  for _, hl in ipairs(activity.highlights) do
    local row = header_count + hl[1]  -- 0-indexed row in buffer
    pcall(vim.api.nvim_buf_set_extmark, buf, SUMMARY_NS, row, hl[2], {
      end_col = hl[3],
      hl_group = hl[4],
    })
  end

  -- Apply treesitter syntax highlighting to code blocks
  local all_code_blocks = {}
  if header.code_blocks then
    for _, cb in ipairs(header.code_blocks) do
      table.insert(all_code_blocks, cb)
    end
  end
  if activity.code_blocks then
    for _, cb in ipairs(activity.code_blocks) do
      table.insert(all_code_blocks, {
        start_row = header_count + cb.start_row,
        end_row = header_count + cb.end_row,
        lang = cb.lang,
        text = cb.text,
        indent = cb.indent,
      })
    end
  end

  for _, cb in ipairs(all_code_blocks) do
    if cb.lang and cb.lang ~= "" then
      local ok, parser = pcall(vim.treesitter.get_string_parser, cb.text, cb.lang)
      if ok and parser then
        local trees = parser:parse()
        if trees and trees[1] then
          local root = trees[1]:root()
          local query_ok, query = pcall(vim.treesitter.query.get, cb.lang, "highlights")
          if query_ok and query then
            for id, node in query:iter_captures(root, cb.text, 0, -1) do
              local name = query.captures[id]
              local sr, sc, er, ec = node:range()
              pcall(vim.api.nvim_buf_set_extmark, buf, SUMMARY_NS,
                cb.start_row + sr, sc + cb.indent,
                { end_row = cb.start_row + er, end_col = ec + cb.indent, hl_group = "@" .. name })
            end
          end
        end
      end
    end
  end

  -- Build summary row map (buffer row -> discussion)
  state.summary_row_map = {}
  for offset, entry in pairs(activity.row_map) do
    state.summary_row_map[header_count + offset + 1] = entry  -- +1 for 1-indexed rows
  end

  vim.bo[buf].modifiable = false

  -- Enable soft wrap for long lines
  if state.layout and state.layout.main_win then
    vim.wo[state.layout.main_win].wrap = true
    vim.wo[state.layout.main_win].linebreak = true
  end
end

return M
