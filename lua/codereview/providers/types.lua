local M = {}

function M.normalize_review(raw)
  return {
    id = raw.id,
    title = raw.title or "",
    author = raw.author or "",
    source_branch = raw.source_branch or "",
    target_branch = raw.target_branch or "main",
    state = raw.state or "unknown",
    base_sha = raw.base_sha,
    head_sha = raw.head_sha,
    start_sha = raw.start_sha,
    web_url = raw.web_url or "",
    description = raw.description or "",
    pipeline_status = raw.pipeline_status,
    approved_by = raw.approved_by or {},
    approvals_required = raw.approvals_required or 0,
    sha = raw.sha or raw.head_sha,
    merge_status = raw.merge_status,
  }
end

function M.normalize_note(raw)
  return {
    id = raw.id,
    author = raw.author or "",
    body = raw.body or "",
    created_at = raw.created_at or "",
    system = raw.system or false,
    resolvable = raw.resolvable or false,
    resolved = raw.resolved or false,
    resolved_by = raw.resolved_by,
    position = raw.position,
  }
end

function M.normalize_discussion(raw)
  local notes = {}
  for _, n in ipairs(raw.notes or {}) do
    table.insert(notes, M.normalize_note(n))
  end
  return { id = raw.id, resolved = raw.resolved or false, notes = notes }
end

function M.normalize_file_diff(raw)
  return {
    diff = raw.diff or "",
    new_path = raw.new_path or "",
    old_path = raw.old_path or "",
    renamed_file = raw.renamed_file or false,
    new_file = raw.new_file or false,
    deleted_file = raw.deleted_file or false,
  }
end

function M.normalize_pipeline(raw)
  return {
    id = raw.id,
    status = raw.status or "unknown",
    ref = raw.ref or "",
    sha = raw.sha or "",
    web_url = raw.web_url or "",
    created_at = raw.created_at or "",
    updated_at = raw.updated_at or "",
    duration = raw.duration or 0,
  }
end

function M.normalize_pipeline_job(raw)
  return {
    id = raw.id,
    name = raw.name or "",
    stage = raw.stage or "",
    status = raw.status or "unknown",
    duration = raw.duration or 0,
    web_url = raw.web_url or "",
    allow_failure = raw.allow_failure or false,
    started_at = raw.started_at or "",
    finished_at = raw.finished_at or "",
  }
end

return M
