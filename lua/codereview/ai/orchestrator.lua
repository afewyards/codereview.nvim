local ai_providers = require("codereview.ai.providers")
local M = {}

--- CLI providers support progress-file reporting; HTTP providers do not.
local CLI_PROVIDERS = {
  claude_cli = true,
  codex_cli = true,
  copilot_cli = true,
  gemini_cli = true,
  opencode_cli = true,
  qwen_cli = true,
}

--- Run a parallel-batch AI orchestration loop.
---
--- @param spec table
---   diffs:            list of {new_path, old_path, diff}
---   build_prompt:     fn(batch, opts) -> string|table
---   parse_output:     fn(text) -> results array
---   on_result:        fn(result)?         fires once per parsed item
---   on_batch_complete fn(batch, parsed)?  fires after each successful batch
---   on_error:         fn(err, batch)?     fires on per-batch failure
---   on_complete:      fn(all_results)
---   on_progress:      fn(done, total)?    fires every 250ms for CLI providers
---   provider_opts:    table?              forwarded to provider.run
---   max_concurrent:   integer? (default 10)
function M.run(spec)
  local cfg = require("codereview.config").get()
  local file_filter = require("codereview.ai.file_filter")
  local before = #(spec.diffs or {})
  spec.diffs = file_filter.apply(spec.diffs or {}, (cfg.ai or {}).skip_patterns)
  local skipped = before - #spec.diffs
  if skipped > 0 then
    vim.notify(string.format("Skipped %d file(s) (lockfiles/generated/binary)", skipped), vim.log.levels.INFO)
  end

  local provider_name = (cfg.ai or {}).provider
  local diffs = spec.diffs
  local total = #diffs
  if total == 0 then
    if spec.on_complete then
      spec.on_complete({})
    end
    return
  end

  -- Create a progress tracker for CLI providers when the caller wants progress callbacks.
  -- HTTP providers (anthropic, openai, ollama) rely on the per-batch on_batch_complete counter instead.
  local prog = nil
  if CLI_PROVIDERS[provider_name] and spec.on_progress then
    prog = require("codereview.ai.progress").new()
    prog:watch(function(n)
      spec.on_progress(n, total)
    end)
  end

  local prompt_opts = { progress_path = prog and prog.path or nil }

  local batches = require("codereview.ai.batch").build(diffs, {
    char_budget = spec.batch_char_budget or (cfg.ai and cfg.ai.batch_char_budget),
    max_files = spec.batch_max_files or (cfg.ai and cfg.ai.batch_max_files),
  })

  local results = {}
  local completed, next_idx, active = 0, 1, 0
  local max_concurrent = spec.max_concurrent or 10

  local function process_next()
    while active < max_concurrent and next_idx <= #batches do
      local batch = batches[next_idx]
      next_idx = next_idx + 1
      active = active + 1

      local prompt_str = spec.build_prompt(batch, prompt_opts)
      if spec.cacheable and type(prompt_str) == "string" then
        if provider_name == "anthropic" then
          local split = prompt_str:find("\n## Files?\n", 1, false) or prompt_str:find("\n## File:", 1, true)
          if split then
            prompt_str = { system = prompt_str:sub(1, split - 1), user = prompt_str:sub(split + 1) }
          end
        end
      end
      ai_providers.get().run(prompt_str, function(output, err)
        active = active - 1
        completed = completed + 1

        if err then
          if spec.on_error then
            spec.on_error(err, batch)
          end
        else
          local parsed = spec.parse_output(output) or {}
          for _, r in ipairs(parsed) do
            table.insert(results, r)
            if spec.on_result then
              spec.on_result(r)
            end
          end
          if spec.on_batch_complete then
            spec.on_batch_complete(batch, parsed)
          end
        end

        if completed >= #batches then
          if spec.on_complete then
            spec.on_complete(results)
          end
          if prog then
            prog:cleanup()
          end
        else
          process_next()
        end
      end, spec.provider_opts)
    end
  end

  process_next()
end

return M
