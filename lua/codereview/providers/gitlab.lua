local types = require("codereview.providers.types")
local M = {}

M.name = "gitlab"

local function encoded_project(ctx)
  return ctx.project:gsub("/", "%%2F")
end

local function mr_base(ctx, iid)
  return "/api/v4/projects/" .. encoded_project(ctx) .. "/merge_requests/" .. iid
end

local function get_headers()
  local auth = require("codereview.api.auth")
  local token, token_type = auth.get_token()
  if not token then return nil, "No authentication token. Run :CodeReviewAuth" end
  return M.build_auth_header(token, token_type)
end

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
    table.insert(approved_by, type(a.user) == "table" and a.user.username or "")
  end

  return types.normalize_review({
    id = mr.iid,
    title = mr.title,
    author = type(mr.author) == "table" and mr.author.username or "",
    source_branch = mr.source_branch,
    target_branch = mr.target_branch,
    state = mr.state,
    base_sha = diff_refs.base_sha,
    head_sha = diff_refs.head_sha,
    start_sha = diff_refs.start_sha,
    web_url = mr.web_url,
    description = mr.description,
    pipeline_status = type(mr.head_pipeline) == "table" and mr.head_pipeline.status or nil,
    approved_by = approved_by,
    approvals_required = mr.approvals_before_merge or 0,
    sha = mr.sha,
    merge_status = mr.merge_status,
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
      base_sha = p.base_sha,
      head_sha = p.head_sha,
      start_sha = p.start_sha,
    }
    -- Preserve range start from line_range (GitLab range comments)
    if type(p.line_range) == "table" and p.line_range.start then
      local s = p.line_range.start
      position.start_new_line = s.new_line
      position.start_old_line = s.old_line
    end
  end

  local change_position = nil
  if raw.change_position then
    local cp = raw.change_position
    change_position = { new_path = cp.new_path, old_path = cp.old_path, new_line = cp.new_line, old_line = cp.old_line }
  end

  return {
    id = raw.id,
    author = type(raw.author) == "table" and raw.author.username or "",
    body = raw.body or "",
    created_at = raw.created_at or "",
    system = raw.system or false,
    resolvable = raw.resolvable or false,
    resolved = raw.resolved or false,
    resolved_by = type(raw.resolved_by) == "table" and raw.resolved_by.username or nil,
    position = position,
    change_position = change_position,
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
--- @param ctx table { base_url, project }
--- @param opts table|nil { state, scope, per_page }
function M.list_reviews(client, ctx, opts)
  local headers, err = get_headers()
  if not headers then return nil, err end
  opts = opts or {}
  local query = {
    state = opts.state or "opened",
    scope = opts.scope or "all",
    per_page = opts.per_page or 50,
  }
  local path = "/api/v4/projects/" .. encoded_project(ctx) .. "/merge_requests"
  local result, err2 = client.get(ctx.base_url, path, { query = query, headers = headers })
  if not result then return nil, err2 end

  local reviews = {}
  for _, mr in ipairs(result.data or {}) do
    table.insert(reviews, M.normalize_mr(mr))
  end
  return reviews
end

--- Get a single MR by iid.
function M.get_review(client, ctx, iid)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local result, err2 = client.get(ctx.base_url, mr_base(ctx, iid), { headers = headers })
  if not result then return nil, err2 end
  return M.normalize_mr(result.data)
end

--- Get file diffs for an MR.
function M.get_diffs(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local raw_diffs = client.paginate_all(ctx.base_url, mr_base(ctx, review.id) .. "/diffs", { headers = headers })
  if not raw_diffs then return nil, "Failed to fetch diffs" end

  local diffs = {}
  for _, f in ipairs(raw_diffs) do
    table.insert(diffs, M.normalize_file_diff(f))
  end
  return diffs
end

--- Fetch raw file content at a specific ref (commit SHA).
--- Returns the file content as a string, or nil + error.
function M.get_file_content(client, ctx, ref, path)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local encoded_path = path:gsub("/", "%%2F")
  local api_path = string.format(
    "/api/v4/projects/%s/repository/files/%s/raw",
    encoded_project(ctx),
    encoded_path
  )
  local result, req_err = client.get(ctx.base_url, api_path, {
    headers = headers,
    query = { ref = ref },
  })
  if not result then return nil, req_err end
  if type(result.data) == "string" then
    return result.data
  end
  return nil, "Unexpected response format"
end

--- Get all discussions for an MR.
function M.get_discussions(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local raw_discs = client.paginate_all(ctx.base_url, mr_base(ctx, review.id) .. "/discussions", { headers = headers })
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
  local headers, err = get_headers()
  if not headers then return nil, err end
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

  return client.post(ctx.base_url, mr_base(ctx, review.id) .. "/discussions", { body = payload, headers = headers })
end

--- Post a range comment (GitLab line_range format).
function M.post_range_comment(client, ctx, review, body, old_path, new_path, start_pos, end_pos)
  local headers, err = get_headers()
  if not headers then return nil, err end
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
  return client.post(ctx.base_url, mr_base(ctx, review.id) .. "/discussions", { body = payload, headers = headers })
end

--- Reply to an existing discussion thread.
function M.reply_to_discussion(client, ctx, review, discussion_id, body)
  local headers, err = get_headers()
  if not headers then return nil, err end
  return client.post(
    ctx.base_url,
    mr_base(ctx, review.id) .. "/discussions/" .. discussion_id .. "/notes",
    { body = { body = body }, headers = headers }
  )
end

--- Edit a note in a discussion.
function M.edit_note(client, ctx, review, discussion_id, note_id, body)
  local headers, err = get_headers()
  if not headers then return nil, err end
  return client.put(
    ctx.base_url,
    mr_base(ctx, review.id) .. "/discussions/" .. discussion_id .. "/notes/" .. note_id,
    { body = { body = body }, headers = headers }
  )
end

--- Delete a note from a discussion.
function M.delete_note(client, ctx, review, discussion_id, note_id)
  local headers, err = get_headers()
  if not headers then return nil, err end
  return client.delete(
    ctx.base_url,
    mr_base(ctx, review.id) .. "/discussions/" .. discussion_id .. "/notes/" .. note_id,
    { headers = headers }
  )
end

--- Toggle resolve status on a discussion.
function M.resolve_discussion(client, ctx, review, discussion_id, resolved)
  local headers, err = get_headers()
  if not headers then return nil, err end
  return client.put(
    ctx.base_url,
    mr_base(ctx, review.id) .. "/discussions/" .. discussion_id,
    { body = { resolved = resolved }, headers = headers }
  )
end

--- Approve an MR.
function M.approve(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local body = {}
  if review.sha then body.sha = review.sha end
  return client.post(ctx.base_url, mr_base(ctx, review.id) .. "/approve", { body = body, headers = headers })
end

--- Remove approval from an MR.
function M.unapprove(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  return client.post(ctx.base_url, mr_base(ctx, review.id) .. "/unapprove", { body = {}, headers = headers })
end

--- Fetch the authenticated user's username. Cached after first call.
M._cached_user = nil

function M.get_current_user(client, ctx)
  if M._cached_user then return M._cached_user end
  local headers, err = get_headers()
  if not headers then return nil, err end
  local resp = client.get(ctx.base_url, "/api/v4/user", { headers = headers })
  if not resp or resp.status ~= 200 then
    return nil, "Failed to fetch current user"
  end
  if not resp.data or not resp.data.username then return nil, "Failed to parse user response" end
  M._cached_user = resp.data.username
  return M._cached_user
end

--- Merge an MR.
function M.merge(client, ctx, review, opts)
  local headers, err = get_headers()
  if not headers then return nil, err end
  opts = opts or {}
  local params = {}
  if opts.squash then params.squash = true end
  if opts.remove_source_branch then params.should_remove_source_branch = true end
  if opts.auto_merge then params.merge_when_pipeline_succeeds = true end
  if review.sha then params.sha = review.sha end
  return client.put(ctx.base_url, mr_base(ctx, review.id) .. "/merge", { body = params, headers = headers })
end

--- Close an MR.
function M.close(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  return client.put(
    ctx.base_url,
    mr_base(ctx, review.id),
    { body = { state_event = "close" }, headers = headers }
  )
end

--- Fetch all draft notes for an MR (unpublished review comments).
function M.get_draft_notes(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local raw_drafts = client.paginate_all(ctx.base_url, mr_base(ctx, review.id) .. "/draft_notes", { headers = headers })
  if not raw_drafts then return {}, nil end

  local drafts = {}
  for _, raw in ipairs(raw_drafts) do
    local position = nil
    if raw.position then
      local p = raw.position
      position = {
        path = p.new_path or p.old_path,
        new_path = p.new_path,
        old_path = p.old_path,
        new_line = p.new_line,
        old_line = p.old_line,
        base_sha = p.base_sha,
        head_sha = p.head_sha,
        start_sha = p.start_sha,
      }
    end

    -- Preserve change_position for outdated drafts (matches normalize_note behavior)
    local change_position = nil
    if raw.change_position then
      local cp = raw.change_position
      change_position = { new_path = cp.new_path, old_path = cp.old_path, new_line = cp.new_line, old_line = cp.old_line }
    end

    table.insert(drafts, {
      notes = {{
        author = "You (draft)",
        body = raw.note or "",
        created_at = raw.created_at or "",
        position = position,
        change_position = change_position,
      }},
      is_draft = true,
      server_draft_id = raw.id,
    })
  end
  return drafts
end

--- Delete a single draft note.
function M.delete_draft_note(client, ctx, review, draft_id)
  local headers, err = get_headers()
  if not headers then return nil, err end
  return client.delete(ctx.base_url, mr_base(ctx, review.id) .. "/draft_notes/" .. draft_id, { headers = headers })
end

--- Create a draft note on an MR (not visible until published).
--- @param params table { body, path, line }
function M.create_draft_comment(client, ctx, review, params)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local payload = {
    note = params.body,
    position = {
      position_type = "text",
      base_sha = review.base_sha,
      head_sha = review.head_sha,
      start_sha = review.start_sha,
      new_path = params.path,
      old_path = params.path,
      new_line = params.line,
    },
  }
  return client.post(ctx.base_url, mr_base(ctx, review.id) .. "/draft_notes", { body = payload, headers = headers })
end

--- Bulk-publish all draft notes on an MR.
--- @param opts table|nil Optional { body: string, event: string }
function M.publish_review(client, ctx, review, opts)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local _, bulk_err = client.post(ctx.base_url, mr_base(ctx, review.id) .. "/draft_notes/bulk_publish", { body = {}, headers = headers })
  if bulk_err then return nil, bulk_err end
  opts = opts or {}
  if opts.body and opts.body ~= "" then
    local _, note_err = client.post(ctx.base_url, mr_base(ctx, review.id) .. "/notes", { body = { body = opts.body }, headers = headers })
    if note_err then return nil, note_err end
  end
  if opts.event == "APPROVE" then
    local approve_body = {}
    if review.sha then approve_body.sha = review.sha end
    local _, approve_err = client.post(ctx.base_url, mr_base(ctx, review.id) .. "/approve", { body = approve_body, headers = headers })
    if approve_err then return nil, approve_err end
  end
  return {}, nil
end

--- Create a new merge request.
--- @param params table { source_branch, target_branch, title, description, draft? }
function M.create_review(client, ctx, params)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local title = params.title
  if params.draft then
    title = "Draft: " .. title
  end
  return client.post(ctx.base_url, "/api/v4/projects/" .. encoded_project(ctx) .. "/merge_requests", {
    body = {
      source_branch = params.source_branch,
      target_branch = params.target_branch,
      title = title,
      description = params.description,
    },
    headers = headers,
  })
end

--- Fetch the head pipeline for an MR.
function M.get_pipeline(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local result, err2 = client.get(ctx.base_url, mr_base(ctx, review.id), { headers = headers })
  if not result then return nil, err2 end
  local hp = result.data and result.data.head_pipeline
  if not hp then return nil, "No pipeline found for this review" end
  return types.normalize_pipeline(hp)
end

--- Fetch jobs for a pipeline.
function M.get_pipeline_jobs(client, ctx, review, pipeline_id)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local path = "/api/v4/projects/" .. encoded_project(ctx)
    .. "/pipelines/" .. pipeline_id .. "/jobs"
  local result, err2 = client.get(ctx.base_url, path, {
    headers = headers, query = { per_page = 100 },
  })
  if not result then return nil, err2 end
  local jobs = {}
  for _, j in ipairs(result.data or {}) do
    table.insert(jobs, types.normalize_pipeline_job(j))
  end
  return jobs
end

--- Fetch the trace (log) for a job.
function M.get_job_trace(client, ctx, review, job_id)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local path = "/api/v4/projects/" .. encoded_project(ctx)
    .. "/jobs/" .. job_id .. "/trace"
  local result, err2 = client.get(ctx.base_url, path, { headers = headers })
  if not result then return nil, err2 end
  return type(result.data) == "string" and result.data or vim.json.encode(result.data)
end

--- Retry a failed job.
function M.retry_job(client, ctx, review, job_id)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local path = "/api/v4/projects/" .. encoded_project(ctx)
    .. "/jobs/" .. job_id .. "/retry"
  return client.post(ctx.base_url, path, { body = {}, headers = headers })
end

--- Cancel a running job.
function M.cancel_job(client, ctx, review, job_id)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local path = "/api/v4/projects/" .. encoded_project(ctx)
    .. "/jobs/" .. job_id .. "/cancel"
  return client.post(ctx.base_url, path, { body = {}, headers = headers })
end

--- Play a manual job.
function M.play_job(client, ctx, review, job_id)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local path = "/api/v4/projects/" .. encoded_project(ctx)
    .. "/jobs/" .. job_id .. "/play"
  return client.post(ctx.base_url, path, { body = {}, headers = headers })
end

return M
