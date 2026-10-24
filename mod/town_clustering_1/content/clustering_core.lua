--- Town Clustering - the clustering itself, with no game API in it.
---
--- This module holds every decision the mod makes about *where towns go*: which
--- towns become cluster centres, how big each cluster is, which towns keep their
--- generated position, and where a relocated town is put down. It touches no
--- `api.*`, so the same code runs inside the game and inside tools/preview,
--- against a snapshot of a map that was generated once.
---
--- That is the whole point of the split. Tuning the clustering in game costs a
--- map generation plus a few minutes of ticks per attempt; against a snapshot it
--- costs milliseconds, and because it is this file running either way, what the
--- preview shows is what the mod will do.
---
--- Plain Lua rather than Teal, deliberately: the offline side then needs only a
--- stock interpreter, no `tl` compiler. `clustering_core.d.tl` carries the types
--- so the game still type-checks the caller.
---
--- The three things it cannot know on its own - whether a point is on the map,
--- under water, or how high it is - arrive as a `terrain` adapter. In game that
--- wraps `api.engine.terrain`; offline it reads a heightmap out of the snapshot.

local core = {}

--- Slider index (1-based) to value. Kept here rather than in the game script so
--- that the preview reads the same tables the mod does, and a slider that gains
--- a value cannot mean two different things in the two places.
core.CLUSTER_COUNTS = { 2, 3, 4, 5, 6, 8 }
core.KEEP_FRACTIONS = { 0.30, 0.45, 0.60, 0.75, 1.00 }
core.ISOLATED_SHARES = { 0.0, 0.05, 0.10, 0.20 }

--- Cluster sizes follow a geometric series; these are the bounds the ratio is
--- drawn from, per slider position. A ratio of 1.0 makes every cluster the same
--- size; the lower the ratio, the more one conurbation dominates. The range is
--- a range rather than one number so that the same settings give a different
--- shape on a different map.
core.VARIATION_RATIO_MIN = { 1.00, 0.78, 0.55, 0.38 }
core.VARIATION_RATIO_MAX = { 1.00, 0.92, 0.80, 0.55 }

--- Isolated towns are scaled to this share of their generated size, so they read
--- as hamlets left behind by the clustering rather than as peers of the towns in
--- the conurbations.
core.ISOLATED_SIZE_SCALE = 0.45

--- Placement rules for a relocated town, all in metres.
---
--- MIN_TOWN_SPACING is deliberately far below the generator's own roughly one
--- town per 5 km2 - about 1400 m between neighbours - because packing towns
--- tighter than the engine ever would is the entire point. It still has to be
--- wide enough that two town centres do not try to grow through each other, and
--- 600 m is the tightest that has been tried in game.
---
--- Note that a cluster centre is itself a town, so it occupies the middle before
--- any mover is placed: the innermost ring that can actually be used is the
--- first one wider than this spacing, not FIRST_RING.
core.MIN_TOWN_SPACING = 600.0
core.FIRST_RING = 420.0
core.RING_STEP = 240.0
core.MAX_RINGS = 14
core.ANGLES_PER_RING = 12

--- Town Spacing slider values. Index 1 is MIN_TOWN_SPACING itself, so leaving the
--- slider alone reproduces the layout this mod has always produced.
---
--- The looser settings exist because the floor turns out to be where clusters
--- actually sit. Measured over a generated map, every cluster settled within
--- about 40 m of 600 - the lattice findSpot's comment warns about - while the
--- engine's own towns were a 2.6 km median apart. Opening the floor up trades
--- some density for a cluster that reads as a group of towns rather than one
--- mass; even 1300 m is roughly twice as dense as the generator.
core.TOWN_SPACINGS = { 600.0, 800.0, 1000.0, 1300.0 }

