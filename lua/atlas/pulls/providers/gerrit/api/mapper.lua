local M = {}

local client = require("atlas.providers.gerrit.client")
local gerrit_mapper = require("atlas.providers.gerrit.mapper")

M.CODE_REVIEW = "Code-Review"
M.VERIFIED = "Verified"
M.PATCHSET_LEVEL = "/PATCHSET_LEVEL"

-- Paths Gerrit shows alongside the real files; they have no counterpart in the local diff.
local MAGIC_FILES = {
	["/COMMIT_MSG"] = true,
	["/MERGE_LIST"] = true,
	["/PATCHSET_LEVEL"] = true,
}

---@param path string|nil
---@return boolean
function M.is_magic_file(path)
	return MAGIC_FILES[path or ""] == true
end

---@param value string|nil Gerrit timestamp, e.g. "2024-02-01 09:59:32.126000000" (UTC).
---@return string
function M.to_iso(value)
	local date, time = tostring(value or ""):match("^(%d%d%d%d%-%d%d%-%d%d) (%d%d:%d%d:%d%d)")
	if date == nil then
		return ""
	end
	return date .. "T" .. time .. "Z"
end

---@class GerritCommentRaw
---@field path string|nil
---@field patch_set integer|nil
---@field side string|nil
---@field line integer|nil
---@field range table|nil
---@field in_reply_to string|nil
---@field unresolved boolean
---@field draft boolean
---@field updated string|nil
---@field thread_last_id string|nil Last published comment of the thread, which a new reply answers.
---@field thread_draft GerritDraftSnapshot|nil The viewer's draft reply in the thread.
---@field published_resolved boolean|nil Resolution state without the viewer's draft.

---@class GerritComment : PullsComment
---@field _raw GerritCommentRaw

M.to_author = gerrit_mapper.to_author

---@param message string|nil
---@return string subject, string body
function M.split_message(message)
	local text = tostring(message or ""):gsub("\r\n", "\n")
	local subject, rest = text:match("^([^\n]*)\n?(.*)$")
	local body = (rest or ""):gsub("^\n+", ""):gsub("%s+$", "")
	return subject or "", body
end

---@param subject string
---@param body string
---@return string
function M.join_message(subject, body)
	body = vim.trim(body or "")
	if body == "" then
		return subject .. "\n"
	end
	return subject .. "\n\n" .. body .. "\n"
end

---@param raw table ChangeInfo
---@return table|nil revision, string|nil sha
local function current_revision(raw)
	local sha = raw.current_revision
	local revisions = type(raw.revisions) == "table" and raw.revisions or {}
	if sha and type(revisions[sha]) == "table" then
		return revisions[sha], sha
	end
	return nil, sha
end

---@param label table|nil LabelInfo
---@return GerritLabelSummary|nil
function M.label_summary(label)
	if type(label) ~= "table" then
		return nil
	end
	local status = "neutral"
	if label.rejected then
		status = "rejected"
	elseif label.approved then
		status = "approved"
	elseif label.disliked then
		status = "disliked"
	elseif label.recommended then
		status = "recommended"
	end
	local min, max = 0, 0
	for _, approval in ipairs(type(label.all) == "table" and label.all or {}) do
		local value = tonumber(approval.value) or 0
		min, max = math.min(min, value), math.max(max, value)
	end
	return {
		status = status,
		min = min,
		max = max,
		blocking = label.blocking == true,
		optional = label.optional == true,
	}
end

---@param raw table ChangeInfo
---@return table<string, integer>
local function code_review_votes(raw)
	local votes = {}
	local labels = type(raw.labels) == "table" and raw.labels or {}
	local code_review = type(labels[M.CODE_REVIEW]) == "table" and labels[M.CODE_REVIEW] or {}
	for _, approval in ipairs(type(code_review.all) == "table" and code_review.all or {}) do
		local value = tonumber(approval.value)
		if approval._account_id and value then
			votes[tostring(approval._account_id)] = value
		end
	end
	return votes
end

