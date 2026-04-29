-- Stub vim globals for busted
_G.vim = _G.vim or {}
vim.json = vim.json or {}

local ok, cjson = pcall(require, "cjson")
if ok then
  vim.json.decode = vim.json.decode or function(s)
    return cjson.decode(s)
  end
else
  vim.json.decode = vim.json.decode
    or function(s)
      s = s:match("^%s*(.-)%s*$")
      if s == "[]" then
        return {}
      end
      local inner = s:match("^%[(.*)%]$")
      if not inner then
        error("not an array: " .. s)
      end
      local result = {}
      local depth = 0
      local obj_start = nil
      for i = 1, #inner do
        local c = inner:sub(i, i)
        if c == "{" then
          depth = depth + 1
          if depth == 1 then
            obj_start = i
          end
        elseif c == "}" then
          depth = depth - 1
          if depth == 0 and obj_start then
            local obj_str = inner:sub(obj_start, i)
            local obj = {}
            for key, val in obj_str:gmatch('"([^"]+)"%s*:%s*(-?%d+)') do
              obj[key] = tonumber(val)
            end
            for key, val in obj_str:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
              obj[key] = val
            end
            table.insert(result, obj)
            obj_start = nil
          end
        end
      end
      return result
    end
end

describe("orchestrator", function()
  local orchestrator = require("codereview.ai.orchestrator")

  it("calls build_prompt once per file (batch size 1) and parses output", function()
    local prompts, results = {}, {}
    local fake_provider = {
      run = function(p, cb)
        table.insert(prompts, p)
        cb('[{"x":1}]')
      end,
    }
    package.loaded["codereview.ai.providers"] = {
      get = function()
        return fake_provider
      end,
    }
    package.loaded["codereview.ai.orchestrator"] = nil
    orchestrator = require("codereview.ai.orchestrator")

    local done = false
    orchestrator.run({
      diffs = { { new_path = "a", diff = "" }, { new_path = "b", diff = "" } },
      build_prompt = function(batch)
        return "P:" .. batch[1].new_path
      end,
      parse_output = function(t)
        return vim.json.decode(t)
      end,
      on_result = function(r)
        table.insert(results, r)
      end,
      on_complete = function()
        done = true
      end,
      max_concurrent = 2,
    })
    assert.are.equal(2, #prompts)
    assert.are.equal(2, #results)
    assert.is_true(done)
  end)

  it("on_error fires when provider returns error; on_complete still fires", function()
    local fake = {
      run = function(_, cb)
        cb(nil, "boom")
      end,
    }
    package.loaded["codereview.ai.providers"] = {
      get = function()
        return fake
      end,
    }
    package.loaded["codereview.ai.orchestrator"] = nil
    orchestrator = require("codereview.ai.orchestrator")

    local errs, done = {}, false
    orchestrator.run({
      diffs = { { new_path = "a", diff = "" } },
      build_prompt = function()
        return ""
      end,
      parse_output = function()
        return {}
      end,
      on_result = function() end,
      on_error = function(e)
        table.insert(errs, e)
      end,
      on_complete = function()
        done = true
      end,
    })
    assert.are.equal(1, #errs)
    assert.is_true(done)
  end)

  it("on_batch_complete fires once per successful batch with parsed results", function()
    local batch_calls = {}
    local fake_provider = {
      run = function(_, cb)
        cb('[{"x":1}]')
      end,
    }
    package.loaded["codereview.ai.providers"] = {
      get = function()
        return fake_provider
      end,
    }
    package.loaded["codereview.ai.orchestrator"] = nil
    orchestrator = require("codereview.ai.orchestrator")

    orchestrator.run({
      diffs = { { new_path = "a", diff = "" }, { new_path = "b", diff = "" } },
      build_prompt = function(batch)
        return batch[1].new_path
      end,
      parse_output = function(t)
        return vim.json.decode(t)
      end,
      on_result = function() end,
      on_batch_complete = function(batch, parsed)
        table.insert(batch_calls, { path = batch[1].new_path, count = #parsed })
      end,
      on_complete = function() end,
    })
    assert.are.equal(2, #batch_calls)
    assert.are.equal(1, batch_calls[1].count)
    assert.are.equal(1, batch_calls[2].count)
  end)

  it("on_batch_complete does NOT fire when provider errors", function()
    local batch_calls = {}
    local fake_provider = {
      run = function(_, cb)
        cb(nil, "err")
      end,
    }
    package.loaded["codereview.ai.providers"] = {
      get = function()
        return fake_provider
      end,
    }
    package.loaded["codereview.ai.orchestrator"] = nil
    orchestrator = require("codereview.ai.orchestrator")

    orchestrator.run({
      diffs = { { new_path = "a", diff = "" } },
      build_prompt = function()
        return ""
      end,
      parse_output = function()
        return {}
      end,
      on_result = function() end,
      on_batch_complete = function(batch, parsed)
        table.insert(batch_calls, { batch = batch, parsed = parsed })
      end,
      on_error = function() end,
      on_complete = function() end,
    })
    assert.are.equal(0, #batch_calls)
  end)

  it("on_complete fires with empty results when diffs is empty", function()
    package.loaded["codereview.ai.providers"] = {
      get = function()
        return { run = function() end }
      end,
    }
    package.loaded["codereview.ai.orchestrator"] = nil
    orchestrator = require("codereview.ai.orchestrator")

    local complete_results
    orchestrator.run({
      diffs = {},
      build_prompt = function()
        return ""
      end,
      parse_output = function()
        return {}
      end,
      on_result = function() end,
      on_complete = function(r)
        complete_results = r
      end,
    })
    assert.same({}, complete_results)
  end)
end)
