-- Pure normalization of bridge state and the requests for each control. No I/O.
local M = {}

local BRI_MAX = 254
-- Brightness step of the dim/brighten controls: about 10% of the range.
M.BRI_STEP = 25

export type Light = {
	id: string, name: string, on: boolean, reachable: boolean, bri: number?,
}
export type Group = {
	id: string, name: string, kind: string, lights: { string },
	on: number, total: number, offline: number, bri: number?,
}
export type Scene = { id: string, name: string }
export type Snapshot = {
	lights: { Light }, groups: { Group }, scenes: { [string]: { Scene } },
	on: number, total: number, offline: number,
}

local function byName(a, b)
	local x, y = string.lower(a.name), string.lower(b.name)
	if x == y then return a.id < b.id end
	return x < y
end

local KIND_ORDER = { Room = 1, Zone = 2 }

function M.normalize(groups: any, lights: any, scenes: any): Snapshot
	local list, byId = {}, {}
	for id, l in (if type(lights) == "table" then lights else {}) do
		if type(l) == "table" then
			local s = if type(l.state) == "table" then l.state else {}
			local light = {
				id = tostring(id),
				name = tostring(l.name or ("Light " .. tostring(id))),
				-- An unreachable light keeps reporting its last state; it is not lit in any useful sense.
				reachable = s.reachable ~= false,
				on = s.on == true and s.reachable ~= false,
				bri = if type(s.bri) == "number" then s.bri else nil,
			}
			table.insert(list, light)
			byId[light.id] = light
		end
	end
	table.sort(list, byName)

	local out = {}
	for id, g in (if type(groups) == "table" then groups else {}) do
		if type(g) == "table" and KIND_ORDER[g.type] then
			local members, on, offline, briSum = {}, 0, 0, 0
			for _, lid in (if type(g.lights) == "table" then g.lights else {}) do
				local light = byId[tostring(lid)]
				if light then
					table.insert(members, light.id)
					if not light.reachable then offline += 1
					elseif light.on then
						on += 1
						briSum += light.bri or BRI_MAX
					end
				end
			end
			table.insert(out, {
				id = tostring(id), name = tostring(g.name or ("Group " .. tostring(id))), kind = g.type,
				lights = members, on = on, total = #members, offline = offline,
				bri = if on > 0 then briSum / on else nil,
			})
		end
	end
	table.sort(out, function(a, b)
		if a.kind ~= b.kind then return KIND_ORDER[a.kind] < KIND_ORDER[b.kind] end
		return byName(a, b)
	end)

	local byGroup = {}
	for id, sc in (if type(scenes) == "table" then scenes else {}) do
		-- `recycle` scenes are temporary ones apps create; only saved group scenes are useful buttons.
		if type(sc) == "table" and sc.type == "GroupScene" and sc.group and sc.recycle ~= true then
			local gid = tostring(sc.group)
			byGroup[gid] = byGroup[gid] or {}
			table.insert(byGroup[gid], { id = tostring(id), name = tostring(sc.name or id) })
		end
	end
	for _, items in byGroup do table.sort(items, byName) end

	local on, offline = 0, 0
	for _, light in list do
		if not light.reachable then offline += 1 elseif light.on then on += 1 end
	end
	return { lights = list, groups = out, scenes = byGroup, on = on, total = #list, offline = offline }
end

function M.find(snapshot: Snapshot?, id: string?): Group?
	if not snapshot or not id then return nil end
	for _, g in snapshot.groups do
		if g.id == id then return g end
	end
	return nil
end

function M.light(snapshot: Snapshot?, id: string?): Light?
	if not snapshot or not id then return nil end
	for _, l in snapshot.lights do
		if l.id == id then return l end
	end
	return nil
end

-- Status line text: lit lights over reachable ones, then any unreachable count.
function M.summary(snapshot: Snapshot?): { text: string, tone: string }
	if not snapshot then return { text = "Hue · loading", tone = "muted" } end
	local reachable = snapshot.total - snapshot.offline
	local text = "Hue " .. snapshot.on .. "/" .. reachable .. " on"
	if snapshot.offline > 0 then text ..= " · " .. snapshot.offline .. " offline" end
	return { text = text, tone = if snapshot.on > 0 then "default" else "muted" }
end

-- A request for the bridge: v1 path under /api/<key> and its JSON body.
export type Request = { path: string, body: { [string]: any } }

-- Group 0 is the bridge's implicit group of every light.
function M.setAll(on: boolean): Request
	return { path = "/groups/0/action", body = { on = on } }
end

-- Toggling a partly lit group turns it off, matching the Hue app's room switch.
function M.toggleGroup(group: Group): Request
	return { path = "/groups/" .. group.id .. "/action", body = { on = group.on == 0 } }
end

function M.stepGroup(group: Group, direction: number): Request
	if group.on == 0 and direction > 0 then
		-- bri_inc on a dark group changes nothing visible; start it at the lowest step instead.
		return { path = "/groups/" .. group.id .. "/action", body = { on = true, bri = M.BRI_STEP } }
	end
	return {
		path = "/groups/" .. group.id .. "/action",
		body = { bri_inc = direction * M.BRI_STEP, transitiontime = 2 },
	}
end

function M.scene(groupId: string, sceneId: string): Request
	return { path = "/groups/" .. groupId .. "/action", body = { scene = sceneId } }
end

-- Toggle-all from a fresh `/lights` read: any reachable lit light turns everything off. Deciding
-- from the bridge at command time, not a cached status, keeps a stale cache from sending the
-- same direction twice.
function M.toggleAll(lights: any): Request
	return M.setAll(M.normalize(nil, lights, nil).on == 0)
end

function M.toggleLight(light: Light): Request
	return { path = "/lights/" .. light.id .. "/state", body = { on = not light.on } }
end

function M.percent(bri: number?): number?
	if not bri then return nil end
	return math.clamp(math.floor(bri / BRI_MAX * 100 + 0.5), 1, 100)
end

return M
