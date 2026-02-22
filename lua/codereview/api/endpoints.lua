local M = {}

local function project_path(project_id)
  return "/projects/" .. project_id
end

local function mr_path(project_id, iid)
  return project_path(project_id) .. "/merge_requests/" .. iid
end

function M.mr_list(project_id)
  return project_path(project_id) .. "/merge_requests"
end

function M.mr_detail(project_id, iid)
  return mr_path(project_id, iid)
end

function M.mr_diffs(project_id, iid)
  return mr_path(project_id, iid) .. "/diffs"
end

function M.mr_approve(project_id, iid)
  return mr_path(project_id, iid) .. "/approve"
end

function M.mr_unapprove(project_id, iid)
  return mr_path(project_id, iid) .. "/unapprove"
end

function M.mr_merge(project_id, iid)
  return mr_path(project_id, iid) .. "/merge"
end

function M.discussions(project_id, iid)
  return mr_path(project_id, iid) .. "/discussions"
end

function M.discussion_notes(project_id, iid, discussion_id)
  return mr_path(project_id, iid) .. "/discussions/" .. discussion_id .. "/notes"
end

function M.discussion(project_id, iid, discussion_id)
  return mr_path(project_id, iid) .. "/discussions/" .. discussion_id
end

function M.draft_notes(project_id, iid)
  return mr_path(project_id, iid) .. "/draft_notes"
end

function M.draft_note(project_id, iid, draft_note_id)
  return mr_path(project_id, iid) .. "/draft_notes/" .. draft_note_id
end

function M.draft_notes_publish(project_id, iid)
  return mr_path(project_id, iid) .. "/draft_notes/bulk_publish"
end

function M.mr_pipelines(project_id, iid)
  return mr_path(project_id, iid) .. "/pipelines"
end

function M.pipeline(project_id, pipeline_id)
  return project_path(project_id) .. "/pipelines/" .. pipeline_id
end

function M.pipeline_jobs(project_id, pipeline_id)
  return project_path(project_id) .. "/pipelines/" .. pipeline_id .. "/jobs"
end

function M.job_trace(project_id, job_id)
  return project_path(project_id) .. "/jobs/" .. job_id .. "/trace"
end

return M
