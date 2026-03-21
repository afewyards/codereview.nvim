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
  if not token then
    return nil, "No authentication token. Run :CodeReviewAuth"
  end
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
    updated_at = mr.updated_at,
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
  local resolvable = raw.resolvable or false
  local resolved = raw.resolved or true
  for _, n in ipairs(raw.notes or {}) do
    local note = normalize_note(n)
    table.insert(notes, note)

    if note.resolvable then
      resolvable = true
      if not note.resolved then
        resolved = false
      end
    end
  end
  return { id = raw.id, resolved = resolved, resolvable = resolvable, notes = notes }
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
  if not headers then
    return nil, err
  end
  opts = opts or {}
  local query = {
    state = opts.state or "opened",
    scope = opts.scope or "all",
  }
  local path = "/api/v4/projects/" .. encoded_project(ctx) .. "/merge_requests"
  local data, err2 = client.paginate_all(ctx.base_url, path, { query = query, headers = headers })
  if not data then
    return nil, err2
  end

  local reviews = {}
  for _, mr in ipairs(data) do
    table.insert(reviews, M.normalize_mr(mr))
  end
  return reviews
end

--- Get a single MR by iid.
function M.get_review(client, ctx, iid)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local result, err2 = client.get(ctx.base_url, mr_base(ctx, iid), { headers = headers })
  if not result then
    return nil, err2
  end
  return M.normalize_mr(result.data)
end

--- Get file diffs for an MR.
function M.get_diffs(client, ctx, review)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local raw_diffs = client.paginate_all(ctx.base_url, mr_base(ctx, review.id) .. "/diffs", { headers = headers })
  if not raw_diffs then
    return nil, "Failed to fetch diffs"
  end

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
  if not headers then
    return nil, err
  end
  local encoded_path = path:gsub("/", "%%2F")
  local api_path = string.format("/api/v4/projects/%s/repository/files/%s/raw", encoded_project(ctx), encoded_path)
  local result, req_err = client.get(ctx.base_url, api_path, {
    headers = headers,
    query = { ref = ref },
  })
  if not result then
    return nil, req_err
  end
  if type(result.data) == "string" then
    return result.data
  end
  return nil, "Unexpected response format"
end

--- Get all discussions for an MR.
function M.get_discussions(client, ctx, review)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local raw_discs = client.paginate_all(ctx.base_url, mr_base(ctx, review.id) .. "/discussions", { headers = headers })
  if not raw_discs then
    return nil, "Failed to fetch discussions"
  end

  local discussions = {}
  for _, d in ipairs(raw_discs) do
    table.insert(discussions, M.normalize_discussion(d))
  end
  M.fetch_all_reactions(client, ctx, review, discussions)
  return discussions
end

--- Find the MR head SHA at the time of the user's last approval.
--- Returns the head_commit_sha of the latest version created before the user approved.
function M.get_last_reviewed_sha(client, ctx, review, username)
  local headers, _ = get_headers()
  if not headers then
    return nil
  end
  local base = mr_base(ctx, review.id)

  local approval_res = client.get(ctx.base_url, base .. "/approval_state", { headers = headers })
  if not approval_res or not approval_res.data then
    return nil
  end

  local approved_at
  for _, rule in ipairs(approval_res.data.rules or {}) do
    for _, approver in ipairs(rule.approved_by or {}) do
      if approver.username == username then
        if not approved_at or (approver.approved_at and approver.approved_at > approved_at) then
          approved_at = approver.approved_at
        end
      end
    end
  end
  if not approved_at then
    return nil
  end

  local versions_data = client.paginate_all(ctx.base_url, base .. "/versions", { headers = headers })
  if not versions_data then
    return nil
  end

  local best_sha, best_time = nil, ""
  for _, v in ipairs(versions_data) do
    if v.created_at and v.created_at <= approved_at and v.created_at > best_time then
      best_time = v.created_at
      best_sha = v.head_commit_sha
    end
  end
  return best_sha
end

--- Get all commits for an MR.
function M.get_commits(client, ctx, review)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local raw = client.paginate_all(ctx.base_url, mr_base(ctx, review.id) .. "/commits", { headers = headers })
  if not raw then
    return nil, "Failed to fetch commits"
  end
  local commits = {}
  for _, c in ipairs(raw) do
    table.insert(commits, types.normalize_commit(c))
  end
  return commits
