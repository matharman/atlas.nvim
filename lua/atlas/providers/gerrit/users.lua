local M = {
	-- list_members = nil,
	-- get_assignable_users = nil,
}
---@cast M AtlasUsersCapability

local client = require("atlas.providers.gerrit.client")
local mapper = require("atlas.providers.gerrit.mapper")

---@param on_done fun(user: AtlasUser|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_user(on_done)
	local cache_key = "gerrit:user:self"
	local cached, ok = client.get_cache(cache_key)
	if ok then
		on_done(cached, nil)
		return nil
	end
	return client.request("GET", "/accounts/self", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		if type(result) ~= "table" or result._account_id == nil then
			on_done(nil, "Invalid Gerrit account")
			return
		end
		local author = mapper.to_author(result)
		local user = { id = author.id, name = author.name, username = author.username }
		client.set_cache(cache_key, user)
		on_done(user, nil)
	end, { action = "Fetch Gerrit account" })
end

return M
