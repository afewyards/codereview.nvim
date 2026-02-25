local parser = require("codereview.mr.diff_parser")

describe("diff_parser", function()
  describe("parse_hunks", function()
    it("parses a simple unified diff into hunks", function()
      local diff_text = table.concat({
        "@@ -10,3 +10,4 @@",
        " context line",
        "-removed line",
        "+added line",
        "+another added",
        " trailing context",
      }, "\n")

      local hunks = parser.parse_hunks(diff_text)
      assert.equals(1, #hunks)
      assert.equals(10, hunks[1].old_start)
      assert.equals(10, hunks[1].new_start)
      assert.equals(5, #hunks[1].lines)
    end)

    it("classifies line types correctly", function()
      local diff_text = "@@ -1,3 +1,3 @@\n context\n-old\n+new\n"
      local hunks = parser.parse_hunks(diff_text)
      local lines = hunks[1].lines
      assert.equals("context", lines[1].type)
      assert.equals("delete", lines[2].type)
      assert.equals("add", lines[3].type)
    end)

    it("computes old_line and new_line for each line", function()
      local diff_text = "@@ -5,3 +5,4 @@\n ctx\n-del\n+add1\n+add2\n ctx2\n"
      local hunks = parser.parse_hunks(diff_text)
      local lines = hunks[1].lines
      assert.equals(5, lines[1].old_line)
      assert.equals(5, lines[1].new_line)
      assert.equals(6, lines[2].old_line)
      assert.is_nil(lines[2].new_line)
      assert.is_nil(lines[3].old_line)
      assert.equals(6, lines[3].new_line)
      assert.is_nil(lines[4].old_line)
      assert.equals(7, lines[4].new_line)
      assert.equals(7, lines[5].old_line)
      assert.equals(8, lines[5].new_line)
    end)
  end)

  describe("build_display hunk boundaries", function()
    it("inserts hunk_boundary between two hunks", function()
      local diff_text = table.concat({
        "@@ -1,3 +1,3 @@",
        " ctx",
        "-old",
        "+new",
        " ctx",
        "@@ -20,3 +20,3 @@",
        " ctx",
        "-old2",
        "+new2",
        " ctx",
      }, "\n")
      local hunks = parser.parse_hunks(diff_text)
      local display = parser.build_display(hunks, 99999)
      local boundaries = {}
      for i, item in ipairs(display) do
        if item.type == "hunk_boundary" then
          table.insert(boundaries, i)
        end
      end
      assert.equals(1, #boundaries)
    end)

    it("does not insert hunk_boundary for single hunk", function()
      local diff_text = "@@ -1,3 +1,3 @@\n ctx\n-old\n+new\n ctx\n"
      local hunks = parser.parse_hunks(diff_text)
      local display = parser.build_display(hunks, 99999)
      for _, item in ipairs(display) do
        assert.is_not.equals("hunk_boundary", item.type)
      end
    end)
  end)

  describe("word_diff", function()
    it("finds changed segments between two lines", function()
      local old = "local resp = curl.post(url, { body = token })"
      local new = "local resp, err = curl.post(url, {"
      local segments = parser.word_diff(old, new)
      assert.truthy(#segments > 0)
    end)
  end)
end)
