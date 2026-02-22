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
  local parts = {}
  for part in ctx.project:gmatch("[^/]+") do table.insert(parts, part) end
  local owner, repo = parts[1], parts[2]
  local path_url = string.format("/repos/%s/%s/pulls", owner, repo)
  local result, err = client.get(ctx.base_url, path_url, {
    query = { state = opts.state or "open", per_page = opts.per_page or 50 },
  })
  if not result then return nil, err end
  local reviews = {}
  for _, pr in ipairs(result.data or {}) do
    table.insert(reviews, M.normalize_pr(pr))
  end
  return reviews
end

-- API operations -------------------------------------------------------------

--- Post a single-line review comment.
function M.post_comment(owner, repo, pr_number, token, body, commit_sha, path, line, side)
  local client = require("codereview.api.client")
  local path_url = string.format("/repos/%s/%s/pulls/%d/comments", owner, repo, pr_number)
  local payload = {
    body = body,
    commit_id = commit_sha,
    path = path,
    line = line,
    side = side or "RIGHT",
  }
  return client.post(M.base_url, path_url, {
    body = payload,
    headers = M.build_auth_header(token),
  })
end

--- Post a multi-line range comment (GitHub supports start_line/start_side).
function M.post_range_comment(owner, repo, pr_number, token, body, commit_sha, path, start_line, end_line, side)
  local client = require("codereview.api.client")
  local path_url = string.format("/repos/%s/%s/pulls/%d/comments", owner, repo, pr_number)
  local payload = {
    body = body,
    commit_id = commit_sha,
    path = path,
    start_line = start_line,
    line = end_line,
    start_side = side or "RIGHT",
    side = side or "RIGHT",
  }
  return client.post(M.base_url, path_url, {
    body = payload,
    headers = M.build_auth_header(token),
  })
end

--- Reply to an existing review comment thread.
function M.reply_to_comment(owner, repo, pr_number, token, comment_id, body)
  local client = require("codereview.api.client")
  local path_url = string.format("/repos/%s/%s/pulls/%d/comments/%d/replies", owner, repo, pr_number, comment_id)
  return client.post(M.base_url, path_url, {
    body = { body = body },
    headers = M.build_auth_header(token),
  })
end

--- Close a PR (state = "closed"). Uses PATCH.
function M.close(owner, repo, pr_number, token)
  local client = require("codereview.api.client")
  local path_url = string.format("/repos/%s/%s/pulls/%d", owner, repo, pr_number)
  return client.patch(M.base_url, path_url, {
    body = { state = "closed" },
    headers = M.build_auth_header(token),
  })
end

--- GitHub does not support resolving individual review threads via the REST API.
function M.resolve_discussion()
  return nil, "not supported"
end

--- GitHub does not support un-approving reviews via the REST API.
function M.unapprove()
  return nil, "not supported"
end

--- Fetch approvals for a PR from /pulls/:id/reviews.
--- TODO: implement full review fetch. Returns {} for now.
function M.approved_by()
  return {}
end

return M
