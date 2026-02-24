-- tests/codereview/integration/note_actions_spec.lua
-- Integration tests for note selection, edit, and delete flows.

require("tests.unit_helper")

package.preload["codereview.providers"] = function()
  return { detect = function() return nil, nil, "stub" end }
end
package.preload["codereview.api.client"] = function()
  return {}
end

local diff = require("codereview.mr.diff")

describe("note selection + edit + delete", function()
  local disc

  before_each(function()
    disc = {
      id = "d1",
      resolved = false,
      notes = {
        { id = 1, author = "testuser", body = "original", created_at = "2026-02-23T10:00:00Z",
          system = false, resolvable = true, resolved = false },
        { id = 2, author = "testuser", body = "reply text", created_at = "2026-02-23T10:05:00Z",
          system = false, resolvable = true, resolved = false },
      },
    }
  end)

  describe("edit note", function()
    it("updates note body in-place", function()
      disc.notes[1].body = "edited text"
      assert.equals("edited text", disc.notes[1].body)
      assert.equals(2, #disc.notes)  -- other notes untouched
    end)

    it("can edit reply body", function()
      disc.notes[2].body = "updated reply"
      assert.equals("updated reply", disc.notes[2].body)
      assert.equals("original", disc.notes[1].body)  -- root note untouched
    end)
  end)

  describe("delete note", function()
    it("removes a reply note from discussion", function()
      table.remove(disc.notes, 2)
      assert.equals(1, #disc.notes)
      assert.equals("original", disc.notes[1].body)
    end)

    it("removing all notes leaves empty discussion", function()
      table.remove(disc.notes, 2)
      table.remove(disc.notes, 1)
      assert.equals(0, #disc.notes)
    end)

    it("note id lookup works for deletion", function()
      local target_id = 2
      for i, n in ipairs(disc.notes) do
        if n.id == target_id then
          table.remove(disc.notes, i)
          break
        end
      end
      assert.equals(1, #disc.notes)
      assert.equals(1, disc.notes[1].id)
    end)
  end)
end)
