local M = {}
---@cast M AtlasActionsCapability

local actions = require("atlas.pulls.actions")
local action_utils = require("atlas.pulls.actions.utils")
local changes_api = require("atlas.pulls.providers.gerrit.api.changes")
local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.ui.picker")

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function review_available(ctx)
	if ctx.pr == nil or (ctx.pr.state ~= "open" and ctx.pr.state ~= "draft") then
		return false, "Change is not open"
	end
	return true, nil
end

---@type AtlasPullAction[]
local ACTIONS = {}
M.items = ACTIONS

---@param action AtlasPullAction
local function register(action)
	table.insert(ACTIONS, action)
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function restore(ctx, done)
	local pr = assert(ctx.pr)
	action_utils.notify(ctx, "loading", string.format("Restoring change %s...", tostring(pr.id)))
	changes_api.restore(pr, function(ok, err)
		if not ok then
			action_utils.notify(ctx, "error", err or "Restore failed")
			done(nil, err or "Restore failed")
			return
		end
		pr.state = "open"
		action_utils.notify(ctx, "success", string.format("Restored change %s", tostring(pr.id)), 1200)
		done({ changed_pr = true, message = "Restored" }, nil)
	end)
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function search(ctx, done)
	picker.search({
		title = "Search Gerrit Changes",
		fetch_on_open = false,
		format_item = function(item)
			return item.label
		end,
		fetch = function(query, fetch_done)
			query = vim.trim(query)
			if query == "" then
				fetch_done({}, nil)
				return
			end
			return changes_api.fetch_pullrequests({ name = "Search", search = query }, {
				force_refresh = false,
				pagelen = 30,
			}, function(page, errors)
				if errors then
					fetch_done(nil, table.concat(errors, "; "))
					return
				end
				local items = {}
				for _, pr in ipairs(page.items) do
					table.insert(items, {
						id = tostring(pr.id),
						label = string.format("%s %s - %s", tostring(pr.id), pr.repo_full_name, pr.title),
						value = pr,
					})
				end
				fetch_done(items, nil)
			end)
		end,
		on_select = function(item)
			require("atlas.pulls.ui.detail").open(item.value, { provider = ctx.provider })
			done(nil, nil)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

register({
	id = actions.approve.id,
	label = actions.approve.label,
	icon = actions.approve.icon,
	is_available = review_available,
	run = actions.approve.run,
})

register({
	id = actions.request_changes.id,
	label = actions.request_changes.label,
	icon = actions.request_changes.icon,
	is_available = review_available,
	run = actions.request_changes.run,
})

register(vim.tbl_extend("force", actions.decline, { label = "Abandon change" }))
register(vim.tbl_extend("force", actions.convert_to_draft, { label = "Mark as work in progress" }))
register(actions.ready_for_review)

register({
	id = "restore",
	label = "Restore change",
	icon = icons.get("reopen", "actions"),
	is_available = function(ctx)
		if ctx.pr == nil or ctx.pr.state ~= "declined" then
			return false, "Change is not abandoned"
		end
		return true, nil
	end,
	run = restore,
})

register(actions.edit_pr)
register(actions.edit_reviewers)

register({
	id = "search",
	label = "Search Changes",
	icon = icons.get("search", "actions"),
	run = search,
})

register({
	id = "edit_search",
	label = "Edit search",
	icon = icons.get("search", "actions"),
	run = function(_, done)
		local state = require("atlas.pulls.state")
		vim.ui.input({ prompt = "Search: ", default = state.query }, function(input)
			local view = state.search_view()
			if input == nil or vim.trim(input) == "" or view == nil then
				done(nil, nil)
				return
			end
			view.search = vim.trim(input)
			view._states = nil
			require("atlas.pulls.ui.dashboard.controller").refresh_view()
			done(nil, nil)
		end)
	end,
})

register(actions.open_diff)
register(actions.checkout)

register(actions.copy_id)
register(actions.copy_url)
register(actions.open_in_browser)

---@param id AtlasPullActionId|"restore"
---@return AtlasPullAction|nil
function M.find(id)
	for _, action in ipairs(ACTIONS) do
		if action.id == id then
			return action
		end
	end
	return nil
end

return M