---@param raw table ChangeInfo
---@param commented table<string, boolean>|nil Account ids that posted a message without voting.
---@return PullsReviewer[]|nil
function M.to_reviewers(raw, commented)
	if type(raw.reviewers) ~= "table" then
		return nil
	end
	local owner_id = tostring(type(raw.owner) == "table" and raw.owner._account_id or "")
	local votes = code_review_votes(raw)
	local reviewers = {}
	for state, role in pairs({ REVIEWER = "reviewer", CC = "participant" }) do
		for _, account in ipairs(type(raw.reviewers[state]) == "table" and raw.reviewers[state] or {}) do
			local author = M.to_author(account)
			if author.id ~= owner_id then
				local vote = votes[author.id] or 0
				local decision = "pending"
				if vote >= 1 then
					decision = "approved"
				elseif vote <= -1 then
					decision = "changes_requested"
				elseif commented and commented[author.id] then
					decision = "reviewed"
				end
				table.insert(
					reviewers,
					vim.tbl_extend("force", author, {
						provider_id = author.id,
						role = role,
						decision = decision,
					})
				)
			end
		end
	end
	table.sort(reviewers, function(a, b)
		if a.role ~= b.role then
			return a.role == "reviewer"
		end
		return a.name < b.name
	end)
	return reviewers
end

---@param raw table ChangeInfo
---@return "open"|"merged"|"declined"|"draft"
local function to_state(raw)
	local status = tostring(raw.status or "")
	if status == "MERGED" then
		return "merged"
	end
	if status == "ABANDONED" then
		return "declined"
	end
	return raw.work_in_progress == true and "draft" or "open"
end

