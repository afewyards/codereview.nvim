local comment_float = require("codereview.mr.comment_float")
local spinner = require("codereview.ui.spinner")
local M = {}

local ACTIONS = { "Comment", "Approve", "Request Changes" }
local ACTION_EVENTS = {
	["Comment"] = "COMMENT",
	["Approve"] = "APPROVE",
	["Request Changes"] = "REQUEST_CHANGES",
}

--- Build footer tuples for the current action and summary state.
local function build_footer(action_idx, summary_state)
	local parts = {
		{ " ", "CodeReviewFloatFooterText" },
		{ "◀", "CodeReviewFloatFooterKey" },
		{ " " .. ACTIONS[action_idx] .. " ", "CodeReviewFloatFooterText" },
		{ "▶", "CodeReviewFloatFooterKey" },
		{ "  ", "CodeReviewFloatFooterText" },
		{ "<C-s>", "CodeReviewFloatFooterKey" },
		{ " submit ", "CodeReviewFloatFooterText" },
	}
	if summary_state == "idle" then
		table.insert(parts, { "  ", "CodeReviewFloatFooterText" })
		table.insert(parts, { "<C-g>", "CodeReviewFloatFooterKey" })
		table.insert(parts, { " summary ", "CodeReviewFloatFooterText" })
	elseif summary_state == "ready" then
		table.insert(parts, { "  ", "CodeReviewFloatFooterText" })
		table.insert(parts, { "<C-g>", "CodeReviewFloatFooterKey" })
		table.insert(parts, { " insert summary ", "CodeReviewFloatFooterText" })
	end
	return parts
end

