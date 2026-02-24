-- NOTE: Tests cover sync-safe public helpers only. Async variants require a
-- running event loop and are tested via integration tests in later stages.
local client = require("codereview.api.client")

describe("api.client", function()
  describe("build_url", function()
    it("concatenates base URL and path", function()
      local url = client.build_url("https://gitlab.com", "/api/v4/projects/123/merge_requests")
      assert.equals("https://gitlab.com/api/v4/projects/123/merge_requests", url)
    end)

    it("works for GitHub-style paths", function()
      local url = client.build_url("https://api.github.com", "/repos/owner/repo/pulls")
      assert.equals("https://api.github.com/repos/owner/repo/pulls", url)
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

  describe("request error handling", function()
    local orig_request

    before_each(function()
      orig_request = _G._plenary_curl_stub.request
    end)

    after_each(function()
      _G._plenary_curl_stub.request = orig_request
    end)

    it("returns nil and error when curl.request throws", function()
      _G._plenary_curl_stub.request = function()
        error("Timeout was reached")
      end
      local result, err = client.request("get", "https://api.example.com", "/test", {
        headers = { ["Authorization"] = "Bearer test" },
      })
      assert.is_nil(result)
      assert.truthy(err:find("Timeout was reached"))
    end)

    it("returns nil and error when curl.request throws on rate-limit retry", function()
      local call_count = 0
      _G._plenary_curl_stub.request = function()
        call_count = call_count + 1
        if call_count == 1 then
          return { status = 429, headers = { ["retry-after"] = "0" }, body = "" }
        end
        error("Connection refused")
      end
      local result, err = client.request("get", "https://api.example.com", "/test", {
        headers = { ["Authorization"] = "Bearer test" },
      })
      assert.is_nil(result)
      assert.truthy(err:find("Connection refused"))
    end)
  end)

  describe("get_url error handling", function()
    local orig_request

    before_each(function()
      orig_request = _G._plenary_curl_stub.request
    end)

    after_each(function()
      _G._plenary_curl_stub.request = orig_request
    end)

    it("returns nil and error when curl throws during get_url", function()
      _G._plenary_curl_stub.request = function()
        error("Could not resolve host")
      end
      local result, err = client.get_url("https://api.example.com/items", {
        headers = { ["Authorization"] = "Bearer test" },
      })
      assert.is_nil(result)
      assert.truthy(err:find("Could not resolve host"))
    end)
  end)
end)
