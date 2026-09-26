local url = require("atlas.providers.url")

---@type AtlasProvider
return {
	id = "gerrit",
	name = "Gerrit",
	hostname = function()
		local base = url.configured_base("gerrit")
		return base and base.host or nil
	end,
	resolver = require("atlas.providers.gerrit.resolve"),
	domains = {
		pulls = {
			module = "atlas.pulls.providers.gerrit",
			icon = { icon = "", hl_group = "AtlasGerritTheme" },
			bookmark_key = "S",
		},
	},
	capabilities = {
		-- repository = nil,
		-- notifications = nil,
		users = require("atlas.providers.gerrit.users"),
		completion = require("atlas.providers.gerrit.completion"),
	},
}
