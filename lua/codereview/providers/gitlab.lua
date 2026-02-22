local types = require("codereview.providers.types")
local M = {}

M.name = "gitlab"

--- Build auth headers for GitLab API requests.
function M.build_auth_header(token, token_type)
  if token_type == "oauth" then
    return { ["Authorization"] = "Bearer " .. token, ["Content-Type"] = "application/json" }
  else
    return { ["PRIVATE-TOKEN"] = token, ["Content-Type"] = "application/json" }
  end
end

--- Parse x-next-page header from GitLab response headers.
function M.parse_next_page(headers)
  local next_page = headers and headers["x-next-page"]
  if next_page and next_page ~= "" then
    return tonumber(next_page)
  end
  return nil
end

--- Map a GitLab MR raw object to a normalized review.
function M.normalize_mr(mr)
  local diff_refs = mr.diff_refs or {}
  local approved_by = {}
  for _, a in ipairs(mr.approved_by or {}) do
    table.insert(approved_by, a.user and a.user.username or "")
  end

  return types.normalize_review({
    id = mr.iid,
    title = mr.title,
    author = mr.author and mr.author.username or "",
    source_branch = mr.source_branch,
    target_branch = mr.target_branch,
    state = mr.state,
    base_sha = diff_refs.base_sha,
    head_sha = diff_refs.head_sha,
    start_sha = diff_refs.start_sha,
    web_url = mr.web_url,
    description = mr.description,
    pipeline_status = mr.head_pipeline and mr.head_pipeline.status or nil,
    approved_by = approved_by,
    approvals_required = mr.approvals_before_merge or 0,
    sha = mr.sha,
  })
end

--- Map a GitLab note raw object to a normalized note (flattens username fields).
local function normalize_note(raw)
  local position = nil
  if raw.position then
    local p = raw.position
    position = {
      path = p.new_path or p.old_path,
      new_path = p.new_path,
      old_path = p.old_path,
      new_line = p.new_line,
      old_line = p.old_line,
    }
  end

  return {
    id = raw.id,
    author = raw.author and raw.author.username or "",
    body = raw.body or "",
    created_at = raw.created_at or "",
    system = raw.system or false,
    resolvable = raw.resolvable or false,
    resolved = raw.resolved or false,
    resolved_by = raw.resolved_by and raw.resolved_by.username or nil,
    position = position,
  }
end

--- Map a GitLab discussion raw object to a normalized discussion.
function M.normalize_discussion(raw)
  local notes = {}
  for _, n in ipairs(raw.notes or {}) do
    table.insert(notes, normalize_note(n))
  end
  return { id = raw.id, resolved = raw.resolved or false, notes = notes }
end

--- Normalize a GitLab file diff entry.
function M.normalize_file_diff(raw)
  return types.normalize_file_diff(raw)
end

--- List open MRs for the project.
--- @param client table HTTP client module
--- @param ctx table { base_url, project_id }
--- @param opts table|nil { state, scope, per_page }
function M.list_reviews(client, ctx, opts)
  local endpoints = require("codereview.api.endpoints")
  opts = opts or {}
  local query = {
    state = opts.state or "opened",
    scope = opts.scope or "all",
    per_page = opts.per_page or 50,
  }
  local result, err = client.get(ctx.base_url, endpoints.mr_list(ctx.project_id), { query = query })
  if not result then return nil, err end

  local reviews = {}
  for _, mr in ipairs(result.data or {}) do
    table.insert(reviews, M.normalize_mr(mr))
  end
  return reviews
end

--- Get a single MR by iid.
function M.get_review(client, ctx, iid)
  local endpoints = require("codereview.api.endpoints")
  local result, err = client.get(ctx.base_url, endpoints.mr_detail(ctx.project_id, iid))
  if not result then return nil, err end
  return M.normalize_mr(result.data)
end

--- Get file diffs for an MR.
function M.get_diffs(client, ctx, review)
  local endpoints = require("codereview.api.endpoints")
  local result, err = client.get(ctx.base_url, endpoints.mr_diffs(ctx.project_id, review.id))
  if not result then return nil, err end

  local diffs = {}
  for _, f in ipairs(result.data or {}) do
    table.insert(diffs, M.normalize_file_diff(f))
  end
  return diffs
