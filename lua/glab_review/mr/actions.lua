local client = require("glab_review.api.client")
local endpoints = require("glab_review.api.endpoints")
local git = require("glab_review.git")
local M = {}

function M.build_merge_params(opts)
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

  if opts.sha then
    params.sha = opts.sha
  end

  return params
end

function M.approve(mr)
  local base_url, project = git.detect_project()
  if not base_url or not project then
    return nil, "Could not detect GitLab project"
  end

  local encoded = client.encode_project(project)
  local body = {}
  if mr.sha then
    body.sha = mr.sha
  end

  return client.post(base_url, endpoints.mr_approve(encoded, mr.iid), { body = body })
end

function M.unapprove(mr)
  local base_url, project = git.detect_project()
  if not base_url or not project then
    return nil, "Could not detect GitLab project"
  end

  local encoded = client.encode_project(project)
  return client.post(base_url, endpoints.mr_unapprove(encoded, mr.iid), { body = {} })
end

function M.merge(mr, opts)
  local base_url, project = git.detect_project()
  if not base_url or not project then
    return nil, "Could not detect GitLab project"
  end

  local encoded = client.encode_project(project)
  local params = M.build_merge_params(opts or {})
  if mr.sha then
    params.sha = mr.sha
  end

  return client.put(base_url, endpoints.mr_merge(encoded, mr.iid), { body = params })
end

function M.close(mr)
  local base_url, project = git.detect_project()
  if not base_url or not project then
    return nil, "Could not detect GitLab project"
  end

  local encoded = client.encode_project(project)
  return client.put(base_url, endpoints.mr_detail(encoded, mr.iid), {
    body = { state_event = "close" },
  })
end

return M
