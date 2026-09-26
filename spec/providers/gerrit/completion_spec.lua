local MODULES = {
	"atlas.providers.gerrit.completion.users",
	"atlas.pulls.providers.gerrit.api.changes",
	"atlas.providers.gerrit.client",
}

local calls

---@param change table|nil ChangeInfo returned for a pull request context
---@param accounts table[]|nil AccountInfo list returned by account suggestions
---@return AtlasCompletionSource
local function load_source(change, accounts)
	for _, name in ipairs(MODULES) do
		package.loaded[name] = nil
	end
	package.loaded["atlas.pulls.providers.gerrit.api.changes"] = {
		fetch_change = function(_, _, on_done)
			on_done(change, nil)
		end,
	}
	package.loaded["atlas.providers.gerrit.client"] = {
		url_encode = require("atlas.core.utils").url_encode,
		request = function(method, endpoint, _, on_done)
			table.insert(calls, method .. " " .. endpoint)
			on_done(accounts or {}, nil)
		end,
	}
	return require("atlas.providers.gerrit.completion.users")
end

---@param items AtlasCompletionItem[]
---@return string[]
local function inserts(items)
	local result = {}
	for _, item in ipairs(items) do
		table.insert(result, item.insert_text)
	end
	return result
end

local alice = { _account_id = 1, name = "Alice", username = "alice", email = "alice@example.com" }
local bob = { _account_id = 2, name = "Bob", username = "bob" }

describe("Gerrit mention completion", function()
	before_each(function()
		calls = {}
	end)

	after_each(function()
		for _, name in ipairs(MODULES) do
			package.loaded[name] = nil
		end
	end)

	it("offers each participant of the change once, preferring the email", function()
		local source = load_source({
			owner = alice,
			reviewers = { REVIEWER = { bob }, CC = { alice } },
			messages = { { author = bob } },
		})
		local items
		source.complete({ provider = "gerrit", pr = { id = 1, repo_full_name = "proj" } }, "", function(value)
			items = value
		end)

		assert.same({ "@alice@example.com", "@bob" }, inserts(assert(items)))
		assert.equal(0, #calls)
	end)

	it("suggests accounts outside a change", function()
		local source = load_source(nil, { bob })
		local items
		source.complete({ provider = "gerrit" }, "bo", function(value)
			items = value
		end)

		assert.same({ "@bob" }, inserts(assert(items)))
		assert.equal("GET /accounts/?suggest&q=bo&n=20&o=DETAILS", calls[1])
	end)

	it("starts completion at the @ that begins the handle", function()
		local source = load_source()

		assert.same({ 5, "alice@example.co" }, { source.match("Ping @alice@example.co") })
		assert.same({ 0, "al" }, { source.match("@al") })
		assert.is_nil(source.match("mail me at me@example.com"))
	end)

	it("formats reply mentions like completions", function()
		local source = load_source()

		assert.equal("@alice@example.com", source.format_mention({ name = "Alice", username = "alice", email = "alice@example.com" }))
		assert.equal("@bob", source.format_mention({ name = "Bob", username = "bob" }))
		assert.is_nil(source.format_mention({ name = "Nobody", username = "" }))
	end)
end)