---@param raw any ChangeInfo
---@return GerritPullRequest|nil
function M.to_pull_request(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local number = tonumber(raw._number)
	if number == nil then
		return nil
	end
	local project = tostring(raw.project or "")
	local workspace, repo = project:match("^(.+)/([^/]+)$")
	local revision, sha = current_revision(raw)
	local commit = revision and type(revision.commit) == "table" and revision.commit or {}
	local parents = type(commit.parents) == "table" and commit.parents or {}
	local base = type(parents[1]) == "table" and tostring(parents[1].commit or "") or ""
	local change_ref = revision and revision.ref or nil
	local https_url, ssh_url = client.clone_urls(project)

	local labels = {}
	for name, label in pairs(type(raw.labels) == "table" and raw.labels or {}) do
		labels[name] = M.label_summary(label)
	end

	---@type GerritPullRequest
	return {
		id = number,
		title = tostring(raw.subject or ""),
		state = to_state(raw),
		author = M.to_author(raw.owner),
		source = {
			branch = "change/" .. tostring(number),
			commit_hash = sha or "",
			fetch_ref = change_ref,
		},
		destination = {
			branch = tostring(raw.branch or ""),
			commit_hash = base,
			fetch_ref = change_ref,
			https_url = https_url,
			ssh_url = ssh_url,
		},
		comments_count = tonumber(raw.total_comment_count) or 0,
		created_on = M.to_iso(raw.created),
		updated_on = M.to_iso(raw.updated),
		link = { html = client.change_url(project, number) },
		provider = "gerrit",
		repo = {
			id = project,
			name = repo or project,
			owner = workspace or "",
			repo_name = repo or project,
			full_name = project,
			html_url = client.project_url(project),
		},
		repo_full_name = project,
		reviewers = M.to_reviewers(raw),
		change_id = tostring(raw.change_id or ""),
		patch_set = revision and tonumber(revision._number) or nil,
		labels = labels,
		permitted_labels = type(raw.permitted_labels) == "table" and raw.permitted_labels or nil,
		unresolved_comments_count = tonumber(raw.unresolved_comment_count) or 0,
		lines_added = tonumber(raw.insertions),
		lines_removed = tonumber(raw.deletions),
	}
end

---@param raw_list any
---@return GerritPullRequest[]
function M.to_pull_requests(raw_list)
	local pulls = {}
	for _, raw in ipairs(type(raw_list) == "table" and raw_list or {}) do
		local pr = M.to_pull_request(raw)
		if pr then
			table.insert(pulls, pr)
		end
	end
	return pulls
end

---@param raw table ChangeInfo
---@return GerritPullRequestDetails
function M.to_details(raw)
	local revision = current_revision(raw)
	local commit = revision and type(revision.commit) == "table" and revision.commit or {}
	local _, body = M.split_message(commit.message)
	local hashtags = {}
	for _, tag in ipairs(type(raw.hashtags) == "table" and raw.hashtags or {}) do
		table.insert(hashtags, { name = "#" .. tostring(tag) })
	end
	return {
		description = body,
		change_id = tostring(raw.change_id or ""),
		topic = raw.topic,
		labels = hashtags,
	}
end
---@param raw table CommentInfo
---@return PullsInlineCommentPosition|nil inline, PullsFileCommentPosition|nil file
local function to_position(raw)
	local path = raw.path
	if path == nil or M.is_magic_file(path) then
		return nil, nil
	end
	local range = type(raw.range) == "table" and raw.range or nil
	local line = range and tonumber(range.end_line) or tonumber(raw.line)
	if line == nil then
		return nil, { path = path, commit_hash = raw.commit_id }
	end
	local parent_side = raw.side == "PARENT"
	local start = range and tonumber(range.start_line) or nil
	if start == line then
		start = nil
	end
	return {
		path = path,
		from = parent_side and line or nil,
		to = not parent_side and line or nil,
		start_from = parent_side and start or nil,
		start_to = not parent_side and start or nil,
		commit_hash = raw.commit_id,
	},
		nil
end

---@class GerritCommentContext
---@field pr PullRequest
---@field current_patch_set integer|nil
---@field ported table|nil Ported CommentInfo for the same comment id.
---@field draft boolean|nil

---@param raw table CommentInfo, with `path` set.
---@param ctx GerritCommentContext
---@return GerritComment
function M.to_comment(raw, ctx)
	local display = ctx.ported or raw
	local inline, file = to_position(display)
	local patch_set = tonumber(raw.patch_set)
	local outdated = ctx.ported == nil
		and ctx.current_patch_set ~= nil
		and patch_set ~= nil
		and patch_set ~= ctx.current_patch_set
		and (inline ~= nil or file ~= nil)
	local id = tostring(raw.id or "")
	local base = tostring((ctx.pr.link or {}).html or "")
	return {
		id = id,
		author = ctx.draft and raw.author == nil and { name = "You", id = "", username = "" }
			or M.to_author(raw.author),
		body = tostring(raw.message or ""),
		created_at = M.to_iso(raw.updated),
		inline = inline,
		file = file,
		state = outdated and "OUTDATED" or nil,
		pending = ctx.draft or nil,
		outdated = outdated or nil,
		url = base ~= "" and id ~= "" and (base .. "/comment/" .. id .. "/") or nil,
		_raw = {
			path = raw.path,
			patch_set = patch_set,
			side = raw.side,
			line = raw.line,
			range = raw.range,
			in_reply_to = raw.in_reply_to,
			unresolved = raw.unresolved == true,
			draft = ctx.draft == true,
			updated = raw.updated,
		},
	}
end

---@class GerritDraftSnapshot
---@field id string
---@field patch_set integer|nil
---@field message string
---@field path string
---@field side string|nil
---@field line integer|nil
---@field range table|nil
---@field in_reply_to string|nil
---@field unresolved boolean

---@param draft GerritComment
---@return GerritDraftSnapshot
function M.draft_snapshot(draft)
	local raw = draft._raw
	return {
		id = tostring(draft.id),
		patch_set = raw.patch_set,
		message = draft.body,
		path = raw.path,
		side = raw.side,
		line = raw.line,
		range = raw.range,
		in_reply_to = raw.in_reply_to,
		unresolved = raw.unresolved,
	}
end

---@param comments GerritComment[] Published comments and drafts of one change.
---@return GerritComment[]
function M.link_threads(comments)
	local by_id = {}
	for _, comment in ipairs(comments) do
		by_id[comment.id] = comment
	end

	---@param comment PullsComment
	---@return PullsComment
	local function root_of(comment)
		local seen = {}
		local current = comment
		while current._raw.in_reply_to and by_id[current._raw.in_reply_to] and not seen[current.id] do
			seen[current.id] = true
			current = by_id[current._raw.in_reply_to]
		end
		return current
	end

	local threads = {}
	for _, comment in ipairs(comments) do
		local root = root_of(comment)
		threads[root.id] = threads[root.id] or { root = root, items = {} }
		table.insert(threads[root.id].items, comment)
		if root ~= comment then
			comment.parent_id = root.id
		end
		comment.thread_id = root.id
	end

	---@param current PullsComment|nil
	---@param comment PullsComment
	---@return PullsComment
	local function later(current, comment)
		if current == nil or tostring(comment._raw.updated) >= tostring(current._raw.updated) then
			return comment
		end
		return current
	end

	for _, thread in pairs(threads) do
		local root = thread.root
		local published, draft
		for _, comment in ipairs(thread.items) do
			if comment._raw.draft then
				draft = later(draft, comment)
			else
				published = later(published, comment)
			end
		end
		-- The viewer's own draft reply decides the thread state, so pending resolutions show up.
		local last = draft or published
		local resolved = last ~= nil and not last._raw.unresolved
		local draft_snapshot = draft and M.draft_snapshot(draft) or nil
		for _, comment in ipairs(thread.items) do
			if comment ~= root then
				comment.inline = comment.inline or root.inline
				comment.file = comment.file or root.file
				comment.outdated = comment.outdated or root.outdated
			end
			comment._raw.thread_last_id = published and published.id or root.id
			comment._raw.thread_draft = draft_snapshot
			comment._raw.published_resolved = published ~= nil and not published._raw.unresolved
			if resolved then
				comment.state = "RESOLVED"
			elseif comment.state == nil and root.outdated then
				comment.state = "OUTDATED"
			end
		end
		if resolved and last then
			root.resolved_at = last.created_at
			root.resolved_by = last.author
		end
	end
	return comments
end

---@param line string
---@return integer|nil vote, boolean removed
local function code_review_vote(line)
	local sign, digits = line:match("Code%-Review([+-])(%d+)")
	if sign then
		return (sign == "-" and -1 or 1) * assert(tonumber(digits)), false
	end
	return nil, line:find("%-Code%-Review") ~= nil
end

---@param raw table ChangeMessageInfo
---@return boolean
function M.is_autogenerated(raw)
	return tostring(raw.tag or ""):match("^autogenerated:") ~= nil
end

---@param raw table ChangeMessageInfo
---@return PullsReviewHistoryEntry|nil entry, integer|nil vote
function M.to_history(raw)
	if M.is_autogenerated(raw) or type(raw.author) ~= "table" then
		return nil, nil
	end
	local header, body = M.split_message(raw.message)
	body = body:gsub("^%(%d+ comments?%)%s*", "")
	local vote, removed = code_review_vote(header)
	local state = "commented"
	if vote and vote > 0 then
		state = "approved"
	elseif vote and vote < 0 then
		state = "changes_requested"
	elseif removed then
		state = "dismissed"
	end
	return {
		id = tostring(raw.id or ""),
		author = M.to_author(raw.author),
		state = state,
		submitted_on = M.to_iso(raw.date),
		body = vim.trim(body),
	},
		vote
end

---@param raw table ChangeMessageInfo
---@return PullsActivityEntry|nil
function M.to_activity(raw)
	if not M.is_autogenerated(raw) then
		return nil
	end
	local header = M.split_message(raw.message)
	return {
		kind = "update",
		actor = type(raw.author) == "table" and M.to_author(raw.author) or nil,
		date = M.to_iso(raw.date),
		label = header,
	}
end

---@param raw table|nil RelatedChangesInfo
---@param number integer The change whose relation chain this is.
---@return AtlasRelatedItem[]
function M.to_related(raw, number)
	local changes = type(raw) == "table" and type(raw.changes) == "table" and raw.changes or {}
	-- Gerrit lists descendants first, then the change itself, then its ancestors.
	local current
	for index, entry in ipairs(changes) do
		if tonumber(entry._change_number) == number then
			current = index
			break
		end
	end
	local items = {}
	for index, entry in ipairs(changes) do
		local change_number = tonumber(entry._change_number)
		if change_number and index ~= current then
			local commit = type(entry.commit) == "table" and entry.commit or {}
			local status = tostring(entry.status or "NEW")
			local title = tostring(commit.subject or "")
			if status ~= "NEW" then
				title = string.format("%s [%s]", title, status:lower())
			end
			local relationship
			if current then
				relationship = index < current and "child" or "parent"
			end
			table.insert(items, {
				kind = "pr",
				url = client.change_url(tostring(entry.project or ""), change_number),
				key = tostring(change_number),
				title = title,
				relationship = relationship,
			})
		end
	end
	return items
end

---@param hunk DiffHunk
local function close_hunk(hunk)
	hunk.header = string.format("@@ -%d,%d +%d,%d @@", hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count)
end

---@param path string
---@param info table|nil DiffInfo
---@return DiffFile
function M.to_diff_file(path, info)
	---@type DiffFile
	local file = { path = path, status = "modified", hunks = {} }
	if type(info) ~= "table" or info.binary == true then
		return file
	end
	local old_line, new_line = 1, 1
	local hunk

	---@param kind "add"|"remove"|"context"
	---@param content string
	local function push(kind, content)
		if hunk == nil then
			hunk = {
				header = "",
				context = "",
				old_start = old_line,
				old_count = 0,
				new_start = new_line,
				new_count = 0,
				additions = 0,
				deletions = 0,
				lines = {},
			}
			table.insert(file.hunks, hunk)
		end
		local marker = kind == "add" and "+" or kind == "remove" and "-" or " "
		table.insert(hunk.lines, {
			kind = kind,
			text = marker .. content,
			content = content,
			old_line = kind ~= "add" and old_line or nil,
			new_line = kind ~= "remove" and new_line or nil,
		})
		if kind ~= "add" then
			old_line = old_line + 1
			hunk.old_count = hunk.old_count + 1
		end
		if kind ~= "remove" then
			new_line = new_line + 1
			hunk.new_count = hunk.new_count + 1
		end
		hunk.additions = hunk.additions + (kind == "add" and 1 or 0)
		hunk.deletions = hunk.deletions + (kind == "remove" and 1 or 0)
	end

	for _, chunk in ipairs(type(info.content) == "table" and info.content or {}) do
		if chunk.skip then
			if hunk then
				close_hunk(hunk)
				hunk = nil
			end
			old_line = old_line + chunk.skip
			new_line = new_line + chunk.skip
		end
		for _, text in ipairs(chunk.ab or {}) do
			push("context", text)
		end
		for _, text in ipairs(chunk.a or {}) do
			push("remove", text)
		end
		for _, text in ipairs(chunk.b or {}) do
			push("add", text)
		end
	end
	if hunk then
		close_hunk(hunk)
	end
	return file
end

---@param hunk DiffHunk
---@param side "old"|"new"
---@param line integer
---@param context_lines integer
---@return DiffHunk
local function window_hunk(hunk, side, line, context_lines)
	local anchor
	for index, diff_line in ipairs(hunk.lines) do
		if (side == "old" and diff_line.old_line == line) or (side == "new" and diff_line.new_line == line) then
			anchor = index
			break
		end
	end
	if anchor == nil then
		return hunk
	end

	local first = math.max(1, anchor - context_lines)
	local last = math.min(#hunk.lines, anchor + context_lines)
	if first == 1 and last == #hunk.lines then
		return hunk
	end

	local old_start, new_start = hunk.old_start, hunk.new_start
	for index = 1, first - 1 do
		local kind = hunk.lines[index].kind
		if kind ~= "add" then
			old_start = old_start + 1
		end
		if kind ~= "remove" then
			new_start = new_start + 1
		end
	end

	---@type DiffHunk
	local window = {
		header = "",
		context = hunk.context,
		old_start = old_start,
		old_count = 0,
		new_start = new_start,
		new_count = 0,
		additions = 0,
		deletions = 0,
		lines = {},
	}
	for index = first, last do
		local diff_line = hunk.lines[index]
		table.insert(window.lines, diff_line)
		if diff_line.kind ~= "add" then
			window.old_count = window.old_count + 1
		end
		if diff_line.kind ~= "remove" then
			window.new_count = window.new_count + 1
		end
		window.additions = window.additions + (diff_line.kind == "add" and 1 or 0)
		window.deletions = window.deletions + (diff_line.kind == "remove" and 1 or 0)
	end
	-- A unified diff header names the line before an empty side.
	if window.old_count == 0 then
		window.old_start = math.max(0, window.old_start - 1)
	end
	if window.new_count == 0 then
		window.new_start = math.max(0, window.new_start - 1)
	end
	close_hunk(window)
	return window
end

---@param file DiffFile|nil
---@param side "old"|"new"
---@param line integer
---@return DiffHunk|nil The hunk around `line`, trimmed to a few lines of context.
function M.hunk_at(file, side, line)
	for _, hunk in ipairs(file and file.hunks or {}) do
		local start = side == "old" and hunk.old_start or hunk.new_start
		local count = side == "old" and hunk.old_count or hunk.new_count
		if line >= start and line < start + count then
			return window_hunk(hunk, side, line, 3)
		end
	end
	return nil
end

return M