--- Ring geometry for a given spacing, scaled from the constants above so that
--- 600 m reproduces FIRST_RING and RING_STEP exactly.
---
--- The rings scale with the floor rather than staying fixed: widening only the
--- floor would leave the inner rings too tight to use and put a hole in the
--- middle of every cluster, instead of opening the cluster out.
function core.geometry(spacing)
	spacing = spacing or core.MIN_TOWN_SPACING
	local scale = spacing / core.MIN_TOWN_SPACING
	return {
		spacing = spacing,
		firstRing = core.FIRST_RING * scale,
		ringStep = core.RING_STEP * scale,
	}
end

--- How far a town may wander off its ring, as a share of that ring's radius.
--- Because it scales with the radius, the middle of a cluster stays tight while
--- the outskirts scatter - which is the shape real town groups have, and the
--- shape a fixed spacing cannot produce.
core.JITTER_SHARE = 0.18

--- No cluster drops below this share of the largest one's weight. Without a
--- floor, eight clusters at the low end of the ratio range leaves the last few
--- holding a single town each, which reads as a stray rather than as a group.
core.SIZE_MIN_WEIGHT = 0.18

--- A candidate is rejected if the ground rises or falls more than MAX_SLOPE_DROP
--- across a probe of SLOPE_PROBE metres either side of it, or if any probe lands
--- in water. Towns need buildable ground, and the generator's own placer applies
--- a similar test.
---
--- Both radii matter. 24 m alone missed a river or a bank just beyond it and left
--- the centre looking fine while the town had nowhere to build; 48 m alone steps
--- straight over a ditch or a ridge at 24 m. Eight directions rather than four
--- because at 48 m a feature lying diagonally between the axes slips through a
--- four-point test entirely.
---
--- Note that MAX_SLOPE_DROP applies across every sample, so widening the reach
--- also tightens the gradient a candidate may sit on - 14 m across 48 m is 29%,
--- where 14 m across 24 m was 58%. That is the intended direction, but it is the
--- knob to turn if clusters come out sparse or the log reports stranded towns.
core.SLOPE_PROBE = 48.0
core.SLOPE_PROBE_INNER = 24.0
core.PROBE_DIRECTIONS = 8
core.MAX_SLOPE_DROP = 14.0

--- Small deterministic RNG. We avoid math.random so that the result depends only
--- on the generated map, not on whatever else has consumed randomness - and so
--- that the preview and the game agree.
local function nextRandom(rng)
	rng.seed = (rng.seed * 1103515245 + 12345) % 2147483648
	return rng.seed / 2147483648
end
core.nextRandom = nextRandom

--- Split `amount` between buckets in proportion to `weights`, by largest
--- remainder, so the parts add up to exactly `amount` rather than to whatever
--- rounding each one individually happens to give.
local function share(amount, weights)
	local parts = {}
	local remainder = {}
	local total = 0.0
	for __, weight in ipairs(weights) do total = total + weight end

	local handedOut = 0
	for i, weight in ipairs(weights) do
		local exact = 0.0
		if total > 0 then exact = amount * weight / total end
		parts[i] = math.floor(exact)
		remainder[i] = exact - parts[i]
		handedOut = handedOut + parts[i]
	end

	while handedOut < amount do
		local best, bestRemainder = 0, -1.0
		for i = 1, #weights do
			if remainder[i] > bestRemainder then
				bestRemainder = remainder[i]
				best = i
			end
		end
		if best == 0 then break end
		parts[best] = parts[best] + 1
		remainder[best] = -1.0
		handedOut = handedOut + 1
	end
	return parts
end
core.share = share

local function pick(list, index, fallback)
	if index ~= nil and index >= 1 and index <= #list then
		return list[index]
	end
	return fallback
end

