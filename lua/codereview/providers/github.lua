local types = require("codereview.providers.types")
local M = {}

M.name = "github"
M.base_url = "https://api.github.com"

-- Auth -----------------------------------------------------------------------

function M.build_auth_header(token)
  return {
    ["Authorization"] = "Bearer " .. token,
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/vnd.github+json",
    ["X-GitHub-Api-Version"] = "2022-11-28",
  }
end

-- Helpers --------------------------------------------------------------------

local function parse_owner_repo(ctx)
  local parts = {}
  for part in ctx.project:gmatch("[^/]+") do table.insert(parts, part) end
  return parts[1], parts[2]
end

local function get_headers()
  local auth = require("codereview.api.auth")
  local token = auth.get_token("github")
  if not token then return nil, "No GitHub token found" end
  return M.build_auth_header(token)
end

-- Pagination -----------------------------------------------------------------

--- Extracts the next URL from a GitHub Link header.
--- GitHub uses URL-based pagination: Link: <url>; rel="next", ...
function M.parse_next_page(headers)
  local link = headers and (headers["link"] or headers["Link"])
  if not link then return nil end
  return link:match('<([^>]+)>%s*;%s*rel="next"')
end

-- Normalization helpers -------------------------------------------------------

local function normalize_comment_to_note(comment)
  return {
    id = comment.id,
    author = comment.user and comment.user.login or "",
    body = comment.body or "",
    created_at = comment.created_at or "",
    system = false,
    resolvable = true,
    resolved = false,
    position = {
      new_path = comment.path,
      new_line = comment.line,
      side = comment.side,   -- stored UPPERCASE: "RIGHT" or "LEFT"
      commit_sha = comment.commit_id,
    },
  }
end

-- PR normalization -----------------------------------------------------------

--- Maps a GitHub PR object to the normalized Review shape.
--- GitHub has no separate start_sha — use base.sha for both base_sha and start_sha.
function M.normalize_pr(pr)
  return types.normalize_review({
    id = pr.number,
    title = pr.title,
    author = pr.user and pr.user.login or "",
    source_branch = pr.head and pr.head.ref or "",
    target_branch = pr.base and pr.base.ref or "main",
    state = pr.state,
    head_sha = pr.head and pr.head.sha,
    base_sha = pr.base and pr.base.sha,
    start_sha = pr.base and pr.base.sha,  -- GitHub-specific: no separate start sha
    web_url = pr.html_url or "",
    description = pr.body or "",
    sha = pr.head and pr.head.sha,
  })
end

-- Discussion normalization ---------------------------------------------------

--- Groups GitHub review comments into discussion threads.
--- Comments with in_reply_to_id = nil are thread roots.
--- Replies are grouped under their root comment, sorted by created_at.
function M.normalize_review_comments_to_discussions(comments)
  local roots = {}   -- ordered list of root comment IDs
  local by_id = {}   -- { [id] = comment }
  local replies = {} -- { [root_id] = { comments... } }

  for _, comment in ipairs(comments) do
    by_id[comment.id] = comment
    if not comment.in_reply_to_id then
      table.insert(roots, comment.id)
    else
      local root_id = comment.in_reply_to_id
      if not replies[root_id] then
        replies[root_id] = {}
      end
      table.insert(replies[root_id], comment)
    end
  end

  local discussions = {}
  for _, root_id in ipairs(roots) do
    local root = by_id[root_id]
    local thread = { root }
    for _, reply in ipairs(replies[root_id] or {}) do
      table.insert(thread, reply)
    end

    table.sort(thread, function(a, b) return a.created_at < b.created_at end)

    local notes = {}
    for _, c in ipairs(thread) do
      table.insert(notes, normalize_comment_to_note(c))
    end

    table.insert(discussions, {
      id = tostring(root_id),
      resolved = false,
      notes = notes,
    })
  end

  return discussions
end

-- Provider interface ---------------------------------------------------------

--- List open PRs for the repo (owner/repo from ctx.project).
function M.list_reviews(client, ctx, opts)
  opts = opts or {}
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls", owner, repo)
  local result, err2 = client.get(ctx.base_url, path_url, {
    query = { state = opts.state or "open", per_page = opts.per_page or 50 },
    headers = headers,
  })
  if not result then return nil, err2 end
  local reviews = {}
  for _, pr in ipairs(result.data or {}) do
    table.insert(reviews, M.normalize_pr(pr))
  end
  return reviews
end

--- Get a single PR by number.
function M.get_review(client, ctx, pr_number)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls/%d", owner, repo, pr_number)
  local result, err2 = client.get(ctx.base_url, path_url, { headers = headers })
  if not result then return nil, err2 end
  return M.normalize_pr(result.data)
end

