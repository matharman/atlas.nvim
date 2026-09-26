local config = require("atlas.config")
local mapper = require("atlas.pulls.providers.gerrit.api.mapper")

---@param overrides table|nil
---@return table
local function change(overrides)
	local raw = {
		_number = 42,
		project = "group/proj",
		branch = "main",
		change_id = "I0123456789abcdef0123456789abcdef01234567",
		subject = "Fix the thing",
		status = "NEW",
		created = "2024-02-01 09:59:32.126000000",
		updated = "2024-02-02 10:00:00.000000000",
		owner = { _account_id = 1, name = "Owner", username = "owner" },
		current_revision = "head",
		revisions = {
			head = {
				_number = 3,
				ref = "refs/changes/42/42/3",
				commit = { parents = { { commit = "parent" } }, message = "Fix the thing\n\nBody text\n" },
			},
		},
		labels = {
			["Code-Review"] = {
				all = {
					{ _account_id = 2, value = 1 },
					{ _account_id = 3, value = -1 },
					{ _account_id = 4, value = 0 },
				},
			},
		},
		reviewers = {
			REVIEWER = {
				{ _account_id = 1, name = "Owner", username = "owner" },
				{ _account_id = 2, name = "Alice", username = "alice" },
				{ _account_id = 3, name = "Bob", username = "bob" },
				{ _account_id = 4, name = "Carol", username = "carol" },
				{ _account_id = 5, name = "Dave", username = "dave" },
			},
		},
	}
	for key, value in pairs(overrides or {}) do
		raw[key] = value
	end
	return raw
end

