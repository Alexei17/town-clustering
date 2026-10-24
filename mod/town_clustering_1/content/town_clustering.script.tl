--- Town Clustering - redistribute generated towns into clusters.
---
--- The engine places towns uniformly during map generation and there is no way
--- to influence that from the new game dialog (see NOTES.md - no mod code runs
--- in the menu, and a terrain generator can only shape terrain). So instead we
--- let generation finish untouched and rearrange towns afterwards, on the first
--- tick of a new game.
---
--- Towns are *relocated*, not deleted: the town count the player chose with the
--- Town Density setting is preserved exactly. Each town either keeps the
--- position the generator gave it, or is destroyed and re-created next to a
--- cluster centre. Terrain, rivers and industries are never touched.
---
--- This file is the game half: it reads the world, hands the towns to
--- `clustering_core.lua` to decide the new layout, and applies whatever comes
--- back. Every decision about *where towns go* lives in the core, which has no
--- `api.*` in it and so also runs offline against a snapshot - see tools/preview.
--- Keeping the geometry on the other side of that seam is what makes the mod
--- tunable without a map generation per attempt.
---
--- The rebuild uses the same calls the Map Editor uses for its own town import
--- (gui/map_editor/map_editor.tl, makeTowns):
---
---   api.engine.terrain.makeMapFromGame  ->  the current towns, with names,
---                                           size factors and cargo needs
---   api.engine.mapgen.createTowns       ->  { toRemove, toAdd }
---   makeTownDestroyCmd / makeTownCreateCmd
---
--- A town that is listed with its `existing` entity is left alone; one listed
--- without it is created fresh, and any town in the world that the list no
--- longer mentions is returned in `toRemove`.
---
--- The mod only needs to be active when the game starts; afterwards it does
--- nothing and can safely be removed from the savegame.

-- ug_require takes the file name *with* its extension - `::/scripts/mathutil.lua`
-- and `::/scripts/entity_util.tl` are how the base game does it. Only script hook
-- names in mod.json and .gs.lua drop it (`<modid>::/foo.script@fn`). Getting that
-- wrong fails at load with "module ... not found" and no game script runs.
local entity_util = ug_require "::/scripts/entity_util.tl" as EntityUtil
local core = ug_require "town_clustering_1::/clustering_core.lua" as ClusteringCore
local snap = ug_require "town_clustering_1::/snapshot.lua" as TownClusteringSnapshot

local LOG <const> = "[town-clustering] "
local MOD_ID <const> = "town_clustering_1"

--- Only rearrange a genuinely fresh game. Adding this mod to an established
--- save and silently rebuilding half its towns would be catastrophic, so bail
--- out if any meaningful time has passed.
local MAX_START_GAME_TIME <const> = 60 * 60 * 24 * 10

--- Creating towns is asynchronous. Stop waiting for the world to settle after
--- this many ticks and connect whatever is actually there.
local MAX_SETTLE_TICKS <const> = 240

--- A town is created empty and grows its first houses over the ticks that
--- follow, so a population of zero means nothing straight away. Wait until the
--- number of empty towns has stopped falling for this many consecutive checks
--- before concluding that whatever is left is a dud - usually a centre with no
--- room to build, hemmed in by a river or a slope.
local POPULATION_STABLE_TICKS <const> = 90
local MAX_POPULATION_TICKS <const> = 1200

local record State
	--- 0/nil = not started
	--- 1 = towns rebuilt, waiting for the world to show them all
	--- 2 = roads laid, waiting to see which towns stay empty
	--- 3 = empty towns destroyed, one tick before relaying the roads
	--- 4 = finished
	--- 10 = writing a map snapshot to the log, before anything is moved
	--- Each road pass has to wait a tick: the destroy and create commands must
	--- land before the engine is asked to lay out a network.
	phase : integer
	--- how many towns we expect once the rebuild lands
	expected : integer
	--- ticks spent waiting in the current phase
	waited : integer
	--- how many towns had no inhabitants at the last check
	zeroes : integer
	--- consecutive checks in which that count did not fall
	stable : integer
	done : boolean

	--- Snapshot progress. The terrain grid is a few hundred thousand queries, so
	--- it goes out a few rows per tick rather than freezing the game for one long
	--- one; these carry the grid across those ticks.
	snapRow : integer
	snapMinX : number
	snapMinY : number
	snapCols : integer
	snapRows : integer
	snapTowns : integer
	--- 2 = snapshot only, stop afterwards; 3 = snapshot, then cluster as usual
	snapMode : integer
end

