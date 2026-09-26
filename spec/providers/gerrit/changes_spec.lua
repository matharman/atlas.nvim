local utils = require("atlas.core.utils")

local MODULES = {
	"atlas.providers.gerrit.client",
	"atlas.pulls.providers.gerrit.api.changes",
	"atlas.pulls.providers.gerrit.api.mapper",
}

local calls
local response

local function load_changes()
	for _, name in ipairs(MODULES) do
		package.loaded[name] = nil
	end
	package.loaded["atlas.providers.gerrit.client"] = {
		request = function(method, endpoint, data, on_done)
			table.insert(calls, { method = method, endpoint = endpoint, data = data })
			if response.by_endpoint then
				on_done(response.by_endpoint(method, endpoint), nil)
				return { cancel = function() end }
			end
			on_done(response.result, response.err)
			return { cancel = function() end }
		end,
		url_encode = utils.url_encode,
		change_id = function(project, number)
			return project and (utils.url_encode(project) .. "~" .. tostring(number)) or tostring(number)
		end,
		get_cache = function()
			return nil, false
		end,
		set_cache = function() end,
		invalidate_change = function() end,
	}
	return require("atlas.pulls.providers.gerrit.api.changes")
end

describe("Gerrit changes", function()
	before_each(function()
		calls = {}
		response = { result = {}, err = nil }
	end)

	after_each(function()
		for _, name in ipairs(MODULES) do
			package.loaded[name] = nil
		end
	end)

	it("scopes change lookups to the repository", function()
		local changes = load_changes()
		local pulls, failure
		changes.fetch_by_refs({ { id = 12345, repo_full_name = "group/proj" } }, nil, function(value, err)
			pulls, failure = value, err
		end)

		assert.is_truthy(calls[1].endpoint:find("q=change%3A12345%20project%3Agroup%2Fproj", 1, true))
		assert.same({}, pulls)
		assert.equal("Change 12345 not found in group/proj", failure)
	end)

	it("names the change when no repository is known", function()
		local changes = load_changes()
		local failure
		changes.fetch_by_refs({ { id = 12345 } }, nil, function(_, err)
			failure = err
		end)

		assert.equal("Change 12345 not found", failure)
	end)

	it("reports a missing change for a 404 on the project-scoped identifier", function()
		local changes = load_changes()
		response = { result = nil, err = "HTTP 404: Not found: group%2Fproj~12345" }
		local failure
		changes.fetch_change({ id = 12345, repo_full_name = "group/proj" }, nil, function(_, err)
			failure = err
		end)

		assert.equal("/changes/group%2Fproj~12345", calls[1].endpoint:match("^[^?]+"))
		assert.equal("Change 12345 not found in group/proj", failure)
	end)

	describe("update_pr", function()
		local pr = {
			id = 7,
			repo_full_name = "proj",
			state = "open",
			author = { id = "1" },
			destination = { branch = "main" },
		}

		before_each(function()
			response.by_endpoint = function(method, endpoint)
				if method == "GET" and endpoint:find("/commit$") then
					return { message = "Subject\n\nBody\n\nChange-Id: I1\n" }
				end
				if method == "GET" then
					return { reviewers = { REVIEWER = { { _account_id = 2, name = "Rev" } } } }
				end
				return {}
			end
		end)

		---@return string[]
		local function writes()
			local result = {}
			for _, call in ipairs(calls) do
				if call.method ~= "GET" then
					table.insert(result, call.method .. " " .. call.endpoint)
				end
			end
			table.sort(result)
			return result
		end

		it("writes nothing when the fields are unchanged", function()
			local changes = load_changes()
			local ok
			changes.update_pr(pr, { title = "Subject", body = "Body\n\nChange-Id: I1", draft = false, base = "main" }, function(value)
				ok = value
			end)

			assert.is_true(ok)
			assert.same({}, writes())
		end)

		it("edits the message and work in progress state", function()
			local changes = load_changes()
			changes.update_pr(pr, { title = "New subject", draft = true }, function() end)

			assert.same({ "POST /changes/proj~7/wip", "PUT /changes/proj~7/message" }, writes())
			local message = vim.tbl_filter(function(call)
				return call.method == "PUT"
			end, calls)[1]
			assert.equal("New subject\n\nBody\n\nChange-Id: I1\n", message.data.message)
		end)

		it("adds and removes reviewers relative to the change", function()
			local changes = load_changes()
			changes.update_pr(pr, { reviewers = { { provider_id = "3", label = "New" } } }, function() end)

			assert.same({ "DELETE /changes/proj~7/reviewers/2", "POST /changes/proj~7/reviewers" }, writes())
		end)
	end)
end)
