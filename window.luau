-- Window half: palette commands and the status segment. Polling belongs to the host; commands
-- talk to the bridge directly so they work without an open panel.
local bridge = require("./bridge")
local model = require("./model")

local BLOCK = "hue.panel"
local current = { text = "Hue · loading", tone = "muted" }
local currentKey = ""

local function open(cx)
	-- Reuse a live panel in this session's tabs rather than opening a second one. A panel the
	-- host no longer renders (a failed plugin load stops it) is closed and replaced instead.
	local tabs, rendered = {}, {}
	for _, session in cx.session:sessions() do
		if session.current then
			for _, tab in session.tabs do tabs[tab] = true end
		end
	end
	local ok, ids = pcall(tern.kv.get, "panels")
	if ok and type(ids) == "table" then
		for _, id in ids do rendered[id] = true end
	end
	for _, pane in cx.session:panes() do
		if pane.block == BLOCK and tabs[pane.tab] then
			if rendered[pane.pane] and not pane.error then
				cx.layout:focus(pane.pane)
				return
			end
			cx.layout:close(pane.pane)
		end
	end
	if not cx:new_block(BLOCK, {}, "beside") then
		cx:toast("error", "Could not open Hue Lights", "Install the plugin on the current Tern host.")
	end
end

local client: any = nil
local clientDeps = {
	fetch = tern.fetch, encode = tern.json.encode, decode = tern.json.decode, now = tern.now,
	loadHost = function() return tern.kv.get("bridge_host") end,
	saveHost = function(record) tern.kv.set("bridge_host", record) end,
}

local function ensureClient(cx): any
	local err
	client, err = bridge.current(client, tern.fs, tern.getenv, clientDeps)
	if not client then cx:toast("info", "Hue bridge not configured", err) end
	return client
end

local function put(c, req: model.Request, label: string)
	c:put(req.path, req.body, function(_, failure, fresh)
		if failure then
			if fresh then fresh:toast("error", label .. " failed", failure) end
			return
		end
		-- Ask the host to read the new state back for the status line and open panels.
		pcall(tern.kv.set, "poke", tostring(os.time()) .. "-" .. tostring(math.random(1, 1e9)))
	end)
end

local function setAll(cx, on: boolean)
	local c = ensureClient(cx)
	if c then put(c, model.setAll(on), if on then "All lights on" else "All lights off") end
end

tern.command({ id = "open", title = "Open Hue lights", icon = "gauge", run = open })
tern.command({ id = "all-on", title = "Hue: all lights on", icon = "gauge",
	run = function(cx) setAll(cx, true) end })
tern.command({ id = "all-off", title = "Hue: all lights off", icon = "gauge",
	run = function(cx) setAll(cx, false) end })
tern.command({ id = "toggle", title = "Hue: toggle all lights", icon = "gauge",
	run = function(cx)
		local c = ensureClient(cx)
		if not c then return end
		c:get("/lights", function(lights, failure, fresh)
			if failure then
				if fresh then fresh:toast("error", "Toggle all lights failed", failure) end
				return
			end
			local req = model.toggleAll(lights)
			put(c, req, if req.body.on then "All lights on" else "All lights off")
		end)
	end })

tern.chrome.status(function()
	return { { text = current.text, tone = current.tone, icon = "gauge", command = "plugin.hue.open" } }
end)

local function pollOnce()
	local ok, record = pcall(tern.kv.get, "status")
	local nextValue
	if not ok then
		nextValue = { text = "Hue · cache error", tone = "warning" }
	elseif type(record) ~= "table" or type(record.heartbeat) ~= "number"
		or os.time() * 1000 - record.heartbeat > 90_000 then
		nextValue = { text = "Hue · host offline", tone = "warning" }
	else
		nextValue = { text = tostring(record.text), tone = record.tone }
	end
	local key = nextValue.text .. "\0" .. (nextValue.tone or "")
	if key ~= currentKey then
		current, currentKey = nextValue, key
		tern.chrome.refresh()
	end
end

local function poll()
	tern.timer(2_000, poll)
	pcall(pollOnce)
end
tern.timer(100, poll)
