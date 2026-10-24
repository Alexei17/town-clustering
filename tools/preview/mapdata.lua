--- Shared map handling for the preview tools.
---
--- Reading a snapshot, answering the core's three terrain questions from it, and
--- drawing the ground - everything `studio.lua` needs that is not the clustering
--- itself.
---
--- The clustering itself is not here: that is `clustering_core.lua`, in the mod,
--- shared with the game.

local M = {}

M.PANEL = 560 -- px, the side of a map panel

--------------------------------------------------------------------------------
-- Snapshot
--------------------------------------------------------------------------------

--- A snapshot is a Lua file returning a table. The game's own
--- "Export Towns & Industries" writes that shape, and so does
--- `tools/preview/from_log.lua`, so either can be read with no conversion.
function M.loadSnapshot(path, fallback)
	if path == nil then
		return fallback(), "synthetic"
	end
	local chunk, err = loadfile(path)
	if chunk == nil then
		return nil, nil, "could not read snapshot: " .. tostring(err)
	end
	local ok, data = pcall(chunk)
	if not ok or type(data) ~= "table" then
		return nil, nil, "snapshot did not return a table: " .. tostring(data)
	end
	return data, path
end

--- Accept both the game's export shape (`position = { x, y }`) and a plain
--- `{ x, y }`, so a hand-written snapshot is no harder than a real one.
function M.readTowns(data)
	local towns = {}
	for _, t in ipairs(data.towns or {}) do
		local x = t.x or (t.position and t.position.x)
		local y = t.y or (t.position and t.position.y)
		if x ~= nil and y ~= nil then
			towns[#towns + 1] = {
				x = x + 0.0,
				y = y + 0.0,
				name = t.name,
				size = (t.sizeFactors and t.sizeFactors[1]) or 1.0,
				-- measured built radius in metres, when the snapshot carries it
				extent = t.extent,
			}
		end
	end
	return towns
end

--------------------------------------------------------------------------------
-- Terrain
--------------------------------------------------------------------------------