describe("Gerrit mapper", function()
	local original_options

	before_each(function()
		original_options = config.options
		config.options = {
			providers = { gerrit = { base_url = "https://gerrit.example.com", user = "jdoe" } },
		}
	end)

	after_each(function()
		config.options = original_options
	end)

	it("maps states including work in progress", function()
		assert.equal("open", mapper.to_pull_request(change()).state)
		assert.equal("draft", mapper.to_pull_request(change({ work_in_progress = true })).state)
		assert.equal("merged", mapper.to_pull_request(change({ status = "MERGED" })).state)
		assert.equal("declined", mapper.to_pull_request(change({ status = "ABANDONED" })).state)
	end)

	it("uses the patch set parent as the diff base and the change ref for fetching", function()
		local pr = assert(mapper.to_pull_request(change()))

		assert.equal(42, pr.id)
		assert.equal("group/proj", pr.repo_full_name)
		assert.equal("group", pr.repo.owner)
		assert.equal("proj", pr.repo.repo_name)
		assert.equal("group/proj", pr.repo.full_name)
		assert.equal("https://gerrit.example.com/admin/repos/group/proj", pr.repo.html_url)
		assert.equal("head", pr.source.commit_hash)
		assert.equal("parent", pr.destination.commit_hash)
		assert.equal("change/42", pr.source.branch)
		assert.equal("main", pr.destination.branch)
		assert.equal("refs/changes/42/42/3", pr.source.fetch_ref)
		assert.equal("refs/changes/42/42/3", pr.destination.fetch_ref)
		assert.equal("https://gerrit.example.com/a/group/proj", pr.destination.https_url)
		assert.equal("ssh://jdoe@gerrit.example.com:29418/group/proj", pr.destination.ssh_url)
		assert.equal("https://gerrit.example.com/c/group/proj/+/42", pr.link.html)
		assert.equal("2024-02-01T09:59:32Z", pr.created_on)
		assert.equal(3, pr.patch_set)
	end)

	it("maps Code-Review votes to reviewer decisions", function()
		local reviewers = mapper.to_reviewers(change(), { ["5"] = true })
		local decisions = {}
		for _, reviewer in ipairs(assert(reviewers)) do
			decisions[reviewer.username] = reviewer.decision
		end

		assert.same({
			alice = "approved",
			bob = "changes_requested",
			carol = "pending",
			dave = "reviewed",
		}, decisions)
	end)

	it("splits and joins the commit message", function()
		local subject, body = mapper.split_message("Subject\n\nBody\n\nChange-Id: I1\n")

		assert.equal("Subject", subject)
		assert.equal("Body\n\nChange-Id: I1", body)
		assert.equal("New\n\nBody\n\nChange-Id: I1\n", mapper.join_message("New", body))
	end)

	it("lets the viewer's draft reply decide the thread state", function()
		local pr = { link = { html = "https://gerrit.example.com/c/group/proj/+/42" } }
		local function comment(id, in_reply_to, unresolved, day, draft)
			local raw = {
				id = id,
				path = "f.lua",
				line = 3,
				patch_set = 3,
				in_reply_to = in_reply_to,
				unresolved = unresolved,
				updated = "2024-01-0" .. day .. " 00:00:00",
			}
			return mapper.to_comment(raw, { pr = pr, current_patch_set = 3, draft = draft })
		end
		local published = mapper.link_threads({
			comment("a", nil, true, 1),
			comment("b", "a", false, 2),
		})
		local reopened = mapper.link_threads({
			comment("a", nil, true, 1),
			comment("b", "a", false, 2),
			comment("c", "b", true, 3, true),
		})

		assert.equal("RESOLVED", published[1].state)
		assert.equal("a", published[2].parent_id)
		assert.equal("b", published[1]._raw.thread_last_id)
		assert.is_nil(published[1]._raw.thread_draft)

		assert.is_nil(reopened[1].state)
		assert.is_true(reopened[3].pending)
		assert.is_nil(reopened[3].state)
		assert.equal("a", reopened[3].parent_id)
		assert.is_true(reopened[1]._raw.published_resolved)
		assert.equal("c", reopened[1]._raw.thread_draft.id)
		assert.equal("b", reopened[1]._raw.thread_last_id)
	end)

	it("marks comments from older patch sets as outdated unless ported", function()
		local pr = { link = { html = "" } }
		local old = mapper.to_comment(
			{ id = "x", path = "f.lua", line = 9, patch_set = 1 },
			{ pr = pr, current_patch_set = 3 }
		)
		local ported = mapper.to_comment(
			{ id = "y", path = "f.lua", line = 9, patch_set = 1 },
			{ pr = pr, current_patch_set = 3, ported = { id = "y", path = "f.lua", line = 11, patch_set = 3 } }
		)

		assert.is_true(old.outdated)
		assert.equal("OUTDATED", old.state)
		assert.is_nil(ported.outdated)
		assert.equal(11, ported.inline.to)
		assert.equal(9, ported._raw.line)
	end)

	it("parses votes from change messages", function()
		local approved = mapper.to_history({
			id = "m1",
			author = { _account_id = 2 },
			message = "Patch Set 3: Code-Review+2\n\n(1 comment)\n\nLooks good",
		})
		local removed =
			mapper.to_history({ id = "m2", author = { _account_id = 2 }, message = "Patch Set 3: -Code-Review" })
		local generated =
			mapper.to_history({ id = "m3", tag = "autogenerated:gerrit:newPatchSet", message = "Uploaded" })

		assert.equal("approved", approved.state)
		assert.equal("Looks good", approved.body)
		assert.equal("dismissed", removed.state)
		assert.is_nil(generated)
	end)

	it("splits the relation chain around the change", function()
		local function entry(number, status)
			return { project = "proj", _change_number = number, status = status, commit = { subject = "S" .. number } }
		end
		local items = mapper.to_related({
			changes = { entry(12, "NEW"), entry(11, "NEW"), entry(10, "MERGED"), { commit = { subject = "none" } } },
		}, 11)

		assert.equal(2, #items)
		assert.same({
			kind = "pr",
			url = "https://gerrit.example.com/c/proj/+/12",
			key = "12",
			title = "S12",
			relationship = "child",
		}, items[1])
		assert.equal("parent", items[2].relationship)
		assert.equal("S10 [merged]", items[2].title)
	end)

	describe("to_diff_file", function()
		local file = mapper.to_diff_file("f.lua", {
			content = {
				{ ab = { "one", "two", "three", "four" } },
				{ a = { "old five" }, b = { "new five", "new six" } },
				{ ab = { "seven" } },
				{ skip = 90 },
				{ ab = { "ninety eight" } },
			},
		})

		it("tracks both sides' line numbers across chunks and skips", function()
			assert.equal(2, #file.hunks)
			local first, second = file.hunks[1], file.hunks[2]
			assert.equal("@@ -1,6 +1,7 @@", first.header)
			assert.same({ 2, 1 }, { first.additions, first.deletions })
			assert.same({ "remove", 5, nil }, { first.lines[5].kind, first.lines[5].old_line, first.lines[5].new_line })
			assert.same({ "add", nil, 6 }, { first.lines[7].kind, first.lines[7].old_line, first.lines[7].new_line })
			assert.equal("@@ -97,1 +98,1 @@", second.header)
		end)

		it("windows a snippet around a line on either side", function()
			local new_side = assert(mapper.hunk_at(file, "new", 6))
			local old_side = assert(mapper.hunk_at(file, "old", 5))

			assert.equal("+new six", new_side.lines[#new_side.lines - 1].text)
			assert.equal(" two", old_side.lines[1].text)
		end)

		it("has no hunks for binary files", function()
			assert.same({}, mapper.to_diff_file("img.png", { binary = true }).hunks)
		end)
	end)
end)
