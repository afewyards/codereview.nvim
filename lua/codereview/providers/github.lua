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
  local merge_status
  if pr.mergeable == true then
    merge_status = "can_be_merged"
  elseif pr.mergeable == false then
    merge_status = "cannot_be_merged"
  end

  return types.normalize_review({
    id = pr.number,
    title = pr.title,
    author = type(pr.user) == "table" and pr.user.login or "",
    source_branch = type(pr.head) == "table" and pr.head.ref or "",
    target_branch = type(pr.base) == "table" and pr.base.ref or "main",
    state = pr.state,
    head_sha = type(pr.head) == "table" and pr.head.sha or nil,
    base_sha = type(pr.base) == "table" and pr.base.sha or nil,
    start_sha = type(pr.base) == "table" and pr.base.sha or nil,
    web_url = pr.html_url or "",
    description = pr.body or "",
    sha = type(pr.head) == "table" and pr.head.sha or nil,
    merge_status = merge_status,
  })
end

-- Discussion normalization ---------------------------------------------------

function M.normalize_graphql_threads(thread_nodes)
  local discussions = {}
  for _, thread in ipairs(thread_nodes) do
    local comments = type(thread.comments) == "table" and thread.comments.nodes or {}
    if #comments > 0 then
      local notes = {}
      for _, c in ipairs(comments) do
        local line = (c.line ~= vim.NIL) and c.line or nil
        local start_line = (c.startLine ~= vim.NIL) and c.startLine or nil
        local original_line = (c.originalLine ~= vim.NIL) and c.originalLine or nil
        local original_start_line = (c.originalStartLine ~= vim.NIL) and c.originalStartLine or nil
        table.insert(notes, {
          id = c.databaseId,
          node_id = c.id,
          author = type(c.author) == "table" and c.author.login or "",
          body = c.body or "",
          created_at = c.createdAt or "",
          system = false,
          resolvable = true,
          resolved = thread.isResolved or false,
          position = {
            new_path = c.path,
            new_line = line or original_line,
            side = thread.diffSide,
            start_line = start_line or original_start_line,
            start_side = thread.startDiffSide,
            commit_sha = type(c.commit) == "table" and c.commit.oid or nil,
            outdated = thread.isOutdated or c.outdated or false,
          },
        })
      end

      table.insert(discussions, {
        id = tostring(comments[1].databaseId),
        node_id = thread.id,
        resolved = thread.isResolved or false,
        notes = notes,
      })
    end
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
  local all_files = client.paginate_all_url(
    ctx.base_url .. path_url,
    { headers = headers }
  )
  if not all_files then return nil, "Failed to fetch diffs" end

  local diffs = {}
  for _, f in ipairs(all_files) do
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

