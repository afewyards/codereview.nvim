-- NOTE: Tests cover sync-safe helpers only (build_url, encode_project, build_headers,
-- parse_next_page). Async variants require a running event loop and are tested via
-- integration tests in later stages.
local client = require("codereview.api.client")

describe("api.client", function()
  describe("build_url", function()
    it("builds API URL from base and path", function()
      local url = client.build_url("https://gitlab.com", "/projects/123/merge_requests")
      assert.equals("https://gitlab.com/api/v4/projects/123/merge_requests", url)
    end)

    it("URL-encodes project path", function()
      local encoded = client.encode_project("group/subgroup/project")
      assert.equals("group%2Fsubgroup%2Fproject", encoded)
    end)
  end)

  describe("build_headers", function()
    it("uses PRIVATE-TOKEN for PAT", function()
      local headers = client.build_headers("glpat-abc123", "pat")
      assert.equals("glpat-abc123", headers["PRIVATE-TOKEN"])
      assert.is_nil(headers["Authorization"])
    end)

    it("uses Authorization Bearer for OAuth", function()
      local headers = client.build_headers("oauth-token-xyz", "oauth")
      assert.equals("Bearer oauth-token-xyz", headers["Authorization"])
      assert.is_nil(headers["PRIVATE-TOKEN"])
    end)

    it("defaults to PRIVATE-TOKEN when no token_type given", function()
      local headers = client.build_headers("glpat-abc123")
      assert.equals("glpat-abc123", headers["PRIVATE-TOKEN"])
    end)

    it("includes Content-Type", function()
      local headers = client.build_headers("glpat-abc123")
      assert.equals("application/json", headers["Content-Type"])
    end)
  end)

  describe("parse_pagination", function()
    it("extracts next page from headers", function()
      local headers = { ["x-next-page"] = "3" }
      assert.equals(3, client.parse_next_page(headers))
    end)

    it("returns nil when no next page", function()
      local headers = { ["x-next-page"] = "" }
      assert.is_nil(client.parse_next_page(headers))
    end)
  end)

  describe("patch method", function()
    it("delegates to request with patch method", function()
      local orig_request = client.request
      local called_method = nil
      client.request = function(method, ...)
        called_method = method
        return { data = {}, status = 200, headers = {} }
      end
      client.patch("https://example.com", "/path", {})
      client.request = orig_request
      assert.equals("patch", called_method)
    end)
  end)

  describe("parse_next_url", function()
    it("extracts next URL from Link header", function()
      local headers = {
        link = '<https://api.github.com/pulls?page=2>; rel="next", <https://api.github.com/pulls?page=5>; rel="last"',
      }
      assert.equals("https://api.github.com/pulls?page=2", client.parse_next_url(headers))
    end)

    it("returns nil when no next link", function()
      local headers = { link = '<https://api.github.com/pulls?page=5>; rel="last"' }
      assert.is_nil(client.parse_next_url(headers))
    end)

    it("returns nil when link header absent", function()
      assert.is_nil(client.parse_next_url({}))
    end)
  end)

  describe("paginate_all_url", function()
    it("follows next_url until exhausted", function()
      local orig_get_url = client.get_url
      local call_count = 0
      client.get_url = function(url, _opts)
        call_count = call_count + 1
        if call_count == 1 then
          return { data = { "a", "b" }, next_url = "https://api.example.com/page2" }
        else
          return { data = { "c" }, next_url = nil }
        end
      end
      local result = client.paginate_all_url("https://api.example.com/page1", {})
      client.get_url = orig_get_url
      assert.equals(3, #result)
      assert.equals("a", result[1])
      assert.equals("c", result[3])
    end)

    it("returns empty table for empty response", function()
      local orig_get_url = client.get_url
      client.get_url = function(_url, _opts)
        return { data = {}, next_url = nil }
      end
      local result = client.paginate_all_url("https://api.example.com/items", {})
      client.get_url = orig_get_url
      assert.equals(0, #result)
    end)
  end)
end)
