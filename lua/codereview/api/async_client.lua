--- Async client adapter.
--- Drop-in replacement for api/client — maps method names to their async variants.
--- Pass this instead of client inside plenary.async.run() blocks.
local client = require("codereview.api.client")
local M = {}

M.get = client.async_get
M.post = client.async_post
M.put = client.async_put
M.delete = client.async_delete
M.patch = client.async_patch
M.get_url = client.async_get_url
M.paginate_all = client.async_paginate_all
M.paginate_all_url = client.async_paginate_all_url
M.graphql = client.async_graphql

-- Pass-through for non-IO methods
M.build_url = client.build_url
M.parse_next_url = client.parse_next_url

return M