--- Fetch raw file content at a specific ref (commit SHA).
--- Returns the decoded file content as a string, or nil + error.
function M.get_file_content(client, ctx, ref, path)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local api_path = string.format("/repos/%s/%s/contents/%s", owner, repo, path)
  local result, req_err = client.get(ctx.base_url, api_path, {
    headers = headers,
    query = { ref = ref },
  })
  if not result then return nil, req_err end
  local data = result.data
  if type(data) ~= "table" or not data.content then
    return nil, "No content in response"
  end
  local raw = data.content:gsub("%s", "")
  local decoded = vim.base64.decode(raw)
  if not decoded then return nil, "base64 decode failed" end
  return decoded
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
                isOutdated
                comments(first: 100) {
                  nodes {
                    databaseId
                    author { login }
                    body
                    createdAt
                    path
                    line
                    originalLine
                    startLine
                    originalStartLine
                    outdated
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

    local repo = type(data) == "table" and type(data.repository) == "table" and data.repository
    local pr_data = repo and type(repo.pullRequest) == "table" and repo.pullRequest
    local connection = pr_data and type(pr_data.reviewThreads) == "table" and pr_data.reviewThreads
    if not connection then return {}, nil end

    for _, node in ipairs(connection.nodes or {}) do
      table.insert(all_threads, node)
    end

    local page_info = type(connection.pageInfo) == "table" and connection.pageInfo
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
--- When a pending review exists, adds the reply to that review (avoids
--- "user_id can only have one pending review" 422 errors).
function M.reply_to_discussion(client, ctx, review, discussion_id, body)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)

  if M._pending_review_id then
    local path_url = string.format(
      "/repos/%s/%s/pulls/%d/reviews/%d/comments",
      owner, repo, review.id, M._pending_review_id
    )
    return client.post(ctx.base_url, path_url, {
      body = { body = body, in_reply_to = tonumber(discussion_id) },
      headers = headers,
    })
  end

  local path_url = string.format("/repos/%s/%s/pulls/%d/comments/%s/replies", owner, repo, review.id, discussion_id)
  return client.post(ctx.base_url, path_url, { body = { body = body }, headers = headers })
end

--- Edit an existing review comment. discussion_id unused for GitHub (kept for API consistency with GitLab).
function M.edit_note(client, ctx, review, discussion_id, note_id, body)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls/comments/%s", owner, repo, note_id)
  return client.patch(ctx.base_url, path_url, { body = { body = body }, headers = headers })
end

--- Delete a review comment. discussion_id unused for GitHub (kept for API consistency with GitLab).
function M.delete_note(client, ctx, review, discussion_id, note_id)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls/comments/%s", owner, repo, note_id)
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

    local lrepo = type(ldata) == "table" and type(ldata.repository) == "table" and ldata.repository
    local lpr = lrepo and type(lrepo.pullRequest) == "table" and lrepo.pullRequest
    local lthreads_conn = lpr and type(lpr.reviewThreads) == "table" and lpr.reviewThreads
    local threads = lthreads_conn and lthreads_conn.nodes
    if not threads then
      log.error("GraphQL: no review threads in response")
      return nil, "No review threads found"
    end

    local comment_id = tonumber(discussion_id)
    for _, thread in ipairs(threads) do
      local comments = type(thread.comments) == "table" and thread.comments.nodes
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
  if not resp.data or not resp.data.login then return nil, "Failed to parse user response" end
  M._cached_user = resp.data.login
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

-- ID of an existing PENDING review on the server (set when resuming drafts)
M._pending_review_id = nil
M._pending_review_node_id = nil

--- Stage a draft comment server-side inside a PENDING review.
--- Creates the PENDING review on first call (REST); adds to it on subsequent calls (GraphQL).
--- @param params table { body, path, line }
function M.create_draft_comment(client, ctx, review, params)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)

  -- First draft: create PENDING review with the comment included
  if not M._pending_review_id then
    local reviews_path = string.format("/repos/%s/%s/pulls/%d/reviews", owner, repo, review.id)
    local resp, rev_err = client.post(ctx.base_url, reviews_path, {
      body = {
        commit_id = review.sha,
        comments = {{
          body = params.body,
          path = params.path,
          line = params.line,
          side = "RIGHT",
        }},
      },
      headers = headers,
    })
    if not resp then return nil, rev_err end
    M._pending_review_id = resp.data.id
    M._pending_review_node_id = resp.data.node_id
    return resp, nil
  end

  -- Subsequent drafts: add comment via GraphQL
  local mutation = [[
    mutation($reviewId: ID!, $body: String!, $path: String!, $line: Int!, $side: DiffSide!) {
      addPullRequestReviewThread(input: {
        pullRequestReviewId: $reviewId
        body: $body
        path: $path
        line: $line
        side: $side
      }) {
        thread { id }
      }
    }
  ]]
  local data, gql_err = graphql(ctx.base_url, headers, mutation, {
    reviewId = M._pending_review_node_id,
    body = params.body,
    path = params.path,
    line = params.line,
    side = "RIGHT",
  })
  if not data then return nil, gql_err end
  return { data = data }, nil
end

