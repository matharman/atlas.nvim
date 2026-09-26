local original = {
	json = vim.json,
	base64 = vim.base64,
}

local calls
local response

local function load_client()
	package.loaded["atlas.providers.gerrit.client"] = nil
	package.loaded["atlas.core.http"] = {
		curl_raw_request = function(method, url, headers, body, on_done)
			table.insert(calls, { method = method, url = url, headers = headers, body = body })
			on_done(response.body, response.status, response.err)
			return { job_id = 1, cancel = function() end }
		end,
	}
	package.loaded["atlas.config"] = {
		provider_options = function(id)
			return id == "gerrit" and { base_url = "https://gerrit.example.com/", user = "jdoe", http_password = "pw" }
				or nil
		end,
	}
	package.loaded["atlas.core.logger"] = { loginfo = function() end, logerror = function() end }
	package.loaded["atlas.core.memory_cache"] = {}
	return require("atlas.providers.gerrit.client")
end

describe("Gerrit client", function()
	local saved = {}

	before_each(function()
		for _, name in ipairs({ "atlas.core.http", "atlas.config", "atlas.core.logger", "atlas.core.memory_cache" }) do
			saved[name] = package.loaded[name]
		end
		calls = {}
		response = { body = "", status = 200 }
		vim.json = {
			encode = original.json.encode,
			decode = function(text)
				assert(text == '\n{"ok":true}', "unexpected payload: " .. text)
				return { ok = true }
			end,
		}
		vim.base64 = {
			encode = function(value)
				return "b64(" .. value .. ")"
			end,
		}
	end)

	after_each(function()
		for name, value in pairs(saved) do
			package.loaded[name] = value
		end
		package.loaded["atlas.providers.gerrit.client"] = nil
		vim.json = original.json
		vim.base64 = original.base64
	end)

	it("strips the XSSI prefix before decoding", function()
		local client = load_client()
		local value, err = client.decode(')]}\'\n{"ok":true}')

		assert.is_nil(err)
		assert.same({ ok = true }, value)
	end)

	it("treats an empty body as no result", function()
		local client = load_client()
		local value, err = client.decode("")

		assert.is_nil(value)
		assert.is_nil(err)
	end)

	it("sends authenticated requests below /a", function()
		local client = load_client()
		response = { body = ')]}\'\n{"ok":true}', status = 200 }
		local result

		client.request("GET", "/accounts/self", nil, function(value)
			result = value
		end)

		assert.same({ ok = true }, result)
		assert.equal("https://gerrit.example.com/a/accounts/self", calls[1].url)
		assert.equal("Basic b64(jdoe:pw)", calls[1].headers.Authorization)
	end)

	it("reports plain-text error bodies", function()
		local client = load_client()
		response = { body = "Not found: 12\n", status = 404 }
		local failure

		client.request("GET", "/changes/12", nil, function(_, err)
			failure = err
		end)

		assert.equal("HTTP 404: Not found: 12", failure)
	end)
end)
