--- Town Clustering - writing a map snapshot out of a running game.
---
--- The point is to pay for map generation once per seed instead of once per
--- experiment. With a snapshot on disk, every slider combination for that seed
--- can be tried offline in about a second (tools/preview), instead of costing a
--- generation, a game start, and the minutes of ticks the rebuild needs before
--- there is anything to look at.
---
--- It goes out through `log.message`, not a file. The mod already logs to
--- `crash_dump/stdout.txt` and that is known to work; `io` and `os` appear
--- nowhere in the game's own scripts, so whether they survive the sandbox is
--- unknown, and `app.saveUserdata` is GUI-state only and out of reach from a
--- game script (see NOTES.md). The log is the one channel that is certain.
---
--- Format, one line each, after the mod's own `[town-clustering] ` prefix:
---
---   snap begin 1 x0=.. y0=.. step=.. cols=.. rows=.. water=..
---   snap town <x> <y> <sizeFactor> <name>
---   snap h <row> <height,height,...>
---   snap w <row> <0101...>          1 = that sample is on water
---   snap end towns=<n>
---
--- Rows run south to north, columns west to east, both from (x0, y0).
---
--- Plain Lua, no `api.*`: the terrain is reached through the same three-function
--- adapter the clustering core uses, so this is testable offline against a known
--- heightmap. `tools/preview/from_log.lua` reads the format back.

local snapshot = {}

snapshot.VERSION = 1

--- Sample spacing in metres. 32 m keeps a large map to a few hundred log lines
--- while still resolving the banks and channels the slope probe cares about;
--- the probe radii are 24 m and 48 m, so going much coarser would start to
--- smooth away the features that reject a candidate spot.
snapshot.STEP = 32.0

--- Rows emitted per tick. The whole grid is a few hundred thousand terrain
--- queries, which is seconds of work; doing it in one tick would freeze the
--- game, so it is spread out.
snapshot.ROWS_PER_TICK = 12

--- How far out the bounds search is willing to look, in metres.
local SEARCH_LIMIT = 1000000.0

--- Distance from (x, y) to the edge of the map along (dx, dy).
---
--- The map's extent is not reliably derivable from `numTilesX`/`resolution`
--- without knowing how the heightmap is indexed, which is still an open question
--- in NOTES.md. Asking `isValidCoordinate` instead needs no such assumption:
--- walk out doubling until a point is rejected, then bisect. About forty queries
--- per direction.
local function edge(isValid, x, y, dx, dy)
	local lo, hi = 0.0, 1024.0
	while isValid(x + dx * hi, y + dy * hi) do
		lo = hi
		hi = hi * 2
		if hi > SEARCH_LIMIT then
			return lo
		end
	end
	for __ = 1, 24 do
		local mid = (lo + hi) / 2
		if isValid(x + dx * mid, y + dy * mid) then
			lo = mid
		else
			hi = mid
		end
	end
	return lo
end

--- Map bounds, found by probing outwards from a point known to be on the map -
--- a town will do.
function snapshot.bounds(isValid, x, y)
	return x - edge(isValid, x, y, -1, 0),
		y - edge(isValid, x, y, 0, -1),
		x + edge(isValid, x, y, 1, 0),
		y + edge(isValid, x, y, 0, 1)
end

--- Grid dimensions for a set of bounds.
---
--- Rounded, not truncated: `bounds` bisects towards the edge from the inside, so
--- it lands a fraction of a metre short of it. Truncating turned a map exactly
--- 384 steps wide into 384 samples instead of 385 and lost the far edge.
function snapshot.grid(minX, minY, maxX, maxY, step)
	step = step or snapshot.STEP
	return math.floor((maxX - minX) / step + 0.5) + 1,
		math.floor((maxY - minY) / step + 0.5) + 1
end

function snapshot.beginLine(minX, minY, step, cols, rows, waterLevel)
	return string.format(
		"snap begin %d x0=%.2f y0=%.2f step=%.2f cols=%d rows=%d water=%.3f",
		snapshot.VERSION, minX, minY, step, cols, rows, waterLevel)
end

--- A town. The name goes last and unquoted, so it may contain spaces; the parser
--- takes everything after the third field as the name.
function snapshot.townLine(x, y, size, name)
	return string.format("snap town %.2f %.2f %.4f %s",
		x, y, size or 1.0, (name or ""):gsub("[\r\n]", " "))
end

--- How far a town's buildings actually reach from its centre.
---
--- The game draws a border around each town, but it does so natively - the only
--- Lua handle on it is a `showTownBorders` flag on a construction menu's hud
--- icons, with no radius behind it. So measure it instead: a town's buildings are
--- entities with positions, and how far they spread *is* the town's extent.
---
--- Three numbers rather than one, because a single outlying building would make
--- `max` useless on its own and the median alone would understate the edge. The
--- previewer draws p90 and keeps the others for sanity.
function snapshot.percentiles(distances)
	local n = #distances
	if n == 0 then
		return 0, 0, 0
	end
	table.sort(distances)
	local function at(q)
		local i = math.floor(q * (n - 1) + 0.5) + 1
		if i < 1 then i = 1 elseif i > n then i = n end
		return distances[i]
	end
	return at(0.50), at(0.90), distances[n]
end

--- One town's measured extent. `index` matches the order of the `town` lines.
function snapshot.areaLine(index, buildings, p50, p90, furthest)
	return string.format("snap area %d %d %.1f %.1f %.1f",
		index, buildings, p50, p90, furthest)
end

--- One row of terrain: heights, and a water mask beside them.
---
--- Water is emitted separately rather than inferred from height against
--- `waterLevel`, because `isOnWater` is the engine's own answer and the
--- clustering asks it directly. Inferring would be a guess about the thing the
--- preview exists to get right.
function snapshot.rowLines(terrain, minX, minY, step, cols, iy)
	local y = minY + iy * step
	local heights = {}
	local water = {}
	for ix = 0, cols - 1 do
		local x = minX + ix * step
		heights[ix + 1] = string.format("%.1f", terrain.heightAt(x, y))
		water[ix + 1] = terrain.isWater(x, y) and "1" or "0"
	end
	return "snap h " .. iy .. " " .. table.concat(heights, ","),
		"snap w " .. iy .. " " .. table.concat(water)
end

function snapshot.endLine(townCount)
	return string.format("snap end towns=%d", townCount)
end

return snapshot
