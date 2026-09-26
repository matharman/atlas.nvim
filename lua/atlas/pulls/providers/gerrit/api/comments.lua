local M = {}

local changes_api = require("atlas.pulls.providers.gerrit.api.changes")
local client = require("atlas.providers.gerrit.client")
local mapper = require("atlas.pulls.providers.gerrit.api.mapper")
local request_scope = require("atlas.core.requests")

-- The diff selection has no column information, so a range covers its last line up to this column.
local RANGE_END_CHARACTER = 10000

---@param pr PullRequest
---@param revision string|integer
---@return string
local function revision_path(pr, revision)
	return changes_api.change_path(pr) .. "/revisions/" .. client.url_encode(tostring(revision))
end

---@param by_path any Map of path -> CommentInfo[].
---@return table[]
local function flatten(by_path)
	local result = {}
	for path, list in pairs(type(by_path) == "table" and by_path or {}) do
		for _, raw in ipairs(type(list) == "table" and list or {}) do
			raw.path = raw.path or path
			table.insert(result, raw)
		end
	end
	return result
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_comments(pr, opts, on_done)
	---@cast pr GerritPullRequest
	local cache_key = string.format("gerrit:change:%s:comments", tostring(pr.id))
	if not (opts and opts.force_refresh) then
		local cached, ok = client.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local change = changes_api.change_path(pr)
	---@param suffix string
	---@param action string
	local function get(suffix, action)
		return function(done)
			return client.request("GET", change .. suffix, nil, done, { action = action, change = tostring(pr.id) })
		end
	end

	local requests = request_scope.new()
	requests.all({
		comments = get("/comments", "Fetch Gerrit comments"),
		drafts = get("/drafts", "Fetch Gerrit drafts"),
		ported = get("/revisions/current/ported_comments", "Fetch Gerrit ported comments"),
		ported_drafts = get("/revisions/current/ported_drafts", "Fetch Gerrit ported drafts"),
	}, function(values, errors)
		if errors.comments or errors.drafts then
			on_done(nil, errors.comments or errors.drafts)
			return
		end
		-- Servers without the porting endpoints leave older comments at their original lines.
		local ported = {}
		for _, raw in ipairs(flatten(values.ported)) do
			ported[tostring(raw.id)] = raw
		end
		for _, raw in ipairs(flatten(values.ported_drafts)) do
			ported[tostring(raw.id)] = raw
		end

		local comments = {}
		for _, kind in ipairs({ "comments", "drafts" }) do
			for _, raw in ipairs(flatten(values[kind])) do
				table.insert(
					comments,
					mapper.to_comment(raw, {
						pr = pr,
						current_patch_set = pr.patch_set,
						ported = ported[tostring(raw.id)],
						draft = kind == "drafts",
					})
				)
			end
		end
		mapper.link_threads(comments)
		client.set_cache(cache_key, comments)
		on_done(comments, nil)
	end)
	return requests
end

