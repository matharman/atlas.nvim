local M = {}

---@class GerritAuthor : AtlasUser
---@field email string|nil

---@param raw table|nil AccountInfo
---@return GerritAuthor
function M.to_author(raw)
	if type(raw) ~= "table" then
		return { name = "Unknown", id = "", username = "unknown" }
	end
	local username = raw.username or raw.email or raw.name or tostring(raw._account_id or "unknown")
	local name = raw.display_name or raw.name or username
	return {
		name = name,
		id = tostring(raw._account_id or ""),
		username = username,
		email = raw.email,
	}
end

return M
