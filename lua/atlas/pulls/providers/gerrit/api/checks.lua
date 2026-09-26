local M = {}

local changes_api = require("atlas.pulls.providers.gerrit.api.changes")
local mapper = require("atlas.pulls.providers.gerrit.api.mapper")

local PRIORITY = { [mapper.CODE_REVIEW] = 1, [mapper.VERIFIED] = 2 }

---@param label table LabelInfo
---@return string[]
local function voters(label)
	local details = {}
	for _, approval in ipairs(type(label.all) == "table" and label.all or {}) do
		local value = tonumber(approval.value) or 0
		if value ~= 0 then
			table.insert(details, string.format("%s: %+d", mapper.to_author(approval).name, value))
		end
	end
	return details
end

---@param name string
---@param label table LabelInfo
---@return PullsMergeCheck
local function label_check(name, label)
	local summary = assert(mapper.label_summary(label))
	local state, text = "inprogress", "needs a vote"
	if summary.status == "rejected" then
		state, text = "failed", "rejected"
	elseif summary.status == "approved" then
		state, text = "successful", "approved"
	elseif summary.status == "disliked" then
		state, text = "warning", "disliked"
	elseif summary.status == "recommended" then
		state, text = "inprogress", "recommended"
	elseif summary.optional then
		state, text = "muted", "optional"
	end
	local details = voters(label)
	return {
		key = "label:" .. name,
		state = state,
		label = string.format("%s %s", name, text),
		details = #details > 0 and details or nil,
	}
end

---@param change table ChangeInfo
---@return PullsMergeCheck[]
function M.to_checks(change)
	local checks = {}
	if change.work_in_progress == true then
		table.insert(checks, {
			key = "wip",
			state = "warning",
			label = "This change is work in progress",
		})
	end

	local names = vim.tbl_keys(type(change.labels) == "table" and change.labels or {})
	table.sort(names, function(a, b)
		local left, right = PRIORITY[a] or 99, PRIORITY[b] or 99
		return left == right and a < b or left < right
	end)
	for _, name in ipairs(names) do
		table.insert(checks, label_check(name, change.labels[name]))
	end

	local unresolved = tonumber(change.unresolved_comment_count) or 0
	if unresolved > 0 then
		table.insert(checks, {
			key = "unresolved",
			state = "warning",
			label = string.format("%d unresolved comment%s", unresolved, unresolved == 1 and "" or "s"),
		})
	end
	return checks
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(checks: PullsMergeCheck[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch(pr, opts, on_done)
	return changes_api.fetch_change(pr, opts, function(change, err)
		if not change then
			on_done(nil, err)
			return
		end
		on_done(M.to_checks(change), nil)
	end)
end

return M
