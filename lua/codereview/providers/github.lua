local types = require("codereview.providers.types")
local log = require("codereview.log")
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

--- Derive GraphQL endpoint from REST base_url.
--- github.com: "https://api.github.com" → "https://api.github.com/graphql"
--- GHE: "https://gh.corp.com/api/v3" → "https://gh.corp.com/api/graphql"
local function graphql_url(base_url)
  local url = base_url or "https://api.github.com"
  url = url:gsub("/v%d+$", "")
  return url .. "/graphql"
end

local function graphql(base_url, headers, query, variables)
  local curl = require("plenary.curl")
  local payload = { query = query }
  if variables then payload.variables = variables end
  local resp = curl.request({
    url = graphql_url(base_url),
    method = "post",
    headers = headers,
    body = vim.json.encode(payload),
  })
  if not resp or resp.status ~= 200 then
    local msg = "GraphQL request failed: " .. (resp and resp.body or "no response")
    log.error(msg)
    return nil, msg
  end
  local ok, data = pcall(vim.json.decode, resp.body)
  if not ok then return nil, "Failed to parse GraphQL response" end
  if data.errors then
    local msg = "GraphQL errors: " .. vim.json.encode(data.errors)
    log.error(msg)
    return nil, msg
  end
  return data.data
end

-- Pagination -----------------------------------------------------------------

--- Extracts the next URL from a GitHub Link header.
--- GitHub uses URL-based pagination: Link: <url>; rel="next", ...
function M.parse_next_page(headers)
  local link = headers and (headers["link"] or headers["Link"])
  if not link then return nil end
  return link:match('<([^>]+)>%s*;%s*rel="next"')
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

function M.normalize_graphql_threads(thread_nodes)
  local discussions = {}
  for _, thread in ipairs(thread_nodes) do
    local comments = thread.comments and thread.comments.nodes or {}
    if #comments == 0 then goto continue end

    local notes = {}
    for _, c in ipairs(comments) do
      table.insert(notes, {
        id = c.databaseId,
        node_id = c.id,
        author = c.author and c.author.login or "",
        body = c.body or "",
        created_at = c.createdAt or "",
        system = false,
        resolvable = true,
        resolved = thread.isResolved or false,
        position = {
          new_path = c.path,
          new_line = c.line,
          side = thread.diffSide,
          start_line = c.startLine,
          start_side = thread.startDiffSide,
          commit_sha = c.commit and c.commit.oid,
        },
      })
    end

    table.insert(discussions, {
      id = tostring(comments[1].databaseId),
      node_id = thread.id,
      resolved = thread.isResolved or false,
      notes = notes,
    })

    ::continue::
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

  local all_threads = {}
  local cursor = vim.NIL

  repeat
    local query = [[
      query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
        repository(owner: $owner, name: $repo) {
          pullRequest(number: $pr) {
            reviewThreads(first: 100, after: $cursor) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                isResolved
                diffSide
                startDiffSide
                comments(first: 100) {
                  nodes {
                    databaseId
                    author { login }
                    body
                    createdAt
                    path
                    line
                    startLine
                    commit { oid }
                  }
                }
              }
            }
          }
        }
      }
    ]]

    local data, gql_err = graphql(ctx.base_url, headers, query, {
      owner = owner, repo = repo, pr = review.id, cursor = cursor,
    })
    if not data then return nil, gql_err end

    local connection = data
      and data.repository
      and data.repository.pullRequest
      and data.repository.pullRequest.reviewThreads
    if not connection then return {}, nil end

    for _, node in ipairs(connection.nodes or {}) do
      table.insert(all_threads, node)
    end

    local page_info = connection.pageInfo
    if page_info and page_info.hasNextPage then
      cursor = page_info.endCursor
    else
      cursor = nil
    end
  until not cursor

  return M.normalize_graphql_threads(all_threads)
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
      commit_id = position.commit_sha or review.head_sha,
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

