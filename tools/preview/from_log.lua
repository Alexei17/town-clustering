--- Turn a snapshot logged by the mod into a snapshot file the previewer reads.
---
--- The mod writes the map through `log.message` (see
--- `mod/town_clustering_1/content/snapshot.lua` for why the log and not a file).
--- This pulls the last complete snapshot back out of `crash_dump/stdout.txt` and
--- writes it as a Lua table.
---
---   lua tools/preview/from_log.lua <stdout.txt> [out.lua]
---
--- The last complete block wins, so a log with several snapshot runs in it gives
--- the most recent one. An unfinished block - the game was closed mid-dump - is
--- ignored rather than half-read.

local inPath = arg and arg[1]
local outPath = (arg and arg[2]) or "snapshot.lua"

if inPath == nil then
	io.stderr:write(
		"usage: lua from_log.lua <stdout.txt> [out.lua]\n\n" ..
		"The log is normally at\n" ..
		"  C:\\Program Files (x86)\\Steam\\userdata\\<id>\\3493540\\local\\crash_dump\\stdout.txt\n")
	os.exit(1)
end

local file, err = io.open(inPath, "rb")
if file == nil then
	io.stderr:write("could not read " .. inPath .. ": " .. tostring(err) .. "\n")
	os.exit(1)
end

--------------------------------------------------------------------------------
-- Collect blocks
--------------------------------------------------------------------------------

local blocks = {}
local current = nil

