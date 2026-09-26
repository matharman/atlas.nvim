local M = {}

local changes_api = require("atlas.pulls.providers.gerrit.api.changes")
local client = require("atlas.providers.gerrit.client")
local comments_api = require("atlas.pulls.providers.gerrit.api.comments")
local config = require("atlas.config")
local mapper = require("atlas.pulls.providers.gerrit.api.mapper")
local request_scope = require("atlas.core.requests")

---@param pr PullRequest
---@return string
local function revision(pr)
	return pr.source.commit_hash ~= "" and pr.source.commit_hash or "current"
end

---@param pr PullRequest
---@return string
local function revision_path(pr)
	return changes_api.change_path(pr) .. "/revisions/" .. revision(pr)
end

---@param change table ChangeInfo with MESSAGES.
---@return PullsReviewHistoryEntry[] history, table<string, boolean> commented
local function history(change)
	local entries, commented = {}, {}
	for _, message in ipairs(change.messages or {}) do
		local entry, vote = mapper.to_history(message)
		if entry then
			table.insert(entries, entry)
			if vote == nil and entry.author then
				commented[entry.author.id] = true
			end
		end
	end
	return entries, commented
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }
function M.fetch(pr, opts, on_done)
	---@cast pr GerritPullRequest
	local requests = request_scope.new()
	requests.all({
		change = function(done)
			return changes_api.fetch_change(pr, opts, done)
		end,
		comments = function(done)
			return comments_api.fetch_comments(pr, opts, done)
		end,
	}, function(values, errors)
		if errors.change or errors.comments then
			on_done(nil, errors.change or errors.comments)
			return
		end
		local change = values.change
		pr.permitted_labels = change.permitted_labels or pr.permitted_labels

		local comments, pending = {}, false
		for _, comment in ipairs(values.comments) do
			pending = pending or comment.pending == true
			if comment.inline or comment.file then
				table.insert(comments, comment)
			end
		end
		local entries, commented = history(change)
		on_done({
			review = { id = nil, commit_hash = nil, pending = pending },
			comments = comments,
			tasks = {},
			reviewers = mapper.to_reviewers(change, commented) or {},
			history = entries,
		}, nil)
	end)
	return requests
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(data: PullsReviewData|nil, err: string|nil)
---@return { cancel: fun() }
function M.fetch_threads(pr, opts, on_done)
	local requests = request_scope.new()
	requests.run(function(done)
		return M.fetch(pr, opts, done)
	end, function(data, err)
		if not data then
			on_done(nil, err)
			return
		end
		local roots_by_path = {}
		for _, comment in ipairs(data.comments) do
			if comment.parent_id == nil and comment.inline and not comment.outdated and comment.hunk == nil then
				local path = comment.inline.path
				roots_by_path[path] = roots_by_path[path] or {}
				table.insert(roots_by_path[path], comment)
			end
		end
		local starts = {}
		for path in pairs(roots_by_path) do
			starts[path] = function(done)
				return changes_api.fetch_file_diff(pr, path, opts, done)
			end
		end
		-- A missing snippet only hides the code preview, so diff errors are dropped.
		requests.all(starts, function(files)
			for path, roots in pairs(roots_by_path) do
				for _, root in ipairs(files[path] and roots or {}) do
					local inline = root.inline
					local side = inline.to and "new" or "old"
					root.hunk = mapper.hunk_at(files[path], side, inline.to or inline.from)
				end
			end
			on_done(data, nil)
		end)
	end)
	return requests
end

---@param change table ChangeInfo
---@return PullsReviewHistoryEntry[] reviews, PullsActivityEntry[] activities
local function message_entries(change)
	local reviews, activities = {}, {}
	for _, message in ipairs(change.messages or {}) do
		local entry = mapper.to_history(message)
		local activity = entry == nil and mapper.to_activity(message) or nil
		if entry then
			table.insert(reviews, entry)
		elseif activity then
			table.insert(activities, activity)
		end
	end
	return reviews, activities
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(conversation: PullsConversation|nil, err: string|nil)
---@return { cancel: fun() }
function M.fetch_conversation(pr, opts, on_done)
	local requests = request_scope.new()
	requests.all({
		change = function(done)
			return changes_api.fetch_change(pr, opts, done)
		end,
		comments = function(done)
			return comments_api.fetch_conversation_comments(pr, opts, done)
		end,
	}, function(values, errors)
		if values.change == nil and values.comments == nil then
			on_done(nil, errors.change or errors.comments)
			return
		end
		local reviews, activities = {}, {}
		if values.change then
			reviews, activities = message_entries(values.change)
		end
		on_done({
			comments = values.comments or {},
			reviews = reviews,
			activities = activities,
		}, errors.change or errors.comments)
	end)
	return requests
end

---@param value string
---@return integer|nil
local function parse_vote(value)
	return tonumber((tostring(value):gsub("[%s+]", "")))
end

