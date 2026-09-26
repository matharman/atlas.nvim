---@class GerritLabelSummary
---@field status "approved"|"rejected"|"recommended"|"disliked"|"neutral"
---@field min integer
---@field max integer
---@field blocking boolean
---@field optional boolean

---@class GerritPullRequest : PullRequest
---@field change_id string
---@field patch_set integer|nil
---@field labels table<string, GerritLabelSummary>
---@field permitted_labels table<string, string[]>|nil
---@field unresolved_comments_count integer
---@field lines_added integer|nil
---@field lines_removed integer|nil

---@class GerritPullRequestDetails : PullRequestDetails
---@field change_id string
---@field topic string|nil
---@field labels PullsLabel[]

local changes_api = require("atlas.pulls.providers.gerrit.api.changes")
local checks_api = require("atlas.pulls.providers.gerrit.api.checks")
local comments_api = require("atlas.pulls.providers.gerrit.api.comments")
local config = require("atlas.config")
local detail_ui = require("atlas.pulls.providers.gerrit.ui.detail")
local gerrit_query = require("atlas.providers.gerrit.query")
local git = require("atlas.core.git")
local request_scope = require("atlas.core.requests")
local reviews_api = require("atlas.pulls.providers.gerrit.api.reviews")

---@return AtlasGerritPullsViewConfig[]
local function views()
	local options = config.domain_options("gerrit", "pulls") or {}
	local configured = options.views or {}
	if #configured == 0 then
		configured = {
			{ name = "Mine", key = "1", search = "owner:self status:open" },
			{ name = "Review requested", key = "2", search = "reviewer:self -owner:self status:open" },
			{ name = "Current repo", key = "3", layout = "compact", current_repo = true },
		}
	end
	return vim.tbl_map(function(view)
		return vim.tbl_extend("force", {}, view)
	end, configured)
end

---@param view AtlasGerritPullsViewConfig
---@param on_done fun(view: AtlasGerritPullsViewConfig)
---@return { cancel: fun() }|nil
local function resolve_view(view, on_done)
	if not view.current_repo then
		on_done(view)
		return nil
	end
	return git.local_repository(vim.fn.getcwd(), function(target)
		local resolved = vim.tbl_extend("force", {}, view)
		if target and target.provider == "gerrit" and target.repo_full_name then
			resolved.search = gerrit_query.for_project(target.repo_full_name, view.search or "status:open")
		end
		on_done(resolved)
	end)
end

---@param view AtlasGerritPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(page: PullsPage, err: string[]|nil)
---@return AtlasRequestScope
local function fetch_pullrequests(view, opts, on_done)
	local requests = request_scope.new()
	requests.run(function(done)
		return resolve_view(view, done)
	end, function(resolved)
		requests.run(function(done)
			return changes_api.fetch_pullrequests(resolved, opts, done)
		end, on_done)
	end)
	return requests
end

-- Gerrit changes have no source branch, so `branch` cannot narrow the search.
---@param repository AtlasTarget
---@param _branch string|nil
---@return AtlasGerritPullsViewConfig
local function repository_view(repository, _branch)
	return {
		name = "Search",
		layout = "compact",
		search = gerrit_query.for_project(repository.repo_full_name or "", "status:open"),
	}
end

return {
	views = views,
	repository_view = repository_view,
	resolve_search = gerrit_query.query,
	capabilities = {
		actions = require("atlas.pulls.providers.gerrit.actions.registry"),
		core = {
			fetch_pullrequests = fetch_pullrequests,
			fetch_by_refs = changes_api.fetch_by_refs,
			fetch_pullrequest = changes_api.fetch_pullrequest,
			fetch_links = changes_api.fetch_links,
			fetch_description = changes_api.fetch_description,
			fetch_reviewers = changes_api.fetch_reviewers,
			fetch_merge_checks = checks_api.fetch,
			-- merge = nil,
			decline = changes_api.decline,
			fetch_diffstat = changes_api.fetch_diffstat,
			fetch_commits = changes_api.fetch_commits,
		},
		write = {
			-- create = nil,
			update = changes_api.update_pr,
			fetch_reviewer_candidates = changes_api.fetch_reviewer_candidates,
			-- fetch_labels = nil,
			-- fetch_assignees = nil,
		},
		comments = {
			fetch_conversation = reviews_api.fetch_conversation,
			add_comment = comments_api.add_comment,
			edit_comment = comments_api.edit_comment,
			delete_comment = comments_api.delete_comment,
			-- reactions = nil,
			set_thread_resolved = comments_api.set_thread_resolved,
		},
		reviews = {
			fetch = reviews_api.fetch,
			fetch_threads = reviews_api.fetch_threads,
			fetch_review_context = reviews_api.fetch_review_context,
			-- edit_review = nil,
			-- start_review = nil,
			submit_review = reviews_api.submit_review,
			approve = reviews_api.approve,
			request_changes = reviews_api.request_changes,
			discard_review = reviews_api.discard_review,
			set_files_reviewed = reviews_api.set_files_reviewed,
		},
		-- tasks = nil,
		-- pipelines = nil,
		ui = {
			detail = detail_ui,
		},
	},
}
