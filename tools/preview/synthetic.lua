--- A synthetic snapshot, so the previewer can be run before the game has
--- exported anything.
---
--- It is not a Transport Fever map and does not pretend to be. What it does
--- reproduce is the two properties that matter for looking at the clustering:
--- towns spread roughly uniformly at the sort of spacing the stock placer gives
--- (about 1.4 km between neighbours, one town per 5 km2), and terrain with water
--- and slope in it, so candidate spots really do get rejected.
---
--- Use it to see the previewer work and to sanity-check a change to the core.
--- Judge a setting against a real export - see README.md in this folder.

local synthetic = {}

--- The same LCG the core uses, kept local so this file stands alone.
local function lcg(seed)
	local state = seed
	return function()
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

-- 48 tiles of 256 m, so a largish map. Big enough that a run has the ~40 towns
-- the README's cluster-size table is quoted against, while leaving SPACING at
-- what the stock placer actually gives.
local SIZE = 12288.0
local STEP = 32.0     -- heightmap sample spacing
local WATER = 0.0     -- water level, as GameMap.waterLevel reports it
local SPACING = 1400.0 -- target gap between generated towns

--- Height at a point: a few broad swells, a meandering river and a lake. Smooth
--- enough that most ground passes the core's slope test, with banks and ridges
--- that do not.
local function height(x, y)
	local u, v = x / SIZE, y / SIZE

	local h = 34.0
		+ 26.0 * math.sin(u * math.pi * 1.7) * math.cos(v * math.pi * 1.3)
		+ 14.0 * math.sin((u + v) * math.pi * 3.1)
		+ 7.0 * math.cos(u * math.pi * 6.3) * math.sin(v * math.pi * 5.1)

	-- A river wandering down the map. Carved below the water level, with banks
	-- that rise steeply enough to matter to the slope probe.
	local channel = SIZE * (0.42 + 0.16 * math.sin(v * math.pi * 2.3))
	local fromRiver = math.abs(x - channel)
	if fromRiver < 420.0 then
		local t = fromRiver / 420.0
		local carve = (1.0 - t * t) * (h + 8.0)
		h = h - carve
	end

	-- A lake in the north-east.
	local lx, ly = SIZE * 0.78, SIZE * 0.80
	local fromLake = math.sqrt((x - lx) ^ 2 + (y - ly) ^ 2)
	if fromLake < 900.0 then
		local t = fromLake / 900.0
		h = h - (1.0 - t * t) * (h + 6.0)
	end

	return h
end

--- Towns on a jittered grid: that is what a uniform placer looks like, and it is
--- the pattern the mod exists to break up. Anything landing on water or on a
--- steep bank is dropped, as the generator's own placer would.
local function placeTowns(rand)
	local towns = {}
	local cells = math.floor(SIZE / SPACING)
	local inset = SPACING * 0.6

	for gy = 0, cells - 1 do
		for gx = 0, cells - 1 do
			local jitter = SPACING * 0.38
			local x = inset + (gx + 0.5) * SPACING + (rand() - 0.5) * 2 * jitter
			local y = inset + (gy + 0.5) * SPACING + (rand() - 0.5) * 2 * jitter

			if x > 300 and y > 300 and x < SIZE - 300 and y < SIZE - 300 then
				local h = height(x, y)
				-- dry, and not on a bank: a crude stand-in for the real placer's
				-- buildability test, enough that the stock layout is plausible
				local lo, hi = h, h
				for d = 0, 3 do
					local a = d * math.pi / 2
					local p = height(x + math.cos(a) * 90, y + math.sin(a) * 90)
					if p < lo then lo = p end
					if p > hi then hi = p end
				end
				if h > WATER + 6.0 and (hi - lo) < 26.0 then
					towns[#towns + 1] = {
						name = string.format("Town %02d", #towns + 1),
						position = { x = x, y = y },
						-- roughly the shape GameMap.Town.sizeFactors has
						sizeFactors = { 0.7 + rand() * 0.9, 1.0, 1.0 },
					}
				end
			end
		end
	end
	return towns
end

--- Build the snapshot. Same shape as a real one: the game's own
--- "Export Towns & Industries" fields, plus a `terrain` table.
function synthetic.make(seed)
	local rand = lcg(seed or 20260424)

	local cols = math.floor(SIZE / STEP) + 1
	local rows = cols
	local heights = {}
	for iy = 0, rows - 1 do
		for ix = 0, cols - 1 do
			heights[iy * cols + ix + 1] = height(ix * STEP, iy * STEP)
		end
	end

	return {
		towns = placeTowns(rand),
		industries = {},
		terrain = {
			originX = 0.0,
			originY = 0.0,
			cols = cols,
			rows = rows,
			step = STEP,
			sizeX = SIZE,
			sizeY = SIZE,
			waterLevel = WATER,
			heights = heights,
		},
	}
end

return synthetic
