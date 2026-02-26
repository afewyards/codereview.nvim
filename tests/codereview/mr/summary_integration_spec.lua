local detail = require("codereview.mr.detail")

describe("summary redesign integration", function()
  it("renders complete summary with all sections", function()
    local review = {
      id = 99, title = "Big feature", author = "dev",
      source_branch = "feat/big", target_branch = "main",
      state = "opened", pipeline_status = "success",
      approved_by = { "reviewer" }, approvals_required = 2,
      description = "This is a **bold** description",
      merge_status = "can_be_merged",
    }
    local discussions = {
      { id = "d1", resolved = false, notes = {{
        id = 1, author = "bot", body = "assigned to @dev",
        created_at = "2026-02-20T11:00:00Z", system = true,
        resolvable = false, resolved = false,
      }}},
      { id = "d2", resolved = false, notes = {{
        id = 2, author = "alice", body = "Please fix this",
        created_at = "2026-02-25T14:00:00Z", system = false,
        resolvable = true, resolved = false,
        position = { new_path = "src/main.ts", new_line = 10 },
      }}},
    }

    local header = detail.build_header_lines(review, 70)
    local activity = detail.build_activity_lines(discussions, 70)

    -- Header card has bordered box
    assert.is_truthy(header.lines[1]:find("╭", 1, true))

    local all_text = table.concat(header.lines, "\n") .. "\n" .. table.concat(activity.lines, "\n")

    -- All sections present
    assert.is_truthy(all_text:find("## Description"))
    assert.is_truthy(all_text:find("## Activity"))
    assert.is_truthy(all_text:find("## Discussions"))

    -- Content present
    assert.is_truthy(all_text:find("src/main.ts:10"))
    assert.is_truthy(all_text:find("assigned"))
    assert.is_truthy(all_text:find("Please fix this"))
    assert.is_truthy(all_text:find("bold"))

    -- State and metadata in header
    assert.is_truthy(all_text:find("opened"))
    assert.is_truthy(all_text:find("approved"))
    assert.is_truthy(all_text:find("mergeable"))
  end)

  it("renders summary with no discussions", function()
    local review = {
      id = 1, title = "Simple", author = "me",
      source_branch = "fix", target_branch = "main",
      state = "merged", description = "",
      approved_by = {}, approvals_required = 0,
    }

    local header = detail.build_header_lines(review, 60)
    local activity = detail.build_activity_lines({}, 60)

    -- Header still renders
    assert.is_truthy(#header.lines > 0)
    assert.is_truthy(header.lines[1]:find("╭", 1, true))

    -- No description section
    local header_text = table.concat(header.lines, "\n")
    assert.is_falsy(header_text:find("## Description"))

    -- Activity returns empty
    assert.equals(0, #activity.lines)
  end)

  it("has file_path row_map entries for inline discussions", function()
    local discussions = {
      { id = "d1", resolved = false, notes = {{
        id = 1, author = "alice", body = "Fix",
        created_at = "2026-02-25T14:00:00Z", system = false,
        resolvable = true, resolved = false,
        position = { new_path = "src/foo.ts", new_line = 5 },
      }}},
    }

    local result = detail.build_activity_lines(discussions, 70)

    local file_path_entries = {}
    for _, entry in pairs(result.row_map) do
      if entry.type == "file_path" then
        table.insert(file_path_entries, entry)
      end
    end
    assert.equals(1, #file_path_entries)
    assert.equals("src/foo.ts", file_path_entries[1].path)
    assert.equals(5, file_path_entries[1].line)
  end)

  it("has thread_start row_map entries for all discussions", function()
    local discussions = {
      { id = "d1", resolved = false, notes = {{
        id = 1, author = "alice", body = "General comment",
        created_at = "2026-02-25T14:00:00Z", system = false,
        resolvable = true, resolved = false,
      }}},
      { id = "d2", resolved = true, notes = {{
        id = 2, author = "bob", body = "Inline note",
        created_at = "2026-02-25T15:00:00Z", system = false,
        resolvable = true, resolved = true,
        position = { new_path = "a.ts", new_line = 1 },
      }}},
    }

    local result = detail.build_activity_lines(discussions, 70)

    local thread_starts = 0
    for _, entry in pairs(result.row_map) do
      if entry.type == "thread_start" then thread_starts = thread_starts + 1 end
    end
    assert.equals(2, thread_starts)
  end)
end)