--- Get file diffs for a PR.
function M.get_diffs(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls/%d/files", owner, repo, review.id)
  local result, err2 = client.get(ctx.base_url, path_url, { headers = headers })
  if not result then return nil, err2 end

  local diffs = {}
  for _, f in ipairs(result.data or {}) do
    table.insert(diffs, {
      new_path = f.filename,
      old_path = f.previous_filename or f.filename,
      new_file = (f.status == "added"),
      renamed_file = (f.status == "renamed"),
      deleted_file = (f.status == "removed"),
      diff = f.patch or "",
    })
  end
  return diffs
end

--- Get all review comment discussions for a PR.
function M.get_discussions(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local start_url = string.format("%s/repos/%s/%s/pulls/%d/comments", ctx.base_url, owner, repo, review.id)
  local all_comments = client.paginate_all_url(start_url, { headers = headers })
  if not all_comments then return nil, "Failed to fetch discussions" end
  return M.normalize_review_comments_to_discussions(all_comments)
end

--- Post an inline comment or general PR comment.
--- @param position table|nil { new_path, old_path, new_line, old_line, side, commit_sha } or nil for general comment
function M.post_comment(client, ctx, review, body, position)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)

  if position then
    local path_url = string.format("/repos/%s/%s/pulls/%d/comments", owner, repo, review.id)
    local payload = {
      body = body,
      commit_id = position.commit_sha,
      path = position.new_path or position.old_path,
      line = position.new_line or position.old_line,
      side = position.side or "RIGHT",
    }
    return client.post(ctx.base_url, path_url, { body = payload, headers = headers })
  else
    local path_url = string.format("/repos/%s/%s/issues/%d/comments", owner, repo, review.id)
    return client.post(ctx.base_url, path_url, { body = { body = body }, headers = headers })
  end
end

--- Post a multi-line range comment (GitHub supports start_line/start_side).
function M.post_range_comment(client, ctx, review, body, old_path, new_path, start_pos, end_pos)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls/%d/comments", owner, repo, review.id)
  local payload = {
    body = body,
    commit_id = review.sha,
    path = new_path or old_path,
    start_line = start_pos.new_line or start_pos.old_line,
    line = end_pos.new_line or end_pos.old_line,
    start_side = start_pos.side or "RIGHT",
    side = end_pos.side or "RIGHT",
  }
  return client.post(ctx.base_url, path_url, { body = payload, headers = headers })
end

--- Reply to an existing review comment thread.
function M.reply_to_discussion(client, ctx, review, discussion_id, body)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls/%d/comments/%s/replies", owner, repo, review.id, discussion_id)
  return client.post(ctx.base_url, path_url, { body = { body = body }, headers = headers })
end

--- Close a PR (state = "closed"). Uses PATCH.
function M.close(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls/%d", owner, repo, review.id)
  return client.patch(ctx.base_url, path_url, { body = { state = "closed" }, headers = headers })
end

--- GitHub does not support resolving individual review threads via the REST API.
function M.resolve_discussion(client, ctx, review, discussion_id, resolved) -- luacheck: ignore
  return nil, "not supported"
end

--- Approve a PR by submitting an APPROVE review.
function M.approve(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls/%d/reviews", owner, repo, review.id)
  return client.post(ctx.base_url, path_url, { body = { event = "APPROVE" }, headers = headers })
end

--- GitHub does not support un-approving reviews via the REST API.
function M.unapprove(client, ctx, review) -- luacheck: ignore
  return nil, "not supported"
end

--- Merge a PR.
function M.merge(client, ctx, review, opts)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  opts = opts or {}
  local merge_method = opts.squash and "squash" or (opts.rebase and "rebase" or opts.merge_method or "merge")
  local path_url = string.format("/repos/%s/%s/pulls/%d/merge", owner, repo, review.id)
  local params = { merge_method = merge_method }
  if opts.remove_source_branch then params.delete_branch_after = true end
  return client.put(ctx.base_url, path_url, { body = params, headers = headers })
end

--- Fetch approvals for a PR from /pulls/:id/reviews.
--- TODO: implement full review fetch. Returns {} for now.
function M.approved_by()
  return {}
end

-- Accumulator for pending review comments (GitHub batches on publish)
M._pending_comments = {}

--- Stage a draft comment for the next review submission.
--- GitHub doesn't have individual draft notes — comments are batched into a single review.
--- @param params table { body, path, line }
function M.create_draft_comment(client, ctx, review, params) -- luacheck: ignore client ctx
  table.insert(M._pending_comments, {
    body = params.body,
    path = params.path,
    line = params.line,
    side = "RIGHT",
  })
end

--- Publish all accumulated draft comments as a single PR review.
function M.publish_review(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end

  if #M._pending_comments == 0 then
    return nil, "No pending comments to publish"
  end

  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls/%d/reviews", owner, repo, review.id)
  local payload = {
    commit_id = review.sha,
    event = "COMMENT",
    comments = M._pending_comments,
  }

  local result, post_err = client.post(ctx.base_url, path_url, { body = payload, headers = headers })
  M._pending_comments = {} -- clear regardless of success
  return result, post_err
end

--- Create a new pull request.
--- @param params table { source_branch, target_branch, title, description }
function M.create_review(client, ctx, params)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls", owner, repo)
  return client.post(ctx.base_url, path_url, {
    body = {
      head = params.source_branch,
      base = params.target_branch,
      title = params.title,
      body = params.description,
    },
    headers = headers,
  })
end

return M
