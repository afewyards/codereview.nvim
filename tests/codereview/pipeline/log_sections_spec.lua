local log_sections = require("codereview.pipeline.log_sections")

describe("pipeline.log_sections", function()
  describe("parse", function()
    it("returns empty sections for plain text", function()
      local result = log_sections.parse("line1\nline2\nline3")
      assert.equal(3, #result.prefix)
      assert.equal(0, #result.sections)
    end)

    it("parses GitHub group markers", function()
      local trace = table.concat({
        "##[group]Set up job",
        "10:30:45 downloading actions...",
        "10:30:46 complete",
        "##[endgroup]",
        "##[group]Run tests",
        "10:30:47 running...",
        "##[endgroup]",
      }, "\n")
      local result = log_sections.parse(trace)
      assert.equal(0, #result.prefix)
      assert.equal(2, #result.sections)
      assert.equal("Set up job", result.sections[1].title)
      assert.equal(2, #result.sections[1].lines)
      assert.equal("10:30:45 downloading actions...", result.sections[1].lines[1])
      assert.equal("Run tests", result.sections[2].title)
      assert.equal(1, #result.sections[2].lines)
    end)

    it("parses GitLab section markers", function()
      local trace = table.concat({
        "\27[0Ksection_start:1234567890.0:prepare_executor\r\27[0KPreparing executor",
        "Using Shell executor...",
        "\27[0Ksection_end:1234567891.0:prepare_executor\r\27[0K",
        "\27[0Ksection_start:1234567892.0:build_script\r\27[0KRunning build",
        "make all",
        "\27[0Ksection_end:1234567893.0:build_script\r\27[0K",
      }, "\n")
      local result = log_sections.parse(trace)
      assert.equal(0, #result.prefix)
      assert.equal(2, #result.sections)
      assert.equal("Preparing executor", result.sections[1].title)
      assert.equal(1, #result.sections[1].lines)
      assert.equal("Running build", result.sections[2].title)
    end)

    it("captures prefix lines before first section", function()
      local trace = table.concat({
        "some preamble",
        "another line",
        "##[group]Step 1",
        "content",
        "##[endgroup]",
      }, "\n")
      local result = log_sections.parse(trace)
      assert.equal(2, #result.prefix)
      assert.equal("some preamble", result.prefix[1])
      assert.equal(1, #result.sections)
    end)

    it("detects error sections from red ANSI", function()
      local trace = table.concat({
        "##[group]Build",
        "all good",
        "##[endgroup]",
        "##[group]Test",
        "\27[31mFAIL: test_foo\27[0m",
        "##[endgroup]",
      }, "\n")
      local result = log_sections.parse(trace)
      assert.is_false(result.sections[1].has_errors)
      assert.is_true(result.sections[2].has_errors)
    end)

    it("handles empty trace", function()
      local result = log_sections.parse("")
      assert.equal(0, #result.prefix)
      assert.equal(0, #result.sections)
    end)

    it("handles unclosed section at end of trace", function()
      local trace = table.concat({
        "##[group]Running",
        "still going...",
      }, "\n")
      local result = log_sections.parse(trace)
      assert.equal(1, #result.sections)
      assert.equal("Running", result.sections[1].title)
      assert.equal(1, #result.sections[1].lines)
    end)

    it("parses GitLab sections with integer-only timestamps", function()
      local trace = table.concat({
        "\27[0Ksection_start:1741234567:build_script\r\27[0KRunning build",
        "make all",
        "\27[0Ksection_end:1741234568:build_script\r\27[0K",
      }, "\n")
      local result = log_sections.parse(trace)
      assert.equal(0, #result.prefix)
      assert.equal(1, #result.sections)
      assert.equal("Running build", result.sections[1].title)
      assert.equal(1, #result.sections[1].lines)
    end)

    it("parses GitLab sections without carriage return", function()
      local trace = table.concat({
        "\27[0Ksection_start:1741234567.0:setup\27[0KSetup environment",
        "installing deps",
        "\27[0Ksection_end:1741234568.0:setup\27[0K",
      }, "\n")
      local result = log_sections.parse(trace)
      assert.equal(0, #result.prefix)
      assert.equal(1, #result.sections)
      assert.equal("Setup environment", result.sections[1].title)
    end)

    it("parses GitLab sections with dots and hyphens in name", function()
      local trace = table.concat({
        "\27[0Ksection_start:1741234567:step_build.artifacts-v2\r\27[0KBuild artifacts",
        "building...",
        "\27[0Ksection_end:1741234568:step_build.artifacts-v2\r\27[0K",
      }, "\n")
      local result = log_sections.parse(trace)
      assert.equal(1, #result.sections)
      assert.equal("Build artifacts", result.sections[1].title)
    end)
  end)
end)
