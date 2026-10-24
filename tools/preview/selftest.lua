--- Round-trip test for the snapshot path, with no game involved.
---
--- The mod dumps a map through `snapshot.lua` into the log, and
--- `from_log.lua` reads it back. Both halves can be exercised here against the
--- synthetic map: emit a snapshot of known terrain, parse it, and check that what
--- comes back is the terrain that went in.
---
--- Worth running after touching either side, because the real thing costs a game
--- start to test and a format mistake would not show up until then.
---
---   lua tools/preview/selftest.lua

local function scriptDir()
	local path = arg and arg[0] or "selftest.lua"
	return path:match("^(.*)[/\\][^/\\]*$") or "."
end

package.path = table.concat({
	scriptDir() .. "/?.lua",
	scriptDir() .. "/../../mod/town_clustering_1/content/?.lua",
	package.path,
}, ";")

local snapshot = require("snapshot")
local synthetic = require("synthetic")

local failures = 0
local function check(ok, what)
	if ok then
		print("  ok    " .. what)
	else
		print("  FAIL  " .. what)
		failures = failures + 1
	end
end

--------------------------------------------------------------------------------
-- A terrain adapter over the synthetic map, standing in for the engine's
--------------------------------------------------------------------------------

local data = synthetic.make()
local t = data.terrain

local function at(ix, iy)
	if ix < 0 then ix = 0 elseif ix > t.cols - 1 then ix = t.cols - 1 end
	if iy < 0 then iy = 0 elseif iy > t.rows - 1 then iy = t.rows - 1 end
	return t.heights[iy * t.cols + ix + 1]
end

local maxX = t.originX + (t.cols - 1) * t.step
local maxY = t.originY + (t.rows - 1) * t.step

local engine = {
	isValid = function(x, y)
		return x >= t.originX and x <= maxX and y >= t.originY and y <= maxY
	end,
	heightAt = function(x, y)
		return at(math.floor((x - t.originX) / t.step + 0.5),
			math.floor((y - t.originY) / t.step + 0.5))
	end,
}
engine.isWater = function(x, y) return engine.heightAt(x, y) <= t.waterLevel end