end

--- Get MR diff versions (used for mapping commits to version head SHAs).
--- @return table[]|nil versions Array of { head_commit_sha, created_at }
--- @return string|nil err
function M.get_versions(client, ctx, review)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local data = client.paginate_all(ctx.base_url, mr_base(ctx, review.id) .. "/versions", { headers = headers })
  if not data then
    return nil, "Failed to fetch MR versions"
  end
  local versions = {}
  for _, v in ipairs(data) do
    table.insert(versions, {
      head_commit_sha = v.head_commit_sha,
      created_at = v.created_at,
    })
  end
  return versions
end

--- Fetch additions/deletions stats for each commit (mutates in place).
function M.get_commit_stats(client, ctx, commits)
  local headers, _ = get_headers()
  if not headers then
    return
  end
  for _, c in ipairs(commits) do
    local path = "/api/v4/projects/" .. encoded_project(ctx) .. "/repository/commits/" .. c.sha
    local result = client.get(ctx.base_url, path, { headers = headers })
    if result and result.data and result.data.stats then
      c.additions = result.data.stats.additions
      c.deletions = result.data.stats.deletions
    end
  end
end

--- Get file diffs for a single commit via the repository commits API.
--- @param client table HTTP client module
--- @param ctx table { base_url, project }
--- @param sha string commit SHA
--- @return table[]|nil normalized file diffs, string|nil error
function M.get_commit_diffs(client, ctx, sha)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local path = "/api/v4/projects/" .. encoded_project(ctx) .. "/repository/commits/" .. sha .. "/diff"
  local raw = client.paginate_all(ctx.base_url, path, { headers = headers })
  if not raw then
    return nil, "Failed to fetch commit diffs"
  end
  local diffs = {}
  for _, f in ipairs(raw) do
    table.insert(diffs, types.normalize_file_diff(f))
  end
  return diffs
end

--- Post an inline comment or general comment.
--- @param position table|nil { old_path, new_path, old_line, new_line } or nil for general comment
function M.post_comment(client, ctx, review, body, position)
  local log = require("codereview.log")
  log.debug(string.format("gitlab.post_comment: body=%q type=%s", tostring(body), type(body)))
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local payload = { body = body }

  if position then
    payload.position = {
      position_type = "text",
      base_sha = position.base_sha or review.base_sha,
      head_sha = position.head_sha or review.head_sha,
      start_sha = position.start_sha or review.start_sha,
      old_path = position.old_path,
      new_path = position.new_path,
      old_line = position.old_line,
      new_line = position.new_line,
    }
  end

  return client.post(ctx.base_url, mr_base(ctx, review.id) .. "/discussions", { body = payload, headers = headers })
end

