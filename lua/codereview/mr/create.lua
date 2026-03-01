local providers = require("codereview.providers")
local client = require("codereview.api.client")
local ai_providers = require("codereview.ai.providers")
local prompt_mod = require("codereview.ai.prompt")
local M = {}

local SEPARATOR_PATTERN = "^[─━─-][─━─-][─━─-]"

function M.parse_editor_fields(lines)
  local fields = {}
  local sep_idx = nil
  for i, line in ipairs(lines) do
    if line:match(SEPARATOR_PATTERN) then
      sep_idx = i
      break
    end
    local key, value = line:match("^(%w+):%s*(.*)$")
    if key then
      key = key:lower()
      value = vim.trim(value)
      if key == "title" then
        fields.title = value ~= "" and value or nil
      elseif key == "target" then
        fields.target = value
      end
    end
  end
  local desc_start = sep_idx and sep_idx + 1 or (#lines + 1)
  if not sep_idx then
    for i, line in ipairs(lines) do
      if not line:match("^%w+:%s") then
        desc_start = i
        break
      end
    end
  end
  local desc_lines = {}
  for i = desc_start, #lines do
    table.insert(desc_lines, lines[i])
  end
  fields.description = vim.trim(table.concat(desc_lines, "\n"))
  return fields
end

function M.ensure_pushed(branch)
  local upstream = vim.fn.systemlist({ "git", "rev-parse", "--abbrev-ref", branch .. "@{upstream}" })
  local has_upstream = vim.v.shell_error == 0 and #upstream > 0
  if not has_upstream then
    vim.notify("Pushing " .. branch .. " to origin...", vim.log.levels.INFO)
    vim.fn.systemlist({ "git", "push", "--set-upstream", "origin", branch })
    if vim.v.shell_error ~= 0 then return false, "Failed to push branch" end
    return true
  end
  local head = vim.fn.systemlist({ "git", "rev-parse", "HEAD" })
  local up_rev = vim.fn.systemlist({ "git", "rev-parse", "@{upstream}" })
  if vim.v.shell_error == 0 and #head > 0 and #up_rev > 0 and head[1] == up_rev[1] then
    return true
  end
  vim.notify("Pushing " .. branch .. "...", vim.log.levels.INFO)
  vim.fn.systemlist({ "git", "push" })
  if vim.v.shell_error ~= 0 then return false, "Failed to push branch" end
  return true
end

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

function M.fetch_remote_branches()
  local result = vim.fn.systemlist({ "git", "ls-remote", "--heads", "origin" })
  if vim.v.shell_error ~= 0 then return {} end
  local branches = {}
  for _, line in ipairs(result) do
    local branch = line:match("\trefs/heads/(.+)$")
    if branch then table.insert(branches, branch) end
  end
  return branches
end

local DRAFT_LABELS = { "No Draft", "Draft" }

function M.build_mr_footer(is_draft, target)
  local label = is_draft and DRAFT_LABELS[2] or DRAFT_LABELS[1]
  return {
    { " ", "CodeReviewFloatFooterText" },
    { "◀", "CodeReviewFloatFooterKey" },
    { " " .. label .. " ", "CodeReviewFloatFooterText" },
    { "▶", "CodeReviewFloatFooterKey" },
    { "  ", "CodeReviewFloatFooterText" },
    { "<C-t>", "CodeReviewFloatFooterKey" },
    { " " .. (target or "main") .. " ", "CodeReviewFloatFooterText" },
    { " ", "CodeReviewFloatFooterText" },
    { "<C-s>", "CodeReviewFloatFooterKey" },
    { " submit ", "CodeReviewFloatFooterText" },
  }
end

function M.open_editor(title, description, target, callback)
  local buf = vim.api.nvim_create_buf(false, true)
  local state = {
    draft = false,
    target = target or "main",
  }

  local lines = { title or "" }
  for _, line in ipairs(vim.split(description or "", "\n")) do
    table.insert(lines, line)
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "wipe"

  -- Virtual separator after line 1 (title)
  local ns = vim.api.nvim_create_namespace("codereview_mr_separator")
  local sep_width = math.min(88, vim.o.columns - 12)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_lines = { { { string.rep("─", sep_width), "CodeReviewFloatBorder" } } },
    virt_lines_above = false,
  })

  local width = math.min(90, vim.o.columns - 10)
  local height = math.min(#lines + 6, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " Create MR/PR ",
    title_pos = "center",
    footer = M.build_mr_footer(state.draft, state.target),
    footer_pos = "center",
  })

  local function update_footer()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_config(win, {
        footer = M.build_mr_footer(state.draft, state.target),
        footer_pos = "center",
      })
    end
  end

  local function toggle_draft()
    state.draft = not state.draft
    update_footer()
  end

  local function pick_target()
    local branches = M.fetch_remote_branches()
    if #branches == 0 then
      vim.notify("No remote branches found", vim.log.levels.WARN)
      return
    end
    vim.ui.select(branches, { prompt = "Target branch:" }, function(choice)
      if not choice then return end
      state.target = choice
      update_footer()
    end)
  end

  local map_opts = { buffer = buf, nowait = true }

  vim.keymap.set({ "n", "i" }, "<Tab>", toggle_draft, map_opts)
  vim.keymap.set({ "n", "i" }, "<S-Tab>", toggle_draft, map_opts)
  vim.keymap.set({ "n", "i" }, "<C-t>", pick_target, map_opts)

  vim.keymap.set("n", "<C-s>", function()
    local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local title_text = vim.trim(buf_lines[1] or "")
    if title_text == "" then
      vim.notify("Title cannot be empty", vim.log.levels.WARN)
      return
    end
    local desc_lines = {}
    for i = 2, #buf_lines do
      table.insert(desc_lines, buf_lines[i])
    end
    vim.api.nvim_win_close(win, true)
    callback({
      title = title_text,
      description = vim.trim(table.concat(desc_lines, "\n")),
      target = state.target,
      draft = state.draft,
    })
  end, map_opts)

  vim.keymap.set("n", "q", function()
    vim.api.nvim_win_close(win, true)
  end, map_opts)
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
  local ok, push_err = M.ensure_pushed(branch)
  if not ok then
    vim.notify("Push failed: " .. (push_err or ""), vim.log.levels.ERROR)
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
      vim.notify("AI failed: " .. err, vim.log.levels.ERROR)
      return
    end
    local title, description = prompt_mod.parse_mr_draft(output)
    M.open_editor(title, description, target, function(fields)
      M.submit_mr(branch, fields)
    end)
  end)
end

function M.submit_mr(source_branch, fields)
  local provider, ctx, err = providers.detect()
  if not provider then
    vim.notify("Could not detect platform: " .. (err or ""), vim.log.levels.ERROR)
    return
  end
  local result, post_err = provider.create_review(client, ctx, {
    source_branch = source_branch,
    target_branch = fields.target,
    title = fields.title,
    description = fields.description,
    draft = fields.draft,
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