--- Edit an existing review comment. discussion_id unused for GitHub (kept for API consistency with GitLab).
function M.edit_note(client, ctx, review, discussion_id, note_id, body)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls/%d/comments/%s", owner, repo, review.id, note_id)
  return client.patch(ctx.base_url, path_url, { body = { body = body }, headers = headers })
end

--- Delete a review comment. discussion_id unused for GitHub (kept for API consistency with GitLab).
function M.delete_note(client, ctx, review, discussion_id, note_id)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls/%d/comments/%s", owner, repo, review.id, note_id)
  return client.delete(ctx.base_url, path_url, { headers = headers })
end

--- Close a PR (state = "closed"). Uses PATCH.
function M.close(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls/%d", owner, repo, review.id)
  return client.patch(ctx.base_url, path_url, { body = { state = "closed" }, headers = headers })
end

--- Resolve/unresolve a review thread via GitHub GraphQL API.
--- discussion_id is the root comment ID (string). We look up the thread node_id
--- via GraphQL, then call resolveReviewThread or unresolveReviewThread.
--- If node_id is provided (cached from get_discussions), the lookup step is skipped.
function M.resolve_discussion(client, ctx, review, discussion_id, resolved, node_id)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)

  local thread_node_id = node_id

  if not thread_node_id then
    -- Step 1: find the thread node_id for this comment
    local lookup_query = string.format([[
      query {
        repository(owner: "%s", name: "%s") {
          pullRequest(number: %d) {
            reviewThreads(first: 100) {
              nodes {
                id
                isResolved
                comments(first: 1) {
                  nodes { databaseId }
                }
              }
            }
          }
        }
      }
    ]], owner, repo, review.id)

    log.debug("GraphQL: fetching review threads for comment " .. discussion_id)
    local ldata, lerr = graphql(nil, headers, lookup_query)
    if not ldata then
      return nil, lerr or "GraphQL lookup failed"
    end

    local threads = ldata
      and ldata.repository
      and ldata.repository.pullRequest
      and ldata.repository.pullRequest.reviewThreads
      and ldata.repository.pullRequest.reviewThreads.nodes
    if not threads then
      log.error("GraphQL: no review threads in response")
      return nil, "No review threads found"
    end

    local comment_id = tonumber(discussion_id)
    for _, thread in ipairs(threads) do
      local comments = thread.comments and thread.comments.nodes
      if comments and #comments > 0 and comments[1].databaseId == comment_id then
        thread_node_id = thread.id
        break
      end
    end

    if not thread_node_id then
      log.error("GraphQL: no thread matched comment id " .. discussion_id)
      return nil, "Could not find thread for comment " .. discussion_id
    end
  end

  -- Step 2: resolve or unresolve
  local action = resolved and "resolve" or "unresolve"
  log.debug("GraphQL: " .. action .. " thread " .. thread_node_id)
  local mutation
  if resolved then
    mutation = string.format([[
      mutation { resolveReviewThread(input: {threadId: "%s"}) { thread { id isResolved } } }
    ]], thread_node_id)
  else
    mutation = string.format([[
      mutation { unresolveReviewThread(input: {threadId: "%s"}) { thread { id isResolved } } }
    ]], thread_node_id)
  end

  local _, merr = graphql(nil, headers, mutation)
  if merr then
    return nil, merr
  end

  log.info("GraphQL: thread " .. thread_node_id .. " " .. action .. "d")
  return { data = true }
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

--- Fetch the authenticated user's login. Cached after first call.
M._cached_user = nil

function M.get_current_user(client, ctx)
  if M._cached_user then return M._cached_user end
  local headers, err = get_headers()
  if not headers then return nil, err end
  local resp = client.get(ctx.base_url, "/user", { headers = headers })
  if not resp or resp.status ~= 200 then
    return nil, "Failed to fetch current user"
  end
  local ok, data = pcall(vim.json.decode, resp.body)
  if not ok then return nil, "Failed to parse user response" end
  M._cached_user = data.login
  return M._cached_user
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