--- The core asks three things about a point; these are the engine's answers.
--- Offline the same three come off a heightmap, which is the only difference
--- between a preview run and a real one.
local terrain : ClusteringCore.Terrain = {
	isValid = function(x : number, y : number) : boolean
		return api.engine.terrain.isValidCoordinate(api.type.Vec2f.new(x, y))
	end,
	isWater = function(x : number, y : number) : boolean
		return api.engine.terrain.isOnWater(api.type.Vec2f.new(x, y))
	end,
	heightAt = function(x : number, y : number) : number
		return api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y))
	end,
}

--- The mod's own slider positions, as 1-based indices into each param's `values`
--- list in mod.json. The core turns them into the numbers it works in, so the
--- two sides cannot disagree about what index 3 means.
local function readParams() : ClusteringCore.Params
	local all = api.engine.config.getModParams()
	local own = all ~= nil and all[MOD_ID] as {string : integer} or nil
	if own == nil then
		log.message(LOG .. "no mod params found; using defaults")
	end
	return core.resolveParams(own)
end

--- The Map Snapshot slider: 1 = Off, 2 = Snapshot Only, 3 = Snapshot then cluster.
local function readSnapshotMode() : integer
	local all = api.engine.config.getModParams()
	local own = all ~= nil and all[MOD_ID] as {string : integer} or nil
	if own == nil then
		return 1
	end
	local mode = own["cluster.snapshot"]
	if mode == nil or mode < 1 or mode > 3 then
		return 1
	end
	return mode
end

