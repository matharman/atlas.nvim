local utils = require("atlas.core.utils")

local MODULES = {
	"atlas.providers.gerrit.client",
	"atlas.pulls.providers.gerrit.api.changes",
	"atlas.pulls.providers.gerrit.api.comments",
	"atlas.pulls.providers.gerrit.api.mapper",
}

local calls

local function load_comments()
	for _, name in ipairs(MODULES) do
		package.loaded[name] = nil
	end
	package.loaded["atlas.providers.gerrit.client"] = {
		request = function(method, endpoint, data, on_done)
			table.insert(calls, { method = method, endpoint = endpoint, data = data })
			on_done(vim.tbl_extend("force", { id = "new", patch_set = 3 }, data or {}), nil)
			return { cancel = function() end }
		end,
		url_encode = utils.url_encode,
		change_id = function(_, number)
			return tostring(number)
		end,
		invalidate_change = function() end,
	}
	return require("atlas.pulls.providers.gerrit.api.comments")
end

local pr = {
	id = 42,
	repo_full_name = "proj",
	source = { commit_hash = "head" },
	link = { html = "https://gerrit.example.com/c/proj/+/42" },
	patch_set = 3,
}

---@param opts PullsAddCommentOpts
---@return table call
local function add_draft(opts)
	local comments = load_comments()
	opts.pending = true
	comments.add_comment(pr, "Looks off", opts, function() end)
	return calls[#calls]
end

describe("Gerrit comments", function()
	before_each(function()
		calls = {}
	end)

	after_each(function()
		for _, name in ipairs(MODULES) do
			package.loaded[name] = nil
		end
	end)

	it("comments on the new side as a revision line", function()
		local call = add_draft({ inline = { path = "a.lua", from = 8, to = 10 } })

		assert.equal("PUT", call.method)
		assert.equal("/changes/42/revisions/head/drafts", call.endpoint)
		assert.equal("a.lua", call.data.path)
		assert.equal(10, call.data.line)
		assert.is_nil(call.data.side)
		assert.is_true(call.data.unresolved)
	end)

	it("comments on the old side as a parent line", function()
		local call = add_draft({ inline = { path = "a.lua", from = 5 } })

		assert.equal("PARENT", call.data.side)
		assert.equal(5, call.data.line)
	end)

	it("sends a range for multi-line selections", function()
		local call = add_draft({ inline = { path = "a.lua", to = 12, start_to = 10 } })

		assert.equal(12, call.data.line)
		assert.equal(10, call.data.range.start_line)
		assert.equal(12, call.data.range.end_line)
	end)

	it("sends file comments without a line", function()
		local call = add_draft({ file = { path = "a.lua" } })

		assert.equal("a.lua", call.data.path)
		assert.is_nil(call.data.line)
	end)

	it("replies on the parent patch set after the last thread comment", function()
		local parent = {
			id = "root",
			state = "RESOLVED",
			_raw = { path = "a.lua", line = 4, side = "PARENT", patch_set = 2, thread_last_id = "last" },
		}
		local call = add_draft({ parent = parent })

		assert.equal("/changes/42/revisions/2/drafts", call.endpoint)
		assert.equal("last", call.data.in_reply_to)
		assert.equal("PARENT", call.data.side)
		assert.is_false(call.data.unresolved)
	end)

	it("posts general comments at patch set level", function()
		local call = add_draft({})

		assert.equal("/PATCHSET_LEVEL", call.data.path)
		assert.is_false(call.data.unresolved)
	end)

	describe("set_thread_resolved", function()
		---@param raw table
		---@param resolved boolean
		---@return table|nil change
		local function toggle(raw, resolved)
			local comments = load_comments()
			local root = { id = "root", thread_id = "root", _raw = raw }
			local change
			comments.set_thread_resolved(pr, root, resolved, function(ok, err, draft)
				assert.is_true(ok, err)
				change = draft
			end)
			return change
		end

		local function thread(extra)
			return vim.tbl_extend("force", {
				path = "a.lua",
				line = 4,
				patch_set = 2,
				thread_last_id = "last",
				published_resolved = false,
			}, extra or {})
		end

		it("records a resolution as a draft reply", function()
			local change = assert(toggle(thread(), true))
			local call = calls[1]

			assert.equal("PUT", call.method)
			assert.equal("/changes/42/revisions/2/drafts", call.endpoint)
			assert.equal("Done", call.data.message)
			assert.equal("last", call.data.in_reply_to)
			assert.is_false(call.data.unresolved)
			assert.is_true(change.comment.pending)
			assert.is_false(change.removed)
		end)

		it("drops its own draft when toggled back to the published state", function()
			local draft = { id = "d1", patch_set = 2, message = "Done", path = "a.lua", unresolved = false }
			local change = assert(toggle(thread({ thread_draft = draft }), false))

			assert.equal("DELETE", calls[1].method)
			assert.equal("/changes/42/revisions/2/drafts/d1", calls[1].endpoint)
			assert.is_true(change.removed)
			assert.equal("d1", change.comment.id)
		end)

		it("keeps the text of an existing draft reply", function()
			local draft = { id = "d2", patch_set = 2, message = "Fixed in PS3", path = "a.lua", unresolved = true }
			toggle(thread({ thread_draft = draft }), true)

			assert.equal("PUT", calls[1].method)
			assert.equal("/changes/42/revisions/2/drafts/d2", calls[1].endpoint)
			assert.equal("Fixed in PS3", calls[1].data.message)
			assert.is_false(calls[1].data.unresolved)
		end)

		it("does nothing when the thread already has that state", function()
			assert.is_nil(toggle(thread({ published_resolved = true }), true))
			assert.equal(0, #calls)
		end)
	end)

	it("saves the edited text of a draft", function()
		local comments = load_comments()
		local updated
		comments.edit_comment(pr, {
			id = "d1",
			_raw = { draft = true, path = "a.lua", line = 4, patch_set = 2, unresolved = true },
		}, "edited", function(comment, err)
			assert.is_nil(err)
			updated = comment
		end)

		assert.equal("PUT", calls[1].method)
		assert.equal("/changes/42/revisions/2/drafts/d1", calls[1].endpoint)
		assert.equal("edited", calls[1].data.message)
		assert.equal("edited", assert(updated).body)
		assert.is_true(updated.pending)
	end)

	it("refuses to edit published comments", function()
		local comments = load_comments()
		local failure
		comments.edit_comment(pr, { id = "c", _raw = { draft = false } }, "edited", function(_, err)
			failure = err
		end)

		assert.is_truthy(failure)
		assert.equal(0, #calls)
	end)
end)
