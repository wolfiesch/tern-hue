local model = require("../model")
local bridge = require("../bridge")

local function eq(a, b, msg)
	if a ~= b then error((msg or "mismatch") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- Unreachable lights report their last `on`; they must count as offline, not lit.
local snap = model.normalize({
	["1"] = { type = "Room", name = "Kitchen", lights = { "1", "2", "3" } },
	["2"] = { type = "Zone", name = "Desk", lights = { "2" } },
	["3"] = { type = "Entertainment", name = "Music", lights = { "1" } },
	["4"] = { type = "Room", name = "attic", lights = {} },
}, {
	["1"] = { name = "Lamp", state = { on = true, reachable = false, bri = 254 } },
	["2"] = { name = "Strip", state = { on = true, reachable = true, bri = 127 } },
	["3"] = { name = "Bulb", state = { on = false, reachable = true, bri = 10 } },
}, {
	a = { type = "GroupScene", group = "1", name = "Relax" },
	b = { type = "GroupScene", group = "1", name = "Bright" },
	c = { type = "GroupScene", group = "1", name = "temp", recycle = true },
	d = { type = "LightScene", name = "orphan" },
})
eq(snap.on, 1, "lit lights")
eq(snap.offline, 1, "offline lights")
eq(snap.total, 3, "all lights")
eq(#snap.groups, 3, "entertainment areas are left out")
-- Rooms before zones; names case-insensitively.
eq(snap.groups[1].name, "attic")
eq(snap.groups[2].name, "Kitchen")
eq(snap.groups[3].kind, "Zone")
local kitchen = model.find(snap, "1") :: any
eq(kitchen.on, 1); eq(kitchen.offline, 1); eq(kitchen.total, 3)
eq(kitchen.bri, 127, "brightness averages lit, reachable lights only")
eq(#snap.scenes["1"], 2, "recycled and light scenes are hidden")
eq(snap.scenes["1"][1].name, "Bright")
eq(model.summary(snap).text, "Hue 1/2 on · 1 offline")
eq(model.summary(nil).text, "Hue · loading")

-- A partly lit room turns off; a dark one turns on.
eq(model.toggleGroup(kitchen).body.on, false)
eq(model.toggleGroup(model.find(snap, "4") :: any).body.on, true)
-- Brightening a dark room must light it: bri_inc alone does nothing while off.
local up = model.stepGroup(model.find(snap, "4") :: any, 1)
eq(up.body.on, true); eq(up.body.bri_inc, nil)
eq(model.stepGroup(kitchen, -1).body.bri_inc, -model.BRI_STEP)
eq(model.setAll(false).path, "/groups/0/action")
eq(model.percent(254), 100); eq(model.percent(1), 1); eq(model.percent(nil), nil)

-- Config: the openhue file, quoting and comments.
local cfg = bridge.parseConfig('# openhue\nbridge: "192.168.1.2"\nkey: abcDEF-123 # paired\n') :: any
eq(cfg.bridge, "192.168.1.2"); eq(cfg.key, "abcDEF-123")
local none, why = bridge.parseConfig("bridge: 10.0.0.2\n")
eq(none, nil); assert(why and why:find("key"), "names the missing key")

-- v1 errors surface; unauthorized gets the re-pair hint.
assert((bridge.firstError({ { error = { type = 1, description = "unauthorized user" } } }) :: string):find("openhue setup"))
eq(bridge.firstError({ { success = { ["/lights/1/state/on"] = true } } }), nil)

-- Client: network errors never echo the key, and DHCP moves are rediscovered once.
local calls, saved = {}, nil
local function fakeFetch(url, _opts, cb)
	table.insert(calls, url)
	if url:find("discovery") then
		return cb({ status = 200, body = "moved", headers = {}, timed_out = false })
	end
	if url:find("^http://10%.0%.0%.9/") then
		return cb({ status = 200, body = "ok", headers = {}, timed_out = false })
	end
	cb({ status = 0, body = "", headers = {}, timed_out = false, error = "connect failed for " .. url })
end
local client = bridge.client({
	fetch = fakeFetch, encode = function() return "{}" end, now = function() return 0 end,
	decode = function(text)
		if text == "moved" then return { { internalipaddress = "10.0.0.9" } } end
		return { ok = true }
	end,
	saveHost = function(r) saved = r end,
}, { bridge = "10.0.0.2", key = "SECRETKEY" })
local got
client:get("/lights", function(data, err) got = { data = data, err = err } end)
eq(got.err, nil, "retried at the rediscovered address")
eq(saved.ip, "10.0.0.9"); eq(saved.from, "10.0.0.2")
eq(#calls, 3)

local down = bridge.client({
	fetch = function(url, _o, cb) cb({ status = 0, body = "", headers = {}, timed_out = false, error = "refused " .. url }) end,
	encode = function() return "{}" end, decode = function() return {} end, now = function() return 0 end,
}, { bridge = "10.0.0.2", key = "SECRETKEY" })
down:get("/lights", function(_, err) got = err end)
assert(not got:find("SECRETKEY"), "the application key is redacted")
assert(got:find("<key>"), "redaction marks where the key was")

-- Toggle-all reads the bridge: an unreachable light's stale `on` must not keep the house dark.
eq(model.toggleAll({
	["1"] = { name = "A", state = { on = true, reachable = false } },
	["2"] = { name = "B", state = { on = false, reachable = true } },
}).body.on, true, "only unreachable lights report on: turn everything on")
eq(model.toggleAll({
	["1"] = { name = "A", state = { on = false, reachable = true } },
	["2"] = { name = "B", state = { on = true, reachable = true } },
}).body.on, false, "one reachable light lit: turn everything off")

-- The cached client survives while the config is unchanged, keeping its discovery throttle.
local files: { [string]: string? } = { ["/h/.openhue/config.yaml"] = "bridge: 10.0.0.2\nkey: K1\n" }
local fs = {
	exists = function(p) return files[p] ~= nil end,
	read = function(p) return files[p] end,
}
local env = function(name) return if name == "HOME" then "/h" else nil end
local deps = { fetch = fakeFetch, encode = tostring, decode = tostring, now = function() return 0 end }
local first = bridge.current(nil, fs, env, deps)
assert(first, "a valid config yields a client")
eq(bridge.current(first, fs, env, deps), first, "same config reuses the client")
files["/h/.openhue/config.yaml"] = "bridge: 10.0.0.2\nkey: K2\n"
assert(bridge.current(first, fs, env, deps) ~= first, "a new key replaces the client")
files["/h/.openhue/config.yaml"] = nil
local gone, reason = bridge.current(first, fs, env, deps)
eq(gone, nil); assert(reason and reason:find("No Hue config"), "a removed config is reported")

print("hue model tests passed")