-- The Town Spacing setting is meant to be additive: leaving it alone has to
-- reproduce the geometry the mod had before it existed. Comparing plans across
-- maps cannot show that, because a different map gives a different plan; the
-- geometry itself can.
print("town spacing default is a no-op")
do
	local core = require("clustering_core")
	check(core.TOWN_SPACINGS[1] == core.MIN_TOWN_SPACING, string.format(
		"slider position 1 is %.0f m, the old MIN_TOWN_SPACING %.0f m",
		core.TOWN_SPACINGS[1], core.MIN_TOWN_SPACING))

	local g = core.geometry(core.TOWN_SPACINGS[1])
	check(g.spacing == core.MIN_TOWN_SPACING and g.firstRing == core.FIRST_RING
		and g.ringStep == core.RING_STEP, string.format(
		"geometry at position 1 is %.0f/%.0f/%.0f, constants are %.0f/%.0f/%.0f",
		g.spacing, g.firstRing, g.ringStep,
		core.MIN_TOWN_SPACING, core.FIRST_RING, core.RING_STEP))

	local d = core.resolveParams({})
	check(d.spacing == core.MIN_TOWN_SPACING, string.format(
		"with no slider value the spacing defaults to %.0f m", d.spacing))

	local loose = core.geometry(core.TOWN_SPACINGS[#core.TOWN_SPACINGS])
	check(loose.firstRing > g.firstRing and loose.ringStep > g.ringStep,
		"the rings open out with the spacing rather than staying fixed")
end

print("")
print("snapshot round trip")

-- percentiles, on a list whose answers are obvious
do
	local sample = {}
	for i = 1, 101 do sample[i] = (i - 1) * 10.0 end
	local p50, p90, furthest = snapshot.percentiles(sample)
	check(p50 == 500.0, string.format("p50 of 0..1000 is %.0f, expected 500", p50))
	check(p90 == 900.0, string.format("p90 of 0..1000 is %.0f, expected 900", p90))
	check(furthest == 1000.0, string.format("max is %.0f, expected 1000", furthest))
	local e50, e90, emax = snapshot.percentiles({})
	check(e50 == 0 and e90 == 0 and emax == 0, "empty list gives zeroes")
end

--------------------------------------------------------------------------------
-- Bounds discovery
--------------------------------------------------------------------------------

local town = data.towns[1].position
local minX, minY, bx, by = snapshot.bounds(engine.isValid, town.x, town.y)
check(math.abs(minX - t.originX) < 1.0, string.format(
	"west edge found at %.1f, expected %.1f", minX, t.originX))
check(math.abs(by - maxY) < 1.0, string.format(
	"north edge found at %.1f, expected %.1f", by, maxY))

local cols, rows = snapshot.grid(minX, minY, bx, by, t.step)
check(cols == t.cols and rows == t.rows, string.format(
	"grid %dx%d, expected %dx%d", cols, rows, t.cols, t.rows))

--------------------------------------------------------------------------------
-- Emit a log, exactly as the mod would
--------------------------------------------------------------------------------

-- os.tmpname() on Windows hands back a bare "\name" at the root of the current
-- drive, which is usually not writable; build a path in the temp folder instead.
local windows = package.config:sub(1, 1) == "\\"
local tmpdir = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
local logPath = tmpdir .. (windows and "\\" or "/") .. "tc_selftest_log.txt"

local log = assert(io.open(logPath, "wb"))
local function emit(line)
	-- the real log carries a timestamp and the mod's own prefix
	log:write("2026-10-24 18:00:00 [town-clustering] " .. line .. "\n")
end

emit(snapshot.beginLine(minX, minY, t.step, cols, rows, t.waterLevel))
for _, tn in ipairs(data.towns) do
	emit(snapshot.townLine(tn.position.x, tn.position.y, tn.sizeFactors[1], tn.name))
end

-- Measured town extents. The real ones come from the positions of a town's own
-- buildings; here they are invented but travel the same path.
local wantExtent = {}
for i, tn in ipairs(data.towns) do
	local p90 = 220.0 + 160.0 * tn.sizeFactors[1]
	wantExtent[i] = p90
	emit(snapshot.areaLine(i, 40 + i, p90 * 0.55, p90, p90 * 1.4))
end
for iy = 0, rows - 1 do
	local h, w = snapshot.rowLines(engine, minX, minY, t.step, cols, iy)
	emit(h)
	emit(w)
end
emit(snapshot.endLine(#data.towns))
log:close()

--------------------------------------------------------------------------------
-- Parse it back
--------------------------------------------------------------------------------

local outPath = tmpdir .. (windows and "\\" or "/") .. "tc_selftest_snapshot.lua"
local lua = arg and arg[-1] or "lua"
local cmd = string.format('"%s" "%s/from_log.lua" "%s" "%s"',
	lua, scriptDir(), logPath, outPath)
-- cmd.exe strips the outer pair of quotes from a command that begins with one,
-- so a path with spaces in both the exe and an argument needs wrapping again.
if windows then cmd = '"' .. cmd .. '"' end
local ok = os.execute(cmd)
check(ok == true or ok == 0, "from_log.lua ran")

local chunk = loadfile(outPath)
check(chunk ~= nil, "parsed snapshot loads as Lua")

if chunk ~= nil then
	local back = chunk()
	check(#back.towns == #data.towns, string.format(
		"%d towns back, sent %d", #back.towns, #data.towns))
	check(back.terrain.cols == cols and back.terrain.rows == rows,
		"grid dimensions survived")

	-- Town positions, to the two decimals the format carries.
	local worst = 0
	for i, tn in ipairs(back.towns) do
		local orig = data.towns[i].position
		local d = math.max(math.abs(tn.position.x - orig.x), math.abs(tn.position.y - orig.y))
		if d > worst then worst = d end
	end
	check(worst <= 0.01, string.format("town positions within %.4f m", worst))

	-- Measured extents, which the previewer draws as town borders.
	local worstE, withExtent = 0, 0
	for i, tn in ipairs(back.towns) do
		if tn.extent ~= nil and tn.extent.p90 ~= nil then
			withExtent = withExtent + 1
			local d = math.abs(tn.extent.p90 - wantExtent[i])
			if d > worstE then worstE = d end
		end
	end
	check(withExtent == #data.towns, string.format(
		"%d of %d towns came back with an extent", withExtent, #data.towns))
	check(worstE <= 0.05, string.format("extents within %.3f m", worstE))

	-- Heights, to the one decimal the format carries.
	local worstH, checked = 0, 0
	for iy = 0, rows - 1, 7 do
		for ix = 0, cols - 1, 7 do
			local got = back.terrain.heights[iy * cols + ix + 1]
			local want = engine.heightAt(minX + ix * t.step, minY + iy * t.step)
			local d = math.abs(got - want)
			if d > worstH then worstH = d end
			checked = checked + 1
		end
	end
	check(worstH <= 0.05, string.format(
		"heights within %.4f m over %d samples", worstH, checked))

	-- The water mask, against the engine answers that produced it.
	local wrong, total = 0, 0
	local ONE = string.byte("1")
	for iy = 0, rows - 1, 5 do
		local row = back.terrain.water[iy]
		for ix = 0, cols - 1, 5 do
			local got = row:byte(ix + 1) == ONE
			local want = engine.isWater(minX + ix * t.step, minY + iy * t.step)
			if got ~= want then wrong = wrong + 1 end
			total = total + 1
		end
	end
	check(wrong == 0, string.format("water mask exact over %d samples (%d wrong)",
		total, wrong))

	local wet = 0
	for iy = 0, rows - 1 do
		local _, n = (back.terrain.water[iy] or ""):gsub("1", "")
		wet = wet + n
	end
	check(wet > 0, string.format("mask actually has water in it (%d samples)", wet))
end

os.remove(logPath)
os.remove(outPath)

print("")
if failures == 0 then
	print("all checks passed")
	os.exit(0)
else
	print(failures .. " check(s) failed")
	os.exit(1)
end