---@param comment GerritComment
---@return boolean
local function is_conversation(comment)
	return comment.inline == nil and comment.file == nil
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_conversation_comments(pr, opts, on_done)
	return M.fetch_comments(pr, opts, function(comments, err)
		if not comments then
			on_done(nil, err)
			return
		end
		on_done(vim.tbl_filter(is_conversation, comments), nil)
	end)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(comments: PullsComment[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_review_comments(pr, opts, on_done)
	return M.fetch_comments(pr, opts, function(comments, err)
		if not comments then
			on_done(nil, err)
			return
		end
		on_done(
			vim.tbl_filter(function(comment)
				return not is_conversation(comment)
			end, comments),
			nil
		)
	end)
end

---@param line integer
---@param start integer|nil
---@return table|nil
local function to_range(line, start)
	if start == nil or start == line then
		return nil
	end
	return {
		start_line = math.min(start, line),
		start_character = 0,
		end_line = math.max(start, line),
		end_character = RANGE_END_CHARACTER,
	}
end

---@param pr PullRequest
---@param content string
---@param opts PullsAddCommentOpts
---@return table input CommentInput, string|integer revision
local function comment_input(pr, content, opts)
	local parent = opts.parent
	if parent then
		local raw = parent._raw or {}
		return {
			path = raw.path,
			side = raw.side,
			line = raw.line,
			range = raw.range,
			in_reply_to = raw.thread_last_id or parent.id,
			message = content,
			unresolved = parent.state ~= "RESOLVED",
		},
			raw.patch_set or "current"
	end

	local revision = pr.source.commit_hash ~= "" and pr.source.commit_hash or "current"
	local inline = opts.inline
	if inline then
		local on_parent = inline.to == nil
		local line = on_parent and inline.from or inline.to
		local range = to_range(line, on_parent and inline.start_from or inline.start_to)
		return {
			path = inline.path,
			side = on_parent and "PARENT" or nil,
			line = range and range.end_line or line,
			range = range,
			message = content,
			unresolved = true,
		},
			inline.commit_hash or revision
	end
	if opts.file then
		return { path = opts.file.path, message = content, unresolved = true }, opts.file.commit_hash or revision
	end
	return { path = mapper.PATCHSET_LEVEL, message = content, unresolved = false }, revision
end

---@param raw table CommentInfo
---@param input table CommentInput
---@return boolean
local function same_comment(raw, input)
	return raw.message == input.message
		and raw.path == input.path
		and raw.in_reply_to == input.in_reply_to
		and raw.line == input.line
		and raw.side == input.side
end

---@param pr PullRequest
---@param created GerritComment
---@param parent GerritComment|nil
---@return GerritComment
local function attach_to_thread(pr, created, parent)
	if parent then
		created.parent_id = parent.parent_id or parent.id
		created.thread_id = parent.thread_id or parent.id
		created.inline = created.inline or parent.inline
		created.file = created.file or parent.file
		created.outdated = parent.outdated
	else
		created.thread_id = created.id
	end
	if created._raw.draft then
		created._raw.thread_last_id = parent and parent._raw and parent._raw.thread_last_id or nil
	else
		created._raw.thread_last_id = created.id
	end
	client.invalidate_change(pr.id)
	return created
end

---@param pr PullRequest
---@param revision string|integer
---@param input table CommentInput
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function publish_comment(pr, revision, input, on_done)
	return client.request("POST", revision_path(pr, revision) .. "/review", {
		comments = { [input.path] = { input } },
		drafts = "KEEP",
	}, function(_, err)
		on_done(err == nil, err)
	end, { action = "Publish Gerrit comment", change = tostring(pr.id) })
end

---@param pr PullRequest
---@param content string
---@param opts PullsAddCommentOpts|nil
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.add_comment(pr, content, opts, on_done)
	---@cast pr GerritPullRequest
	opts = opts or {}
	if vim.trim(content) == "" then
		on_done(nil, "Empty body")
		return nil
	end
	local input, revision = comment_input(pr, content, opts)
	local ctx = { pr = pr, current_patch_set = pr.patch_set }

	if opts.pending then
		return client.request("PUT", revision_path(pr, revision) .. "/drafts", input, function(result, err)
			if err or type(result) ~= "table" then
				on_done(nil, err or "Gerrit returned no draft")
				return
			end
			ctx.draft = true
			on_done(attach_to_thread(pr, mapper.to_comment(result, ctx), opts.parent), nil)
		end, { action = "Add Gerrit draft", change = tostring(pr.id) })
	end

	-- A review reply does not return the new comment, so look it up afterwards.
	local requests = request_scope.new()
	requests.run(function(done)
		return publish_comment(pr, revision, input, done)
	end, function(ok, err)
		if not ok then
			on_done(nil, err)
			return
		end
		requests.run(function(done)
			return client.request("GET", changes_api.change_path(pr) .. "/comments", nil, done, {
				action = "Fetch Gerrit comments",
				change = tostring(pr.id),
			})
		end, function(result, fetch_err)
			local created
			for _, raw in ipairs(flatten(result)) do
				if
					same_comment(raw, input) and (created == nil or tostring(raw.updated) > tostring(created.updated))
				then
					created = raw
				end
			end
			if not created then
				client.invalidate_change(pr.id)
				on_done(nil, fetch_err or "Comment was posted but could not be reloaded")
				return
			end
			on_done(attach_to_thread(pr, mapper.to_comment(created, ctx), opts.parent), nil)
		end)
	end)
	return requests
end

---@param comment GerritComment
---@return string|nil
local function published_error(comment)
	if comment._raw and comment._raw.draft then
		return nil
	end
	return "Gerrit does not allow changing published comments"
end

---@param pr PullRequest
---@param comment GerritComment
---@param content string
---@param on_done fun(comment: PullsComment|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.edit_comment(pr, comment, content, on_done)
	---@cast pr GerritPullRequest
	local err = published_error(comment)
	if err then
		on_done(nil, err)
		return nil
	end
	local raw = comment._raw
	local endpoint = string.format(
		"%s/drafts/%s",
		revision_path(pr, raw.patch_set or "current"),
		client.url_encode(tostring(comment.id))
	)
	return client.request("PUT", endpoint, {
		path = raw.path,
		side = raw.side,
		line = raw.line,
		range = raw.range,
		in_reply_to = raw.in_reply_to,
		unresolved = raw.unresolved,
		message = content,
	}, function(result, request_err)
		if request_err or type(result) ~= "table" then
			on_done(nil, request_err or "Gerrit returned no draft")
			return
		end
		local updated = mapper.to_comment(result, { pr = pr, current_patch_set = pr.patch_set, draft = true })
		updated.parent_id = comment.parent_id
		updated.thread_id = comment.thread_id
		updated.inline = updated.inline or comment.inline
		updated.file = updated.file or comment.file
		updated.outdated = comment.outdated
		updated._raw.thread_last_id = raw.thread_last_id
		client.invalidate_change(pr.id)
		on_done(updated, nil)
	end, { action = "Edit Gerrit draft", change = tostring(pr.id) })
end

---@param pr PullRequest
---@param comment GerritComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_draft(pr, comment, on_done)
	local endpoint = string.format(
		"%s/drafts/%s",
		revision_path(pr, comment._raw.patch_set or "current"),
		client.url_encode(tostring(comment.id))
	)
	return client.request("DELETE", endpoint, nil, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		client.invalidate_change(pr.id)
		on_done(true, nil)
	end, { action = "Delete Gerrit draft", change = tostring(pr.id) })
end

---@param pr PullRequest
---@param comment GerritComment
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.delete_comment(pr, comment, on_done)
	local err = published_error(comment)
	if err then
		on_done(false, err)
		return nil
	end
	return M.delete_draft(pr, comment, on_done)
end

local RESOLVE_MESSAGE = "Done"
local REOPEN_MESSAGE = "Reopened"

-- Drafts are not marked as Atlas-created, so a draft whose whole text is a status message
-- counts as one: toggling back to the published state deletes it, even if typed by hand.
---@param message string|nil
---@return boolean
local function is_status_message(message)
	return message == RESOLVE_MESSAGE or message == REOPEN_MESSAGE
end

-- Resolution is recorded as a draft reply and published with the rest of the review.
-- An existing draft reply in the thread is reused instead of stacking a second one.
---@param pr PullRequest
---@param root GerritComment
---@param resolved boolean
---@param on_done fun(ok: boolean, err: string|nil, draft: PullsThreadDraftChange|nil)
---@return { cancel: fun() }|nil
function M.set_thread_resolved(pr, root, resolved, on_done)
	---@cast pr GerritPullRequest
	local raw = root._raw
	if raw == nil or raw.path == nil then
		on_done(false, "Missing comment thread")
		return nil
	end
	local draft = raw.thread_draft
	local status_message = resolved and RESOLVE_MESSAGE or REOPEN_MESSAGE

	---@param created GerritComment|nil
	---@param removed GerritComment|nil
	local function finish(created, removed)
		raw.thread_draft = created and mapper.draft_snapshot(created) or nil
		if created and created.id == tostring(root.id) then
			created.parent_id, created.thread_id = root.parent_id, root.thread_id
			created.inline, created.file, created.outdated = root.inline, root.file, root.outdated
			created._raw.thread_last_id = raw.thread_last_id
		elseif created then
			attach_to_thread(pr, created, root)
		end
		if created then
			created._raw.thread_draft = raw.thread_draft
			created._raw.published_resolved = raw.published_resolved
		end
		client.invalidate_change(pr.id)
		on_done(true, nil, { comment = created or removed, removed = removed ~= nil })
	end

	---@param method string
	---@param endpoint string
	---@param input table|nil
	---@param action string
	---@param on_result fun(result: any)
	local function send(method, endpoint, input, action, on_result)
		return client.request(method, endpoint, input, function(result, err)
			if err then
				on_done(false, err)
				return
			end
			on_result(result)
		end, { action = action, change = tostring(pr.id) })
	end

	---@param result any
	local function mapped(result)
		if type(result) ~= "table" then
			on_done(false, "Gerrit returned no draft")
			return
		end
		finish(mapper.to_comment(result, { pr = pr, current_patch_set = pr.patch_set, draft = true }), nil)
	end

	if draft then
		local endpoint =
			string.format("%s/drafts/%s", revision_path(pr, draft.patch_set or "current"), client.url_encode(draft.id))
		if resolved == raw.published_resolved and is_status_message(draft.message) then
			return send("DELETE", endpoint, nil, "Delete Gerrit draft", function()
				finish(nil, { id = draft.id, pending = true, body = draft.message, created_at = "", _raw = {} })
			end)
		end
		return send("PUT", endpoint, {
			path = draft.path,
			side = draft.side,
			line = draft.line,
			range = draft.range,
			in_reply_to = draft.in_reply_to,
			message = is_status_message(draft.message) and status_message or draft.message,
			unresolved = not resolved,
		}, "Edit Gerrit draft", mapped)
	end

	if resolved == raw.published_resolved then
		on_done(true, nil, nil)
		return nil
	end
	return send("PUT", revision_path(pr, raw.patch_set or "current") .. "/drafts", {
		path = raw.path,
		side = raw.side,
		line = raw.line,
		range = raw.range,
		in_reply_to = raw.thread_last_id or root.id,
		message = status_message,
		unresolved = not resolved,
	}, "Add Gerrit draft", mapped)
end

return M
