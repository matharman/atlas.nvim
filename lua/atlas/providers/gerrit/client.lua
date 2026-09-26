local M = {}

local config = require("atlas.config")
local http = require("atlas.core.http")
local logger = require("atlas.core.logger")
local memory_cache = require("atlas.core.memory_cache")
local utils = require("atlas.core.utils")

-- Gerrit prefixes every JSON response to defeat XSSI.
local XSSI_PREFIX = ")]}'"
local DEFAULT_SSH_PORT = 29418

---@type string|nil
local command_password

---@return AtlasGerritConfig
local function gerrit_config()
	return config.provider_options("gerrit") or {}
end

---@param value any
---@return string
local function one_line(value)
	return (vim.trim(tostring(value or "")):gsub("[\r\n]+", " | "))
end

---@return string|nil password, string|nil err
local function password()
	local cfg = gerrit_config()
	if type(cfg.http_password) == "string" and cfg.http_password ~= "" then
		return cfg.http_password, nil
	end
	if cfg.token_cmd == nil then
		return nil, nil
	end
	if command_password then
		return command_password, nil
	end
	local cmd = type(cfg.token_cmd) == "table" and cfg.token_cmd or { "sh", "-c", tostring(cfg.token_cmd) }
	local ok, result = pcall(function()
		return vim.system(cmd, { text = true }):wait(10000)
	end)
	if not ok or result.code ~= 0 then
		return nil, "providers.gerrit.token_cmd failed"
	end
	local value = vim.trim(result.stdout or "")
	if value == "" then
		return nil, "providers.gerrit.token_cmd returned an empty password"
	end
	command_password = value
	return value, nil
end

---@return string|nil user, string|nil password, string|nil err
function M.get_auth()
	local cfg = gerrit_config()
	local user = tostring(cfg.user or "")
	if M.base_url() == "" or user == "" then
		return nil, nil, "Missing Gerrit credentials in config (providers.gerrit.base_url / providers.gerrit.user)"
	end
	local secret, err = password()
	if err then
		return nil, nil, err
	end
	if secret == nil then
		return nil,
			nil,
			"Missing Gerrit credentials in config (providers.gerrit.http_password / providers.gerrit.token_cmd)"
	end
	return user, secret, nil
end

---@return string
function M.base_url()
	return (tostring(gerrit_config().base_url or ""):gsub("/+$", ""))
end

---@param project string
---@return string https_url, string ssh_url
function M.clone_urls(project)
	local cfg = gerrit_config()
	local base = M.base_url()
	local host = base:match("^%a[%w+.-]*://([^/:]+)") or ""
	local ssh_host = type(cfg.ssh_host) == "string" and cfg.ssh_host ~= "" and cfg.ssh_host or host
	local user = tostring(cfg.user or "")
	local ssh_user = user ~= "" and (user .. "@") or ""
	local port = tonumber(cfg.ssh_port) or DEFAULT_SSH_PORT
	return string.format("%s/a/%s", base, project), string.format("ssh://%s%s:%d/%s", ssh_user, ssh_host, port, project)
end

---@param project string
---@return string
function M.project_url(project)
	return string.format("%s/admin/repos/%s", M.base_url(), project)
end

---@param project string
---@param number integer|string
---@return string
function M.change_url(project, number)
	return string.format("%s/c/%s/+/%s", M.base_url(), project, tostring(number))
end

---@param project string|nil
---@param number integer|string
---@return string
function M.change_id(project, number)
	if project == nil or project == "" then
		return tostring(number)
	end
	return M.url_encode(project) .. "~" .. tostring(number)
end

---@return number
function M.cache_ttl()
	return tonumber(gerrit_config().cache_ttl) or 300
end

---@param key string
---@return any|nil, boolean
function M.get_cache(key)
	if M.cache_ttl() <= 0 then
		return nil, false
	end
	local entry = memory_cache.get(key)
	if not entry then
		return nil, false
	end
	return entry.value, true
end

---@param key string
---@param value any
function M.set_cache(key, value)
	if M.cache_ttl() <= 0 then
		return
	end
	memory_cache.set(key, value, M.cache_ttl())
end

---@param number integer|string
function M.invalidate_change(number)
	memory_cache.clear_prefix(string.format("gerrit:change:%s:", tostring(number)))
	memory_cache.clear_prefix("gerrit:list:")
end

M.url_encode = utils.url_encode

---@param body string
---@return any|nil value, string|nil err
function M.decode(body)
	local text = body
	if text:sub(1, #XSSI_PREFIX) == XSSI_PREFIX then
		text = text:sub(#XSSI_PREFIX + 1)
	end
	if vim.trim(text) == "" then
		return nil, nil
	end
	local ok, value = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
	if not ok then
		return nil, "Failed to parse Gerrit response: " .. one_line(value)
	end
	return value, nil
end

---@param method string
---@param endpoint string Path below `/a`, e.g. "/changes/".
---@param data table|nil
---@param on_done fun(result: any, err: string|nil)
---@param ctx table|nil
---@return { job_id: integer, cancel: fun() }|nil
function M.request(method, endpoint, data, on_done, ctx)
	local user, secret, auth_err = M.get_auth()
	if auth_err then
		logger.logerror("Gerrit auth missing", { error = auth_err })
		on_done(nil, auth_err)
		return nil
	end

	local payload
	if data ~= nil then
		local ok, encoded = pcall(vim.json.encode, data)
		if not ok then
			logger.logerror("Gerrit payload encode failed", { method = method, endpoint = endpoint })
			on_done(nil, "Request payload is invalid")
			return nil
		end
		payload = encoded
	end

	local headers = {
		Authorization = "Basic " .. vim.base64.encode(string.format("%s:%s", user, secret)),
		Accept = "application/json",
	}
	if payload then
		headers["Content-Type"] = "application/json; charset=UTF-8"
	end

	local log = vim.tbl_extend("keep", { method = method, endpoint = endpoint }, ctx or {})
	local message = log.action or "Gerrit request"
	log.action = nil
	logger.loginfo(message, log)

	return http.curl_raw_request(method, M.base_url() .. "/a" .. endpoint, headers, payload, function(body, status, err)
		if not err and status ~= nil and (status < 200 or status >= 300) then
			local text = one_line(body)
			err = text ~= "" and string.format("HTTP %d: %s", status, text) or string.format("HTTP %d", status)
		end
		local result
		if not err then
			result, err = M.decode(body or "")
		end
		if err then
			logger.logerror(message .. " failed", vim.tbl_extend("force", {}, log, { error = err }))
			on_done(nil, err)
			return
		end
		on_done(result, nil)
	end)
end

return M