--- Slider indices to the values the planner actually uses. `indices` is what
--- `api.engine.config.getModParams()` hands back for this mod, or the same shape
--- built by hand in the preview; a missing or out-of-range entry falls back to
--- the mod.json default.
function core.resolveParams(indices)
	indices = indices or {}
	return {
		clusterCount = math.floor(pick(core.CLUSTER_COUNTS, indices["cluster.count"], 4)),
		keepFraction = pick(core.KEEP_FRACTIONS, indices["cluster.keep"], 0.45),
		isolatedShare = pick(core.ISOLATED_SHARES, indices["cluster.isolated"], 0.10),
		ratioLow = pick(core.VARIATION_RATIO_MIN, indices["cluster.variation"], 0.55),
		ratioHigh = pick(core.VARIATION_RATIO_MAX, indices["cluster.variation"], 0.80),
		spacing = pick(core.TOWN_SPACINGS, indices["cluster.spacing"], core.MIN_TOWN_SPACING),
	}
end

local function distance2(ax, ay, bx, by)
	local dx, dy = ax - bx, ay - by
	return dx * dx + dy * dy
end
core.distance2 = distance2

--- Farthest-point sampling: start somewhere, then repeatedly take the town
--- furthest from everything chosen so far. Gives centres spread across the map
--- rather than bunched in one corner, without needing a map-size constant.
local function chooseCentres(towns, count, rng)
	local centres = { towns[1 + math.floor(nextRandom(rng) * #towns)] }
	while #centres < count and #centres < #towns do
		local best = nil
		local bestDist = -1.0
		for __, town in ipairs(towns) do
			local nearest = math.huge
			for __, centre in ipairs(centres) do
				local d = distance2(town.x, town.y, centre.x, centre.y)
				if d < nearest then nearest = d end
			end
			if nearest > bestDist then
				bestDist = nearest
				best = town
			end
		end
		if best == nil then break end
		centres[#centres + 1] = best
	end
	return centres
end
core.chooseCentres = chooseCentres

--- Is this somewhere a town could plausibly stand? The engine will happily
--- create a town in a lake or up a cliff if we ask it to, so we ask carefully.
---
--- `terrain` supplies the three queries this needs. In game they are
--- `api.engine.terrain.isValidCoordinate` / `isOnWater` / `getHeightAt`; offline
--- they come off a heightmap, where "water" is any sample at or below the map's
--- own `waterLevel`.
local function isBuildable(terrain, x, y)
	if not terrain.isValid(x, y) then
		return false
	end
	if terrain.isWater(x, y) then
		return false
	end

	local centre = terrain.heightAt(x, y)
	local lo, hi = centre, centre

	local radii = { core.SLOPE_PROBE_INNER, core.SLOPE_PROBE }
	for __, radius in ipairs(radii) do
		for direction = 0, core.PROBE_DIRECTIONS - 1 do
			local angle = direction * math.pi * 2 / core.PROBE_DIRECTIONS
			local px = x + math.cos(angle) * radius
			local py = y + math.sin(angle) * radius

			if not terrain.isValid(px, py) then
				return false
			end
			if terrain.isWater(px, py) then
				return false
			end

			local h = terrain.heightAt(px, py)
			if h < lo then lo = h end
			if h > hi then hi = h end
		end
	end

	return (hi - lo) <= core.MAX_SLOPE_DROP
end
core.isBuildable = isBuildable

--- Find somewhere near `centre` for one relocated town: work outwards ring by
--- ring, and take one of the spots on the first ring that has any. Returns false
--- if the neighbourhood is full, in which case the caller leaves the town where
--- the generator put it rather than losing it.
local function findSpot(terrain, geom, cx, cy, placed, rng)
	local step = math.pi * 2 / core.ANGLES_PER_RING
	local minGap2 = geom.spacing * geom.spacing

	for ring = 1, core.MAX_RINGS do
		local radius = geom.firstRing + (ring - 1) * geom.ringStep
		local phase = nextRandom(rng) * math.pi * 2
		local wobble = radius * core.JITTER_SHARE

		-- Gather every spot on this ring that would work, then take one of them
		-- at random.
		--
		-- Taking the first that fits - which is what this used to do - walks the
		-- slots in order and stops, so every town lands at the smallest radius
		-- that will have it and the cluster packs into an even lattice sitting
		-- 3% above MIN_TOWN_SPACING. Measured, the median gap between neighbours
		-- was 822 m against a floor of 800. That reads as machined.
		--
		-- The candidates are wobbled off the ring before they are tested, not
		-- after, so the spacing floor still holds exactly.
		local spotsX = {}
		local spotsY = {}
		for slot = 0, core.ANGLES_PER_RING - 1 do
			local angle = phase + slot * step + (nextRandom(rng) - 0.5) * step * 0.8
			local reach = radius + (nextRandom(rng) - 0.5) * 2 * wobble
			local x = cx + math.cos(angle) * reach
			local y = cy + math.sin(angle) * reach

			local clear = true
			for __, p in ipairs(placed) do
				if distance2(x, y, p[1], p[2]) < minGap2 then
					clear = false
					break
				end
			end
			if clear and isBuildable(terrain, x, y) then
				spotsX[#spotsX + 1] = x
				spotsY[#spotsY + 1] = y
			end
		end

		if #spotsX > 0 then
			local choice = 1 + math.floor(nextRandom(rng) * #spotsX)
			return true, spotsX[choice], spotsY[choice]
		end
	end
	return false, 0, 0
end
core.findSpot = findSpot

--- Seed from the map itself, so the same map always clusters the same way and
--- the preview reproduces what the game will do.
local function seedFrom(towns)
	local seed = #towns * 7919
	for __, town in ipairs(towns) do
		seed = (seed + math.floor(town.x) * 31 + math.floor(town.y) * 17) % 2147483648
	end
	return math.abs(seed) + 1
end
core.seedFrom = seedFrom

--- Decide the whole new layout.
---
--- `request.towns` is the generated towns, each carrying at least `x` and `y`;
--- whatever else is on them is handed back untouched on `source`, so the caller
--- can get at names and size factors when it applies the plan.
--- `request.params` is a table from `resolveParams`, and `request.terrain` is the
--- adapter described above.
---
--- Returns nil plus a reason when there is nothing worth doing, so the caller can
--- log it and leave the map alone. Otherwise returns a plan: every town with its
--- fate and its final position, the centres, and the counts worth logging.
---
--- Nothing here mutates the world; applying the plan is the caller's job. That is
--- what lets the preview run it.
function core.plan(request)
	local towns = {}
	for i, source in ipairs(request.towns) do
		towns[#towns + 1] = {
			index = i, source = source,
			x = source.x, y = source.y,
			origX = source.x, origY = source.y,
			dist = 0, centre = 1, kind = "move",
		}
	end
	local total = #towns
	if total < 2 then
		return nil, "no towns to work with"
	end

	local params = request.params
	local terrain = request.terrain
	local geom = core.geometry(params.spacing)

	local stayCount = math.max(1, math.floor(total * params.keepFraction + 0.5))
	if stayCount >= total then
		return nil, "every town stays put; nothing to do"
	end

	local rng = { seed = seedFrom(towns) }

	local centres = chooseCentres(towns, params.clusterCount, rng)
	for __, town in ipairs(towns) do
		local nearest = math.huge
		local nearestIndex = 1
		for i, centre in ipairs(centres) do
			local d = distance2(town.x, town.y, centre.x, centre.y)
			if d < nearest then
				nearest = d
				nearestIndex = i
			end
		end
		town.dist = nearest
		town.centre = nearestIndex
	end

	-- Nearest to a centre keep the position the generator gave them; they are
	-- already where we want towns to be.
	table.sort(towns, function(a, b)
		return a.dist < b.dist
	end)

	local movers = total - stayCount
	local isolatedCount = math.floor(movers * params.isolatedShare + 0.5)

	-- How big should each cluster be?
	--
	-- Sharing the towns out evenly makes the clusters come out the same size,
	-- which reads as generated. Each centre instead gets a weight from a
	-- geometric series - one conurbation dominates, a couple are middling, one is
	-- a modest group - and every later share follows those weights.
	--
	-- The ratio varies per map, and which centre draws which weight is shuffled,
	-- so the big one is not always whichever centre the sampling happened to pick
	-- first.
	local ratio = params.ratioLow + nextRandom(rng) * (params.ratioHigh - params.ratioLow)
	local weights = {}
	local w = 1.0
	for i = 1, #centres do
		if w < core.SIZE_MIN_WEIGHT then
			weights[i] = core.SIZE_MIN_WEIGHT
		else
			weights[i] = w
		end
		w = w * ratio
	end
	for i = #centres, 2, -1 do
		local j = 1 + math.floor(nextRandom(rng) * i)
		weights[i], weights[j] = weights[j], weights[i]
	end

	-- Towns that keep their position have to follow the weights too. Capping only
	-- the movers leaves the clusters barely more than a fifth apart, because the
	-- towns that stay are spread evenly by geography and dilute everything the
	-- weights do.
	local stayQuota = share(stayCount, weights)

	local stays = {}
	for i = 1, #centres do stays[i] = 0 end
	local staysTotal = 0
	for __, town in ipairs(towns) do
		-- towns are in ascending distance order, so a cluster fills its places
		-- with the towns already closest to it
		local k = town.centre
		if stays[k] < stayQuota[k] then
			town.kind = "stay"
			stays[k] = stays[k] + 1
			staysTotal = staysTotal + 1
		else
			town.kind = "move"
		end
	end

	-- Spare a few of the movers as isolated towns: they stay out in the country
	-- where they were generated and are scaled down, so they read as outlying
	-- hamlets rather than as peers of the towns in the conurbations. Taken from
	-- the far end and spaced out, so they sit well away from the clusters.
	local isolated = {}
	for i = 1, isolatedCount do
		local index = total - (i - 1) * 2
		if towns[index] ~= nil and towns[index].kind == "move" then
			towns[index].kind = "isolated"
			isolated[#isolated + 1] = towns[index]
		end
	end

	-- Everything that is not moving occupies its spot already.
	local placed = {}
	for __, town in ipairs(towns) do
		if town.kind ~= "move" then
			placed[#placed + 1] = { town.x, town.y }
		end
	end

	local moverCount = 0
	for __, town in ipairs(towns) do
		if town.kind == "move" then
			moverCount = moverCount + 1
		end
	end

	local quota = share(moverCount, weights)

	-- A cluster with nothing in it is just a gap. Borrow from the largest.
	for i = 1, #centres do
		if stays[i] + quota[i] == 0 then
			local big = 1
			for k = 2, #centres do
				if quota[k] > quota[big] then big = k end
			end
			if quota[big] > 1 then
				quota[big] = quota[big] - 1
				quota[i] = 1
			end
		end
	end

	local placedIn = {}
	for i = 1, #centres do placedIn[i] = 0 end

	local moved, stranded = 0, 0
	for __, town in ipairs(towns) do
		if town.kind == "move" then
			-- Try the centre with the most of its quota outstanding first, and
			-- fall through to the others if its neighbourhood turns out to be
			-- full - better a slightly off-quota cluster than a stranded town.
			local order = {}
			for i = 1, #centres do order[i] = i end
			table.sort(order, function(a, b)
				return (quota[a] - placedIn[a]) > (quota[b] - placedIn[b])
			end)

			local settled = false
			for __, k in ipairs(order) do
				if quota[k] - placedIn[k] > 0 then
					local ok, x, y = findSpot(terrain, geom, centres[k].x, centres[k].y, placed, rng)
					if ok then
						town.x = x
						town.y = y
						town.centre = k
						placedIn[k] = placedIn[k] + 1
						moved = moved + 1
						placed[#placed + 1] = { x, y }
						settled = true
						break
					end
				end
			end
			if not settled then
				-- Nowhere to put it: leave the town alone rather than destroy it.
				-- A quieter result than losing a town.
				town.kind = "stay"
				stranded = stranded + 1
				placed[#placed + 1] = { town.x, town.y }
			end
		end
	end

	if moved == 0 then
		return nil, "found nowhere to move any town to; leaving the map alone"
	end

	local sizes = {}
	for i = 1, #centres do
		sizes[i] = stays[i] + placedIn[i]
	end

	return {
		towns = towns,
		centres = centres,
		isolated = isolated,
		weights = weights,
		ratio = ratio,
		spacing = geom.spacing,
		seed = rng.seed,
		sizes = sizes,
		total = total,
		moved = moved,
		stayed = staysTotal,
		stranded = stranded,
	}
end

--- Work out whether the engine's connection indices are 0- or 1-based, from the
--- data rather than by assuming. A zero anywhere proves 0-based; a value equal to
--- the town count proves 1-based, because neither is legal in the other scheme.
--- Returns -1 when the sample proves nothing, in which case the caller must leave
--- the proposal alone: guessing risks linking the wrong towns or crashing.
function core.connectionBase(connections, count)
	local lowest, highest = math.huge, -math.huge
	for __, conn in ipairs(connections) do
		for k = 1, 2 do
			local v = conn[k]
			if v < lowest then lowest = v end
			if v > highest then highest = v end
		end
	end

	local base = -1
	if #connections == 0 then
		base = -1
	elseif lowest <= 0 then
		base = 0
	elseif highest >= count then
		base = 1
	end
	return base,
		lowest == math.huge and 0 or lowest,
		highest == -math.huge and 0 or highest
end

--- Join up a set of proposed town connections until every town is reachable.
---
--- `getDefaultTownConnections` is a *proposal*, not a finished network, and on a
--- clustered map it reliably leaves each cluster an island. This walks the
--- proposal with union-find and adds the shortest link available between any two
--- components until there is one, which for clustered towns is the pair of towns
--- facing each other across the gap.
---
--- Indices in `connections` are the engine's, with `base` saying what its first
--- index is; links added here come back in the same base. Pure graph work, so the
--- preview can draw the same network the game will try to build.
function core.stitchConnections(connections, base, xs, ys, count)
	local parent = {}
	for i = 1, count do parent[i] = i end

	local function find(i)
		while parent[i] ~= i do
			parent[i] = parent[parent[i]]
			i = parent[i]
		end
		return i
	end

	local components = count
	local function union(a, b)
		local ra, rb = find(a), find(b)
		if ra == rb then return false end
		parent[ra] = rb
		components = components - 1
		return true
	end

	-- Engine index -> our 1-based index. Anything out of range is skipped rather
	-- than silently folded into the wrong town, which is what the old 1-based
	-- guard did to every connection that touched index 0.
	local skipped = 0
	local canAppend = base ~= nil and base >= 0
	if canAppend then
		for __, conn in ipairs(connections) do
			local a = conn[1] - base + 1
			local b = conn[2] - base + 1
			if a >= 1 and a <= count and b >= 1 and b <= count then
				union(a, b)
			else
				skipped = skipped + 1
			end
		end
	end

	local added = 0
	while canAppend and components > 1 do
		local bestA, bestB, bestD = 0, 0, math.huge
		for i = 1, count do
			for j = i + 1, count do
				if find(i) ~= find(j) then
					local d = distance2(xs[i], ys[i], xs[j], ys[j])
					if d < bestD then
						bestD = d
						bestA = i
						bestB = j
					end
				end
			end
		end
		if bestA == 0 then break end
		union(bestA, bestB)
		-- Back into the engine's own index base, and never outside the range it
		-- gave us: a bad index here is an access violation, not an error.
		local ea = bestA - 1 + base
		local eb = bestB - 1 + base
		if ea >= base and ea <= count - 1 + base and eb >= base and eb <= count - 1 + base then
			connections[#connections + 1] = { ea, eb }
			added = added + 1
		end
	end

	return connections, skipped, added
end

return core
