local file_tree = require("codereview.mr.sidebar_components.file_tree")

describe("sidebar_components.file_tree", function()
  local function make_discussion(path, resolved)
    return {
      notes = { { position = { new_path = path } } },
      resolved = resolved or false,
      local_draft = false,
    }
  end

  it("displays counts in N ⚠N AI:N format (no emoji badges)", function()
    local state = {
      view_mode = "diff",
      current_file = 2,
      collapsed_dirs = {},
      file_review_status = {},
      discussions = {
        make_discussion("src/a.lua"),
        make_discussion("src/a.lua"),
        make_discussion("src/a.lua", true),  -- resolved: not unresolved
        make_discussion("src/a.lua"),         -- unresolved
      },
      ai_suggestions = {
        { file = "src/a.lua", status = "pending" },
        { file = "src/a.lua", status = "dismissed" },  -- excluded
      },
      files = {
        { new_path = "src/a.lua", old_path = "src/a.lua" },
      },
    }
    local lines, row_map = {}, {}
    file_tree.render(state, lines, row_map)

    local joined = table.concat(lines, "\n")
    -- Comment count: simple number, no brackets
    assert.truthy(joined:find(" 4"), "Should show comment count as plain number")
    assert.falsy(joined:find("%[4%]"), "Should NOT use [N] bracket format")
    -- Unresolved: ⚠N format
    assert.truthy(joined:find("⚠3"), "Should show 3 unresolved with ⚠ prefix")
    -- AI: AI:N format, not emoji
    assert.truthy(joined:find("AI:1"), "Should show AI count as AI:N")
    assert.falsy(joined:find("🤖"), "Should NOT use robot emoji")
  end)

  it("shows correct review status icon for each status", function()
    local state = {
      view_mode = "diff",
      current_file = 99,  -- no file is current
      collapsed_dirs = {},
      discussions = {},
      ai_suggestions = {},
      file_review_status = {
        ["reviewed.lua"] = { status = "reviewed" },
        ["partial.lua"]  = { status = "partial" },
        -- unvisited.lua has no entry
      },
      files = {
        { new_path = "reviewed.lua", old_path = "reviewed.lua" },
        { new_path = "partial.lua",  old_path = "partial.lua" },
        { new_path = "unvisited.lua", old_path = "unvisited.lua" },
      },
    }
    local lines, row_map = {}, {}
    file_tree.render(state, lines, row_map)

    -- Find lines for each file
    local reviewed_line, partial_line, unvisited_line
    for row, entry in pairs(row_map) do
      if entry.type == "file" then
        if entry.path == "reviewed.lua" then reviewed_line = lines[row]
        elseif entry.path == "partial.lua" then partial_line = lines[row]
        elseif entry.path == "unvisited.lua" then unvisited_line = lines[row]
        end
      end
    end

    assert.truthy(reviewed_line, "Expected reviewed.lua entry")
    assert.truthy(partial_line, "Expected partial.lua entry")
    assert.truthy(unvisited_line, "Expected unvisited.lua entry")
    assert.truthy(reviewed_line:find("●"), "reviewed file should show ● icon")
    assert.truthy(partial_line:find("◑"), "partial file should show ◑ icon")
    assert.truthy(unvisited_line:find("○"), "unvisited file should show ○ icon")
  end)

  it("shows ▸ for current file instead of review status icon", function()
    local state = {
      view_mode = "diff",
      current_file = 1,
      collapsed_dirs = {},
      discussions = {},
      ai_suggestions = {},
      file_review_status = {
        ["current.lua"] = { status = "reviewed" },  -- reviewed but still shows ▸
      },
      files = {
        { new_path = "current.lua", old_path = "current.lua" },
        { new_path = "other.lua",   old_path = "other.lua" },
      },
    }
    local lines, row_map = {}, {}
    file_tree.render(state, lines, row_map)

    local current_line, other_line
    for row, entry in pairs(row_map) do
      if entry.type == "file" then
        if entry.path == "current.lua" then current_line = lines[row]
        elseif entry.path == "other.lua" then other_line = lines[row]
        end
      end
    end

    assert.truthy(current_line, "Expected current.lua entry")
    assert.truthy(current_line:find("▸"), "current file should show ▸ indicator")
    assert.falsy(current_line:find("●"), "current file should NOT show review icon")
    -- other.lua is unvisited and not current, should show ○
    assert.truthy(other_line:find("○"), "non-current file should show review icon")
  end)
end)
