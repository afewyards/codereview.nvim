local providers = require("codereview.providers")
local client = require("codereview.api.client")
local ai_providers = require("codereview.ai.providers")
local prompt_mod = require("codereview.ai.prompt")
local M = {}

function M.get_current_branch()
  local result = vim.fn.systemlist({ "git", "branch", "--show-current" })
  if vim.v.shell_error ~= 0 or #result == 0 then return nil end
  return vim.trim(result[1])
end

function M.get_branch_diff(target)
  target = target or "main"
  local result = vim.fn.systemlist({ "git", "diff", target .. "...HEAD" })
  if vim.v.shell_error ~= 0 then return nil end
  return table.concat(result, "\n")
end

function M.detect_target_branch()
  local result = vim.fn.systemlist({ "git", "symbolic-ref", "refs/remotes/origin/HEAD" })
  if vim.v.shell_error == 0 and #result > 0 then
    local branch = result[1]:match("refs/remotes/origin/(.+)")
    if branch then return branch end
  end
  return "main"
end

function M.open_editor(title, description, callback)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = { title, "" }
  for _, line in ipairs(vim.split(description, "\n")) do
    table.insert(lines, line)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(80, vim.o.columns - 10)
  local height = math.min(#lines + 5, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " New MR — line 1 = title, rest = description — <CR> submit, q cancel ",
    title_pos = "center",
  })

  vim.keymap.set("n", "<CR>", function()
    local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local new_title = buf_lines[1] or title
    local desc_start = 2
    while desc_start <= #buf_lines and vim.trim(buf_lines[desc_start]) == "" do
      desc_start = desc_start + 1
    end
    local new_desc = table.concat(buf_lines, "\n", desc_start)
    vim.api.nvim_win_close(win, true)
    callback(vim.trim(new_title), vim.trim(new_desc))
  end, { buffer = buf })

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, { buffer = buf })
end

function M.create()
  local branch = M.get_current_branch()
  if not branch then
    vim.notify("Not on a branch", vim.log.levels.ERROR)
    return
  end
  if branch == "main" or branch == "master" then
    vim.notify("Cannot create MR from " .. branch, vim.log.levels.ERROR)
    return
  end

  local target = M.detect_target_branch()
  local diff = M.get_branch_diff(target)
  if not diff or diff == "" then
    vim.notify("No diff found against " .. target, vim.log.levels.WARN)
    return
  end

  local mr_prompt = prompt_mod.build_mr_prompt(branch, diff)
  vim.notify("Generating MR description...", vim.log.levels.INFO)

  ai_providers.get().run(mr_prompt, function(output, err)
    if err then
      vim.notify("Claude CLI failed: " .. err, vim.log.levels.ERROR)
      return
    end

    local title, description = prompt_mod.parse_mr_draft(output)
    M.open_editor(title, description, function(final_title, final_desc)
      M.submit_mr(branch, target, final_title, final_desc)
    end)
  end)
end

function M.submit_mr(source_branch, target_branch, title, description)
  local provider, ctx, err = providers.detect()
  if not provider then
    vim.notify("Could not detect platform: " .. (err or ""), vim.log.levels.ERROR)
    return
  end

  local result, post_err = provider.create_review(client, ctx, {
    source_branch = source_branch,
    target_branch = target_branch,
    title = title,
    description = description,
  })

  if not result then
    vim.notify("Failed to create MR: " .. (post_err or ""), vim.log.levels.ERROR)
    return
  end

  local mr = result.data
  if mr then
    local url = mr.web_url or mr.html_url or ""
    local id = mr.iid or mr.number or mr.id
    vim.notify(string.format("MR #%s created: %s", id, url), vim.log.levels.INFO)
  end
end

return M
