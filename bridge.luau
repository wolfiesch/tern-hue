-- Hue bridge access over the local CLIP v1 API. Dependencies are injected so both plugin
-- halves share one client and tests run without a bridge.
local M = {}

local TIMEOUT = 5_000
-- discovery.meethue.com allows about one request per 15 minutes per client.
local DISCOVERY_INTERVAL = 15 * 60_000

local function trim(s: string): string
	return (s:match("^%s*(.-)%s*$")) or ""
end

local function unquote(s: string): string
	return s:match('^"(.*)"$') or s:match("^'(.*)'$") or s
end

-- Reads the openhue CLI's config (`bridge: <ip>`, `key: <app key>`), the format `openhue setup` writes.
function M.parseConfig(text: string): ({ bridge: string, key: string }?, string?)
	local out = {}
	for line in text:gmatch("[^\r\n]+") do
		if not line:match("^%s*#") then
			local k, v = line:match("^%s*([%w_]+)%s*:%s*(.-)%s*$")
			if k and v and v ~= "" then
				if not v:match("^[\"']") then v = trim((v:gsub("%s+#.*$", ""))) end
				out[k] = unquote(v)
			end
		end
	end
	if not out.bridge or out.bridge == "" then return nil, "The config has no `bridge:` address." end
	if not out.key or out.key == "" then return nil, "The config has no `key:` application key." end
	return { bridge = out.bridge, key = out.key }, nil
end

function M.configPath(getenv: (string) -> string?): string?
	local explicit = getenv("TERN_HUE_CONFIG")
	if explicit and explicit ~= "" then return explicit end
	local home = getenv("HOME") or getenv("USERPROFILE")
	if not home or home == "" then return nil end
	return home .. "/.openhue/config.yaml"
end

function M.load(fs: any, getenv: (string) -> string?): ({ bridge: string, key: string, path: string }?, string?)
	local path = M.configPath(getenv)
	if not path then return nil, "HOME is unset, so the Hue config cannot be found." end
	if not fs.exists(path) then return nil, "No Hue config at " .. path .. "." end
	local ok, text = pcall(fs.read, path, 16_384)
	if not ok then return nil, "Could not read " .. path .. "." end
	local cfg, err = M.parseConfig(text)
	if not cfg then return nil, (err :: string) .. " (" .. path .. ")" end
	return { bridge = cfg.bridge, key = cfg.key, path = path }, nil
end

-- The first v1 error in a response (`[{"error": {...}}]`), as a message for people.
function M.firstError(data: any): string?
	if type(data) ~= "table" then return nil end
	for _, entry in data do
		if type(entry) == "table" and type(entry.error) == "table" then
			if entry.error.type == 1 then
				return "The bridge rejected the application key. Pair again with `openhue setup`."
			end
			return "Bridge error: " .. tostring(entry.error.description or entry.error.type)
		end
	end
	return nil
end

local function redact(text: string, secret: string): string
	if secret == "" then return text end
	local out, start = {}, 1
	while true do
		local i, j = text:find(secret, start, true)
		if not i then break end
		table.insert(out, text:sub(start, i - 1))
		table.insert(out, "<key>")
		start = j + 1
	end
	table.insert(out, text:sub(start))
	return table.concat(out)
end

-- deps: fetch(url, opts, cb), encode, decode, now() in ms, and optional
-- loadHost()/saveHost(ip) to remember a rediscovered bridge address.
function M.client(deps: any, cfg: { bridge: string, key: string })
	local self = {
		configured = cfg.bridge,
		key = cfg.key,
		host = cfg.bridge,
		lastDiscovery = -math.huge,
	}
	local remembered = deps.loadHost and deps.loadHost()
	if type(remembered) == "table" and remembered.from == cfg.bridge and type(remembered.ip) == "string" then
		self.host = remembered.ip
	end

	-- Asks the cloud discovery endpoint for the bridge's current LAN address (DHCP can move it).
	local function rediscover(done: (boolean, any?) -> ())
		local now = deps.now()
		if now - self.lastDiscovery < DISCOVERY_INTERVAL then
			done(false)
			return
		end
		self.lastDiscovery = now
		deps.fetch("https://discovery.meethue.com/", { timeout_ms = TIMEOUT }, function(res, cx)
			if res.error or res.status ~= 200 then return done(false, cx) end
			local ok, list = pcall(deps.decode, res.body)
			if not ok or type(list) ~= "table" or #list ~= 1 or type(list[1]) ~= "table"
				or type(list[1].internalipaddress) ~= "string" then
				return done(false, cx)
			end
			local ip = list[1].internalipaddress
			if ip == self.host then return done(false, cx) end
			self.host = ip
			if deps.saveHost then deps.saveHost({ from = self.configured, ip = ip }) end
			return done(true, cx)
		end)
	end

	function self:request(method: string, path: string, body: any?, done: (any?, string?, ...any) -> ())
		local function attempt(retry: boolean)
			local url = "http://" .. self.host .. "/api/" .. self.key .. path
			local opts = {
				method = method,
				timeout_ms = TIMEOUT,
				headers = if body ~= nil then { ["Content-Type"] = "application/json" } else nil,
				body = if body ~= nil then deps.encode(body) else nil,
			}
			-- `cx` is the window half's fresh context for this callback (nil in the host); it is only
			-- valid inside the callback that received it, so pass on the newest one.
			deps.fetch(url, opts, function(res, cx)
				if res.error then
					local message = "Bridge unreachable at " .. self.host .. ": " .. redact(res.error, self.key)
					if retry then
						return rediscover(function(moved, newer)
							if moved then attempt(false) else done(nil, message, newer or cx) end
						end)
					end
					return done(nil, message, cx)
				end
				if res.status ~= 200 then
					return done(nil, "Bridge answered HTTP " .. tostring(res.status) .. ".", cx)
				end
				local ok, data = pcall(deps.decode, res.body)
				if not ok then return done(nil, "Bridge sent a response that is not JSON.", cx) end
				local err = M.firstError(data)
				if err then return done(nil, err, cx) end
				return done(data, nil, cx)
			end)
		end
		attempt(true)
	end

	function self:get(path: string, done) self:request("GET", path, nil, done) end
	function self:put(path: string, body: any, done) self:request("PUT", path, body, done) end

	return self
end

-- The client for the current config, reusing `previous` while the config is unchanged so its
-- rediscovery throttle and remembered address survive between calls.
function M.current(previous: any, fs: any, getenv: (string) -> string?, deps: any): (any, string?)
	local cfg, err = M.load(fs, getenv)
	if not cfg then return nil, err end
	if previous and previous.key == cfg.key and previous.configured == cfg.bridge then return previous, nil end
	return M.client(deps, cfg), nil
end

return M
