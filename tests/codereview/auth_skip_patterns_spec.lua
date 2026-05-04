local auth = require("codereview.api.auth")

describe("auth.get_ai_skip_patterns", function()
  before_each(function()
    auth.reset()
  end)

  it("returns empty table when no config file", function()
    local saved_filereadable = vim.fn.filereadable
    vim.fn.filereadable = function(path)
      if path and path:match("%.codereview%.nvim$") then
        return 0
      end
      return saved_filereadable(path)
    end
    local patterns = auth.get_ai_skip_patterns()
    vim.fn.filereadable = saved_filereadable
    assert.same({}, patterns)
  end)

  it("parses comma-separated patterns", function()
    local parse = auth._parse_skip_patterns_for_test
    local result = parse("*.test.ts,docs/**,*.snap")
    assert.same({ "*.test.ts", "docs/**", "*.snap" }, result)
  end)

  it("trims whitespace around patterns", function()
    local parse = auth._parse_skip_patterns_for_test
    local result = parse("  *.test.ts , docs/** ,*.snap  ")
    assert.same({ "*.test.ts", "docs/**", "*.snap" }, result)
  end)

  it("handles empty string", function()
    local parse = auth._parse_skip_patterns_for_test
    local result = parse("")
    assert.same({}, result)
  end)
end)
