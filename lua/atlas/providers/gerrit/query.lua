-- Gerrit search syntax:
-- https://gerrit-review.googlesource.com/Documentation/user-search.html

local M = {}

---@type PullsStateFilter[]
local ALL_STATES = { "open", "merged", "declined" }
local API_STATES = { open = "open", merged = "merged", declined = "abandoned" }
---@type table<string, PullsStateFilter[]>
local STATUS_TOKENS = {
	["status:open"] = { "open" },
	["status:new"] = { "open" },
	["status:pending"] = { "open" },
	["status:merged"] = { "merged" },
	["status:abandoned"] = { "declined" },
	["status:closed"] = { "merged", "declined" },
	["is:open"] = { "open" },
	["is:merged"] = { "merged" },
	["is:abandoned"] = { "declined" },
	["is:closed"] = { "merged", "declined" },
}

---@param input string
---@return string[]
local function tokenize(input)
	local tokens, current = {}, {}
	local quoted = false
	for i = 1, #input do
		local char = input:sub(i, i)
		if char == '"' then
			quoted = not quoted
			table.insert(current, char)
		elseif char:match("%s") and not quoted then
			if #current > 0 then
				table.insert(tokens, table.concat(current))
				current = {}
			end
		else
			table.insert(current, char)
		end
	end
	if #current > 0 then
		table.insert(tokens, table.concat(current))
	end
	return tokens
end

---@param input string|nil
---@return string remaining, PullsStateFilter[]|nil states
function M.split_states(input)
	local remaining, selected = {}, nil
	local depth = 0
	for _, token in ipairs(tokenize(input or "")) do
		local states = depth == 0 and STATUS_TOKENS[token:lower()] or nil
		if states then
			selected = selected or {}
			for _, state in ipairs(states) do
				selected[state] = true
			end
		else
			table.insert(remaining, token)
			local _, opened = token:gsub("%(", "")
			local _, closed = token:gsub("%)", "")
			depth = math.max(0, depth + opened - closed)
		end
	end
	if selected == nil then
		return table.concat(remaining, " "), nil
	end
	local states = {}
	for _, state in ipairs(ALL_STATES) do
		if selected[state] then
			table.insert(states, state)
		end
	end
	return table.concat(remaining, " "), states
end

---@param states PullsStateFilter[]
---@return string
local function state_clause(states)
	local parts = {}
	for _, state in ipairs(states) do
		table.insert(parts, "status:" .. API_STATES[state])
	end
	if #parts == 1 then
		return parts[1]
	end
	return "(" .. table.concat(parts, " OR ") .. ")"
end

---@param view AtlasPullsViewConfig
---@return string, PullsStateFilter[]
function M.query(view)
	---@cast view AtlasGerritPullsViewConfig
	local remaining, parsed = M.split_states(view.search)
	local states = view._states or parsed or { "open" }
	local clause = state_clause(states)
	return remaining ~= "" and (remaining .. " " .. clause) or clause, states
end

---@param project string
---@param search string|nil
---@return string
function M.for_project(project, search)
	local clause = "project:" .. (project:find("%s") and ('"' .. project .. '"') or project)
	search = vim.trim(search or "")
	return search ~= "" and (clause .. " " .. search) or clause
end

return M
