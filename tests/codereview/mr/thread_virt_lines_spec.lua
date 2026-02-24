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
