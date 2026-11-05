-- Native block view. Pure: takes the snapshot, status and UI builders; no bridge access.
local model = require("./model")

local M = {}

local function ago(seconds: number): string
	if seconds < 5 then return "just now" end
	if seconds < 60 then return seconds .. "s ago" end
	return math.floor(seconds / 60) .. "m ago"
end

local function stateCell(on: number, total: number, offline: number)
	if total == 0 then return { text = "no lights", dot = "muted" } end
	if offline == total then return { text = "offline", dot = "error" } end
	local text = on .. "/" .. (total - offline) .. " on"
	if offline > 0 then text ..= " · " .. offline .. " offline" end
	return { text = text, dot = if on > 0 then "success" else "muted" }
end

local function briCell(bri: number?)
	local pct = model.percent(bri)
	if not pct then return "—" end
	return { meter = { value = pct / 100, tone = "accent" } }
end

local function groupTable(ui, groups, selected, head: string)
	local cols = {
		{ id = "name", head = head, grow = 1 },
		{ id = "state", head = "State", priority = 2 },
		{ id = "bri", head = "Brightness", grow = 1, priority = 1 },
		{ id = "pct", head = "", align = "end", priority = 1, mono = true },
		{ id = "toggle", head = "" },
		{ id = "down", head = "", priority = 3 },
		{ id = "up", head = "", priority = 3 },
	}
	local rows = {}
	for _, g in groups do
		local dark = g.total == 0 or g.offline == g.total
		local reason = if dark then "No reachable lights" else nil
		local pct = model.percent(g.bri)
		table.insert(rows, {
			id = g.id,
			title = g.kind,
			cells = {
				g.name,
				stateCell(g.on, g.total, g.offline),
				briCell(g.bri),
				if pct then pct .. "%" else "",
				{ button = { text = if g.on > 0 then "Off" else "On", act = "toggle=" .. g.id,
					variant = if g.on > 0 then "default" else "primary", disabled = reason } },
				{ button = { text = "−", act = "dim=" .. g.id, disabled = reason or (g.on == 0 and "Off") or nil } },
				{ button = { text = "+", act = "brighten=" .. g.id, disabled = reason } },
			},
		})
	end
	return ui.table(cols, rows, { selectable = true, selected = selected, empty = "No rooms or zones on this bridge" })
end

local function detail(ui, snapshot, group)
	local parts = {}
	local scenes = snapshot.scenes[group.id] or {}
	if #scenes > 0 then
		local buttons = {}
		for _, sc in scenes do
			table.insert(buttons, ui.button(sc.name, { size = "sm", actions = { click = "scene=" .. group.id .. ":" .. sc.id } }))
		end
		table.insert(parts, ui.section("Scenes", { ui.el("div", { role = "hue.scenes" }, buttons) }))
	end
	local rows = {}
	for _, lid in group.lights do
		local light = model.light(snapshot, lid)
		if light then
			table.insert(rows, {
				id = light.id,
				cells = {
					light.name,
					if not light.reachable then { text = "offline", dot = "error" }
						else { text = if light.on then "on" else "off", dot = if light.on then "success" else "muted" },
					if light.on then briCell(light.bri) else "",
					{ button = { text = if light.on then "Off" else "On", act = "light=" .. light.id,
						disabled = if light.reachable then nil else "Unreachable: check its power switch" } },
				},
			})
		end
	end
	table.insert(parts, ui.table({
		{ id = "name", head = "Light", grow = 1 },
		{ id = "state", head = "State" },
		{ id = "bri", head = "Brightness", grow = 1, priority = 1 },
		{ id = "toggle", head = "" },
	}, rows, { empty = "No lights in this group" }))
	return ui.card({ ui.span(group.name, "strong") }, parts, { meta = group.kind, role = "hue.detail" })
end

-- status: { refreshing, error, configError, updated (os.time seconds) }
function M.render(snapshot: any, status: any, selected: string?, now: number, ui: any)
	if status.configError then
		return {
			main = ui.col({
				ui.card({ ui.span("Hue bridge not configured", "strong") }, {
					ui.text(status.configError),
					ui.md("Pair once with the [openhue CLI](https://www.openhue.io/cli): run `openhue setup`, press the bridge's link button when asked, then press **r** here. Set `TERN_HUE_CONFIG` to use another file with `bridge:` and `key:` lines."),
				}, { tone = "warning" }),
			}),
		}
	end

	local children = {}
	local summary = model.summary(snapshot)
	local toolbar = ui.row({
		ui.button("All on", { variant = "primary", actions = { click = "all=on" }, disabled = if snapshot then nil else true }),
		ui.button("All off", { actions = { click = "all=off" }, disabled = if snapshot then nil else true }),
		ui.button("", { icon = "refresh", title = "Refresh (r)", actions = { click = "refresh" }, busy = status.refreshing }),
	})
	table.insert(children, ui.row({ ui.text({ ui.span(summary.text, "strong") }), toolbar }))

	if status.error then
		table.insert(children, ui.card({ ui.span(if snapshot then "Showing last known state" else "Bridge unavailable", "strong") },
			{ ui.text(status.error) }, { tone = "warning" }))
	end

	if snapshot then
		local rooms, zones = {}, {}
		for _, g in snapshot.groups do
			table.insert(if g.kind == "Room" then rooms else zones, g)
		end
		table.insert(children, groupTable(ui, rooms, selected, "Room"))
		if #zones > 0 then
			table.insert(children, ui.section("Zones", { groupTable(ui, zones, selected, "Zone") }))
		end
		local group = model.find(snapshot, selected)
		if group then table.insert(children, detail(ui, snapshot, group)) end
	elseif not status.error then
		table.insert(children, ui.progress(nil, "Reading the bridge"))
	end

	local foot = if status.updated then "Updated " .. ago(math.max(0, now - status.updated)) else "Not updated yet"
	return {
		main = ui.col(children),
		dock = ui.col({ ui.text({ ui.span(foot .. " · select a room for scenes and lights · r refresh", "muted") }) }),
	}
end

return M
