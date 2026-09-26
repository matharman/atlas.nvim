local config = require("atlas.config")
local providers = require("atlas.providers")
local client = require("atlas.providers.gerrit.client")

describe("Gerrit resolve", function()
	local original_options

	before_each(function()
		original_options = config.options
		config.options = {
			providers = { gerrit = { base_url = "https://gerrit.example.com/", user = "jdoe" } },
			pulls = {},
			issues = {},
		}
	end)

	after_each(function()
		config.options = original_options
	end)

	it("resolves change URLs with and without a patch set", function()
		local change = assert(providers.resolve("https://gerrit.example.com/c/tools/+/12"))
		local nested = assert(providers.resolve("https://gerrit.example.com/c/group/sub/proj/+/34/5"))

		assert.equal("gerrit", change.provider)
		assert.equal("pr", change.entity)
		assert.equal(12, change.id)
		assert.equal("tools", change.repo_full_name)
		assert.is_nil(change.workspace)
		assert.equal("tools", change.repo)
		assert.equal("https://gerrit.example.com/a/tools", change.repository_url)

		assert.equal(34, nested.id)
		assert.equal("group/sub/proj", nested.repo_full_name)
		assert.equal("group/sub", nested.workspace)
		assert.equal("proj", nested.repo)
	end)

	it("resolves fragment URLs without a project", function()
		local legacy = assert(providers.resolve("https://gerrit.example.com/#/c/77/"))
		local with_project = assert(providers.resolve("https://gerrit.example.com/#/c/group/proj/+/78/2"))

		assert.equal(77, legacy.id)
		assert.is_nil(legacy.repo_full_name)
		assert.equal(78, with_project.id)
		assert.equal("group/proj", with_project.repo_full_name)
	end)

	it("resolves remotes as repositories on the HTTP host", function()
		local cases = {
			"ssh://jdoe@gerrit.example.com:29418/group/proj",
			"ssh://gerrit.example.com:29418/group/proj.git",
			"https://gerrit.example.com/a/group/proj",
			"https://gerrit.example.com/group/proj.git",
			"https://gerrit.example.com/admin/repos/group/proj,branches",
		}
		for _, remote in ipairs(cases) do
			local target = assert(providers.resolve(remote), remote)
			assert.equal("gerrit", target.provider, remote)
			assert.equal("repo", target.entity, remote)
			assert.equal("group/proj", target.repo_full_name, remote)
			assert.equal("gerrit.example.com", target.host, remote)
		end
	end)

	it("matches a separate SSH host", function()
		config.options.providers.gerrit.ssh_host = "gerrit-ssh.example.com"

		local target = assert(providers.resolve("ssh://jdoe@gerrit-ssh.example.com:29418/proj"))

		assert.equal("gerrit.example.com", target.host)
		assert.equal("proj", target.repo_full_name)
	end)

	it("honors a base path and port", function()
		config.options.providers.gerrit.base_url = "https://example.com:8443/r"

		local change = assert(providers.resolve("https://example.com:8443/r/c/proj/+/5"))
		local remote = assert(providers.resolve("ssh://example.com:29418/proj"))

		assert.equal(5, change.id)
		assert.equal("example.com:8443", change.host)
		assert.equal("example.com:8443", remote.host)
		assert.is_nil(providers.resolve("https://example.com:8443/other/c/proj/+/5"))
	end)

	it("round-trips the change link", function()
		local link = client.change_url("group/proj", 12)
		local target = assert(providers.resolve(link))

		assert.equal("https://gerrit.example.com/c/group/proj/+/12", link)
		assert.equal(12, target.id)
		assert.equal("group/proj", target.repo_full_name)
	end)

	it("rejects web routes that are not changes", function()
		local target, err = providers.resolve("https://gerrit.example.com/q/status:open")
		assert.is_nil(target)
		assert.is_truthy(err)
	end)

	it("ignores hosts that are not configured", function()
		assert.is_nil(providers.resolve("https://other.example.com/c/proj/+/1"))
	end)
end)