--- Fetch draft comments from an existing PENDING review.
--- Sets _pending_review_id only if a pending review with comments is found.
function M.get_pending_review_drafts(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)

  -- Find PENDING review (use per_page=100 to reduce pagination risk)
  local reviews_path = string.format("/repos/%s/%s/pulls/%d/reviews", owner, repo, review.id)
  local resp, rev_err = client.get(ctx.base_url, reviews_path, { headers = headers, query = { per_page = 100 } })
  if not resp then return nil, rev_err end

  local pending_id = nil
  local pending_node_id = nil
  for _, r in ipairs(resp.data or {}) do
    if r.state == "PENDING" then
      pending_id = r.id
      pending_node_id = r.node_id
      break
    end
  end

  if not pending_id then return {} end

  -- Fetch comments from the pending review
  local comments_path = string.format("/repos/%s/%s/pulls/%d/reviews/%d/comments", owner, repo, review.id, pending_id)
  local cresp, cerr = client.get(ctx.base_url, comments_path, { headers = headers, query = { per_page = 100 } })
  if not cresp then return nil, cerr end

  local drafts = {}
  for _, c in ipairs(cresp.data or {}) do
    table.insert(drafts, {
      notes = {{
        author = "You (draft)",
        body = c.body or "",
        created_at = c.created_at or "",
        position = {
          new_path = c.path,
          new_line = c.line,
          side = c.side or "RIGHT",
        },
      }},
      is_draft = true,
      server_draft_id = c.id,
    })
  end

  -- Always track the pending review so create_draft_comment reuses it
  -- (avoids "User can only have one pending review" 422 errors)
  M._pending_review_id = pending_id
  M._pending_review_node_id = pending_node_id

  return drafts
end

--- Delete the pending review (discard all draft comments).
function M.discard_pending_review(client, ctx, review)
  if not M._pending_review_id then return nil, "No pending review to discard" end
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path = string.format("/repos/%s/%s/pulls/%d/reviews/%d", owner, repo, review.id, M._pending_review_id)
  local result, del_err = client.delete(ctx.base_url, path, { headers = headers })
  M._pending_review_id = nil
  M._pending_review_node_id = nil
  return result, del_err
end

--- Publish all server-side draft comments by submitting the PENDING review.
function M.publish_review(client, ctx, review, opts)
  opts = opts or {}
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)

  if not M._pending_review_id then
    return { data = true }, nil
  end

  local payload = { event = opts.event or "COMMENT" }
  if opts.body and opts.body ~= "" then
    payload.body = opts.body
  end

  local submit_path = string.format("/repos/%s/%s/pulls/%d/reviews/%d/events", owner, repo, review.id, M._pending_review_id)
  local result, post_err = client.post(ctx.base_url, submit_path, { body = payload, headers = headers })
  M._pending_review_id = nil
  M._pending_review_node_id = nil
  return result, post_err
end

--- Create a new pull request.
--- @param params table { source_branch, target_branch, title, description, draft? }
function M.create_review(client, ctx, params)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local path_url = string.format("/repos/%s/%s/pulls", owner, repo)
  local body = {
    head = params.source_branch,
    base = params.target_branch,
    title = params.title,
    body = params.description,
  }
  if params.draft then
    body.draft = true
  end
  return client.post(ctx.base_url, path_url, {
    body = body,
    headers = headers,
  })
end

-- Pipeline methods -------------------------------------------------------

--- Map GitHub check suite status + conclusion to a unified status string.
local function map_check_status(status, conclusion)
  if status == "completed" then
    return conclusion or "unknown"
  elseif status == "in_progress" then
    return "running"
  elseif status == "queued" then
    return "pending"
  end
  return status or "unknown"
end

--- Map GitHub check-run status/conclusion to a job status string.
local function map_job_status(cr)
  if cr.status == "completed" then
    return cr.conclusion or "unknown"
  end
  return cr.status or "unknown"
end

--- Extract workflow run ID from a check-run's details_url.
local function extract_run_id(details_url)
  if not details_url then return nil end
  return details_url:match("/actions/runs/(%d+)")
end

