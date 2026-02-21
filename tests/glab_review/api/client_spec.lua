-- NOTE: Tests cover sync-safe helpers only (build_url, encode_project, build_headers,
-- parse_next_page). Async variants require a running event loop and are tested via
-- integration tests in later stages.
local client = require("glab_review.api.client")

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
end)