--- The adapter the core asks its three questions through. In game these are
--- `api.engine.terrain.isValidCoordinate` / `isOnWater` / `getHeightAt`.
---
--- With a `terrain` table in the snapshot the answers are real. Without one,
--- every point on the map is dry and flat: cluster structure comes out right,
--- but nothing is rejected for water or slope.
function M.makeTerrain(data, towns)
	local t = data.terrain

	if t == nil or t.heights == nil then
		local minX, minY = math.huge, math.huge
		local maxX, maxY = -math.huge, -math.huge
		for _, town in ipairs(towns) do
			if town.x < minX then minX = town.x end
			if town.y < minY then minY = town.y end
			if town.x > maxX then maxX = town.x end
			if town.y > maxY then maxY = town.y end
		end
		local pad = 1000.0
		minX, minY, maxX, maxY = minX - pad, minY - pad, maxX + pad, maxY + pad
		return {
			kind = "flat",
			minX = minX, minY = minY, maxX = maxX, maxY = maxY,
			isValid = function(x, y)
				return x >= minX and x <= maxX and y >= minY and y <= maxY
			end,
			isWater = function() return false end,
			heightAt = function() return 0.0 end,
		}
	end

	local step = t.step or 32.0
	local cols = t.cols or math.floor((t.sizeX or 0) / step) + 1
	local rows = t.rows or math.floor(#t.heights / cols)
	local originX = t.originX or 0.0
	local originY = t.originY or 0.0
	local waterLevel = t.waterLevel or 0.0
	local heights = t.heights

	local maxX = originX + (cols - 1) * step
	local maxY = originY + (rows - 1) * step

	local function at(ix, iy)
		if ix < 0 then ix = 0 elseif ix > cols - 1 then ix = cols - 1 end
		if iy < 0 then iy = 0 elseif iy > rows - 1 then iy = rows - 1 end
		return heights[iy * cols + ix + 1] or 0.0
	end

	local function heightAt(x, y)
		local fx = (x - originX) / step
		local fy = (y - originY) / step
		local ix, iy = math.floor(fx), math.floor(fy)
		local tx, ty = fx - ix, fy - iy
		local h00, h10 = at(ix, iy), at(ix + 1, iy)
		local h01, h11 = at(ix, iy + 1), at(ix + 1, iy + 1)
		local a = h00 + (h10 - h00) * tx
		local b = h01 + (h11 - h01) * tx
		return a + (b - a) * ty
	end

	-- A snapshot dumped from a game carries the engine's own `isOnWater` answers
	-- as one 0/1 string per row. Prefer them: that is the question the clustering
	-- actually asks, and inferring water from height against `waterLevel` would
	-- be a guess about the very thing the preview exists to get right.
	local mask = t.water
	local isWater
	if mask ~= nil then
		local ONE = string.byte("1")
		isWater = function(x, y)
			local ix = math.floor((x - originX) / step + 0.5)
			local iy = math.floor((y - originY) / step + 0.5)
			if ix < 0 then ix = 0 elseif ix > cols - 1 then ix = cols - 1 end
			if iy < 0 then iy = 0 elseif iy > rows - 1 then iy = rows - 1 end
			local row = mask[iy]
			if row == nil then
				return heightAt(x, y) <= waterLevel
			end
			return row:byte(ix + 1) == ONE
		end
	else
		isWater = function(x, y) return heightAt(x, y) <= waterLevel end
	end

	return {
		kind = "heightmap",
		minX = originX, minY = originY, maxX = maxX, maxY = maxY,
		cols = cols, rows = rows, step = step,
		waterLevel = waterLevel,
		heights = heights,
		at = at,
		measured = mask ~= nil,
		isValid = function(x, y)
			return x >= originX and x <= maxX and y >= originY and y <= maxY
		end,
		isWater = isWater,
		heightAt = heightAt,
	}
end

--- Panel size in pixels for this map, longest side `maxSide`.
---
--- Real maps are not square - the first one dumped from a game was 13.8 x 41.5 km
--- - so a fixed square panel would draw a tall map into a third of its width and
--- leave the rest blank. The panel takes the map's own aspect instead.
function M.panelSize(terrain, maxSide)
	maxSide = maxSide or M.PANEL
	local spanX = terrain.maxX - terrain.minX
	local spanY = terrain.maxY - terrain.minY
	local span = math.max(spanX, spanY)
	if span <= 0 then
		return maxSide, maxSide
	end
	return maxSide * spanX / span, maxSide * spanY / span
end

--- World metres to panel pixels. y is up in the world and down in SVG.
--- The scale is uniform because the panel already carries the map's aspect.
function M.projector(terrain, panelW, panelH)
	local spanX = math.max(terrain.maxX - terrain.minX, 1e-9)
	local spanY = math.max(terrain.maxY - terrain.minY, 1e-9)
	return function(x, y)
		return (x - terrain.minX) / spanX * panelW,
			panelH - (y - terrain.minY) / spanY * panelH
	end
end

--------------------------------------------------------------------------------
-- Drawing the ground
--------------------------------------------------------------------------------

--- Terrain as bands of rects.
---
--- Heights are quantised into a fixed number of bands and runs of the same band
--- along a row are emitted as one rect. Two reasons: a page of one rect per
--- sample ran to megabytes and was slow to paint, and banded ground reads like a
--- contour map, which makes a valley or a ridge easier to see than a smooth ramp
--- does. Water is one flat band, because water is what rejects a spot.
local BANDS = 18

function M.terrainSvg(terrain, project, panelW, panelH)
	panelW = panelW or M.PANEL
	panelH = panelH or panelW
	if terrain.kind ~= "heightmap" then
		return string.format(
			'<rect x="0" y="0" width="%.2f" height="%.2f" fill="url(#flat)"/>',
			panelW, panelH)
	end

	local hi = -math.huge
	for _, h in ipairs(terrain.heights) do
		if h > hi then hi = h end
	end
	local span = math.max(hi - terrain.waterLevel, 1.0)

	local function band(h)
		if h <= terrain.waterLevel then
			return 0
		end
		local t = math.min((h - terrain.waterLevel) / span, 1.0)
		return 1 + math.floor(t * (BANDS - 1) + 0.5)
	end

	local colours = { [0] = "#6b93b5" }
	for b = 1, BANDS do
		local t = (b - 1) / (BANDS - 1)
		-- green lowland -> tan -> pale stone. Blue stays under green the whole
		-- way, or the uplands come out mauve and read as something meaningful.
		colours[b] = string.format("#%02x%02x%02x",
			math.floor(150 + 72 * t),
			math.floor(168 + 46 * t),
			math.floor(120 + 72 * t))
	end

	-- One stride for both axes, counted in samples rather than pixels: samples are
	-- `step` metres apart either way, so an equal stride keeps the cells square,
	-- and counting in pixels made a tall map coarse because its panel is narrow.
	-- The cap is on the longer axis; the run merge keeps the cost down.
	local stride = math.max(1, math.floor(math.max(terrain.cols, terrain.rows) / 400))
	local strideX, strideY = stride, stride

	local pxPerColumn = panelW / math.max(terrain.cols - 1, 1)
	local pxPerRow = panelH / math.max(terrain.rows - 1, 1)
	local cellH = pxPerRow * strideY
	local out = {}

	local function emit(ix0, ix1, iy, b)
		local x0 = project(terrain.minX + ix0 * terrain.step, 0)
		local _, y = project(0, terrain.minY + iy * terrain.step)
		local width = (ix1 - ix0 + strideX) * pxPerColumn
		out[#out + 1] = string.format(
			'<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s"/>',
			x0, y - cellH, width + 0.3, cellH + 0.3, colours[b])
	end

	for iy = 0, terrain.rows - 1, strideY do
		local runStart, runBand = nil, nil
		local ix = 0
		while ix <= terrain.cols - 1 do
			local b = band(terrain.at(ix, iy))
			if b ~= runBand then
				if runBand ~= nil then
					emit(runStart, ix - strideX, iy, runBand)
				end
				runStart, runBand = ix, b
			end
			ix = ix + strideX
		end
		if runBand ~= nil then
			emit(runStart, ix - strideX, iy, runBand)
		end
	end
	return table.concat(out)
end

M.FLAT_PATTERN = [[<pattern id="flat" width="8" height="8" patternUnits="userSpaceOnUse">
<rect width="8" height="8" fill="#eee6d5"/>
<path d="M0 8L8 0" stroke="#e3d8c2" stroke-width="1"/>
</pattern>]]

--------------------------------------------------------------------------------
-- Measurements
--------------------------------------------------------------------------------

--- Nearest-neighbour gaps, the number worth watching while tuning. The core's
--- own comment records why: taking the first spot that fit packed every cluster
--- into a lattice whose median gap sat 3% above MIN_TOWN_SPACING, and "that reads
--- as machined".
function M.gapStats(points, distance2)
	local gaps = {}
	for i = 1, #points do
		local nearest = math.huge
		for j = 1, #points do
			if i ~= j then
				local d = distance2(points[i][1], points[i][2], points[j][1], points[j][2])
				if d < nearest then nearest = d end
			end
		end
		if nearest < math.huge then
			gaps[#gaps + 1] = math.sqrt(nearest)
		end
	end
	if #gaps == 0 then
		return { median = 0, min = 0, max = 0 }
	end
	table.sort(gaps)
	local mid = math.floor(#gaps / 2)
	local median
	if #gaps % 2 == 1 then
		median = gaps[mid + 1]
	else
		median = (gaps[mid] + gaps[mid + 1]) / 2
	end
	return { median = median, min = gaps[1], max = gaps[#gaps] }
end

--- Cluster colours. Distinct hues at matched lightness, so no cluster reads as
--- more important than another.
M.CLUSTER_COLOURS = {
	"#c1442e", "#2e6fb7", "#3f8f54", "#b5842b", "#7a4fa3",
	"#2f8f8a", "#b2566f", "#5f7a2e",
}

function M.clusterColour(i)
	return M.CLUSTER_COLOURS[((i - 1) % #M.CLUSTER_COLOURS) + 1]
end

--- Metres of map per pixel of panel.
function M.metresPerPx(terrain, panelW)
	return (terrain.maxX - terrain.minX) / math.max(panelW, 1e-9)
end

--- How much room the town borders have before they run into each other.
---
--- The extents in a snapshot are measured at the start of a game, when towns are
--- at their smallest, so "do the borders overlap" is almost always no and tells
--- you nothing. What a setting really decides is how much growth it tolerates:
--- the closest pair of borders meets once every town has grown by this factor.
---
--- `points` is {{x, y}} in metres and `radii` the matching border radii, also in
--- metres; a radius of 0 means the town has no measured extent and is skipped.
--- Returns the growth factor and the closest gap in metres, or nil when fewer
--- than two towns have an extent.
function M.borderHeadroom(points, radii)
	local factor, gap, pairs = math.huge, math.huge, 0
	for i = 1, #points do
		for j = i + 1, #points do
			local ri, rj = radii[i] or 0, radii[j] or 0
			if ri > 0 and rj > 0 then
				local dx = points[i][1] - points[j][1]
				local dy = points[i][2] - points[j][2]
				local d = math.sqrt(dx * dx + dy * dy)
				local sum = ri + rj
				if d / sum < factor then factor = d / sum end
				if d - sum < gap then gap = d - sum end
				pairs = pairs + 1
			end
		end
	end
	if pairs == 0 then
		return nil
	end
	return factor, gap
end

--- A town's border radius in pixels, from the extent measured in game, or nil
--- when the snapshot does not carry one.
---
--- `p90` rather than the furthest building: one outlying farmhouse would put the
--- border far outside anything that reads as the town.
---
--- `scale` shrinks it for a town the mod scales down. Capacity falls by
--- ISOLATED_SIZE_SCALE and a town's built area goes roughly with its capacity,
--- so the radius goes with the square root of it.
function M.borderPx(extent, metresPerPx, scale)
	if extent == nil or extent.p90 == nil or extent.p90 <= 0 then
		return nil
	end
	return extent.p90 * (scale or 1.0) / metresPerPx
end

--- Town marker radius, in pixels, for a town of this size factor.
---
--- Sized in world metres and then projected, rather than a fixed pixel size.
--- A fixed size lied badly: on a 41 km map a size-2 town was drawn 1.1 km across
--- against a 600 m spacing floor, so markers overlapped no matter how well spaced
--- the towns were, and every cluster looked like one blob whatever the settings
--- actually did.
---
--- The scale is chosen so two neighbouring towns just touch at the 600 m floor
--- and separate as the spacing opens up - so overlap in the picture means towns
--- that really would grow into each other.
---
--- Clamped in pixels at both ends: a marker still has to be visible on a huge map
--- and must not swallow a small one.
--- Marker and border radii together, in pixels.
---
--- The marker is capped against the border so the border is always visible as a
--- ring around it. Without that cap it disappears: a town's measured extent is
--- around 200 m, and on a map 41 km across that is about the same few pixels a
--- legible marker needs, so the dot sat exactly on top of the halo.
---
--- Worth knowing when reading the picture: at that map scale a real town border
--- is only a few pixels wide whatever is done with it. The border numbers under
--- the map - closest gap, and the growth a cluster tolerates - are the readout;
--- the halos show you which towns are involved.
function M.markerWithBorder(size, extent, metresPerPx, scale)
	local border = M.borderPx(extent, metresPerPx, scale)
	local marker = M.markerRadius(size, metresPerPx)
	if border ~= nil then
		marker = math.min(marker, math.max(1.5, border * 0.45))
	end
	return marker, border
end

function M.markerRadius(size, metresPerPx)
	local world = 90 + 110 * math.min(size or 1.0, 2.5)
	local px = world / metresPerPx
	if px < 1.8 then
		px = 1.8
	elseif px > 16 then
		px = 16
	end
	return px
end

function M.esc(s)
	return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

return M
