local M = {}

M.EMOJIS = {
  { name = "thumbsup", icon = "👍", github = "+1", gitlab = "thumbsup", github_graphql = "THUMBS_UP" },
  { name = "thumbsdown", icon = "👎", github = "-1", gitlab = "thumbsdown", github_graphql = "THUMBS_DOWN" },
  { name = "laugh", icon = "😄", github = "laugh", gitlab = "laughing", github_graphql = "LAUGH" },
  { name = "confused", icon = "😕", github = "confused", gitlab = "confused", github_graphql = "CONFUSED" },
  { name = "heart", icon = "❤️", github = "heart", gitlab = "heart", github_graphql = "HEART" },
  { name = "hooray", icon = "🎉", github = "hooray", gitlab = "tada", github_graphql = "HOORAY" },
  { name = "rocket", icon = "🚀", github = "rocket", gitlab = "rocket", github_graphql = "ROCKET" },
  { name = "eyes", icon = "👀", github = "eyes", gitlab = "eyes", github_graphql = "EYES" },
}

-- Reverse lookup tables built at module load time for O(1) conversion
local by_name_map = {}
local by_github_map = {}
local by_gitlab_map = {}
local by_github_graphql_map = {}

for _, entry in ipairs(M.EMOJIS) do
  by_name_map[entry.name] = entry
  by_github_map[entry.github] = entry
  by_gitlab_map[entry.gitlab] = entry
  by_github_graphql_map[entry.github_graphql] = entry
end

--- Returns the emoji entry by normalized name, or nil.
function M.by_name(name)
  return by_name_map[name]
end

--- Converts a GitHub GraphQL enum (e.g. "THUMBS_UP") to normalized name (e.g. "thumbsup").
function M.from_github_graphql(content)
  local entry = by_github_graphql_map[content]
  return entry and entry.name or nil
end

--- Converts a GitHub REST API name (e.g. "+1") to normalized name.
function M.from_github(api_name)
  local entry = by_github_map[api_name]
  return entry and entry.name or nil
end

--- Converts a GitLab API name (e.g. "tada") to normalized name.
function M.from_gitlab(api_name)
  local entry = by_gitlab_map[api_name]
  return entry and entry.name or nil
end

--- Converts a normalized name to the provider-specific API name.
--- provider_name is "github" or "gitlab".
function M.to_provider(name, provider_name)
  local entry = by_name_map[name]
  if not entry then
    return nil
  end
  return entry[provider_name]
end

--- Converts a normalized name to the GitHub GraphQL enum string.
function M.to_github_graphql(name)
  local entry = by_name_map[name]
  return entry and entry.github_graphql or nil
end

return M
