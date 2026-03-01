-- tests/codereview/mr/create_spec.lua
-- Stub vim globals for unit testing
_G.vim = _G.vim or {}
vim.trim = vim.trim or function(s) return s:match("^%s*(.-)%s*$") end
vim.split = vim.split or function(s, sep)
  local parts = {}
  for part in (s .. sep):gmatch("(.-)" .. sep) do table.insert(parts, part) end
  return parts
end

local prompt_mod = require("codereview.ai.prompt")
local create = require("codereview.mr.create")

describe("parse_editor_fields", function()
  it("extracts title, target, and description with separator", function()
    local lines = {
      "Title: My feature",
      "Target: main",
      "───────────────",
      "This is the description.",
    }
    local fields = create.parse_editor_fields(lines)
    assert.equals("My feature", fields.title)
    assert.equals("main", fields.target)
    assert.equals("This is the description.", fields.description)
    assert.equals(false, fields.draft)
  end)

  it("defaults draft to false", function()
    local lines = { "Title: Test", "───" }
    local fields = create.parse_editor_fields(lines)
    assert.equals(false, fields.draft)
  end)

  it("parses draft = yes as true", function()
    local lines = { "Title: Test", "Draft: yes", "───" }
    local fields = create.parse_editor_fields(lines)
    assert.equals(true, fields.draft)
  end)

  it("parses draft = true as true", function()
    local lines = { "Title: Test", "Draft: true", "───" }
    local fields = create.parse_editor_fields(lines)
    assert.equals(true, fields.draft)
  end)

  it("returns nil title for empty title", function()
    local lines = { "Title: ", "───" }
    local fields = create.parse_editor_fields(lines)
    assert.is_nil(fields.title)
  end)

  it("treats lines after header fields as description when no separator", function()
    local lines = {
      "Title: My feature",
      "Target: main",
      "This is the description.",
      "Second line.",
    }
    local fields = create.parse_editor_fields(lines)
    assert.equals("My feature", fields.title)
    assert.equals("main", fields.target)
    assert.truthy(fields.description:find("This is the description."))
    assert.truthy(fields.description:find("Second line."))
  end)

  it("collects multiple description lines below separator", function()
    local lines = {
      "Title: Feature",
      "───────────────",
      "Line one.",
      "Line two.",
    }
    local fields = create.parse_editor_fields(lines)
    assert.truthy(fields.description:find("Line one."))
    assert.truthy(fields.description:find("Line two."))
  end)

  it("returns empty description when nothing below separator", function()
    local lines = { "Title: Feature", "───" }
    local fields = create.parse_editor_fields(lines)
    assert.equals("", fields.description)
  end)
end)

describe("ensure_pushed", function()
  local orig_systemlist
  local orig_shell_error
  local orig_notify

  before_each(function()
    orig_systemlist = vim.fn.systemlist
    orig_shell_error = vim.v.shell_error
    orig_notify = vim.notify
    vim.notify = function() end
    vim.log = vim.log or { levels = { INFO = 2, WARN = 3, ERROR = 4 } }
  end)

  after_each(function()
    vim.fn.systemlist = orig_systemlist
    vim.v.shell_error = orig_shell_error
    vim.notify = orig_notify
  end)

  it("returns true when upstream exists and HEAD matches upstream", function()
    local calls = {}
    vim.fn.systemlist = function(cmd)
      table.insert(calls, cmd)
      local key = table.concat(cmd, " ")
      if key:find("abbrev%-ref") then
        vim.v.shell_error = 0
        return { "origin/feature" }
      elseif key:find("rev%-parse HEAD") or (cmd[2] == "rev-parse" and cmd[3] == "HEAD") then
        vim.v.shell_error = 0
        return { "abc123" }
      elseif key:find("rev%-parse") and key:find("upstream") or (cmd[3] == "@{upstream}") then
        vim.v.shell_error = 0
        return { "abc123" }
      end
      vim.v.shell_error = 0
      return { "abc123" }
    end

    -- Simulate: upstream check succeeds, HEAD == upstream
    local call_n = 0
    vim.fn.systemlist = function(cmd)
      call_n = call_n + 1
      if call_n == 1 then
        -- git rev-parse --abbrev-ref branch@{upstream}
        vim.v.shell_error = 0
        return { "origin/feature" }
      elseif call_n == 2 then
        -- git rev-parse HEAD
        vim.v.shell_error = 0
        return { "deadbeef" }
      elseif call_n == 3 then
        -- git rev-parse @{upstream}
        vim.v.shell_error = 0
        return { "deadbeef" }
      end
    end

    local ok, err = create.ensure_pushed("feature/my-branch")
    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals(3, call_n)
  end)

  it("pushes with --set-upstream when no upstream exists", function()
    local call_n = 0
    local pushed = false
    vim.fn.systemlist = function(cmd)
      call_n = call_n + 1
      if call_n == 1 then
        -- git rev-parse --abbrev-ref branch@{upstream} → no upstream
        vim.v.shell_error = 1
        return {}
      elseif call_n == 2 then
        -- git push --set-upstream origin branch
        pushed = true
        vim.v.shell_error = 0
        return {}
      end
    end

    local ok, err = create.ensure_pushed("feature/my-branch")
    assert.is_true(ok)
    assert.is_nil(err)
    assert.is_true(pushed)
    assert.equals(2, call_n)
  end)

  it("returns true and pushes when HEAD is ahead of upstream", function()
    local call_n = 0
    local pushed = false
    vim.fn.systemlist = function(cmd)
      call_n = call_n + 1
      if call_n == 1 then
        -- upstream check succeeds
        vim.v.shell_error = 0
        return { "origin/feature" }
      elseif call_n == 2 then
        -- HEAD rev
        vim.v.shell_error = 0
        return { "newcommit" }
      elseif call_n == 3 then
        -- upstream rev (different → ahead)
        vim.v.shell_error = 0
        return { "oldcommit" }
      elseif call_n == 4 then
        -- git push
        pushed = true
        vim.v.shell_error = 0
        return {}
      end
    end

    local ok, err = create.ensure_pushed("feature/my-branch")
    assert.is_true(ok)
    assert.is_nil(err)
    assert.is_true(pushed)
    assert.equals(4, call_n)
  end)

  it("returns false and error message when push fails", function()
    local call_n = 0
    vim.fn.systemlist = function(cmd)
      call_n = call_n + 1
      if call_n == 1 then
        -- no upstream
        vim.v.shell_error = 1
        return {}
      elseif call_n == 2 then
        -- push fails
        vim.v.shell_error = 1
        return {}
      end
    end

    local ok, err = create.ensure_pushed("feature/my-branch")
    assert.is_false(ok)
    assert.is_not_nil(err)
    assert.truthy(err:find("push") or err:find("Push") or err:find("Failed"))
  end)
end)