end

--- Get all discussions for an MR.
function M.get_discussions(client, ctx, review)
  local endpoints = require("codereview.api.endpoints")
  local raw_discs = client.paginate_all(ctx.base_url, endpoints.discussions(ctx.project_id, review.id))
  if not raw_discs then return nil, "Failed to fetch discussions" end

  local discussions = {}
  for _, d in ipairs(raw_discs) do
    table.insert(discussions, M.normalize_discussion(d))
  end
  return discussions
end

--- Post an inline comment or general comment.
--- @param position table|nil { old_path, new_path, old_line, new_line } or nil for general comment
function M.post_comment(client, ctx, review, body, position)
  local endpoints = require("codereview.api.endpoints")
  local payload = { body = body }

  if position then
    payload.position = {
      position_type = "text",
      base_sha = review.base_sha,
      head_sha = review.head_sha,
      start_sha = review.start_sha,
      old_path = position.old_path,
      new_path = position.new_path,
      old_line = position.old_line,
      new_line = position.new_line,
    }
  end

  return client.post(ctx.base_url, endpoints.discussions(ctx.project_id, review.id), { body = payload })
end

--- Post a range comment (GitLab line_range format).
function M.post_range_comment(client, ctx, review, body, old_path, new_path, start_pos, end_pos)
  local endpoints = require("codereview.api.endpoints")
  local payload = {
    body = body,
    position = {
      position_type = "text",
      base_sha = review.base_sha,
      head_sha = review.head_sha,
      start_sha = review.start_sha,
      old_path = old_path,
      new_path = new_path,
      line_range = {
        start = {
          line_code = nil,
          type = start_pos.type or "new",
          old_line = start_pos.old_line,
          new_line = start_pos.new_line,
        },
        ["end"] = {
          line_code = nil,
          type = end_pos.type or "new",
          old_line = end_pos.old_line,
          new_line = end_pos.new_line,
        },
      },
    },
  }
  return client.post(ctx.base_url, endpoints.discussions(ctx.project_id, review.id), { body = payload })
end

--- Reply to an existing discussion thread.
function M.reply_to_discussion(client, ctx, review, discussion_id, body)
  local endpoints = require("codereview.api.endpoints")
  return client.post(
    ctx.base_url,
    endpoints.discussion_notes(ctx.project_id, review.id, discussion_id),
    { body = { body = body } }
  )
end

--- Toggle resolve status on a discussion.
function M.resolve_discussion(client, ctx, review, discussion_id, resolved)
  local endpoints = require("codereview.api.endpoints")
  return client.put(
    ctx.base_url,
    endpoints.discussion(ctx.project_id, review.id, discussion_id),
    { body = { resolved = resolved } }
  )
end

--- Approve an MR.
function M.approve(client, ctx, review)
  local endpoints = require("codereview.api.endpoints")
  local body = {}
  if review.sha then body.sha = review.sha end
  return client.post(ctx.base_url, endpoints.mr_approve(ctx.project_id, review.id), { body = body })
end

--- Remove approval from an MR.
function M.unapprove(client, ctx, review)
  local endpoints = require("codereview.api.endpoints")
  return client.post(ctx.base_url, endpoints.mr_unapprove(ctx.project_id, review.id), { body = {} })
end

--- Merge an MR.
function M.merge(client, ctx, review, opts)
  local endpoints = require("codereview.api.endpoints")
  opts = opts or {}
  local params = {}
  if opts.squash then params.squash = true end
  if opts.remove_source_branch then params.should_remove_source_branch = true end
  if opts.auto_merge then params.merge_when_pipeline_succeeds = true end
  if review.sha then params.sha = review.sha end
  return client.put(ctx.base_url, endpoints.mr_merge(ctx.project_id, review.id), { body = params })
end

--- Close an MR.
function M.close(client, ctx, review)
  local endpoints = require("codereview.api.endpoints")
  return client.put(
    ctx.base_url,
    endpoints.mr_detail(ctx.project_id, review.id),
    { body = { state_event = "close" } }
  )
end

return M
