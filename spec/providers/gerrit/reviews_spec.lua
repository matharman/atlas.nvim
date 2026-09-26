local utils = require("atlas.core.utils")

local MODULES = {
	"atlas.providers.gerrit.client",
	"atlas.pulls.providers.gerrit.api.changes",
	"atlas.pulls.providers.gerrit.api.comments",
	"atlas.pulls.providers.gerrit.api.mapper",
	"atlas.pulls.providers.gerrit.api.reviews",
}

local DIFF = { content = { { ab = { "one", "two" } }, { b = { "three" } } } }

local COMMENTS = {
	["a.lua"] = {
		{ id = "r1", line = 3, patch_set = 3, updated = "2024-01-01 00:00:00" },
		{ id = "c1", line = 3, patch_set = 3, in_reply_to = "r1", updated = "2024-01-02 00:00:00" },
		{ id = "r4", line = 1, patch_set = 3, updated = "2024-01-03 00:00:00" },
	},
	["b.lua"] = { { id = "r2", line = 1, patch_set = 1, updated = "2024-01-01 00:00:00" } },
	["c.lua"] = { { id = "r3", line = 2, patch_set = 3, updated = "2024-01-01 00:00:00" } },
}

local calls

local function load_reviews()
	for _, name in ipairs(MODULES) do
		package.loaded[name] = nil
	end
	package.loaded["atlas.providers.gerrit.client"] = {
		request = function(_, endpoint, _, on_done)
			table.insert(calls, endpoint)
			local path = endpoint:match("/files/([^/]+)/diff")
			if path == "a.lua" then
				on_done(DIFF, nil)
			elseif path then
				on_done(nil, "HTTP 500")
			elseif endpoint:match("/comments$") then
				on_done(COMMENTS, nil)
			elseif endpoint:match("^/changes/42%?") then
				on_done({ messages = {}, reviewers = {} }, nil)
			else
				on_done({}, nil)
			end
			return { cancel = function() end }
		end,
		url_encode = utils.url_encode,
		change_id = function(_, number)
			return tostring(number)
		end,
		get_cache = function()
			return nil, false
		end,
		set_cache = function() end,
		invalidate_change = function() end,
	}
	return require("atlas.pulls.providers.gerrit.api.reviews")
end

describe("Gerrit review threads", function()
	before_each(function()
		calls = {}
	end)

	after_each(function()
		for _, name in ipairs(MODULES) do
			package.loaded[name] = nil
		end
	end)

	it("attaches code snippets to current thread roots", function()
		local reviews = load_reviews()
		local pr = { id = 42, source = { commit_hash = "head" }, link = { html = "" }, patch_set = 3 }
		local data
		reviews.fetch_threads(pr, nil, function(value, err)
			assert.is_nil(err)
			data = value
		end)

		local by_id = {}
		for _, comment in ipairs(assert(data).comments) do
			by_id[comment.id] = comment
		end
		local diff_calls = {}
		for _, endpoint in ipairs(calls) do
			if endpoint:find("/diff?", 1, true) then
				table.insert(diff_calls, endpoint)
			end
		end

		assert.equal(2, #diff_calls)
		assert.equal(" two", by_id.r4.hunk.lines[2].text)
		assert.equal("+three", by_id.r1.hunk.lines[#by_id.r1.hunk.lines].text)
		assert.is_nil(by_id.c1.hunk)
		assert.is_nil(by_id.r2.hunk)
		assert.is_nil(by_id.r3.hunk)
	end)
end)
