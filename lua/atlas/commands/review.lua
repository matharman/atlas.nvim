local config = require("atlas.config")
local diff = require("atlas.pulls.diff")
local git = require("atlas.core.git")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local providers = require("atlas.providers")
local ui_utils = require("atlas.ui.shared.utils")
local request_scope = require("atlas.core.requests")

local M = {}

local requests = request_scope.new()

local function no_repository()
	notify.error("No supported Git repository found", { vim_notify = true })
end

---@param value string
---@return boolean
local function is_change_id(value)
	return #value == 41 and value:match("^I%x+$") ~= nil
end

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@return AtlasPickerPreview
local function format_preview(pr, details)
	---@cast pr GitHubPullRequest
	local author = pr.author.username ~= "" and "@" .. pr.author.username or pr.author.name
	local status = pr.state .. "   updated " .. ui_utils.relative_time(pr.updated_on)
	if pr.lines_added ~= nil and pr.lines_removed ~= nil then
		status = status .. string.format("   +%d -%d", pr.lines_added, pr.lines_removed)
	end
	local description = ui_utils.strip_markup(details and details.description or "")
	local lines = {
		author,
		pr.source.branch .. " → " .. pr.destination.branch,
		status,
		"",
	}
	vim.list_extend(lines, vim.split(description ~= "" and description or "No description", "\n", { plain = true }))
	return {
		title = "#" .. tostring(pr.id),
		lines = lines,
	}
end

---@param pr PullRequest|nil
local function open_diff(pr)
	if not pr then
		return
	end
	diff.open_pr(pr, function(err)
		if err then
			notify.error("Unable to open diff: " .. tostring(err), { vim_notify = true })
		end
	end)
end

---@param repository AtlasTarget|nil
---@param branch string|nil
local function open_repository(repository, branch)
	if not repository then
		no_repository()
		return
	end
	if not providers.domain(repository.provider, "pulls") or not config.provider_options(repository.provider) then
		no_repository()
		return
	end

	local provider = assert(providers.load(repository.provider, "pulls"))
	---@cast provider PullsProvider
	local repo_full_name = assert(repository.repo_full_name, "Repository target missing repo_full_name")
	local view = provider.repository_view(repository, branch)
	local label = branch and (branch .. " in " .. repo_full_name) or repo_full_name
	notify.info("Fetching pull requests for " .. label .. "...", { vim_notify = true })
	requests.run(function(done)
		return provider.capabilities.core.fetch_pullrequests(view, { force_refresh = true, pagelen = 50 }, done)
	end, function(page, errors)
		if errors and #errors > 0 then
			notify.error(table.concat(errors, "; "), { vim_notify = true })
			return
		end

		local pulls = page.items
		local pull_requests = {}
		for _, pr in ipairs(pulls) do
			if pr.state == "open" or pr.state == "draft" then
				table.insert(pull_requests, pr)
			end
		end
		if #pull_requests == 0 then
			notify.info("No open pull requests found for " .. label, { vim_notify = true })
			return
		end
		if branch and #pull_requests == 1 then
			open_diff(pull_requests[1])
			return
		end

		picker.select_with_preview({
			title = "Review pull request",
			items = pull_requests,
			key = function(pr)
				return tostring(pr.id)
			end,
			format_item = function(pr)
				return string.format("#%s %s", tostring(pr.id), pr.title)
			end,
			preview_item = function(pr, done)
				return provider.capabilities.core.fetch_pullrequest(
					pr,
					{ force_refresh = false },
					function(details, err)
						if err then
							done({ title = "#" .. tostring(pr.id), lines = { err } })
							return
						end
						done(format_preview(pr, details))
					end
				)
			end,
			on_select = open_diff,
		})
	end)
end

---@param target string|nil A pull request URL, a number in the current repository (or on the configured Gerrit host outside one), a Gerrit Change-Id, "." for the current branch's pull request, or nil to pick one.
function M.open(target)
	requests.cancel()
	requests = request_scope.new()
	if not target then
		requests.run(function(done)
			return git.local_repository(nil, done)
		end, open_repository)
		return
	end
	if target == "." then
		local cwd = git.default_cwd()
		requests.all({
			repository = function(done)
				return git.local_repository(cwd, done)
			end,
			branch = function(done)
				return git.current_branch(cwd, done)
			end,
		}, function(values, errors)
			if values.repository and not values.branch then
				notify.warn(errors.branch, { vim_notify = true })
			end
			open_repository(values.repository, values.branch)
		end)
		return
	end

	---@param ref AtlasTarget
	local function open_target(ref)
		diff.open_pr(ref, function(open_err)
			if open_err then
				notify.error(open_err, { vim_notify = true })
			end
		end)
	end

	local function open_reference(repository)
		local pr, err = providers.resolve(target, { repository = repository, domain = "pulls" })
		if not pr or pr.domain ~= "pulls" or pr.entity ~= "pr" then
			notify.error(err or "Expected a pull request URL or number", { vim_notify = true })
			return
		end
		open_target(pr)
	end

	local change_id = is_change_id(target)
	if change_id or target:match("^[#!]?%d+$") then
		requests.run(function(done)
			return git.local_repository(nil, done)
		end, function(repository)
			local local_provider = repository
					and config.provider_options(repository.provider)
					and repository.provider
				or nil
			if local_provider == nil and config.provider_options("gerrit") and (change_id or target:match("^#?%d+$")) then
				local number = tonumber((target:gsub("^#", "")))
				open_target({
					provider = "gerrit",
					domain = "pulls",
					entity = "pr",
					id = number or target,
					number = number,
				})
				return
			end
			if not change_id then
				open_reference(repository)
				return
			end
			if local_provider ~= "gerrit" then
				notify.error("Change-Ids are only supported for Gerrit", { vim_notify = true })
				return
			end
			---@cast repository AtlasTarget
			open_target(vim.tbl_extend("force", {}, repository, { domain = "pulls", entity = "pr", id = target }))
		end)
	else
		open_reference(nil)
	end
end

return M