---@param permitted table<string, string[]>|nil
---@param vote integer
---@return integer|nil vote, string|nil err
function M.clamp_vote(permitted, vote)
	local values = permitted and permitted[mapper.CODE_REVIEW] or nil
	if type(values) ~= "table" or #values == 0 then
		return nil, "You cannot vote on Code-Review for this change"
	end
	local min, max = 0, 0
	for _, value in ipairs(values) do
		local parsed = parse_vote(value)
		if parsed then
			min, max = math.min(min, parsed), math.max(max, parsed)
		end
	end
	local clamped = math.max(min, math.min(max, vote))
	if clamped == 0 then
		return nil, string.format("You cannot vote Code-Review%+d on this change", vote)
	end
	return clamped, nil
end

---@param pr PullRequest
---@param body string|nil
---@param vote integer|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
local function publish(pr, body, vote, on_done)
	local requests = request_scope.new()

	---@param labels table|nil
	local function post(labels)
		local input = { drafts = "PUBLISH_ALL_REVISIONS", labels = labels }
		if body and vim.trim(body) ~= "" then
			input.message = body
		end
		requests.run(function(done)
			return client.request("POST", revision_path(pr) .. "/review", input, done, {
				action = "Publish Gerrit review",
				change = tostring(pr.id),
			})
		end, function(_, err)
			if err then
				on_done(false, err)
				return
			end
			client.invalidate_change(pr.id)
			on_done(true, nil)
		end)
	end

	if vote == nil then
		post(nil)
		return requests
	end
	requests.run(function(done)
		return changes_api.fetch_change(pr, { force_refresh = true }, done)
	end, function(change, err)
		if not change then
			on_done(false, err)
			return
		end
		local clamped, clamp_err = M.clamp_vote(change.permitted_labels, vote)
		if not clamped then
			on_done(false, clamp_err)
			return
		end
		post({ [mapper.CODE_REVIEW] = clamped })
	end)
	return requests
end

---@param key "approve_vote"|"request_changes_vote"
---@param default integer
---@return integer
local function configured_vote(key, default)
	local options = config.provider_options("gerrit") or {}
	return tonumber(options[key]) or default
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.submit_review(pr, _review, body, on_done)
	return publish(pr, body, nil, on_done)
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.approve(pr, _review, body, on_done)
	return publish(pr, body, configured_vote("approve_vote", 1), on_done)
end

---@param pr PullRequest
---@param _review PullsReview|nil
---@param body string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.request_changes(pr, _review, body, on_done)
	return publish(pr, body, configured_vote("request_changes_vote", -1), on_done)
end

---@param pr PullRequest
---@param _review PullsReview
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.discard_review(pr, _review, on_done)
	local requests = request_scope.new()
	requests.run(function(done)
		return comments_api.fetch_comments(pr, { force_refresh = true }, done)
	end, function(comments, err)
		if not comments then
			on_done(false, err)
			return
		end
		local drafts = vim.tbl_filter(function(comment)
			return comment.pending == true
		end, comments)
		local function next_draft(index)
			local draft = drafts[index]
			if draft == nil then
				client.invalidate_change(pr.id)
				on_done(true, nil)
				return
			end
			requests.run(function(done)
				return comments_api.delete_draft(pr, draft, done)
			end, function(ok, delete_err)
				if not ok then
					on_done(false, delete_err)
					return
				end
				next_draft(index + 1)
			end)
		end
		next_draft(1)
	end)
	return requests
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(context: PullsReviewContext|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_review_context(pr, opts, on_done)
	local cache_key = string.format("gerrit:change:%s:reviewed:%s", tostring(pr.id), revision(pr))
	---@param paths string[]
	local function finish(paths)
		local reviewed_files = {}
		for _, path in ipairs(paths) do
			reviewed_files[path] = true
		end
		on_done({ reviewed_files = reviewed_files }, nil)
	end
	if not (opts and opts.force_refresh) then
		local cached, ok = client.get_cache(cache_key)
		if ok then
			finish(cached)
			return nil
		end
	end
	return client.request("GET", revision_path(pr) .. "/files?reviewed", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local paths = type(result) == "table" and result or {}
		client.set_cache(cache_key, paths)
		finish(paths)
	end, { action = "Fetch Gerrit reviewed files", change = tostring(pr.id) })
end

-- Gerrit marks files one at a time.
---@param pr PullRequest
---@param paths string[]
---@param reviewed boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.set_files_reviewed(pr, paths, reviewed, on_done)
	local starts = {}
	for _, path in ipairs(paths) do
		local endpoint = string.format("%s/files/%s/reviewed", revision_path(pr), client.url_encode(path))
		starts[path] = function(done)
			return client.request(reviewed and "PUT" or "DELETE", endpoint, nil, done, {
				action = reviewed and "Mark Gerrit file reviewed" or "Mark Gerrit file unreviewed",
				change = tostring(pr.id),
				path = path,
			})
		end
	end
	local requests = request_scope.new()
	requests.all(starts, function(_, errors)
		client.invalidate_change(pr.id)
		local failed = {}
		for path, err in pairs(errors) do
			table.insert(failed, string.format("%s: %s", path, err))
		end
		table.sort(failed)
		on_done(#failed == 0, #failed > 0 and table.concat(failed, "; ") or nil)
	end)
	return requests
end

return M