for line in file:lines() do
	-- The log carries its own prefixes; find our marker wherever it sits.
	local body = line:match("snap%s+(.*)$")
	if body ~= nil then
		local kind = body:match("^(%S+)")

		if kind == "begin" then
			local version = tonumber(body:match("^begin%s+(%d+)"))
			local t = {
				version = version,
				minX = tonumber(body:match("x0=(-?[%d.]+)")),
				minY = tonumber(body:match("y0=(-?[%d.]+)")),
				step = tonumber(body:match("step=(-?[%d.]+)")),
				cols = tonumber(body:match("cols=(%d+)")),
				rows = tonumber(body:match("rows=(%d+)")),
				waterLevel = tonumber(body:match("water=(-?[%d.]+)")),
			}
			current = { terrain = t, towns = {}, areas = {},
				heightRows = {}, waterRows = {} }

		elseif current ~= nil then
			if kind == "town" then
				local x, y, size, name =
					body:match("^town%s+(-?[%d.]+)%s+(-?[%d.]+)%s+(-?[%d.]+)%s*(.*)$")
				if x ~= nil then
					current.towns[#current.towns + 1] = {
						x = tonumber(x), y = tonumber(y),
						size = tonumber(size), name = name ~= "" and name or nil,
					}
				end

			elseif kind == "area" then
				local i, n, p50, p90, far =
					body:match("^area%s+(%d+)%s+(%d+)%s+([%d.]+)%s+([%d.]+)%s+([%d.]+)")
				if i ~= nil then
					current.areas[tonumber(i)] = {
						buildings = tonumber(n), p50 = tonumber(p50),
						p90 = tonumber(p90), furthest = tonumber(far),
					}
				end

			elseif kind == "h" then
				local row, csv = body:match("^h%s+(%d+)%s+(.*)$")
				if row ~= nil then current.heightRows[tonumber(row)] = csv end

			elseif kind == "w" then
				local row, bits = body:match("^w%s+(%d+)%s+(%S*)$")
				if row ~= nil then current.waterRows[tonumber(row)] = bits end

			elseif kind == "end" then
				current.declared = tonumber(body:match("towns=(%d+)"))
				blocks[#blocks + 1] = current
				current = nil
			end
		end
	end
end
file:close()

if #blocks == 0 then
	if current ~= nil then
		-- A `begin` with no `end`. Almost always the dump is still running: it
		-- goes out a dozen terrain rows per tick, so a large map takes a hundred
		-- ticks, and the log is read while the game is still writing it.
		local got = 0
		for _ in pairs(current.heightRows) do got = got + 1 end
		io.stderr:write(string.format(
			"a snapshot was started but has not finished: %d of %d terrain rows so "
			.. "far.\nWait for the log to say 'snapshot complete', then retry. "
			.. "(If the game was closed\nmid-dump, start a new game again.)\n",
			got, current.terrain.rows or 0))
	else
		io.stderr:write(
			"no snapshot found in " .. inPath .. "\n" ..
			"Set 'Debug: Map Snapshot' to 'Snapshot Only' and start a new game.\n"
			.. "The log should show '[town-clustering] snap begin'.\n")
	end
	os.exit(1)
end

local block = blocks[#blocks]
local t = block.terrain

--------------------------------------------------------------------------------
-- Check it is whole
--------------------------------------------------------------------------------

local function fail(msg)
	io.stderr:write("snapshot is damaged: " .. msg .. "\n")
	os.exit(1)
end

if t.cols == nil or t.rows == nil or t.step == nil then
	fail("header did not parse")
end
if t.version ~= 1 then
	fail("unknown format version " .. tostring(t.version))
end

local missing = 0
for iy = 0, t.rows - 1 do
	if block.heightRows[iy] == nil then missing = missing + 1 end
end
if missing > 0 then
	fail(missing .. " of " .. t.rows .. " terrain rows are absent; the log may have "
		.. "been truncated or the dump did not finish")
end

--------------------------------------------------------------------------------
-- Flatten
--------------------------------------------------------------------------------

local heights = {}
local n = 0
for iy = 0, t.rows - 1 do
	local count = 0
	for value in block.heightRows[iy]:gmatch("[^,]+") do
		n = n + 1
		heights[n] = tonumber(value)
		count = count + 1
	end
	if count ~= t.cols then
		fail(string.format("row %d has %d samples, expected %d", iy, count, t.cols))
	end
end

--------------------------------------------------------------------------------
-- Write
--------------------------------------------------------------------------------

local out, werr = io.open(outPath, "wb")
if out == nil then
	io.stderr:write("could not write " .. outPath .. ": " .. tostring(werr) .. "\n")
	os.exit(1)
end

out:write("-- Map snapshot recovered from a game log by tools/preview/from_log.lua\n")
out:write("-- Source: " .. inPath:gsub("\\", "/") .. "\n")
out:write("return {\n  towns = {\n")
for i, town in ipairs(block.towns) do
	-- `extent` is the town's measured built radius in metres: how far its own
	-- buildings reach from its centre. The game draws a border but exposes no
	-- radius, so this is measured rather than derived.
	local area = block.areas[i]
	local extent = ""
	if area ~= nil and area.buildings > 0 then
		extent = string.format(
			", extent = { buildings = %d, p50 = %.1f, p90 = %.1f, furthest = %.1f }",
			area.buildings, area.p50, area.p90, area.furthest)
	end
	out:write(string.format(
		"    { position = { x = %.2f, y = %.2f }, sizeFactors = { %.4f, 1.0, 1.0 }, "
		.. "name = %q%s },\n",
		town.x, town.y, town.size or 1.0, town.name or "", extent))
end
out:write("  },\n  industries = {},\n  terrain = {\n")
out:write(string.format(
	"    originX = %.2f, originY = %.2f,\n    cols = %d, rows = %d, step = %.2f,\n"
	.. "    waterLevel = %.3f,\n", t.minX, t.minY, t.cols, t.rows, t.step, t.waterLevel))

-- Water as one string per row: compact, and the previewer indexes it directly
-- rather than inferring water from height, which is what the engine was asked.
out:write("    water = {\n")
for iy = 0, t.rows - 1 do
	out:write(string.format("      [%d] = %q,\n", iy, block.waterRows[iy] or ""))
end
out:write("    },\n    heights = {\n      ")
for i = 1, n do
	out:write(string.format("%.1f", heights[i]))
	if i < n then out:write(",") end
	if i % 20 == 0 then out:write("\n      ") end
end
out:write("\n    },\n  },\n}\n")
out:close()

local withExtent = 0
for i = 1, #block.towns do
	local a = block.areas[i]
	if a ~= nil and a.buildings > 0 then withExtent = withExtent + 1 end
end
print(string.format(
	"%d towns (%d with a measured extent), %dx%d terrain samples at %.0f m, water level %.1f",
	#block.towns, withExtent, t.cols, t.rows, t.step, t.waterLevel))
if block.declared ~= nil and block.declared ~= #block.towns then
	print(string.format(
		"warning: log says %d towns but %d were parsed", block.declared, #block.towns))
end
print("wrote " .. outPath)