describe("open_editor", function()
  local captured_lines
  local orig_api, orig_o, orig_bo, orig_keymap, orig_notify, orig_log

  before_each(function()
    captured_lines = nil
    orig_api = vim.api
    orig_o = vim.o
    orig_bo = vim.bo
    orig_keymap = vim.keymap
    orig_notify = vim.notify
    orig_log = vim.log

    vim.api = {
      nvim_create_buf = function() return 1 end,
      nvim_buf_set_lines = function(_, _, _, _, lines) captured_lines = lines end,
      nvim_open_win = function() return 1 end,
      nvim_win_close = function() end,
      nvim_buf_get_lines = function() return {} end,
    }
    vim.o = { columns = 100, lines = 40 }
    vim.bo = setmetatable({}, {
      __index = function(t, k)
        if not rawget(t, k) then rawset(t, k, {}) end
        return rawget(t, k)
      end,
    })
    vim.keymap = { set = function() end }
    vim.notify = function() end
    vim.log = { levels = { INFO = 2, WARN = 3, ERROR = 4 } }
  end)

  after_each(function()
    vim.api = orig_api
    vim.o = orig_o
    vim.bo = orig_bo
    vim.keymap = orig_keymap
    vim.notify = orig_notify
    vim.log = orig_log
  end)

  it("sets buffer lines with Title:, Target:, Draft:, and separator", function()
    create.open_editor("My feature", "Some description", "main", function() end)

    assert.is_not_nil(captured_lines)
    assert.truthy(captured_lines[1]:find("^Title:"))
    assert.truthy(captured_lines[2]:find("^Target:"))
    assert.truthy(captured_lines[3]:find("^Draft:"))
    local has_sep = false
    for _, line in ipairs(captured_lines) do
      if line:match("^[─━─-][─━─-][─━─-]") then
        has_sep = true
        break
      end
    end
    assert.is_true(has_sep)
  end)

  it("includes provided title and target in header", function()
    create.open_editor("Fix bug", "desc", "develop", function() end)

    assert.truthy(captured_lines[1]:find("Fix bug"))
    assert.truthy(captured_lines[2]:find("develop"))
  end)

  it("defaults target to main when nil", function()
    create.open_editor("Title", "desc", nil, function() end)

    assert.truthy(captured_lines[2]:find("main"))
  end)
end)

describe("mr.create prompts", function()
  describe("build_mr_prompt", function()
    it("includes branch name and diff", function()
      local result = prompt_mod.build_mr_prompt("fix/auth-refresh", "@@ diff content @@")
      assert.truthy(result:find("fix/auth%-refresh"))
      assert.truthy(result:find("diff content"))
    end)
  end)

  describe("parse_mr_draft", function()
    it("extracts structured title and description", function()
      local output = "## Title\nFix auth token refresh\n\n## Description\nFixes the bug.\n- Better errors\n"
      local title, desc = prompt_mod.parse_mr_draft(output)
      assert.equals("Fix auth token refresh", title)
      assert.truthy(desc:find("Better errors"))
    end)

    it("falls back to first-line title", function()
      local output = "Fix auth token refresh\n\nFixes the bug."
      local title, desc = prompt_mod.parse_mr_draft(output)
      assert.equals("Fix auth token refresh", title)
      assert.equals("Fixes the bug.", desc)
    end)
  end)
end)
