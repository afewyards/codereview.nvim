package.loaded["codereview.config"] = {
  get = function() return { diff = { comment_width = 64 } } end,
}
package.loaded["codereview.ui.markdown"] = {
  parse_inline = function(text, hl) return { { text, hl } } end,
  find_spans = function() return {} end,
}

local tvl = require("codereview.mr.thread_virt_lines")

describe("thread_virt_lines", function()
  describe("build", function()
    it("single-note thread produces correct virt_lines structure", function()
      local disc = {
        id = "d1",
        notes = {
          { author = "alice", body = "LGTM", created_at = "2026-02-20T10:30:00Z" },
        },
      }
      local result = tvl.build(disc, {})
      assert.is_table(result.virt_lines)
      assert.is_nil(result.spacer_offset)
      -- header + body line + footer = at least 3 lines
      assert.is_true(#result.virt_lines >= 3)
      -- first chunk of header is the border prefix
      assert.equals("  ┌ ", result.virt_lines[1][1][1])
      -- second chunk is the author
      assert.truthy(result.virt_lines[1][2][1]:find("alice"))
      -- status is Unresolved for unresolved disc
      assert.truthy(result.virt_lines[1][4][1]:find("Unresolved"))
      -- last line is the footer
      assert.truthy(result.virt_lines[#result.virt_lines][1][1]:find("└"))
    end)

    it("resolved disc shows Resolved status", function()
      local disc = {
        id = "d2",
        resolved = true,
        notes = {
          { author = "bob", body = "Done", created_at = "2026-02-20T12:00:00Z" },
        },
      }
      local result = tvl.build(disc, {})
      assert.truthy(result.virt_lines[1][4][1]:find("Resolved"))
    end)

    it("multi-note thread includes reply author and body", function()
      local disc = {
        id = "d3",
        notes = {
          { author = "alice", body = "First comment", created_at = "2026-02-20T10:00:00Z" },
          { author = "bob", body = "Reply here", created_at = "2026-02-20T11:00:00Z" },
        },
      }
      local result = tvl.build(disc, {})
      -- collect all chunk texts
      local texts = {}
      for _, line in ipairs(result.virt_lines) do
        for _, chunk in ipairs(line) do
          table.insert(texts, chunk[1])
        end
      end
      local joined = table.concat(texts, " ")
      assert.truthy(joined:find("@bob"))
      assert.truthy(joined:find("Reply here"))
    end)

    it("system notes in replies are skipped", function()
      local disc = {
        id = "d4",
        notes = {
          { author = "alice", body = "Comment", created_at = "2026-02-20T10:00:00Z" },
          { author = "system", body = "resolved this thread", created_at = "2026-02-20T11:00:00Z", system = true },
          { author = "bob", body = "A real reply", created_at = "2026-02-20T12:00:00Z" },
        },
      }
      local result = tvl.build(disc, {})
      local texts = {}
      for _, line in ipairs(result.virt_lines) do
        for _, chunk in ipairs(line) do
          table.insert(texts, chunk[1])
        end
      end
      local joined = table.concat(texts, " ")
      assert.falsy(joined:find("resolved this thread"))
      assert.truthy(joined:find("A real reply"))
    end)

    it("returns empty virt_lines for discussion with no notes", function()
      local disc = { id = "d5", notes = {} }
      local result = tvl.build(disc, {})
      assert.equals(0, #result.virt_lines)
    end)

    it("outdated flag adds Outdated chunk to header", function()
      local disc = {
        id = "d6",
        notes = {
          { author = "alice", body = "Old comment", created_at = "2026-02-20T10:00:00Z" },
        },
      }
      local result = tvl.build(disc, { outdated = true })
      local texts = {}
      for _, chunk in ipairs(result.virt_lines[1]) do
        table.insert(texts, chunk[1])
      end
      assert.truthy(table.concat(texts, " "):find("Outdated"))
    end)

    it("selected note uses CodeReviewSelectedNote highlight", function()
      local disc = {
        id = "d7",
        notes = {
          { author = "alice", body = "Some comment", created_at = "2026-02-20T10:00:00Z" },
        },
      }
      local result = tvl.build(disc, { sel_idx = 1 })
      -- first chunk of header should use selected highlight
      assert.equals("CodeReviewSelectedNote", result.virt_lines[1][1][2])
    end)

    it("pending disc shows Posting status", function()
      local disc = {
        id = "d8",
        is_optimistic = true,
        notes = {
          { author = "alice", body = "Pending comment", created_at = "2026-02-20T10:00:00Z" },
        },
      }
      local result = tvl.build(disc, {})
      assert.truthy(result.virt_lines[1][4][1]:find("Posting"))
    end)

    it("failed disc shows Failed status and retry footer", function()
      local disc = {
        id = "d9",
        is_failed = true,
        notes = {
          { author = "alice", body = "Failed comment", created_at = "2026-02-20T10:00:00Z" },
        },
      }
      local result = tvl.build(disc, {})
      assert.truthy(result.virt_lines[1][4][1]:find("Failed"))
      -- footer should contain retry hint
      local footer = result.virt_lines[#result.virt_lines]
      local footer_texts = {}
      for _, chunk in ipairs(footer) do table.insert(footer_texts, chunk[1]) end
      assert.truthy(table.concat(footer_texts, " "):find("retry"))
    end)
  end)

  describe("spacer support", function()
    it("editing note_idx=1 replaces body with spacers and sets spacer_offset=1", function()
      local disc = {
        id = "disc1",
        notes = {
          { author = "alice", body = "Original body", created_at = "2026-02-20T10:00:00Z" },
        },
      }
      local result = tvl.build(disc, {
        editing_note = { disc_id = "disc1", note_idx = 1 },
        spacer_height = 3,
      })
      assert.equals(1, result.spacer_offset)
      -- header is still present
      assert.equals("  ┌ ", result.virt_lines[1][1][1])
      -- 3 spacer lines follow the header
      assert.equals(3 + 2, #result.virt_lines) -- header + 3 spacers + footer
      for i = 2, 4 do
        local chunk = result.virt_lines[i][1][1]
        assert.truthy(chunk:find("│"), "line " .. i .. " should contain │")
        -- "  │" is 5 bytes (│ is 3-byte UTF-8) + 61 spaces = 66
        assert.equals(5 + 61, #chunk)
      end
      -- body text must not appear
      local texts = {}
      for _, line in ipairs(result.virt_lines) do
        for _, chunk in ipairs(line) do table.insert(texts, chunk[1]) end
      end
      assert.falsy(table.concat(texts, " "):find("Original body"))
    end)

    it("editing reply (note_idx=2) skips separator+header+body, inserts spacers", function()
      local disc = {
        id = "disc2",
        notes = {
          { author = "alice", body = "First", created_at = "2026-02-20T10:00:00Z" },
          { author = "bob", body = "Reply text", created_at = "2026-02-20T11:00:00Z" },
        },
      }
      local result = tvl.build(disc, {
        editing_note = { disc_id = "disc2", note_idx = 2 },
        spacer_height = 2,
      })
      -- spacer_offset = header(1) + first body(1) = 2
      assert.equals(2, result.spacer_offset)
      -- "Reply text" body must not appear
      local texts = {}
      for _, line in ipairs(result.virt_lines) do
        for _, chunk in ipairs(line) do table.insert(texts, chunk[1]) end
      end
      assert.falsy(table.concat(texts, " "):find("Reply text"))
      -- alice's first note body should still be present
      assert.truthy(table.concat(texts, " "):find("First"))
      -- 2 spacer lines should be present
      local spacer_count = 0
      for _, line in ipairs(result.virt_lines) do
        -- spacer lines: single chunk, "  │" (5 bytes) + 61 spaces = 66 bytes
        if #line == 1 and #line[1][1] == 5 + 61 then
          spacer_count = spacer_count + 1
        end
      end
      assert.equals(2, spacer_count)
    end)

    it("non-matching disc_id returns spacer_offset=nil and renders normally", function()
      local disc = {
        id = "disc3",
        notes = {
          { author = "alice", body = "Body text", created_at = "2026-02-20T10:00:00Z" },
        },
      }
      local result = tvl.build(disc, {
        editing_note = { disc_id = "other_disc", note_idx = 1 },
        spacer_height = 3,
      })
      assert.is_nil(result.spacer_offset)
      -- body should render normally
      local texts = {}
      for _, line in ipairs(result.virt_lines) do
        for _, chunk in ipairs(line) do table.insert(texts, chunk[1]) end
      end
      assert.truthy(table.concat(texts, " "):find("Body text"))
    end)

    it("editing last note in 3-note thread inserts spacers before footer", function()
      local disc = {
        id = "disc5",
        notes = {
          { author = "alice", body = "First", created_at = "2026-02-20T10:00:00Z" },
          { author = "bob", body = "Second", created_at = "2026-02-20T11:00:00Z" },
          { author = "charlie", body = "Last note", created_at = "2026-02-20T12:00:00Z" },
        },
      }
      local result = tvl.build(disc, {
        editing_note = { disc_id = "disc5", note_idx = 3 },
        spacer_height = 2,
      })
      -- spacer_offset: header(1) + alice_body(1) + bob_sep(1) + bob_reply_header(1) + bob_body(1) = 5
      assert.equals(5, result.spacer_offset)
      -- "Last note" body must not appear
      local texts = {}
      for _, line in ipairs(result.virt_lines) do
        for _, chunk in ipairs(line) do table.insert(texts, chunk[1]) end
      end
      assert.falsy(table.concat(texts, " "):find("Last note"))
      -- earlier notes still rendered
      assert.truthy(table.concat(texts, " "):find("First"))
      assert.truthy(table.concat(texts, " "):find("@bob"))
      -- 2 spacer lines present
      local spacer_count = 0
      for _, line in ipairs(result.virt_lines) do
        if #line == 1 and #line[1][1] == 5 + 61 then
          spacer_count = spacer_count + 1
        end
      end
      assert.equals(2, spacer_count)
      -- footer is still last
      assert.truthy(result.virt_lines[#result.virt_lines][1][1]:find("└"))
    end)

    it("spacer_height=0 with editing_note produces no spacer lines", function()
      local disc = {
        id = "disc4",
        notes = {
          { author = "alice", body = "Content", created_at = "2026-02-20T10:00:00Z" },
        },
      }
      local result = tvl.build(disc, {
        editing_note = { disc_id = "disc4", note_idx = 1 },
        spacer_height = 0,
      })
      assert.equals(1, result.spacer_offset)
      -- only header + footer
      assert.equals(2, #result.virt_lines)
    end)
  end)

  describe("is_resolved", function()
    it("uses discussion.resolved when set", function()
      assert.is_true(tvl.is_resolved({ resolved = true, notes = {} }))
      assert.is_false(tvl.is_resolved({ resolved = false, notes = {} }))
    end)

    it("falls back to first note resolved field", function()
      assert.is_true(tvl.is_resolved({ notes = { { resolved = true } } }))
      assert.is_false(tvl.is_resolved({ notes = { { resolved = false } } }))
    end)

    it("returns nil when notes is empty and resolved is nil", function()
      assert.is_falsy(tvl.is_resolved({ notes = {} }))
    end)
  end)
end)
