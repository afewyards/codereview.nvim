local progress

describe("progress", function()
  before_each(function()
    -- Stub vim APIs needed by progress.lua in the busted environment
    vim.fn.stdpath = function(_)
      return os.getenv("TMPDIR") or "/tmp"
    end
    vim.uv = vim.uv or {}
    vim.uv.fs_stat = function(path)
      local f = io.open(path, "r")
      if f then
        f:close()
        return {}
      end
      return nil
    end
    vim.uv.new_timer = function()
      return {
        start = function() end,
        stop = function() end,
        close = function() end,
      }
    end
    vim.schedule_wrap = vim.schedule_wrap or function(fn)
      return fn
    end

    package.loaded["codereview.ai.progress"] = nil
    progress = require("codereview.ai.progress")
  end)

  it("creates tmp file and counts appended lines", function()
    local p = progress.new()
    assert.is_string(p.path)
    assert.are.equal(0, p:count())
    local f = io.open(p.path, "a")
    f:write("a\n")
    f:close()
    f = io.open(p.path, "a")
    f:write("b\n")
    f:close()
    assert.are.equal(2, p:count())
    p:cleanup()
    assert.is_nil(vim.uv.fs_stat(p.path))
  end)

  it("count returns 0 when progress file has no lines", function()
    local p = progress.new()
    assert.are.equal(0, p:count())
    p:cleanup()
  end)

  it("cleanup removes the tmp file", function()
    local p = progress.new()
    local path = p.path
    -- File exists before cleanup
    assert.is_not_nil(vim.uv.fs_stat(path))
    p:cleanup()
    -- File gone after cleanup
    assert.is_nil(vim.uv.fs_stat(path))
  end)
end)