--- Fetch pipeline (check-suite) status for the PR's head SHA.
function M.get_pipeline(client, ctx, review)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local sha = review.head_sha or review.sha
  if not sha then return nil, "No head SHA available" end
  local path = string.format("/repos/%s/%s/commits/%s/check-suites", owner, repo, sha)
  local result, err2 = client.get(ctx.base_url, path, { headers = headers })
  if not result then return nil, err2 end
  local suites = result.data and result.data.check_suites or {}
  if #suites == 0 then return nil, "No check suites found" end
  -- Use the first (most recent) suite
  local s = suites[1]
  local types_mod = require("codereview.providers.types")
  return types_mod.normalize_pipeline({
    id = s.id,
    status = map_check_status(s.status, s.conclusion),
    ref = sha,
    sha = sha,
    web_url = s.url or "",
    created_at = s.created_at or "",
    updated_at = s.updated_at or "",
    duration = 0,
  })
end

--- Fetch check-runs (jobs) for a check-suite.
function M.get_pipeline_jobs(client, ctx, review, suite_id) -- luacheck: ignore suite_id
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local sha = review.head_sha or review.sha
  local path = string.format("/repos/%s/%s/commits/%s/check-runs", owner, repo, sha)
  local result, err2 = client.get(ctx.base_url, path, {
    headers = headers, query = { per_page = 100 },
  })
  if not result then return nil, err2 end
  local types_mod = require("codereview.providers.types")
  local jobs = {}
  for _, cr in ipairs(result.data and result.data.check_runs or {}) do
    table.insert(jobs, types_mod.normalize_pipeline_job({
      id = cr.id,
      name = cr.name,
      stage = type(cr.app) == "table" and cr.app.name or "checks",
      status = map_job_status(cr),
      duration = 0,
      web_url = cr.html_url or "",
      allow_failure = false,
      started_at = cr.started_at or "",
      finished_at = cr.completed_at or "",
    }))
  end
  return jobs
end

--- Fetch job log. GitHub requires downloading workflow run logs as a ZIP.
--- Falls back to "not available" when run ID cannot be determined.
function M.get_job_trace(client, ctx, review, job_id)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  -- Fetch the check run to find the workflow run ID
  local cr_path = string.format("/repos/%s/%s/check-runs/%d", owner, repo, job_id)
  local cr_result, cr_err = client.get(ctx.base_url, cr_path, { headers = headers })
  if not cr_result then return nil, cr_err end
  local run_id = extract_run_id(cr_result.data and cr_result.data.details_url)
  if not run_id then return nil, "Cannot determine workflow run for log download" end
  -- Download logs
  local log_path = string.format("/repos/%s/%s/actions/runs/%s/logs", owner, repo, run_id)
  local log_result, log_err = client.get(ctx.base_url, log_path, { headers = headers })
  if not log_result then return nil, log_err end
  return type(log_result.data) == "string" and log_result.data or "Log download returned non-text data"
end

--- Retry a job by re-running its workflow.
function M.retry_job(client, ctx, review, job_id)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local cr_path = string.format("/repos/%s/%s/check-runs/%d", owner, repo, job_id)
  local cr_result, cr_err = client.get(ctx.base_url, cr_path, { headers = headers })
  if not cr_result then return nil, cr_err end
  local run_id = extract_run_id(cr_result.data and cr_result.data.details_url)
  if not run_id then return nil, "Cannot determine workflow run" end
  local path = string.format("/repos/%s/%s/actions/runs/%s/rerun", owner, repo, run_id)
  return client.post(ctx.base_url, path, { body = {}, headers = headers })
end

--- Cancel a running workflow.
function M.cancel_job(client, ctx, review, job_id)
  local headers, err = get_headers()
  if not headers then return nil, err end
  local owner, repo = parse_owner_repo(ctx)
  local cr_path = string.format("/repos/%s/%s/check-runs/%d", owner, repo, job_id)
  local cr_result, cr_err = client.get(ctx.base_url, cr_path, { headers = headers })
  if not cr_result then return nil, cr_err end
  local run_id = extract_run_id(cr_result.data and cr_result.data.details_url)
  if not run_id then return nil, "Cannot determine workflow run" end
  local path = string.format("/repos/%s/%s/actions/runs/%s/cancel", owner, repo, run_id)
  return client.post(ctx.base_url, path, { body = {}, headers = headers })
end

--- GitHub does not support triggering manual jobs directly.
function M.play_job(client, ctx, review, job_id) -- luacheck: ignore ctx review job_id
  return nil, "Manual job trigger not supported on GitHub"
end

return M
