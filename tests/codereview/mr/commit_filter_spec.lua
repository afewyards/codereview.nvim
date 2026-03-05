local commit_filter = require("codereview.mr.commit_filter")

describe("commit_filter", function()
  local function make_state()
    return {
      files = {
        { new_path = "a.lua", diff = "diff a" },
        { new_path = "b.lua", diff = "diff b" },
        { new_path = "c.lua", diff = "diff c" },
      },
      discussions = {
        { id = "d1", notes = { { position = { original_commit_sha = "commit2", new_path = "a.lua" } } } },
        { id = "d2", notes = { { position = { original_commit_sha = "other_sha", new_path = "b.lua" } } } },
        { id = "d3", notes = { { position = nil } } },
      },
      commits = {
        { sha = "commit1", title = "First" },
        { sha = "commit2", title = "Second" },
        { sha = "commit3", title = "Third" },
      },
      provider = {
        build_commit_matcher = function(commits, versions) -- luacheck: ignore
          return function(position, commit_sha)
            if not position then
              return false
            end
            return position.original_commit_sha == commit_sha
          end
        end,
      },
      commit_filter = nil,
      original_files = nil,
      original_discussions = nil,
      current_file = 2,
      line_data_cache = { x = 1 },
      row_disc_cache = { y = 2 },
      git_diff_cache = { z = 3 },
      scroll_line_data = { w = 4 },
      scroll_row_disc = { w = 5 },
      row_ai_cache = { a = 6 },
      scroll_row_ai = { b = 7 },
      file_review_status = { s = 8 },
      file_sections = { f = 9 },
      review = { base_sha = "base", head_sha = "head" },
    }
  end

  describe("apply", function()
    it("backs up files and discussions", function()
      local state = make_state()
      local original_files = state.files
      local original_discussions = state.discussions
      commit_filter.apply(state, {
        from_sha = "commit1",
        to_sha = "commit2",
        label = "Second",
        changed_paths = { "a.lua" },
      })
      assert.same(original_files, state.original_files)
      assert.same(original_discussions, state.original_discussions)
    end)

    it("filters files to changed_paths", function()
      local state = make_state()
      commit_filter.apply(state, {
        from_sha = "commit1",
        to_sha = "commit2",
        label = "Second",
        changed_paths = { "a.lua" },
      })
      assert.equals(1, #state.files)
      assert.equals("a.lua", state.files[1].new_path)
    end)

    it("filters discussions using provider matcher", function()
      local state = make_state()
      commit_filter.apply(state, {
        from_sha = "commit1",
        to_sha = "commit2",
        label = "Second",
        changed_paths = { "a.lua" },
      })
      -- d1 matches (original_commit_sha = "commit2"), d2 and d3 do not
      assert.equals(1, #state.discussions)
      assert.equals("d1", state.discussions[1].id)
    end)

    it("resets current_file and clears caches", function()
      local state = make_state()
      commit_filter.apply(state, {
        from_sha = "commit1",
        to_sha = "commit2",
        label = "Second",
        changed_paths = { "a.lua" },
      })
      assert.equals(1, state.current_file)
      assert.same({}, state.line_data_cache)
      assert.same({}, state.row_disc_cache)
      assert.same({}, state.git_diff_cache)
    end)

    it("sets commit_filter on state", function()
      local state = make_state()
      commit_filter.apply(state, {
        from_sha = "commit1",
        to_sha = "commit2",
        label = "Second",
        changed_paths = { "a.lua" },
      })
      assert.equals("commit1", state.commit_filter.from_sha)
      assert.equals("commit2", state.commit_filter.to_sha)
      assert.equals("Second", state.commit_filter.label)
    end)

    it("stores is_current closure from provider", function()
      local state = make_state()
      local called_with = {}
      state.provider.build_commit_matcher = function()
        local matcher = function(position, commit_sha)
          return position and position.original_commit_sha == commit_sha
        end
        local is_current = function(position, _commit_sha)
          table.insert(called_with, position)
          return position and position.head_sha == "version_head_A"
        end
        return matcher, is_current
      end
      commit_filter.apply(state, {
        from_sha = "commit1",
        to_sha = "commit2",
        label = "Second",
        changed_paths = { "a.lua" },
      })
      assert.is_function(state.commit_filter.is_current)
      -- is_current should be bound to to_sha
      assert.is_true(state.commit_filter.is_current({ head_sha = "version_head_A" }))
      assert.is_false(state.commit_filter.is_current({ head_sha = "other" }))
    end)

    it("sets nil is_current when provider returns no second value", function()
      local state = make_state()
      commit_filter.apply(state, {
        from_sha = "commit1",
        to_sha = "commit2",
        label = "Second",
        changed_paths = { "a.lua" },
      })
      assert.is_nil(state.commit_filter.is_current)
    end)
  end)

  describe("clear", function()
    it("restores original files and discussions", function()
      local state = make_state()
      local original_files = state.files
      local original_discussions = state.discussions
      commit_filter.apply(state, {
        from_sha = "commit1",
        to_sha = "commit2",
        label = "Second",
        changed_paths = { "a.lua" },
      })
      commit_filter.clear(state)
      assert.same(original_files, state.files)
      assert.same(original_discussions, state.discussions)
    end)

    it("clears commit_filter and originals", function()
      local state = make_state()
      commit_filter.apply(state, {
        from_sha = "commit1",
        to_sha = "commit2",
        label = "Second",
        changed_paths = { "a.lua" },
      })
      commit_filter.clear(state)
      assert.is_nil(state.commit_filter)
      assert.is_nil(state.original_files)
      assert.is_nil(state.original_discussions)
    end)

    it("resets current_file and clears caches", function()
      local state = make_state()
      commit_filter.apply(state, {
        from_sha = "commit1",
        to_sha = "commit2",
        label = "Second",
        changed_paths = { "a.lua" },
      })
      commit_filter.clear(state)
      assert.equals(1, state.current_file)
      assert.same({}, state.line_data_cache)
    end)
  end)

  describe("is_active", function()
    it("returns false when no filter", function()
      assert.is_false(commit_filter.is_active({ commit_filter = nil }))
    end)
    it("returns true when filter set", function()
      assert.is_true(commit_filter.is_active({ commit_filter = { from_sha = "a", to_sha = "b" } }))
    end)
  end)

  describe("matches_discussion", function()
    local function make_matcher()
      return function(position, commit_sha)
        if not position then
          return false
        end
        return position.original_commit_sha == commit_sha
      end
    end

    it("returns true when matcher matches a note", function()
      local disc = { notes = { { position = { original_commit_sha = "sha2" } } } }
      assert.is_true(commit_filter.matches_discussion(disc, "sha2", make_matcher()))
    end)

    it("returns false when matcher rejects all notes", function()
      local disc = { notes = { { position = { original_commit_sha = "sha1" } } } }
      assert.is_false(commit_filter.matches_discussion(disc, "sha2", make_matcher()))
    end)

    it("rejects general comments (no position)", function()
      local disc = { notes = { { position = nil } } }
      assert.is_false(commit_filter.matches_discussion(disc, "sha2", make_matcher()))
    end)

    it("returns true if any note in a multi-note discussion matches", function()
      local disc = {
        notes = {
          { position = { original_commit_sha = "other" } },
          { position = { original_commit_sha = "sha2" } },
        },
      }
      assert.is_true(commit_filter.matches_discussion(disc, "sha2", make_matcher()))
    end)
  end)

  describe("get_changed_paths", function()
    local orig_system
    before_each(function()
      orig_system = vim.fn.system
    end)
    after_each(function()
      vim.fn.system = orig_system
      vim.v.shell_error = 0
    end)

    it("returns list of changed file paths between two SHAs", function()
      vim.fn.system = function(cmd)
        vim.v.shell_error = 0
        if type(cmd) == "table" and cmd[2] == "diff" and cmd[3] == "--name-only" then
          return "a.lua\nb.lua\nc.lua\n"
        end
        return ""
      end
      local paths = commit_filter.get_changed_paths("sha1", "sha2")
      assert.same({ "a.lua", "b.lua", "c.lua" }, paths)
    end)
    it("returns empty list on git error", function()
      vim.fn.system = function()
        vim.v.shell_error = 1
        return ""
      end
      local paths = commit_filter.get_changed_paths("sha1", "sha2")
      assert.same({}, paths)
    end)
  end)
end)
