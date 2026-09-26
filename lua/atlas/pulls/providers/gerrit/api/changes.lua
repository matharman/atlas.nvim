local M = {}

local client = require("atlas.providers.gerrit.client")
local gerrit_query = require("atlas.providers.gerrit.query")
local mapper = require("atlas.pulls.providers.gerrit.api.mapper")
local request_scope = require("atlas.core.requests")

local LIST_OPTIONS ={ "CURRENT_REVISION", "CURRENT_COMMIT", "DETAILED_LABELS", "DETAILED_ACCOUNTS" }
local DETAIL_OPTIONS = { "CURRENT_REVISION", "CURRENT_COMMIT", "DETAILED_LABELS", "DETAILED_ACCOUNTS", "MESSAGES" }

---@param options string[]
---@return string
local function option_params(options)
	local parts = {}
	for _, option in ipairs(options) do
		table.insert(parts, "o=" .. option)
	end
	return table.concat(parts, "&")
end

---@param pr PullRequestRef
---@return string
function M.change_path(pr)
	return "/changes/" .. client.change_id(pr.repo_full_name, pr.id)
end

---@param pr PullRequestRef
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(change: table|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_change(pr, opts, on_done)
	local cache_key = string.format("gerrit:change:%s:detail", tostring(pr.id))
	if not (opts and opts.force_refresh) then
		local cached, ok = client.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end
	return client.request("GET", M.change_path(pr) .. "?" .. option_params(DETAIL_OPTIONS), nil, function(result, err)
		if err or type(result) ~= "table" then
			local not_found = err == nil or err:match("^HTTP 404") ~= nil
			on_done(nil, not_found and M.not_found_message(pr) or err)
			return
		end
		client.set_cache(cache_key, result)
		on_done(result, nil)
	end, { action = "Fetch Gerrit change", change = tostring(pr.id) })
end

---@param view AtlasPullsViewConfig
---@param opts PullsFetchOpts
---@param on_done fun(page: PullsPage, err: string[]|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequests(view, opts, on_done)
	local query = gerrit_query.query(view)
	local start = tonumber(opts.cursor and opts.cursor.start) or 0
	local limit = tonumber(opts.pagelen) or 25
	local endpoint = string.format(
		"/changes/?q=%s&n=%d&S=%d&%s",
		client.url_encode(query),
		limit,
		start,
		option_params(LIST_OPTIONS)
	)

	---@param raw table[]
	local function finish(raw)
		local last = raw[#raw]
		local more = type(last) == "table" and last._more_changes == true
		on_done({
			items = mapper.to_pull_requests(raw),
			next_cursor = more and { start = tostring(start + #raw) } or nil,
			query = query,
		}, nil)
	end

	local cache_key = "gerrit:list:" .. endpoint
	if not opts.force_refresh then
		local cached, ok = client.get_cache(cache_key)
		if ok then
			finish(cached)
			return nil
		end
	end
	return client.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done({ items = {}, query = query }, { err })
			return
		end
		local raw = type(result) == "table" and result or {}
		client.set_cache(cache_key, raw)
		finish(raw)
	end, { action = "List Gerrit changes", query = query })
end

---@param ref PullRequestRef
---@return string
local function ref_query(ref)
	local query = "change:" .. tostring(ref.id)
	if ref.repo_full_name and ref.repo_full_name ~= "" then
		query = query .. " " .. gerrit_query.for_project(ref.repo_full_name)
	end
	return query
end

---@param ref PullRequestRef
---@return string
function M.not_found_message(ref)
	local message = "Change " .. tostring(ref.id) .. " not found"
	if ref.repo_full_name and ref.repo_full_name ~= "" then
		message = message .. " in " .. ref.repo_full_name
	end
	return message
end

---@param matches table[]
---@return table|nil
local function pick_change(matches)
	for _, raw in ipairs(matches) do
		if raw.status == "NEW" then
			return raw
		end
	end
	return matches[1]
end

---@param refs PullRequestRef[]
---@param opts PullsFetchOpts|nil
---@param on_done fun(pulls: PullRequest[], err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_by_refs(refs, opts, on_done)
	if #refs == 0 then
		on_done({}, nil)
		return nil
	end
	local queries = {}
	for _, ref in ipairs(refs) do
		if tostring(ref.id or "") == "" then
			on_done({}, "Invalid change identifier")
			return nil
		end
		table.insert(queries, "q=" .. client.url_encode(ref_query(ref)))
	end
	local endpoint = string.format("/changes/?%s&%s", table.concat(queries, "&"), option_params(LIST_OPTIONS))

	---@param raw table
	local function finish(raw)
		-- One `q` returns a flat list; several return one list per query.
		local groups = #refs == 1 and { raw } or raw
		local pulls, seen = {}, {}
		for _, matches in ipairs(groups) do
			local pr = mapper.to_pull_request(pick_change(type(matches) == "table" and matches or {}))
			if pr and not seen[pr.id] then
				seen[pr.id] = true
				table.insert(pulls, pr)
			end
		end
		local err
		if #pulls == 0 then
			err = #refs == 1 and M.not_found_message(refs[1])
				or string.format("None of the %d requested changes were found", #refs)
		end
		on_done(pulls, err)
	end

	local cache_key = "gerrit:list:refs:" .. endpoint
	if not (opts and opts.force_refresh) then
		local cached, ok = client.get_cache(cache_key)
		if ok then
			finish(cached)
			return nil
		end
	end
	return client.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done({}, err)
			return
		end
		local raw = type(result) == "table" and result or {}
		client.set_cache(cache_key, raw)
		finish(raw)
	end, { action = "Fetch Gerrit changes", count = #refs })
end

---@param pr PullRequestRef
---@param opts PullsFetchOpts|nil
---@param on_done fun(details: PullRequestDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pullrequest(pr, opts, on_done)
	return M.fetch_change(pr, opts, function(change, err)
		if not change then
			on_done(nil, err)
			return
		end
		on_done(mapper.to_details(change), nil)
	end)
end

---@param pr PullRequest
---@param on_done fun(message: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_commit_message(pr, on_done)
	return client.request("GET", M.change_path(pr) .. "/revisions/current/commit", nil, function(result, err)
		if err or type(result) ~= "table" then
			on_done(nil, err or "Commit not found")
			return
		end
		on_done(tostring(result.message or ""), nil)
	end, { action = "Fetch Gerrit commit message", change = tostring(pr.id) })
end

---@param pr PullRequest
---@param _opts { force_refresh: boolean|nil }|nil
---@param on_done fun(description: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_description(pr, _opts, on_done)
	return fetch_commit_message(pr, function(message, err)
		if not message then
			on_done(nil, err)
			return
		end
		local _, body = mapper.split_message(message)
		on_done(body, nil)
	end)
end

---@param pr PullRequest
---@param method string
---@param suffix string
---@param body table|nil
---@param action string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function write(pr, method, suffix, body, action, on_done)
	return client.request(method, M.change_path(pr) .. suffix, body, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		client.invalidate_change(pr.id)
		on_done(true, nil)
	end, { action = action, change = tostring(pr.id) })
end

-- Editing the commit message uploads a new patch set.
---@param pr PullRequest
---@param edit fun(subject: string, body: string): string, string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
local function update_message(pr, edit, on_done)
	local requests = request_scope.new()
	requests.run(function(done)
		return fetch_commit_message(pr, done)
	end, function(message, err)
		if not message then
			on_done(false, err)
			return
		end
		local current_subject, current_body = mapper.split_message(message)
		local updated = mapper.join_message(edit(current_subject, current_body))
		-- Gerrit rejects an unchanged message instead of skipping the new patch set.
		if updated == mapper.join_message(current_subject, current_body) then
			on_done(true, nil)
			return
		end
		requests.run(function(done)
			return write(pr, "PUT", "/message", { message = updated }, "Update Gerrit commit message", done)
		end, on_done)
	end)
	return requests
end

---@param pr PullRequest
---@param draft boolean
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_draft(pr, draft, on_done)
	local suffix = draft and "/wip" or "/ready"
	return write(
		pr,
		"POST",
		suffix,
		vim.empty_dict(),
		draft and "Mark Gerrit change WIP" or "Mark Gerrit change ready",
		on_done
	)
end

---@param pr PullRequest
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.decline(pr, on_done)
	return write(pr, "POST", "/abandon", vim.empty_dict(), "Abandon Gerrit change", on_done)
end

---@param pr PullRequest
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.restore(pr, on_done)
	return write(pr, "POST", "/restore", vim.empty_dict(), "Restore Gerrit change", on_done)
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(reviewers: PullsReviewer[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewers(pr, opts, on_done)
	return M.fetch_change(pr, opts, function(change, err)
		if not change then
			on_done(nil, err)
			return
		end
		local commented = {}
		for _, message in ipairs(change.messages or {}) do
			local entry, vote = mapper.to_history(message)
			if entry and vote == nil and entry.author then
				commented[entry.author.id] = true
			end
		end
		on_done(mapper.to_reviewers(change, commented) or {}, nil)
	end)
end

---@param opts { repo_slug: string, pr: PullRequest|nil }
---@param on_done fun(reviewers: PullsReviewerCandidate[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_reviewer_candidates(opts, on_done)
	local pr = opts.pr
	if pr == nil then
		on_done(nil, "Gerrit suggests reviewers for an existing change only")
		return nil
	end
	local requests = request_scope.new()
	requests.all({
		current = function(done)
			return M.fetch_reviewers(pr, { force_refresh = true }, done)
		end,
		suggested = function(done)
			return client.request("GET", M.change_path(pr) .. "/suggest_reviewers?n=50", nil, done, {
				action = "Suggest Gerrit reviewers",
				change = tostring(pr.id),
			})
		end,
	}, function(values, errors)
		if errors.current then
			on_done(nil, errors.current)
			return
		end
		local owner_id = tostring(pr.author and pr.author.id or "")
		local reviewers, seen = {}, {}
		---@param author AtlasUser
		---@param selected boolean
		local function add(author, selected)
			local id = tostring(author.id or "")
			if id == "" or id == owner_id or seen[id] then
				return
			end
			seen[id] = true
			table.insert(reviewers, {
				label = string.format("%s (%s)", author.name, author.username),
				provider_id = id,
				selected = selected,
			})
		end
		for _, reviewer in ipairs(values.current or {}) do
			if reviewer.role == "reviewer" then
				add(reviewer, true)
			end
		end
		for _, suggestion in ipairs(type(values.suggested) == "table" and values.suggested or {}) do
			if type(suggestion.account) == "table" then
				add(mapper.to_author(suggestion.account), false)
			end
		end
		on_done(reviewers, nil)
	end)
	return requests
end

---@param pr PullRequest
---@param reviewers PullsReviewerCandidate[]
---@param original PullsReviewerCandidate[]
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
local function update_reviewers(pr, reviewers, original, on_done)
	local wanted, had = {}, {}
	for _, reviewer in ipairs(reviewers) do
		wanted[reviewer.provider_id] = true
	end
	for _, reviewer in ipairs(original) do
		had[reviewer.provider_id] = true
	end
	local steps = {}
	for id in pairs(wanted) do
		if not had[id] then
			table.insert(steps, { method = "POST", suffix = "/reviewers", body = { reviewer = id } })
		end
	end
	for id in pairs(had) do
		if not wanted[id] then
			table.insert(steps, { method = "DELETE", suffix = "/reviewers/" .. client.url_encode(id) })
		end
	end

	local requests = request_scope.new()
	local function next_step(index)
		local step = steps[index]
		if step == nil then
			on_done(true, nil)
			return
		end
		requests.run(function(done)
			return write(pr, step.method, step.suffix, step.body, "Update Gerrit reviewers", done)
		end, function(ok, err)
			if not ok then
				on_done(false, err)
				return
			end
			next_step(index + 1)
		end)
	end
	next_step(1)
	return requests
end

---@param pr PullRequest
---@param reviewers PullsReviewerCandidate[]
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
local function replace_reviewers(pr, reviewers, on_done)
	local requests = request_scope.new()
	requests.run(function(done)
		return M.fetch_reviewers(pr, { force_refresh = true }, done)
	end, function(current, err)
		if not current then
			on_done(false, err)
			return
		end
		local original = {}
		for _, reviewer in ipairs(current) do
			if reviewer.role == "reviewer" then
				table.insert(original, { label = reviewer.name, provider_id = reviewer.id })
			end
		end
		requests.run(function(done)
			return update_reviewers(pr, reviewers, original, done)
		end, on_done)
	end)
	return requests
end

-- Each field is written with its own endpoint, so a failure can leave earlier fields saved.
---@param pr PullRequest
---@param opts PullsUpdatePROpts
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }
function M.update_pr(pr, opts, on_done)
	---@type (fun(done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)[]
	local steps = {}
	if opts.title ~= nil or opts.body ~= nil then
		table.insert(steps, function(done)
			return update_message(pr, function(subject, body)
				return opts.title or subject, opts.body or body
			end, done)
		end)
	end
	if opts.draft ~= nil and opts.draft ~= (pr.state == "draft") then
		table.insert(steps, function(done)
			return M.set_draft(pr, opts.draft, done)
		end)
	end
	if opts.base and opts.base ~= "" and opts.base ~= pr.destination.branch then
		table.insert(steps, function(done)
			return write(pr, "POST", "/move", { destination_branch = opts.base }, "Move Gerrit change", done)
		end)
	end
	if opts.reviewers then
		table.insert(steps, function(done)
			return replace_reviewers(pr, opts.reviewers, done)
		end)
	end

	local requests = request_scope.new()
	local function next_step(index)
		local step = steps[index]
		if step == nil then
			on_done(true, nil)
			return
		end
		requests.run(step, function(ok, err)
			if not ok then
				on_done(false, err)
				return
			end
			next_step(index + 1)
		end)
	end
	next_step(1)
	return requests
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(commits: PullsCommit[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_commits(pr, opts, on_done)
	return M.fetch_change(pr, opts, function(change, err)
		if not change then
			on_done(nil, err)
			return
		end
		local sha = change.current_revision
		local revision = sha and change.revisions and change.revisions[sha] or nil
		local commit = revision and revision.commit or nil
		if not commit then
			on_done({}, nil)
			return
		end
		local author = type(commit.author) == "table" and commit.author or {}
		on_done({
			{
				hash = sha,
				repo_full_name = pr.repo_full_name,
				short_hash = sha:sub(1, 8),
				message = tostring(commit.message or commit.subject or ""),
				author_name = tostring(author.name or ""),
				date = mapper.to_iso(author.date),
				html_url = pr.link.html,
			},
		}, nil)
	end)
end

---@param cache_key string
---@param endpoint string
---@param action string
---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(result: any, err: string|nil)
---@return { cancel: fun() }|nil
local function cached_get(cache_key, endpoint, action, pr, opts, on_done)
	if not (opts and opts.force_refresh) then
		local cached, ok = client.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end
	return client.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		client.set_cache(cache_key, result)
		on_done(result, nil)
	end, { action = action, change = tostring(pr.id) })
end

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(links: AtlasRelatedItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_links(pr, opts, on_done)
	return cached_get(
		string.format("gerrit:change:%s:related", tostring(pr.id)),
		M.change_path(pr) .. "/revisions/current/related",
		"Fetch Gerrit relation chain",
		pr,
		opts,
		function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			on_done(mapper.to_related(result, assert(tonumber(pr.id))), nil)
		end
	)
end

---@param pr PullRequest
---@param path string
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(file: DiffFile|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_file_diff(pr, path, opts, on_done)
	local revision = pr.source.commit_hash ~= "" and pr.source.commit_hash or "current"
	return cached_get(
		string.format("gerrit:change:%s:diff:%s:%s", tostring(pr.id), revision, path),
		string.format(
			"%s/revisions/%s/files/%s/diff?context=ALL&intraline=false",
			M.change_path(pr),
			revision,
			client.url_encode(path)
		),
		"Fetch Gerrit file diff",
		pr,
		opts,
		function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			on_done(mapper.to_diff_file(path, result), nil)
		end
	)
end

local FILE_STATUS = { A = "added", D = "deleted", R = "renamed", C = "added" }

---@param pr PullRequest
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(entries: PullsDiffstatEntry[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_diffstat(pr, opts, on_done)
	local cache_key = string.format("gerrit:change:%s:files", tostring(pr.id))
	---@param files table<string, table>
	local function finish(files)
		local entries = {}
		for path, info in pairs(files) do
			if not mapper.is_magic_file(path) then
				table.insert(entries, {
					status = FILE_STATUS[info.status or ""] or "modified",
					path = path,
					old_path = info.old_path,
					lines_added = tonumber(info.lines_inserted) or 0,
					lines_removed = tonumber(info.lines_deleted) or 0,
				})
			end
		end
		table.sort(entries, function(a, b)
			return a.path < b.path
		end)
		on_done(entries, nil)
	end
	if not (opts and opts.force_refresh) then
		local cached, ok = client.get_cache(cache_key)
		if ok then
			finish(cached)
			return nil
		end
	end
	return client.request("GET", M.change_path(pr) .. "/revisions/current/files", nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local files = type(result) == "table" and result or {}
		client.set_cache(cache_key, files)
		finish(files)
	end, { action = "Fetch Gerrit files", change = tostring(pr.id) })
end

return M