--- Post a range comment (GitLab line_range format).
--- @param opts table|nil Optional SHA overrides { base_sha, head_sha, start_sha }
function M.post_range_comment(client, ctx, review, body, old_path, new_path, start_pos, end_pos, opts)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  opts = opts or {}
  local start_type = start_pos.type or (start_pos.new_line and "new" or "old")
  local end_type = end_pos.type or (end_pos.new_line and "new" or "old")
  local payload = {
    body = body,
    position = {
      position_type = "text",
      base_sha = opts.base_sha or review.base_sha,
      head_sha = opts.head_sha or review.head_sha,
      start_sha = opts.start_sha or review.start_sha,
      old_path = old_path,
      new_path = new_path,
      old_line = end_pos.old_line,
      new_line = end_pos.new_line,
      line_range = {
        start = {
          type = start_type,
          old_line = start_pos.old_line,
          new_line = start_pos.new_line,
        },
        ["end"] = {
          type = end_type,
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
  local log = require("codereview.log")
  log.debug(string.format("gitlab.reply_to_discussion: body=%q type=%s", tostring(body), type(body)))
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  return client.post(
    ctx.base_url,
    mr_base(ctx, review.id) .. "/discussions/" .. discussion_id .. "/notes",
    { body = { body = body }, headers = headers }
  )
end

--- Edit a note in a discussion.
function M.edit_note(client, ctx, review, discussion_id, note_id, body)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  return client.put(
    ctx.base_url,
    mr_base(ctx, review.id) .. "/discussions/" .. discussion_id .. "/notes/" .. note_id,
    { body = { body = body }, headers = headers }
  )
end

--- Delete a note from a discussion.
function M.delete_note(client, ctx, review, discussion_id, note_id)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  return client.delete(
    ctx.base_url,
    mr_base(ctx, review.id) .. "/discussions/" .. discussion_id .. "/notes/" .. note_id,
    { headers = headers }
  )
end

--- Toggle resolve status on a discussion.
function M.resolve_discussion(client, ctx, review, discussion_id, resolved)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  return client.put(
    ctx.base_url,
    mr_base(ctx, review.id) .. "/discussions/" .. discussion_id,
    { body = { resolved = resolved }, headers = headers }
  )
end

--- Approve an MR.
function M.approve(client, ctx, review)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local body = {}
  if review.sha then
    body.sha = review.sha
  end
  return client.post(ctx.base_url, mr_base(ctx, review.id) .. "/approve", { body = body, headers = headers })
end

--- Remove approval from an MR.
function M.unapprove(client, ctx, review)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  return client.post(ctx.base_url, mr_base(ctx, review.id) .. "/unapprove", { body = {}, headers = headers })
end

--- Fetch the authenticated user's username. Cached after first call.
M._cached_user = nil

function M.get_current_user(client, ctx)
  if M._cached_user then
    return M._cached_user
  end
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local resp = client.get(ctx.base_url, "/api/v4/user", { headers = headers })
  if not resp or resp.status ~= 200 then
    return nil, "Failed to fetch current user"
  end
  if not resp.data or not resp.data.username then
    return nil, "Failed to parse user response"
  end
  M._cached_user = resp.data.username
  return M._cached_user
end

--- Merge an MR.
function M.merge(client, ctx, review, opts)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  opts = opts or {}
  local params = {}
  if opts.squash then
    params.squash = true
  end
  if opts.remove_source_branch then
    params.should_remove_source_branch = true
  end
  if opts.auto_merge then
    params.merge_when_pipeline_succeeds = true
  end
  if review.sha then
    params.sha = review.sha
  end
  return client.put(ctx.base_url, mr_base(ctx, review.id) .. "/merge", { body = params, headers = headers })
end

--- Close an MR.
function M.close(client, ctx, review)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  return client.put(ctx.base_url, mr_base(ctx, review.id), { body = { state_event = "close" }, headers = headers })
end

--- Fetch all draft notes for an MR (unpublished review comments).
function M.get_draft_notes(client, ctx, review)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local raw_drafts = client.paginate_all(ctx.base_url, mr_base(ctx, review.id) .. "/draft_notes", { headers = headers })
  if not raw_drafts then
    return {}, nil
  end

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
      change_position =
        { new_path = cp.new_path, old_path = cp.old_path, new_line = cp.new_line, old_line = cp.old_line }
    end

    table.insert(drafts, {
      notes = {
        {
          author = "You (draft)",
          body = raw.note or "",
          created_at = raw.created_at or "",
          position = position,
          change_position = change_position,
        },
      },
      is_draft = true,
      server_draft_id = raw.id,
    })
  end
  return drafts
end

--- Delete a single draft note.
function M.delete_draft_note(client, ctx, review, draft_id)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  return client.delete(ctx.base_url, mr_base(ctx, review.id) .. "/draft_notes/" .. draft_id, { headers = headers })
end

--- Create a draft note on an MR (not visible until published).
--- @param params table { body, path, line, base_sha?, head_sha?, start_sha? }
function M.create_draft_comment(client, ctx, review, params)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local payload = {
    note = params.body,
    position = {
      position_type = "text",
      base_sha = params.base_sha or review.base_sha,
      head_sha = params.head_sha or review.head_sha,
      start_sha = params.start_sha or review.start_sha,
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
  if not headers then
    return nil, err
  end
  local _, bulk_err =
    client.post(ctx.base_url, mr_base(ctx, review.id) .. "/draft_notes/bulk_publish", { body = {}, headers = headers })
  if bulk_err then
    return nil, bulk_err
  end
  opts = opts or {}
  if opts.body and opts.body ~= "" then
    local _, note_err =
      client.post(ctx.base_url, mr_base(ctx, review.id) .. "/notes", { body = { body = opts.body }, headers = headers })
    if note_err then
      return nil, note_err
    end
  end
  if opts.event == "APPROVE" then
    local approve_body = {}
    if review.sha then
      approve_body.sha = review.sha
    end
    local _, approve_err =
      client.post(ctx.base_url, mr_base(ctx, review.id) .. "/approve", { body = approve_body, headers = headers })
    if approve_err then
      return nil, approve_err
    end
  end
  return {}, nil
end

--- Create a new merge request.
--- @param params table { source_branch, target_branch, title, description, draft? }
function M.create_review(client, ctx, params)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
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
  if not headers then
    return nil, err
  end
  local result, err2 = client.get(ctx.base_url, mr_base(ctx, review.id), { headers = headers })
  if not result then
    return nil, err2
  end
  local hp = result.data and result.data.head_pipeline
  if not hp then
    return nil, "No pipeline found for this review"
  end
  return types.normalize_pipeline(hp)
end

--- Fetch jobs for a pipeline.
function M.get_pipeline_jobs(client, ctx, review, pipeline_id)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local path = "/api/v4/projects/" .. encoded_project(ctx) .. "/pipelines/" .. pipeline_id .. "/jobs"
  local result, err2 = client.get(ctx.base_url, path, {
    headers = headers,
    query = { per_page = 100 },
  })
  if not result then
    return nil, err2
  end
  local jobs = {}
  for _, j in ipairs(result.data or {}) do
    table.insert(jobs, types.normalize_pipeline_job(j))
  end
  return jobs
end

--- Fetch the trace (log) for a job.
function M.get_job_trace(client, ctx, review, job_id)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local path = "/api/v4/projects/" .. encoded_project(ctx) .. "/jobs/" .. job_id .. "/trace"
  local result, err2 = client.get(ctx.base_url, path, { headers = headers })
  if not result then
    return nil, err2
  end
  return type(result.data) == "string" and result.data or vim.json.encode(result.data)
end

--- Retry a failed job.
function M.retry_job(client, ctx, review, job_id)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local path = "/api/v4/projects/" .. encoded_project(ctx) .. "/jobs/" .. job_id .. "/retry"
  return client.post(ctx.base_url, path, { body = {}, headers = headers })
end

--- Build a matcher closure that checks if a note position belongs to a given commit.
--- Reuses the same version-map logic as commit_filter.build_version_map.
--- @param commits table[] Array of { sha, ... } (newest first)
--- @param versions table[] Array of { head_commit_sha, created_at }
--- @return fun(position: table|nil, commit_sha: string): boolean
function M.build_commit_matcher(commits, versions)
  if #commits == 0 or #versions == 0 then
    local f = function()
      return false
    end
    return f, f
  end

  -- Sort versions by created_at ascending
  local sorted_versions = {}
  for _, v in ipairs(versions) do
    table.insert(sorted_versions, v)
  end
  table.sort(sorted_versions, function(a, b)
    return (a.created_at or "") < (b.created_at or "")
  end)

  -- Reverse commits to oldest-first
  local ordered = {}
  for i = #commits, 1, -1 do
    table.insert(ordered, commits[i].sha)
  end

  -- Build commit_index for O(1) lookup
  local commit_index = {}
  for i, sha in ipairs(ordered) do
    commit_index[sha] = i
  end

  -- Walk versions; each version owns commits from prev boundary+1 to its head index
  local version_map = {}
  local prev_idx = 0
  for _, v in ipairs(sorted_versions) do
    local v_idx = commit_index[v.head_commit_sha]
    if v_idx then
      for i = prev_idx + 1, v_idx do
        version_map[ordered[i]] = version_map[ordered[i]] or {}
        table.insert(version_map[ordered[i]], v.head_commit_sha)
      end
      prev_idx = v_idx
    end
  end

  local function matcher(position, commit_sha)
    if not position then
      return false
    end
    local version_heads = version_map[commit_sha]
    if not version_heads then
      return false
    end
    for _, vh in ipairs(version_heads) do
      if position.head_sha == vh then
        return true
      end
    end
    return false
  end

  local function is_current(position, commit_sha)
    return matcher(position, commit_sha)
  end

  return matcher, is_current
end

--- Cancel a running job.
function M.cancel_job(client, ctx, review, job_id)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local path = "/api/v4/projects/" .. encoded_project(ctx) .. "/jobs/" .. job_id .. "/cancel"
  return client.post(ctx.base_url, path, { body = {}, headers = headers })
end

--- Play a manual job.
function M.play_job(client, ctx, review, job_id)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local path = "/api/v4/projects/" .. encoded_project(ctx) .. "/jobs/" .. job_id .. "/play"
  return client.post(ctx.base_url, path, { body = {}, headers = headers })
end

--- Fetch MR IIDs with pending todos for the current user.
--- @return table<number, boolean> Set of MR iids with pending todos
function M.get_unread_mr_ids(client, ctx)
  local headers, err = get_headers()
  if not headers then
    return {}, err
  end
  local data = client.paginate_all(ctx.base_url, "/api/v4/todos", {
    query = { type = "MergeRequest", state = "pending", project_id = encoded_project(ctx) },
    headers = headers,
  })
  local ids = {}
  for _, todo in ipairs(data or {}) do
    if todo.target and todo.target.iid then
      ids[todo.target.iid] = true
    end
  end
  return ids
end

--- Fetch award emojis for a single MR note and return normalized reactions.
--- @param note_id number|string The note ID
--- @return table[]|nil reactions, string|nil err
function M.get_note_reactions(client, ctx, review, note_id)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local reactions_module = require("codereview.reactions")
  local current_user = M.get_current_user(client, ctx)
  local path = mr_base(ctx, review.id) .. "/notes/" .. note_id .. "/award_emoji"
  local awards = client.paginate_all(ctx.base_url, path, { headers = headers })
  if not awards then
    return {}, nil
  end

  local by_name = {}
  local order = {}
  for _, award in ipairs(awards) do
    local normalized = reactions_module.from_gitlab(award.name)
    if normalized then
      if not by_name[normalized] then
        by_name[normalized] = { name = normalized, count = 0, reacted = false, awards = {} }
        table.insert(order, normalized)
      end
      local entry = by_name[normalized]
      entry.count = entry.count + 1
      local username = type(award.user) == "table" and award.user.username or nil
      table.insert(entry.awards, { id = award.id, user = username })
      if current_user and username == current_user then
        entry.reacted = true
      end
    end
  end

  local result = {}
  for _, name in ipairs(order) do
    table.insert(result, by_name[name])
  end
  return result, nil
end

--- Batch fetch reactions for all notes in a list of discussions. Mutates note.reactions in place.
--- Skips system notes.
function M.fetch_all_reactions(client, ctx, review, discussions)
  for _, disc in ipairs(discussions or {}) do
    for _, note in ipairs(disc.notes or {}) do
      if note.id and not note.system then
        local reactions, _ = M.get_note_reactions(client, ctx, review, note.id)
        note.reactions = reactions or {}
      end
    end
  end
end

--- Add an emoji reaction to a note.
--- @param emoji_name string Normalized emoji name (e.g. "thumbsup")
function M.add_reaction(client, ctx, review, note_id, emoji_name)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local reactions_module = require("codereview.reactions")
  local gitlab_name = reactions_module.to_provider(emoji_name, "gitlab")
  if not gitlab_name then
    return nil, "Unknown emoji: " .. tostring(emoji_name)
  end
  local path = mr_base(ctx, review.id) .. "/notes/" .. note_id .. "/award_emoji"
  return client.post(ctx.base_url, path, { body = { name = gitlab_name }, headers = headers })
end

--- Remove an emoji reaction from a note by award ID.
--- @param award_id number The award emoji ID to delete (from stored awards data)
function M.remove_reaction(client, ctx, review, note_id, award_id)
  local headers, err = get_headers()
  if not headers then
    return nil, err
  end
  local path = mr_base(ctx, review.id) .. "/notes/" .. note_id .. "/award_emoji/" .. award_id
  return client.delete(ctx.base_url, path, { headers = headers })
end

return M
