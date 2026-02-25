-- lua/codereview/mr/sidebar_layout.lua
-- Layout orchestrator: composes all 5 sidebar components into a buffer.
-- Handles the inconsistent component APIs and normalises highlights.

local M = {}

local diff_render = require("codereview.mr.diff_render")
local apply_line_hl = diff_render.apply_line_hl
local apply_word_hl = diff_render.apply_word_hl

-- Re-use the same namespace as the rest of the sidebar.
local DIFF_NS = vim.api.nvim_create_namespace("codereview_diff")

local WIDTH = 30

-- ─── Highlight normalisation ──────────────────────────────────────────────────

--- Normalise component highlights into `out`, offsetting rows by `offset`.
---
--- Components use two different formats:
---   • Positional (header):  { 0indexed_row, col_start, col_end, hl_group }
---   • Named (status/footer): { row=N (1-indexed), line_hl=...|word_hl=... }
---
--- Output entries always use: { row0 (0-indexed), line_hl?, word_hl?, hl_group?,
---                               col_start?, col_end? }
local function normalise_highlights(highlights, offset, out)
  for _, hl in ipairs(highlights or {}) do
    if hl.row then
      -- Named format: row is 1-indexed
      table.insert(out, {
        row0      = offset + hl.row - 1,
        line_hl   = hl.line_hl,
        word_hl   = hl.word_hl,
        col_start = hl.col_start,
        col_end   = hl.col_end,
      })
    else
      -- Positional format: hl[1] is 0-indexed row
      table.insert(out, {
        row0      = offset + hl[1],
        col_start = hl[2],
        col_end   = hl[3],
        hl_group  = hl[4],
      })
    end
  end
end

--- Apply a single normalised highlight entry to the buffer.
local function apply_hl(buf, hl)
  if hl.line_hl then
    pcall(apply_line_hl, buf, hl.row0, hl.line_hl)
  elseif hl.word_hl then
    pcall(apply_word_hl, buf, hl.row0, hl.col_start or 0, hl.col_end or 0, hl.word_hl)
  elseif hl.hl_group then
    if hl.col_start and hl.col_end then
      pcall(apply_word_hl, buf, hl.row0, hl.col_start, hl.col_end, hl.hl_group)
    else
      pcall(apply_line_hl, buf, hl.row0, hl.hl_group)
    end
  end
end

-- ─── Range + row_map helpers ─────────────────────────────────────────────────

--- Record a component's line range (1-indexed, inclusive) in state.sidebar_component_ranges.
local function record_range(state, name, offset, count)
  state.sidebar_component_ranges[name] = {
    start  = offset + 1,
    ["end"] = offset + count,
  }
end

--- Merge numeric-keyed row_map entries into state.sidebar_row_map, offsetting by `offset`.
local function merge_row_map(state, row_map, offset)
  for k, v in pairs(row_map or {}) do
    if type(k) == "number" then
      state.sidebar_row_map[offset + k] = v
    end
  end
end

-- ─── Public render ────────────────────────────────────────────────────────────

--- Render all sidebar components into `buf`.
--- @param buf   integer  buffer handle
--- @param state table    diff viewer state
function M.render(buf, state)
  local header_comp        = require("codereview.mr.sidebar_components.header")
  local status_comp        = require("codereview.mr.sidebar_components.status")
  local summary_button_comp = require("codereview.mr.sidebar_components.summary_button")
  local file_tree_comp     = require("codereview.mr.sidebar_components.file_tree")
  local footer_comp        = require("codereview.mr.sidebar_components.footer")

  local all_lines      = {}
  local all_highlights = {}

  state.sidebar_component_ranges = {}
  state.sidebar_row_map          = {}

  -- ── 1. Header ──────────────────────────────────────────────────────────────
  -- API: render(review, width) → { lines, highlights, row_map }
  local header_res = header_comp.render(state.review or {}, WIDTH)
  local header_offset = #all_lines
  record_range(state, "header", header_offset, #header_res.lines)
  for _, l in ipairs(header_res.lines) do table.insert(all_lines, l) end
  normalise_highlights(header_res.highlights, header_offset, all_highlights)
  merge_row_map(state, header_res.row_map, header_offset)

  -- Blank separator after header
  table.insert(all_lines, "")

  -- ── 2. Status ──────────────────────────────────────────────────────────────
  -- API: render(state, width) → { lines, highlights, row_map }
  local status_res    = status_comp.render(state, WIDTH)
  local status_offset = #all_lines
  record_range(state, "status", status_offset, #status_res.lines)
  for _, l in ipairs(status_res.lines) do table.insert(all_lines, l) end
  normalise_highlights(status_res.highlights, status_offset, all_highlights)
  -- Named row_map keys (e.g. status/drafts/threads) are not numeric — skip

  -- Blank separator after status only when it rendered content
  if #status_res.lines > 0 then
    table.insert(all_lines, "")
  end

  -- ── 3. Summary button + 4. File tree ───────────────────────────────────────
  -- Both use the mutable pattern: render(state, lines, row_map) with no return.
  -- summary_button appends 2 lines (button + blank); file_tree appends file rows.
  local mid_lines   = {}
  local mid_row_map = {}

  summary_button_comp.render(state, mid_lines, mid_row_map)
  local sb_count = #mid_lines   -- lines owned by summary_button (2)

  file_tree_comp.render(state, mid_lines, mid_row_map)
  local ft_count = #mid_lines - sb_count

  local mid_offset = #all_lines
  record_range(state, "summary_button", mid_offset,           sb_count)
  record_range(state, "file_tree",      mid_offset + sb_count, ft_count)

  for _, l in ipairs(mid_lines) do table.insert(all_lines, l) end
  merge_row_map(state, mid_row_map, mid_offset)

  -- No blank separator before footer (per spec)

  -- ── 5. Footer ──────────────────────────────────────────────────────────────
  -- API: build(state, width) → lines, highlights  (two return values; 1-indexed rows)
  local footer_lines, footer_hls = footer_comp.build(state, WIDTH)
  local footer_offset = #all_lines
  record_range(state, "footer", footer_offset, #footer_lines)
  for _, l in ipairs(footer_lines) do table.insert(all_lines, l) end
  normalise_highlights(footer_hls, footer_offset, all_highlights)

  -- ── Write buffer ───────────────────────────────────────────────────────────
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, all_lines)
  vim.bo[buf].modifiable = false

  -- ── Apply highlights ───────────────────────────────────────────────────────
  vim.api.nvim_buf_clear_namespace(buf, DIFF_NS, 0, -1)
  for _, hl in ipairs(all_highlights) do
    apply_hl(buf, hl)
  end
end

return M
