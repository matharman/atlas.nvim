local config = require("atlas.config")
local notes = require("atlas.pulls.notes")

describe("pulls.notes.resolve_target", function()
	local original_options

	---@param base_url string
	local function use_gerrit(base_url)
		config.options = {
			providers = { gerrit = { base_url = base_url, user = "jdoe" } },
			pulls = {},
			issues = {},
		}
	end

	before_each(function()
		original_options = config.options
		use_gerrit("https://gerrit.example.com")
	end)

	after_each(function()
		config.options = original_options
	end)

	it("resolves Gerrit change URLs without lowercasing the project", function()
		local target = assert(notes.resolve_target("https://Gerrit.example.com/c/Group/Proj/+/42/3"))

		assert.equal("gerrit", target.provider)
		assert.equal("gerrit.example.com", target.host)
		assert.equal("Group/Proj", target.repository)
		assert.equal("42", target.id)
		assert.equal("gerrit:gerrit.example.com/Group/Proj/pr/42", target.ref)
	end)

	it("resolves Gerrit URLs below a path prefix", function()
		use_gerrit("https://example.com/r")
		local target = assert(notes.resolve_target("https://example.com/r/c/proj/+/7"))

		assert.equal("proj", target.repository)
		assert.equal("7", target.id)
	end)

	it("matches the canonical Gerrit reference", function()
		local url = assert(notes.resolve_target("https://gerrit.example.com/c/Group/Proj/+/42"))
		local canonical = assert(notes.resolve_target("gerrit:gerrit.example.com/Group/Proj/pr/42"))

		assert.equal(url.ref, canonical.ref)
	end)
end)
