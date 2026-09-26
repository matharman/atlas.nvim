---@type PullsProviderDetail
local M = {}

local header = require("atlas.pulls.ui.components.header")

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@param loading boolean
---@return PullsDetailHeaderField[]
function M.header_fields(pr, details, loading)
	---@cast pr GerritPullRequest
	local fields = {}
	if pr.patch_set then
		table.insert(fields, { label = "Patch set", value = tostring(pr.patch_set), hl = "AtlasTextMuted" })
	end
	if details == nil then
		if loading then
			table.insert(fields, header.loading_field("Change-Id"))
		end
		return fields
	end
	---@cast details GerritPullRequestDetails
	if details.change_id ~= "" then
		table.insert(fields, { label = "Change-Id", value = details.change_id, hl = "AtlasTextMuted" })
	end
	if details.topic and details.topic ~= "" then
		table.insert(fields, { label = "Topic", value = details.topic })
	end
	return fields
end

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param loading boolean
---@return PullsDetailChip[]
function M.chips(_pr, details, loading)
	if details == nil or loading then
		return {}
	end
	local chips = {}
	for _, label in ipairs(details.labels or {}) do
		table.insert(chips, { label = label.name, hl = "AtlasTabInactive" })
	end
	return chips
end

---@return PullsDetailTab[]
function M.tabs()
	return require("atlas.pulls.ui.detail").default_tabs()
end

return M
