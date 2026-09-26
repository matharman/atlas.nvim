local M = {}

local config = require("atlas.config")
local url = require("atlas.providers.url")

-- First path segments that belong to the Gerrit web UI rather than to a project.
local WEB_ROUTES = {
	c = true,
	q = true,
	admin = true,
	dashboard = true,
	settings = true,
	login = true,
	plugins = true,
	x = true,
}

---@param host string
---@return string
local function strip_port(host)
	return (host:gsub(":%d+$", ""))
end

---@return AtlasParsedUrl|nil base, table<string, boolean> hosts
local function configured()
	local base = url.configured_base("gerrit")
	local hosts = {}
	if base == nil then
		return nil, hosts
	end
	hosts[strip_port(base.host)] = true
	local ssh_host = (config.provider_options("gerrit") or {}).ssh_host
	if type(ssh_host) == "string" and ssh_host ~= "" then
		hosts[ssh_host:lower()] = true
	end
	return base, hosts
end

---@param project string
---@return string|nil workspace, string repo
local function split_project(project)
	local workspace, repo = project:match("^(.+)/([^/]+)$")
	return workspace, repo or project
end

---@param base AtlasParsedUrl
---@param project string|nil
---@return string web_url, string|nil repository_url
local function repository(base, project)
	local base_url = url.base_url("gerrit", base.host)
	if project == nil then
		return base_url, nil
	end
	return base_url .. "/admin/repos/" .. project, base_url .. "/a/" .. project
end

---@param base AtlasParsedUrl
---@param project string|nil
---@param number integer
---@param value string
---@return AtlasTarget
local function pr_target(base, project, number, value)
	local workspace, repo = nil, nil
	if project then
		workspace, repo = split_project(project)
	end
	local _, repository_url = repository(base, project)
	return {
		provider = "gerrit",
		domain = "pulls",
		entity = "pr",
		url = value,
		repository_url = repository_url,
		host = base.host,
		owner = workspace,
		workspace = workspace,
		repo = repo,
		project_path = project,
		repo_full_name = project,
		id = number,
		number = number,
	}
end

---@param base AtlasParsedUrl
---@param project string
---@return AtlasTarget
local function repo_target(base, project)
	local workspace, repo = split_project(project)
	local web_url, repository_url = repository(base, project)
	return {
		provider = "gerrit",
		domain = "pulls",
		entity = "repo",
		url = web_url,
		repository_url = repository_url,
		host = base.host,
		owner = workspace,
		workspace = workspace,
		repo = repo,
		project_path = project,
		repo_full_name = project,
	}
end

---@param parsed AtlasParsedUrl
---@param base AtlasParsedUrl
---@return string|nil
local function web_path(parsed, base)
	if base.path == "" then
		return parsed.path
	end
	if parsed.path == base.path then
		return ""
	end
	if parsed.path:sub(1, #base.path + 1) == base.path .. "/" then
		return parsed.path:sub(#base.path + 1)
	end
	return nil
end

---@param value string
---@param base AtlasParsedUrl
---@return AtlasTarget|nil
local function resolve_fragment(value, base)
	local fragment = value:match("^https?://[^#]*#(.*)$")
	if fragment == nil then
		return nil
	end
	local project, number = fragment:match("^/c/(.-)/%+/(%d+)")
	if project == nil then
		number = fragment:match("^/c/(%d+)")
	end
	if number == nil then
		return nil
	end
	return pr_target(base, project, assert(tonumber(number)), value)
end

---@param value string
---@param parsed AtlasParsedUrl|nil
---@return AtlasTarget|nil, string|nil
function M.resolve(value, parsed)
	if parsed == nil then
		return nil, nil
	end
	local base, hosts = configured()
	if base == nil or not hosts[strip_port(parsed.host)] then
		return nil, nil
	end

	local is_http = value:match("^[Hh][Tt][Tt][Pp][Ss]?://") ~= nil
	if is_http then
		local target = resolve_fragment(value, base)
		if target then
			return target
		end
	end

	if parsed.remote then
		local path = is_http and web_path(parsed, base) or parsed.path
		if path == nil then
			return nil, nil
		end
		local project = path:gsub("^/+", ""):gsub("%.git$", "")
		if is_http then
			project = project:gsub("^a/", "")
		end
		if project == "" then
			return nil, "Unsupported Gerrit remote. Expected a project path"
		end
		return repo_target(base, project)
	end

	local path = web_path(parsed, base)
	if path == nil then
		return nil, nil
	end

	local project, number, tail = path:match("^/c/(.-)/%+/(%d+)(.*)$")
	if number == nil then
		number, tail = path:match("^/c/(%d+)(.*)$")
	end
	if number == nil then
		number, tail = path:match("^/(%d+)(.*)$")
	end
	if number ~= nil then
		if not url.valid_tail(tail) then
			return nil, "Unsupported Gerrit URL"
		end
		return pr_target(base, project ~= "" and project or nil, assert(tonumber(number)), value)
	end

	project = path:match("^/admin/repos/(.+)$")
	if project then
		return repo_target(base, (project:gsub(",[^/]*$", "")))
	end

	project = path:gsub("^/a/", "/"):match("^/(.+)$")
	local first = project and project:match("^([^/]+)")
	if project and not WEB_ROUTES[first] then
		return repo_target(base, project)
	end

	return nil, "Unsupported Gerrit URL. Expected a change or project URL"
end

return M