--- Open a snapshot: work out the map's extent, then log the header and every
--- town. Returns cols, rows, minX, minY, townCount - cols is 0 if there was
--- nothing to snapshot yet.
---
--- Why the log rather than a file: see snapshot.lua. Briefly, `app.saveUserdata`
--- is GUI-state only and out of reach here, and nothing in the game's own
--- scripts uses `io`, so the log is the one channel known to work.
local function beginSnapshot() : integer, integer, number, number, integer
	local map = api.engine.terrain.makeMapFromGame(false, true, false, false)
	if map == nil or map.towns == nil or #map.towns < 1 then
		log.message(LOG .. "snapshot: no towns to record")
		return 0, 0, 0, 0, 0
	end

	local first = map.towns[1]
	local minX, minY, maxX, maxY = snap.bounds(terrain.isValid, first.pos.x, first.pos.y)
	local cols, rows = snap.grid(minX, minY, maxX, maxY, snap.STEP)

	log.message(LOG .. snap.beginLine(minX, minY, snap.STEP, cols, rows, map.waterLevel))
	for __, town in ipairs(map.towns) do
		local size = 1.0
		if town.sizeFactors ~= nil and town.sizeFactors[1] ~= nil then
			size = town.sizeFactors[1]
		end
		log.message(LOG .. snap.townLine(town.pos.x, town.pos.y, size, town.name or ""))
	end

	-- How far each town's buildings actually reach. The game's own border is drawn
	-- natively with no radius exposed to Lua, so measure the buildings instead -
	-- a town that is about to be moved keeps its identity and its size factors, so
	-- the extent measured here is what it will spread to wherever it lands.
	local town2buildings = api.engine.system.townBuildingSystem.getTown2BuildingMap()
	if town2buildings == nil then
		log.message(LOG .. "snapshot: no town building map; borders not measured")
	else
		local measured = 0
		for i, town in ipairs(map.towns) do
			local distances : {number} = {}
			if town.existing ~= nil then
				local buildings = town2buildings[town.existing]
				if buildings ~= nil then
					for __, building in ipairs(buildings) do
						local pos = entity_util.getPosition(building)
						if pos ~= nil then
							local dx = pos.x - town.pos.x
							local dy = pos.y - town.pos.y
							distances[#distances + 1] = math.sqrt(dx * dx + dy * dy)
						end
					end
				end
			end
			local p50, p90, furthest = snap.percentiles(distances)
			if #distances > 0 then
				measured = measured + 1
			end
			log.message(LOG .. snap.areaLine(i, #distances, p50, p90, furthest))
		end
		log.message(LOG .. string.format(
			"snapshot: measured the extent of %d of %d towns", measured, #map.towns))
	end

	return cols, rows, minX, minY, #map.towns
end

--- Log the next batch of terrain rows. Returns the row to carry on from.
local function emitSnapshotRows(
		minX : number, minY : number,
		cols : integer, rows : integer, from : integer) : integer
	local last = math.min(from + snap.ROWS_PER_TICK - 1, rows - 1)
	for iy = from, last do
		local heights, water = snap.rowLines(terrain, minX, minY, snap.STEP, cols, iy)
		log.message(LOG .. heights)
		log.message(LOG .. water)
	end
	return last + 1
end

local function countTowns() : integer
	local n = 0
	api.engine.forEachEntityWithComponent(function(_entity : Engine.Entity)
		n = n + 1
	end, api.type.ComponentType.TOWN)
	return n
end

--- A town's population, as the game itself counts it: the residential person
--- capacity of its buildings (game_mechanics/towns/town_util.tl, which reads
--- `getTownCapacityUsages(entity).residential.capacity` for the number shown in
--- the town window).
local function townPopulation(entity : Engine.Entity) : integer
	local capacities = api.engine.system.townBuildingSystem.getLandUsePersonCapacities(entity)
	if capacities == nil then
		return 0
	end
	local residential = capacities[api.type["enum"].LandUseType.RESIDENTIAL as integer + 1]
	if residential == nil then
		return 0
	end
	return residential
end

--- Towns with nobody living in them. A town the engine could not build on - the
--- centre is on land, but the ground around it is river or cliff - is created
--- happily and then just sits there empty.
local function emptyTowns() : {Engine.Entity}
	local empty : {Engine.Entity} = {}
	api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
		if townPopulation(entity) <= 0 then
			empty[#empty + 1] = entity
		end
	end, api.type.ComponentType.TOWN)
	return empty
end

--- Rebuild the town layout. Returns the number of towns the world should end up
--- with, or 0 if there was nothing worth doing.
local function redistribute() : integer
	local map = api.engine.terrain.makeMapFromGame(false, true, false, false)
	if map == nil or map.towns == nil or #map.towns < 2 then
		log.message(LOG .. "no towns to work with")
		return 0
	end

	-- The core is handed bare coordinates and gives each town back by its index
	-- here, so names, size factors and the existing entity never have to cross
	-- the seam.
	local sources = map.towns
	local towns : {ClusteringCore.InputTown} = {}
	for __, source in ipairs(sources) do
		towns[#towns + 1] = { x = source.pos.x, y = source.pos.y }
	end

	local plan, reason = core.plan({
		towns = towns,
		params = readParams(),
		terrain = terrain,
	})
	if plan == nil then
		log.message(LOG .. (reason or "nothing to do"))
		return 0
	end

	-- The desired layout. A town listed with its `existing` entity is left
	-- untouched; one listed without is built fresh at the new position.
	local desired : {GameMap.Town} = {}
	for __, planned in ipairs(plan.towns) do
		local source = sources[planned.index]
		local entry = api.type.Map.Town.new()
		entry.pos = api.type.Vec2f.new(planned.x, planned.y)
		entry.name = source.name or ""
		entry.sizeFactors = source.sizeFactors
		entry.landUse2CargoNeeds = source.landUse2CargoNeeds
		if planned.kind ~= "move" then
			entry.existing = source.existing
		end
		desired[#desired + 1] = entry
	end

	local result = api.engine.mapgen.createTowns(tostring(plan.seed), desired)
	for __, entity in ipairs(result.toRemove) do
		api.cmd.sendCommand(api.cmd.makeTownDestroyCmd(entity))
	end
	if #result.toAdd > 0 then
		api.cmd.sendCommand(api.cmd.makeTownCreateCmd(result.toAdd))
	end

	-- Isolated towns keep their entity, so they can simply be scaled down.
	for __, planned in ipairs(plan.isolated) do
		local source = sources[planned.index]
		if source.existing ~= nil and source.sizeFactors ~= nil then
			local scaled : {number} = {}
			for i, factor in ipairs(source.sizeFactors) do
				scaled[i] = factor * core.ISOLATED_SIZE_SCALE
			end
			api.cmd.sendCommand(
				api.cmd.makeTownUpdateSizeCmd(source.existing, scaled, true))
		end
	end

	local sizes = ""
	for i, size in ipairs(plan.sizes) do
		if i > 1 then sizes = sizes .. "/" end
		sizes = sizes .. tostring(size)
	end

	log.message(LOG .. string.format(
		"%d towns -> %d clusters sized %s (ratio %.2f): %d moved, %d left in place, "
		.. "%d isolated, %d stranded (%d destroyed, %d created)",
		plan.total, #plan.centres, sizes, plan.ratio, plan.moved, plan.stayed,
		#plan.isolated, plan.stranded, #result.toRemove, #result.toAdd))
	return plan.total
end

--- Rebuild the inter-town road network.
---
--- getDefaultTownConnections is a *proposal*, not a finished network - the Map
--- Editor merges it into whatever connections already exist rather than
--- treating it as complete (map_editor.tl, "Propose Default Connections"). On a
--- clustered map it reliably leaves each cluster an island, so the core stitches
--- the components together before we hand the lot to the engine.
---
--- Some links will still fail to build: the engine reports "Too Much Incline"
--- or "Collision" and leaves that pair unconnected. That happens to the stock
--- generator's own connections too, on hilly maps, so a connected proposal is
--- the most we can guarantee from here.
local function connectAll()
	local entities : {Engine.Entity} = {}
	local xs : {number} = {}
	local ys : {number} = {}
	local mapTowns : {GameMap.Town} = {}

	api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
		local pos = entity_util.getPosition(entity)
		if pos ~= nil then
			local i = #entities + 1
			entities[i] = entity
			xs[i] = pos.x
			ys[i] = pos.y
			local mapTown = api.type.Map.Town.new()
			mapTown.pos = api.type.Vec2f.new(pos.x, pos.y)
			mapTown.name = entity_util.getEntityName(entity) or ""
			mapTown.existing = entity
			mapTowns[i] = mapTown
		end
	end, api.type.ComponentType.TOWN)

	local count = #entities
	if count < 2 then
		return
	end

	local proposed = api.engine.mapgen.getDefaultTownConnections(mapTowns)

	-- Which end is index zero?
	--
	-- The engine documents these as "indices into the vector townEntities". That
	-- vector is C++, so they are 0-based, while every list on this side of the
	-- boundary is 1-based. Appending a 1-based index to the list crashed the
	-- simulation thread twice on an out-of-range read - the second time reading
	-- 0xFFFFFFFFFFFFFFFF, which is what running off the end of that vector looks
	-- like. The crash landed at the very end of the layout, exactly where our own
	-- appended links sit.
	--
	-- Rather than trust either reading, the core works the base out from the
	-- data: a zero anywhere proves 0-based, and a value equal to the town count
	-- proves 1-based, because neither is legal in the other scheme. A base of -1
	-- means the sample proved nothing, and the proposal is sent unaltered.
	local base, lowest, highest = core.connectionBase(proposed, count)
	local connections, skipped, added = core.stitchConnections(
		proposed, base, xs, ys, count)

	-- keep = true: add the links that are missing, leaving the existing street
	-- network alone.
	--
	-- keep = false means "remove the streets first", and that crashed the game:
	-- an access violation on the Simulation Thread (TransportFever3.exe+0xA4BD7,
	-- reading a freed pointer) a few seconds after this command was sent. By the
	-- time we get here the world has been simulating for minutes - towns have
	-- buildings, industries exist, people are moving - and tearing the whole
	-- street network out from under that leaves the engine holding stale
	-- references. The Map Editor can afford keep = false because nothing is
	-- running there; a game script cannot.
	--
	-- The cost is cosmetic: a destroyed town takes its own streets with it (see
	-- makeTownDestroyCmd), but an inter-town road that used to lead to it can be
	-- left as a stub.
	api.cmd.sendCommand(
		api.cmd.makeTownConnectWithIndustriesCmd(entities, connections, true))
	log.message(LOG .. string.format(
		"connected %d towns with %d links: engine proposed %d indexed %d..%d "
		.. "(read as %d-based), %d skipped, %d added to join separate clusters",
		count, #connections, #connections - added, lowest, highest,
		base, skipped, added))
end

--- Hand over to the rebuild. Reached either straight away, or after a snapshot
--- has been written, so it lives in one place.
local function startClustering(state : GameScriptState<State>)
	local expected = redistribute()
	if expected > 0 then
		state:set({ phase = 1, expected = expected, waited = 0,
			zeroes = 0, stable = 0, done = false })
	else
		state:set({ phase = 4, expected = 0, waited = 0, zeroes = 0, stable = 0, done = true })
	end
end

local mod = {}

mod.update = function(_userParams : table, state : GameScriptState<State>, _dt : number)
	local current = state:get()
	if current ~= nil and current.done then
		return
	end

	if current ~= nil and current.phase == 10 then
		local nextRow = emitSnapshotRows(current.snapMinX, current.snapMinY,
			current.snapCols, current.snapRows, current.snapRow or 0)

		if nextRow < current.snapRows then
			state:set({ phase = 10, expected = 0, waited = 0, zeroes = 0, stable = 0,
				done = false, snapRow = nextRow,
				snapMinX = current.snapMinX, snapMinY = current.snapMinY,
				snapCols = current.snapCols, snapRows = current.snapRows,
				snapTowns = current.snapTowns, snapMode = current.snapMode })
			return
		end

		log.message(LOG .. snap.endLine(current.snapTowns or 0))
		log.message(LOG .. "snapshot complete; recover it with "
			.. "tools/snapshot.ps1, then explore it with tools/studio.ps1")

		if (current.snapMode or 2) == 2 then
			log.message(LOG .. "Snapshot Only: towns left exactly as generated")
			state:set({ phase = 4, expected = 0, waited = 0, zeroes = 0, stable = 0,
				done = true })
			return
		end

		startClustering(state)
		return
	end

	if current ~= nil and current.phase == 1 then
		-- Town creation is asynchronous. Wait for the world to show the town
		-- count we expect before laying out roads, but do not wait forever.
		local waited = (current.waited or 0) + 1
		if countTowns() < current.expected and waited < MAX_SETTLE_TICKS then
			state:set({ phase = 1, expected = current.expected, waited = waited,
				zeroes = 0, stable = 0, done = false })
			return
		end
		if countTowns() < current.expected then
			log.message(LOG .. string.format(
				"gave up waiting: %d of %d towns present", countTowns(), current.expected))
		end
		connectAll()
		state:set({ phase = 2, expected = current.expected, waited = 0,
			zeroes = countTowns(), stable = 0, done = false })
		return
	end

	if current ~= nil and current.phase == 2 then
		-- Every town starts empty and fills over the following ticks, so the
		-- only honest signal is that the number of empty ones has stopped
		-- falling. Whatever is still empty after that could not build at all.
		local waited = (current.waited or 0) + 1
		local empty = emptyTowns()
		local zeroes = #empty

		local stable = (current.stable or 0) + 1
		if zeroes < (current.zeroes or 0) then
			stable = 0
		end

		if zeroes > 0 and stable < POPULATION_STABLE_TICKS and waited < MAX_POPULATION_TICKS then
			state:set({ phase = 2, expected = current.expected, waited = waited,
				zeroes = zeroes, stable = stable, done = false })
			return
		end

		if zeroes > 0 then
			for __, entity in ipairs(empty) do
				api.cmd.sendCommand(api.cmd.makeTownDestroyCmd(entity))
			end
			log.message(LOG .. string.format(
				"removed %d town(s) with no inhabitants after %d ticks; %d left",
				zeroes, waited, countTowns() - zeroes))
			-- Their roads went with them, but the links that led to them can be
			-- left dangling, so lay the network out once more. Rare enough that
			-- the extra pass costs nothing in practice.
			state:set({ phase = 3, expected = current.expected, waited = 0,
				zeroes = 0, stable = 0, done = false })
		else
			log.message(LOG .. string.format(
				"every town is inhabited after %d ticks", waited))
			state:set({ phase = 3, expected = current.expected, waited = 0,
				zeroes = 0, stable = 0, done = true })
		end
		return
	end

	if current ~= nil and current.phase == 3 then
		-- One tick on, so the destroy commands have landed.
		connectAll()
		state:set({ phase = 4, expected = current.expected, waited = 0,
			zeroes = 0, stable = 0, done = true })
		return
	end

	local gameTimeComponent = api.engine.getComponent(
		api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME) as Engine.Component.GameTime
	if gameTimeComponent ~= nil and gameTimeComponent.gameTime > MAX_START_GAME_TIME then
		-- Not a fresh game: almost certainly the mod was added to an existing
		-- save. Do nothing, ever, rather than rearrange someone's towns.
		log.message(LOG .. "not a new game; clustering skipped")
		state:set({ phase = 4, expected = 0, waited = 0, zeroes = 0, stable = 0, done = true })
		return
	end

	-- Towns may not exist on the very first tick; wait for generation.
	if countTowns() < 2 then
		return
	end

	-- Record the map before anything is moved, if asked to. The point is to pay
	-- for generation once per seed: with the snapshot on disk, every setting can
	-- be tried offline in about a second instead of costing another generation
	-- and the minutes of ticks the rebuild needs before there is anything to see.
	local snapMode = readSnapshotMode()
	if snapMode > 1 then
		local cols, rows, minX, minY, townCount = beginSnapshot()
		if cols > 0 then
			log.message(LOG .. string.format(
				"snapshot: %d towns and a %dx%d terrain grid at %.0f m, over about "
				.. "%d ticks", townCount, cols, rows, snap.STEP,
				math.ceil(rows / snap.ROWS_PER_TICK)))
			state:set({ phase = 10, expected = 0, waited = 0, zeroes = 0, stable = 0,
				done = false, snapRow = 0, snapMinX = minX, snapMinY = minY,
				snapCols = cols, snapRows = rows, snapTowns = townCount,
				snapMode = snapMode })
			return
		end
		log.message(LOG .. "snapshot could not be started; carrying on")
	end

	startClustering(state)
end

return mod
