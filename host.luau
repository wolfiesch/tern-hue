-- Host half: one bridge poller per host VM, the Hue Lights block, and the status record windows read.
local bridge = require("./bridge")
local model = require("./model")
local view = require("./view")

-- Poll often while a panel shows; slowly otherwise, for the status line.
local OPEN_INTERVAL = 5_000
local IDLE_INTERVAL = 30_000
local SCENE_INTERVAL = 5 * 60_000

local blocks: { [number]: any } = {}
local status = { refreshing = false, error = nil :: string?, configError = nil :: string?, updated = nil :: number? }
local snapshot: model.Snapshot? = nil
local raw = { groups = nil :: any, lights = nil :: any, scenes = nil :: any }
local client: any = nil
local lastPoll, lastScenes = -math.huge, -math.huge
local pending = false
local lastPoke: any = tern.kv.get("poke")
local published = ""

-- Panes this host VM renders, for windows: a panel left over from a failed plugin load is still
-- in the layout but in no VM's list, so `open` replaces it instead of focusing a dead pane.
local function publishPanels()
	local ids = {}
	for pane in blocks do table.insert(ids, pane) end
	pcall(tern.kv.set, "panels", ids)
end

local function liveBlocks(): boolean
	local live = {}
	for _, pane in tern.pane.list() do live[pane.pane] = true end
	local any, pruned = false, false
	for pane in blocks do
		if live[pane] then any = true else blocks[pane], pruned = nil, true end
	end
	if pruned then publishPanels() end
	return any
end

local function renderLive()
	liveBlocks()
	for _, cx in blocks do pcall(cx.render, cx) end
end

local function publish()
	local summary = if status.configError then { text = "Hue · not configured", tone = "warning" }
		elseif status.error and not snapshot then { text = "Hue · unreachable", tone = "warning" }
		else model.summary(snapshot)
	if status.error and snapshot then summary.text ..= " · stale"; summary.tone = "warning" end
	local reason = status.configError or status.error
	local key = summary.text .. "\0" .. summary.tone .. "\0" .. (reason or "")
	local now = os.time() * 1000
	local record = tern.kv.get("status")
	-- The heartbeat lets windows tell a stopped host from an unchanged bridge.
	if key ~= published or type(record) ~= "table" or now - (record.heartbeat or 0) > 20_000 then
		published = key
		tern.kv.set("status", {
			text = summary.text, tone = summary.tone, heartbeat = now, error = reason,
		})
	end
end

local clientDeps = {
	fetch = tern.fetch, encode = tern.json.encode, decode = tern.json.decode, now = tern.now,
	loadHost = function() return tern.kv.get("bridge_host") end,
	saveHost = function(record) tern.kv.set("bridge_host", record) end,
}

local function ensureClient(): any
	local err
	client, err = bridge.current(client, tern.fs, tern.getenv, clientDeps)
	status.configError = err
	return client
end

local refresh: (boolean?) -> ()

local function finish(err: string?)
	status.refreshing = false
	if err then
		-- Logged on change only: a bridge that stays down would otherwise log every poll.
		if err ~= status.error then tern.log.warn("hue: bridge read failed: " .. err) end
		status.error = err
	else
		snapshot = model.normalize(raw.groups, raw.lights, raw.scenes)
		status.error, status.updated = nil, os.time()
	end
	publish()
	renderLive()
	if pending then
		pending = false
		refresh(false)
	end
end

-- Single flight: a request during a refresh queues exactly one more.
refresh = function(withScenes: boolean?)
	if status.refreshing then
		pending = true
		return
	end
	local c = ensureClient()
	lastPoll = tern.now()
	if not c then
		snapshot = nil
		publish()
		renderLive()
		return
	end
	status.refreshing = true
	local scenes = withScenes or raw.scenes == nil or tern.now() - lastScenes >= SCENE_INTERVAL
	local ok, spawnErr = pcall(function()
		c:get("/groups", function(groups, err)
			if err then return finish(err) end
			raw.groups = groups
			c:get("/lights", function(lights, err2)
				if err2 then return finish(err2) end
				raw.lights = lights
				if not scenes then return finish(nil) end
				c:get("/scenes", function(list, err3)
					-- Scenes are optional: keep the last list rather than failing the whole read.
					if not err3 then raw.scenes, lastScenes = list, tern.now() end
					finish(nil)
				end)
			end)
		end)
	end)
	if not ok then finish("Could not reach the bridge: " .. tostring(spawnErr)) end
end

local function send(req: model.Request, cx: any, label: string)
	local c = ensureClient()
	if not c then
		cx:toast("info", "Hue bridge not configured", status.configError)
		return
	end
	c:put(req.path, req.body, function(_, err)
		if err then
			cx:toast("error", label .. " failed", err)
		end
		-- The bridge applies transitions over a few hundred ms; read back after them.
		tern.timer(400, function() refresh(false) end)
	end)
end

local function act(state: any, name: string, value: string?, cx: any)
	if name == "refresh" then return refresh(true) end
	if name == "all" then return send(model.setAll(value == "on"), cx, "All lights " .. tostring(value)) end
	if name == "light" then
		local light = model.light(snapshot, value)
		if light then send(model.toggleLight(light), cx, light.name) end
		return
	end
	if name == "scene" and value then
		local gid, sid = value:match("^([^:]+):(.+)$")
		if gid and sid then send(model.scene(gid, sid), cx, "Scene") end
		return
	end
	local group = model.find(snapshot, value)
	if not group then return end
	if name == "toggle" then send(model.toggleGroup(group), cx, group.name)
	elseif name == "dim" then send(model.stepGroup(group, -1), cx, group.name)
	elseif name == "brighten" then send(model.stepGroup(group, 1), cx, group.name) end
end

tern.block.define("panel", {
	init = function(cx, _args, saved)
		blocks[cx.pane] = cx
		publishPanels()
		-- A panel opening is the moment fresh state matters most.
		if tern.now() - lastPoll > 1_000 then tern.timer(0, function() refresh(false) end) end
		return { selected = if type(saved) == "table" then saved.selected else nil }
	end,
	title = function() return "Hue Lights" end,
	font = "sans",
	view = function(state, _cx)
		return view.render(snapshot, status, state.selected, os.time(), tern.ui)
	end,
	key = function(_state, key, _cx)
		if key.name == "r" and not key.ctrl and not key.alt and not key.meta then
			refresh(true)
			return true
		end
		return false
	end,
	event = function(state, ev, cx)
		if (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			-- Double-clicking the selected room closes its detail card.
			state.selected = if state.selected == ev.item and ev.ev == "activate" then nil else ev.item
		elseif ev.ev == "action" and type(ev.act) == "string" then
			act(state, ev.act, ev.value, cx)
		end
	end,
	save = function(state) return { selected = state.selected } end,
})

local function tick()
	-- Re-arm first so one failed read cannot stop polling.
	tern.timer(1_000, tick)
	pcall(function()
		-- Window commands change lights directly and poke the host to read them back.
		local poke = tern.kv.get("poke")
		if poke ~= nil and poke ~= lastPoke then
			lastPoke = poke
			tern.timer(400, function() refresh(false) end)
			return
		end
		local interval = if liveBlocks() then OPEN_INTERVAL else IDLE_INTERVAL
		if tern.now() - lastPoll >= interval then refresh(false) end
	end)
end
-- A fresh VM renders nothing yet; restored panels re-register in `init`.
publishPanels()
-- Defer I/O until restored blocks have loaded.
tern.timer(100, tick)
