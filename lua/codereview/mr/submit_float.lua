local comment_float = require("codereview.mr.comment_float")
local M = {}

local ACTIONS = { "Comment", "Approve", "Request Changes" }
local ACTION_EVENTS = {
	["Comment"] = "COMMENT",
	["Approve"] = "APPROVE",
	["Request Changes"] = "REQUEST_CHANGES",
}

--- Build footer tuples for the current action.
local function build_footer(action_idx)
	return {
		{ " ", "CodeReviewFloatFooterText" },
		{ "◀", "CodeReviewFloatFooterKey" },
		{ " " .. ACTIONS[action_idx] .. " ", "CodeReviewFloatFooterText" },
		{ "▶", "CodeReviewFloatFooterKey" },
		{ "  ", "CodeReviewFloatFooterText" },
		{ "<C-s>", "CodeReviewFloatFooterKey" },
		{ " submit ", "CodeReviewFloatFooterText" },
	}
end

--- Open the submit review float.
--- @param opts table { prefill?: string, on_submit: fun(body: string, event: string) }
function M.open(opts)
	opts = opts or {}
	local action_idx = 1

	local handle = comment_float.open("Submit Review", {
		prefill = opts.prefill,
	})

	-- Set initial footer
	vim.api.nvim_win_set_config(handle.win, {
		footer = build_footer(action_idx),
		footer_pos = "center",
	})

	local function cycle(delta)
		action_idx = ((action_idx - 1 + delta) % #ACTIONS) + 1
		if vim.api.nvim_win_is_valid(handle.win) then
			vim.api.nvim_win_set_config(handle.win, {
				footer = build_footer(action_idx),
				footer_pos = "center",
			})
		end
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

	-- Start in insert mode for empty buffer, normal for prefilled
	if opts.prefill and opts.prefill ~= "" then
		vim.cmd("stopinsert")
	else
		vim.cmd("startinsert")
	end

	return handle
end

return M
