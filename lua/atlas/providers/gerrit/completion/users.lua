local changes_api = require("atlas.pulls.providers.gerrit.api.changes")
local client = require("atlas.providers.gerrit.client")
local mapper = require("atlas.providers.gerrit.mapper")

---@param user AtlasUser|GerritAuthor
---@return string|nil
local function format_mention(user)
	-- Gerrit resolves `@<email>` mentions; the username is the fallback when no email is known.
	local handle = user.email or user.username or ""
	if handle ~= "" then
		return "@" .. handle
	end
end

-- Emails contain `@`, so the trigger is the `@` that starts the word.
---@param before string
---@return integer|nil, string|nil
local function match(before)
	local start = before:match("^()@[%w._%+%-@]*$") or before:match("[%s(%[{]()@[%w._%+%-@]*$")
	if start then
		return start - 1, before:sub(start + 1)
	end
end

---@param authors GerritAuthor[]
---@return AtlasCompletionItem[]
local function completion_items(authors)
	local items, seen = {}, {}
	for _, author in ipairs(authors) do
		local mention = format_mention(author)
		if author.id ~= "" and mention and not seen[author.id] then
			seen[author.id] = true
			items[#items + 1] = {
				label = string.format("%s <%s>", author.name, mention:sub(2)),
				insert_text = mention,
				filter_text = table.concat({ author.email or "", author.username or "", author.name }, " "),
			}
		end
	end
	table.sort(items, function(a, b)
		return a.label < b.label
	end)
	return items
end

---@param change table ChangeInfo with DETAILED_ACCOUNTS and MESSAGES.
---@return GerritAuthor[]
local function participants(change)
	local authors = { mapper.to_author(change.owner) }
	local reviewers = type(change.reviewers) == "table" and change.reviewers or {}
	for _, state in ipairs({ "REVIEWER", "CC" }) do
		for _, account in ipairs(type(reviewers[state]) == "table" and reviewers[state] or {}) do
			authors[#authors + 1] = mapper.to_author(account)
		end
	end
	for _, message in ipairs(type(change.messages) == "table" and change.messages or {}) do
		if type(message.author) == "table" then
			authors[#authors + 1] = mapper.to_author(message.author)
		end
	end
	return authors
end

---@type AtlasCompletionSource
return {
	triggers = { "@" },
	format_mention = format_mention,
	match = match,

	complete = function(context, query, done)
		if context.pr then
			return changes_api.fetch_change(context.pr, nil, function(change, err)
				if not change then
					done(nil, err)
					return
				end
				done(completion_items(participants(change)), nil)
			end)
		end

		if query == "" then
			done({}, nil)
			return nil
		end
		local endpoint = string.format("/accounts/?suggest&q=%s&n=20&o=DETAILS", client.url_encode(query))
		return client.request("GET", endpoint, nil, function(result, err)
			if err then
				done(nil, err)
				return
			end
			local authors = {}
			for _, account in ipairs(type(result) == "table" and result or {}) do
				authors[#authors + 1] = mapper.to_author(account)
			end
			done(completion_items(authors), nil)
		end, { action = "Suggest Gerrit accounts" })
	end,
}