--- Open the submit review float.
--- @param opts table { prefill?: string, diff_state?: table, on_submit: fun(body: string, event: string) }
function M.open(opts)
	opts = opts or {}
	local action_idx = 1

	-- Determine initial summary state
	local summary_state
	if opts.prefill and opts.prefill ~= "" then
		summary_state = "loaded"
	elseif opts.diff_state and opts.diff_state.ai_summary_pending then
		summary_state = "generating"
	else
		summary_state = "idle"
	end

	local pending_summary = nil
	local timer = nil
	local frame_idx = 1
	local summary_cb = nil

	local handle = comment_float.open("Submit Review", {
		prefill = opts.prefill,
	})

	local function update_footer()
		if vim.api.nvim_win_is_valid(handle.win) then
			vim.api.nvim_win_set_config(handle.win, {
				footer = build_footer(action_idx, summary_state),
				footer_pos = "center",
			})
		end
	end

	local function start_spinner()
		if timer then return end
		-- Insert spinner as first line
		if vim.api.nvim_buf_is_valid(handle.buf) then
			vim.api.nvim_buf_set_lines(handle.buf, 0, 0, false,
				{ " " .. spinner.FRAMES[frame_idx] .. " Generating summary..." })
		end
		timer = vim.uv.new_timer()
		timer:start(0, 80, function()
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(handle.buf) then return end
				frame_idx = (frame_idx % #spinner.FRAMES) + 1
				vim.api.nvim_buf_set_lines(handle.buf, 0, 1, false,
					{ " " .. spinner.FRAMES[frame_idx] .. " Generating summary..." })
			end)
		end)
	end

	-- Override get_text to skip placeholder line when in generating/ready state
	local original_get_text = handle.get_text
	handle.get_text = function()
		if summary_state == "generating" or summary_state == "ready" then
			local lines = vim.api.nvim_buf_get_lines(handle.buf, 1, -1, false)
			return vim.trim(table.concat(lines, "\n"))
		end
		return original_get_text()
	end

	local function cycle(delta)
		action_idx = ((action_idx - 1 + delta) % #ACTIONS) + 1
		update_footer()
	end

	local function submit()
		local body = handle.get_text()
		local event = ACTION_EVENTS[ACTIONS[action_idx]]
		handle.close()
		if opts.on_submit then
			opts.on_submit(body, event)
		end
	end

	local map_opts = { buffer = handle.buf, nowait = true }
	vim.keymap.set("n", "q", handle.close, map_opts)
	vim.keymap.set("n", "<Esc>", handle.close, map_opts)
	vim.keymap.set({ "n", "i" }, "<C-CR>", submit, map_opts)
	vim.keymap.set({ "n", "i" }, "<C-s>", submit, map_opts)
	vim.keymap.set({ "n", "i" }, "<Tab>", function()
		cycle(1)
	end, map_opts)
	vim.keymap.set({ "n", "i" }, "<S-Tab>", function()
		cycle(-1)
	end, map_opts)

	vim.keymap.set({ "n", "i" }, "<C-g>", function()
		if summary_state == "idle" and opts.diff_state then
			summary_state = "generating"
			start_spinner()
			update_footer()
			local summary_mod = require("codereview.ai.summary")
			summary_mod.generate(
				opts.diff_state.review,
				opts.diff_state.files,
				opts.diff_state.ai_suggestions or {},
				function(text, gen_err)
					vim.schedule(function()
						if handle.closed then return end
						if timer then timer:stop(); timer:close(); timer = nil end
						if gen_err or not text then
							summary_state = "idle"
							if vim.api.nvim_buf_is_valid(handle.buf) then
								vim.api.nvim_buf_set_lines(handle.buf, 0, 1, false, {})
							end
							if gen_err then
								vim.notify("Summary failed: " .. gen_err, vim.log.levels.WARN)
							end
						else
							pending_summary = text
							summary_state = "ready"
							if vim.api.nvim_buf_is_valid(handle.buf) then
								vim.api.nvim_buf_set_lines(handle.buf, 0, 1, false,
									{ "-- Summary ready. Press <C-g> to insert --" })
							end
						end
						update_footer()
					end)
				end
			)
		elseif summary_state == "ready" and pending_summary then
			summary_state = "loaded"
			local lines = vim.split(pending_summary, "\n")
			vim.api.nvim_buf_set_lines(handle.buf, 0, 1, false, lines)
			pending_summary = nil
			update_footer()
		elseif summary_state == "idle" then
			vim.notify("No review context available for summary generation", vim.log.levels.INFO)
		end
	end, map_opts)

	-- Cleanup timer and stale callbacks on buffer wipeout
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = handle.buf,
		once = true,
		callback = function()
			handle.closed = true
			if timer then timer:stop(); timer:close(); timer = nil end
			if opts.diff_state then
				local cbs = opts.diff_state.ai_summary_callbacks
				for i = #cbs, 1, -1 do
					if cbs[i] == summary_cb then
						table.remove(cbs, i)
						break
					end
				end
			end
		end,
	})

	-- Prevent cursor from landing on spinner line (line 1) while generating/ready
	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = handle.buf,
		callback = function()
			if handle.closed then return true end
			if summary_state ~= "generating" and summary_state ~= "ready" then return end
			local row = vim.api.nvim_win_get_cursor(handle.win)[1]
			if row == 1 then
				local line_count = vim.api.nvim_buf_line_count(handle.buf)
				vim.api.nvim_win_set_cursor(handle.win, { math.min(2, line_count), 0 })
			end
		end,
	})

	-- Initial state setup
	if summary_state == "generating" then
		start_spinner()
		-- Register callback for background generation completing
		if opts.diff_state and opts.diff_state.ai_summary_callbacks then
			summary_cb = function(text)
				vim.schedule(function()
					if handle.closed then return end
					if timer then timer:stop(); timer:close(); timer = nil end
					if text then
						pending_summary = text
						summary_state = "ready"
						if vim.api.nvim_buf_is_valid(handle.buf) then
							vim.api.nvim_buf_set_lines(handle.buf, 0, 1, false,
								{ "-- Summary ready. Press <C-g> to insert --" })
						end
					else
						summary_state = "idle"
						if vim.api.nvim_buf_is_valid(handle.buf) then
							vim.api.nvim_buf_set_lines(handle.buf, 0, 1, false, {})
						end
					end
					update_footer()
				end)
			end
			table.insert(opts.diff_state.ai_summary_callbacks, summary_cb)
		end
	end

	-- Set initial footer
	update_footer()

	-- Start in insert mode for empty buffer, normal for prefilled
	if opts.prefill and opts.prefill ~= "" then
		vim.cmd("stopinsert")
	else
		vim.cmd("startinsert")
	end

	return handle
end

return M
