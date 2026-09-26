local actions = require("atlas.pulls.actions")
local providers = require("atlas.providers")

local function assert_functions(value, names, label)
	assert.equal("table", type(value), label)
	for _, name in ipairs(names) do
		assert.equal("function", type(value[name]), label .. "." .. name)
	end
end

describe("gerrit provider contract", function()
	it("exposes the pulls capabilities", function()
		local provider = assert(providers.load("gerrit", "pulls"))
		local capabilities = provider.capabilities

		assert_functions(provider, { "views", "repository_view", "resolve_search" }, "gerrit.pulls")
		assert_functions(capabilities.core, {
			"fetch_pullrequests",
			"fetch_by_refs",
			"fetch_pullrequest",
			"fetch_links",
			"fetch_description",
			"fetch_reviewers",
			"decline",
		}, "gerrit.pulls.core")
		assert_functions(capabilities.write, { "update", "fetch_reviewer_candidates" }, "gerrit.pulls.write")
		assert.is_nil(capabilities.write.create)
		assert_functions(capabilities.reviews, {
			"fetch",
			"fetch_threads",
			"submit_review",
			"approve",
			"request_changes",
			"discard_review",
			"set_files_reviewed",
		}, "gerrit.pulls.reviews")
		assert_functions(capabilities.actions, { "find" }, "gerrit.pulls.actions")
		assert_functions(capabilities.users, { "fetch_user" }, "gerrit.users")
		assert_functions(capabilities.completion.users, { "complete", "match", "format_mention" }, "gerrit.completion")
	end)

	it("offers review actions on open changes only", function()
		local provider = assert(providers.load("gerrit", "pulls"))
		for _, id in ipairs({ "approve", "request_changes" }) do
			assert.is_true(actions.is_available(id, { provider = provider, pr = { state = "open" } }))
			assert.is_false(actions.is_available(id, { provider = provider, pr = { state = "merged" } }))
		end
		assert.is_true(actions.is_available("restore", { provider = provider, pr = { state = "declined" } }))
	end)
end)
