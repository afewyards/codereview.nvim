local tvl = require("codereview.mr.thread_virt_lines")

-- Flatten virt_lines into a plain string for pattern matching
local function flatten_virt(virt_lines)
  local parts = {}
  for _, line in ipairs(virt_lines) do
    for _, chunk in ipairs(line) do
      table.insert(parts, chunk[1])
    end
    table.insert(parts, "\n")
  end
  return table.concat(parts)
end

describe("mr.thread_virt_lines", function()
  describe("format_time_relative", function()
    local function make_iso(secs_ago)
      local t = os.time() - secs_ago
      return os.date("%Y-%m-%dT%H:%M:%S", t)
    end

    it("returns empty string for nil", function()
      assert.equals("", tvl.format_time_relative(nil))
    end)

    it("returns 'just now' for 30s ago", function()
      assert.equals("just now", tvl.format_time_relative(make_iso(30)))
    end)

    it("returns '5m ago' for 300s ago", function()
      assert.equals("5m ago", tvl.format_time_relative(make_iso(300)))
    end)

    it("returns '2h ago' for 7200s ago", function()
      assert.equals("2h ago", tvl.format_time_relative(make_iso(7200)))
    end)

    it("returns '3d ago' for 3 days ago", function()
      assert.equals("3d ago", tvl.format_time_relative(make_iso(3 * 86400)))
    end)

    it("falls back to MM/DD format for 60 days ago", function()
      local iso = make_iso(60 * 86400)
      local mo, d = iso:match("%d+-(%d+)-(%d+)")
      assert.equals(mo .. "/" .. d, tvl.format_time_relative(iso))
    end)
  end)

  describe("build", function()
    local function make_disc(opts)
      opts = opts or {}
      return {
        id = opts.id or "disc-1",
        resolved = opts.resolved,
        is_optimistic = opts.is_pending,
        is_failed = opts.is_err,
        notes = opts.notes or {
          {
            id = 1,
            author = opts.author or "alice",
            body = opts.body or "Comment body",
            created_at = "2026-01-01T00:00:00Z",
            resolvable = true,
            resolved = opts.resolved,
          },
        },
      }
    end

    it("returns empty virt_lines for discussion with no notes", function()
      local disc = { id = "x", notes = {} }
      local result = tvl.build(disc)
      assert.same({}, result.virt_lines)
      assert.is_nil(result.spacer_offset)
    end)

    it("uses heavy top-left border ┏ in header", function()
      local disc = make_disc({ resolved = false })
      local result = tvl.build(disc)
      local flat = flatten_virt(result.virt_lines)
      assert.truthy(flat:find("┏", 1, true))
    end)

    it("does not use light border ┌ in header", function()
      local disc = make_disc({ resolved = false })
      local result = tvl.build(disc)
      local flat = flatten_virt(result.virt_lines)
      assert.falsy(flat:find("┌", 1, true))
    end)

    it("shows ● dot for unresolved thread", function()
      local disc = make_disc({ resolved = false })
      local result = tvl.build(disc)
      local flat = flatten_virt(result.virt_lines)
      assert.truthy(flat:find("●", 1, true))
      assert.truthy(flat:find("Unresolved", 1, true))
    end)

    it("shows ○ dot for resolved thread", function()
      local disc = make_disc({ resolved = true, notes = {
        { id = 1, author = "alice", body = "done", created_at = "2026-01-01T00:00:00Z",
          resolvable = true, resolved = true },
      }})
      local result = tvl.build(disc)
      local flat = flatten_virt(result.virt_lines)
      assert.truthy(flat:find("○", 1, true))
      assert.truthy(flat:find("Resolved", 1, true))
    end)

    it("uses ┃ for body lines", function()
      local disc = make_disc({ resolved = false })
      local result = tvl.build(disc)
      local flat = flatten_virt(result.virt_lines)
      assert.truthy(flat:find("┃", 1, true))
    end)

    it("does not use light border │ for body", function()
      local disc = make_disc({ resolved = false })
      local result = tvl.build(disc)
      local flat = flatten_virt(result.virt_lines)
      assert.falsy(flat:find("│", 1, true))
    end)

    it("uses ┗━━ short cap footer when no selection", function()
      local disc = make_disc({ resolved = false })
      local result = tvl.build(disc)
      local flat = flatten_virt(result.virt_lines)
      assert.truthy(flat:find("┗━━", 1, true))
    end)

    it("does not use light border └ in footer", function()
      local disc = make_disc({ resolved = false })
      local result = tvl.build(disc)
      local flat = flatten_virt(result.virt_lines)
      assert.falsy(flat:find("└", 1, true))
    end)

    it("uses ┗ + keybinds + ━ fill footer when sel_idx set", function()
      local disc = make_disc({ resolved = false })
      local result = tvl.build(disc, { sel_idx = 1, current_user = "bob" })
      local flat = flatten_virt(result.virt_lines)
      assert.truthy(flat:find("┗", 1, true))
      assert.truthy(flat:find("━", 1, true))
      assert.truthy(flat:find("reply", 1, true))
    end)

    it("includes author and body in output", function()
      local disc = make_disc({ author = "jan", body = "Fix this please" })
      local result = tvl.build(disc)
      local flat = flatten_virt(result.virt_lines)
      assert.truthy(flat:find("@jan", 1, true))
      assert.truthy(flat:find("Fix this please", 1, true))
    end)

    it("renders reply with ┃  ↪ prefix", function()
      local disc = {
        id = "d1", resolved = false,
        notes = {
          { id = 1, author = "alice", body = "Question", created_at = "2026-01-01T00:00:00Z",
            resolvable = true, resolved = false },
          { id = 2, author = "bob", body = "Answer", created_at = "2026-01-01T01:00:00Z",
            system = false },
        },
      }
      local result = tvl.build(disc)
      local flat = flatten_virt(result.virt_lines)
      assert.truthy(flat:find("┃  ↪", 1, true))
      assert.truthy(flat:find("@bob", 1, true))
      assert.truthy(flat:find("Answer", 1, true))
    end)

    it("uses ┃ for reply body spacer", function()
      local disc = {
        id = "d1", resolved = false,
        notes = {
          { id = 1, author = "alice", body = "Q", created_at = "2026-01-01T00:00:00Z",
            resolvable = true, resolved = false },
          { id = 2, author = "bob", body = "A", created_at = "2026-01-01T01:00:00Z" },
        },
      }
      local result = tvl.build(disc)
      local count = 0
      local flat = flatten_virt(result.virt_lines)
      for _ in flat:gmatch("┃") do count = count + 1 end
      assert.truthy(count >= 2)
    end)

    it("shows ' Posting…' for pending discussion without dot", function()
      local disc = make_disc({ is_pending = true })
      local result = tvl.build(disc)
      local flat = flatten_virt(result.virt_lines)
      assert.truthy(flat:find("Posting", 1, true))
      assert.falsy(flat:find("●", 1, true))
      assert.falsy(flat:find("○", 1, true))
    end)

    it("shows ' Failed' for failed discussion without dot", function()
      local disc = make_disc({ is_err = true })
      local result = tvl.build(disc)
      local flat = flatten_virt(result.virt_lines)
      assert.truthy(flat:find("Failed", 1, true))
      assert.falsy(flat:find("●", 1, true))
      assert.falsy(flat:find("○", 1, true))
    end)

    it("inserts spacer lines when editing first note", function()
      local disc = make_disc({ resolved = false })
      local result = tvl.build(disc, {
        editing_note = { disc_id = "disc-1", note_idx = 1 },
        spacer_height = 3,
      })
      assert.equals(1, result.spacer_offset)
      -- Header + 3 spacers + footer = 5 lines
      assert.equals(5, #result.virt_lines)
    end)

    it("inserts spacer lines when editing a reply", function()
      local disc = {
        id = "d1", resolved = false,
        notes = {
          { id = 1, author = "alice", body = "Q", created_at = "2026-01-01T00:00:00Z",
            resolvable = true, resolved = false },
          { id = 2, author = "bob", body = "A", created_at = "2026-01-01T01:00:00Z" },
        },
      }
      local result = tvl.build(disc, {
        editing_note = { disc_id = "d1", note_idx = 2 },
        spacer_height = 2,
      })
      assert.is_number(result.spacer_offset)
      assert.truthy(result.spacer_offset > 0)
    end)

    it("hides keybind footer when editing a note", function()
      local disc = make_disc({ resolved = false })
      local result = tvl.build(disc, {
        sel_idx = 1,
        current_user = "alice",
        editing_note = { disc_id = "disc-1", note_idx = 1 },
        spacer_height = 3,
      })
      local flat = flatten_virt(result.virt_lines)
      assert.falsy(flat:find("reply", 1, true))
      assert.truthy(flat:find("┗━━", 1, true))
    end)

    it("returns nil spacer_offset when not editing", function()
      local disc = make_disc({ resolved = false })
      local result = tvl.build(disc)
      assert.is_nil(result.spacer_offset)
    end)
  end)
end)
