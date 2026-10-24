--- Town Clustering - the interactive explorer.
---
--- Builds a single self-contained page with the four mod sliders on it. Moving
--- one redraws the map instantly.
---
--- There is no JavaScript implementation of the clustering, deliberately. Every
--- combination of the four sliders - 6 x 4 x 5 x 4 = 480 of them - is worked out
--- here by `clustering_core.lua`, the file the mod itself runs, and baked into
--- the page. The browser only swaps between results. All 480 take about a second
--- to compute, so there is nothing to gain from a second implementation and a
--- great deal to lose: a JavaScript copy would drift from the mod exactly when it
--- was being used to tune it.
---
--- It also means the page needs no server, no network and no toolchain to open.
---
---   lua tools/preview/studio.lua [snapshot.lua] [--out studio.html]
---
--- See tools/studio.ps1 for a wrapper that finds lua.exe.

local function scriptDir()
	local path = arg and arg[0] or "studio.lua"
	return path:match("^(.*)[/\\][^/\\]*$") or "."
end

package.path = table.concat({
	scriptDir() .. "/?.lua",
	scriptDir() .. "/../../mod/town_clustering_1/content/?.lua",
	package.path,
}, ";")

local core = require("clustering_core")
local map = require("mapdata")
local synthetic = require("synthetic")

--------------------------------------------------------------------------------
-- Arguments
--------------------------------------------------------------------------------

local options = { snapshot = nil, out = "studio.html", title = nil }
do
	local i = 1
	while arg ~= nil and arg[i] ~= nil do
		local a = arg[i]
		if a == "--out" then
			i = i + 1
			options.out = arg[i]
		elseif a == "--title" then
			i = i + 1
			options.title = arg[i]
		elseif a:sub(1, 2) == "--" then
			io.stderr:write("unknown option: " .. a .. "\n")
			os.exit(1)
		else
			options.snapshot = a
		end
		i = i + 1
	end
end

local data, source, err = map.loadSnapshot(options.snapshot, synthetic.make)
if data == nil then
	io.stderr:write(err .. "\n")
	os.exit(1)
end

local towns = map.readTowns(data)
if #towns < 2 then
	io.stderr:write("snapshot has fewer than two towns; nothing to explore\n")
	os.exit(1)
end

local terrain = map.makeTerrain(data, towns)
local panelW, panelH = map.panelSize(terrain, map.PANEL)
local project = map.projector(terrain, panelW, panelH)

--------------------------------------------------------------------------------
-- The inter-town network, as far as it can be known offline
--------------------------------------------------------------------------------

--- The engine's own `getDefaultTownConnections` proposal is not available here,
--- so this runs the mod's *own* stitching over an empty proposal: union-find,
--- joining the two nearest towns in separate components until everything is
--- reachable. The long links between clusters are therefore real; the short roads
--- inside a cluster are the engine's business and only approximated by it.
local function network(points)
	local xs, ys = {}, {}
	for i, p in ipairs(points) do
		xs[i], ys[i] = p[1], p[2]
	end
	return core.stitchConnections({}, 0, xs, ys, #points)
end

--------------------------------------------------------------------------------
-- Compute every combination
--------------------------------------------------------------------------------

local KIND = { stay = 0, move = 1, isolated = 2 }

local function numbers(list)
	return table.concat(list, ",")
end

local combos = {}
local computed, noops = 0, 0

local nCount = #core.CLUSTER_COUNTS
local nVariation = #core.VARIATION_RATIO_MIN
local nKeep = #core.KEEP_FRACTIONS
local nIsolated = #core.ISOLATED_SHARES
local nSpacing = #core.TOWN_SPACINGS

--- Index a combination the same way the page will, so the data can be a flat
--- array with no keys in it.
local function indexOf(count, variation, keep, isolated, spacing)
	return (((((count - 1) * nVariation + (variation - 1)) * nKeep
		+ (keep - 1)) * nIsolated + (isolated - 1)) * nSpacing + (spacing - 1))
end

for count = 1, nCount do
	for variation = 1, nVariation do
		for keep = 1, nKeep do
			for isolated = 1, nIsolated do
			for spacing = 1, nSpacing do
				local params = core.resolveParams({
					["cluster.count"] = count,
					["cluster.variation"] = variation,
					["cluster.keep"] = keep,
					["cluster.isolated"] = isolated,
					["cluster.spacing"] = spacing,
				})
				local plan, reason = core.plan({
					towns = towns, params = params, terrain = terrain,
				})

				local entry
				if plan == nil then
					entry = string.format("{n:%q}", reason or "no change")
					noops = noops + 1
				else
					local flat, points = {}, {}
					local isCentre = {}
					for _, c in ipairs(plan.centres) do isCentre[c.index] = true end

					-- Six per town: x, y, centre, kind, is-a-centre, and the index
					-- the town had before the planner sorted by distance. That
					-- last one is needed because size factors are kept in the
					-- snapshot's order, not the plan's.
					for i, p in ipairs(plan.towns) do
						local n = (i - 1) * 6
						flat[n + 1] = string.format("%.0f", p.x)
						flat[n + 2] = string.format("%.0f", p.y)
						flat[n + 3] = tostring(p.centre)
						flat[n + 4] = tostring(KIND[p.kind] or 0)
						flat[n + 5] = isCentre[p.index] and "1" or "0"
						flat[n + 6] = tostring(p.index - 1)
						points[i] = { p.x, p.y }
					end

					local links = {}
					for _, link in ipairs(network(points)) do
						links[#links + 1] = tostring(link[1])
						links[#links + 1] = tostring(link[2])
					end

					-- Where each town came from, for the ones that moved. Only
					-- the movers, so the page is not carrying 53 identical pairs.
					local from = {}
					for i, p in ipairs(plan.towns) do
						if p.kind == "move" then
							from[#from + 1] = tostring(i - 1)
							from[#from + 1] = string.format("%.0f", p.origX)
							from[#from + 1] = string.format("%.0f", p.origY)
						end
					end

					local sizes = {}
					local biggest, smallest = 0, math.huge
					for _, s in ipairs(plan.sizes) do
						sizes[#sizes + 1] = tostring(s)
						if s > biggest then biggest = s end
						if s < smallest and s > 0 then smallest = s end
					end
					local spread = (smallest < math.huge and smallest > 0)
						and biggest / smallest or 0

					local gaps = map.gapStats(points, core.distance2)

					-- border headroom, using each town's own measured extent
					local radii = {}
					for pi, p in ipairs(plan.towns) do
						local ex = towns[p.index] and towns[p.index].extent
						local r = (ex and ex.p90) or 0
						if p.kind == "isolated" then
							r = r * math.sqrt(core.ISOLATED_SIZE_SCALE)
						end
						radii[pi] = r
					end
					local grow, bgap = map.borderHeadroom(points, radii)

					entry = string.format(
						"{t:[%s],l:[%s],f:[%s],z:[%s],r:%.3f,sp:%.2f,mv:%d,st:%d,is:%d,sd:%d,"
						.. "gm:%.0f,gn:%.0f,bg:%.2f,bq:%.0f}",
						numbers(flat), numbers(links), numbers(from), numbers(sizes),
						plan.ratio, spread, plan.moved, plan.stayed, #plan.isolated,
						plan.stranded, gaps.median, gaps.min, grow or 0, bgap or 0)
					computed = computed + 1
				end

				combos[indexOf(count, variation, keep, isolated, spacing) + 1] = entry
			end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Stock panel
--------------------------------------------------------------------------------

-- Marker radius per town, in pixels, worked out here so the page carries no copy
-- of the sizing rule. Indexed by the snapshot order, which is the index the plan
-- reports for each town.
local metresPerPx = map.metresPerPx(terrain, panelW)
local radiusByIndex, borderByIndex = {}, {}
for i, town in ipairs(towns) do
	-- the marker is capped against the border so the border stays visible;
	-- a border of 0 means the snapshot carried no measured extent for this town
	local r, b = map.markerWithBorder(town.size, town.extent, metresPerPx)
	radiusByIndex[i] = string.format("%.2f", r)
	borderByIndex[i] = string.format("%.2f", b or 0)
end

local stockFlat, stockPoints = {}, {}
for i, town in ipairs(towns) do
	local n = (i - 1) * 4
	stockFlat[n + 1] = string.format("%.0f", town.x)
	stockFlat[n + 2] = string.format("%.0f", town.y)
	stockFlat[n + 3] = radiusByIndex[i]
	stockFlat[n + 4] = borderByIndex[i]
	stockPoints[i] = { town.x, town.y }
end
local stockLinks = {}
for _, link in ipairs(network(stockPoints)) do
	stockLinks[#stockLinks + 1] = tostring(link[1])
	stockLinks[#stockLinks + 1] = tostring(link[2])
end
local stockGaps = map.gapStats(stockPoints, core.distance2)
local stockRadii = {}
for i, town in ipairs(towns) do
	stockRadii[i] = (town.extent and town.extent.p90) or 0
end
local stockGrow, stockBorderGap = map.borderHeadroom(stockPoints, stockRadii)

--------------------------------------------------------------------------------
-- Page
--------------------------------------------------------------------------------

local terrainSvg = map.terrainSvg(terrain, project, panelW, panelH)

local terrainNote
if terrain.kind == "heightmap" then
	terrainNote = string.format(
		"Terrain from the snapshot: %d x %d samples at %.0f m, water level %.1f m. "
		.. "Water is %s, so slope and water rejection are %s.",
		terrain.cols, terrain.rows, terrain.step, terrain.waterLevel,
		terrain.measured and "the engine's own <code>isOnWater</code> answers"
			or "inferred from height against the water level",
		terrain.measured and "what the mod will see" or "close but not measured")
else
	terrainNote = "No terrain in this snapshot, so every point counts as dry and "
		.. "flat. Cluster structure is right, but nothing is rejected for water or "
		.. "slope."
end

local function jsList(list)
	return '["' .. table.concat(list, '","') .. '"]'
end

local html = {}
local function w(s) html[#html + 1] = s end

w([[<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Town Clustering studio</title>
<style>
:root { color-scheme: light; }
body { margin:0; padding:24px; font:14px/1.5 system-ui, sans-serif;
  background:#faf8f4; color:#241f1a; }
h1 { font-size:20px; margin:0 0 4px; }
.meta,.note { color:#6b645b; margin:0 0 6px; max-width:80ch; }
.note { margin-bottom:18px; }
.controls { display:flex; flex-wrap:wrap; gap:18px; margin:0 0 20px;
  padding:14px 16px; background:#fff; border:1px solid #e6ddcd; border-radius:6px; }
.ctrl { flex:1 1 200px; min-width:0; }
.ctrl label { display:block; font-weight:600; margin-bottom:2px; }
.ctrl .val { color:#8a5a2b; font-variant-numeric:tabular-nums; }
.ctrl input { width:100%; margin:4px 0 0; }
.grid { display:flex; flex-wrap:wrap; gap:24px; }
.col { flex:1 1 360px; min-width:0; }
h2 { font-size:15px; margin:0 0 8px; font-weight:600; }
svg.panel { width:100%; height:auto; border:1px solid #ddd5c6; border-radius:4px;
  background:#eee6d5; display:block; }
table.stats { border-collapse:collapse; margin-top:10px; width:100%; }
.stats th,.stats td { text-align:left; padding:3px 8px 3px 0;
  border-bottom:1px solid #ebe4d7; font-weight:400; vertical-align:top; }
.stats th { color:#6b645b; width:56%; }
.stats td { font-variant-numeric:tabular-nums; }
.legend { margin-top:14px; color:#6b645b; }
.legend span { display:inline-block; margin-right:14px; white-space:nowrap; }
code { background:#efe9dc; padding:0 3px; border-radius:3px; }
.warn { color:#9a3412; }
</style></head><body>]])

w("<h1>" .. map.esc(options.title or "Town Clustering studio") .. "</h1>")
w('<p class="meta">snapshot <code>' .. map.esc(source) .. "</code> &mdash; "
	.. #towns .. " towns &mdash; "
	.. computed .. " settings precomputed with the mod's own clustering_core.lua"
	.. (noops > 0 and (", " .. noops .. " of them no-ops") or "") .. "</p>")
w('<p class="note">' .. terrainNote .. "</p>")

w('<div class="controls">')
w([[<div class="ctrl"><label for="s0">Cluster Count <span class="val" id="v0"></span></label>
<input type="range" id="s0" min="1" max="6" value="3"></div>
<div class="ctrl"><label for="s1">Cluster Sizes <span class="val" id="v1"></span></label>
<input type="range" id="s1" min="1" max="4" value="3"></div>
<div class="ctrl"><label for="s2">Towns Left In Place <span class="val" id="v2"></span></label>
<input type="range" id="s2" min="1" max="5" value="2"></div>
<div class="ctrl"><label for="s3">Isolated Towns <span class="val" id="v3"></span></label>
<input type="range" id="s3" min="1" max="4" value="3"></div>
<div class="ctrl"><label for="s4">Town Spacing <span class="val" id="v4"></span></label>
<input type="range" id="s4" min="1" max="4" value="1"></div>]])
w("</div>")

w('<div class="grid">')
w('<div class="col"><h2>As generated</h2>')
w(string.format('<svg viewBox="0 0 %.2f %.2f" class="panel"><defs>%s<g id="ground">%s</g></defs>'
	.. '<use href="#ground"/><g id="stock"></g></svg>', panelW, panelH,
	map.FLAT_PATTERN, terrainSvg))
w('<table class="stats"><tr><th>Towns</th><td>' .. #towns .. "</td></tr>"
	.. string.format('<tr><th>Nearest-neighbour median</th><td>%.0f m</td></tr>', stockGaps.median)
	.. string.format('<tr><th>Nearest-neighbour min</th><td>%.0f m</td></tr>', stockGaps.min)
	.. string.format('<tr><th>Nearest-neighbour max</th><td>%.0f m</td></tr>', stockGaps.max)
	.. (stockGrow and string.format(
		'<tr><th>Closest border gap</th><td>%.0f m</td></tr>'
		.. '<tr><th>Borders meet once towns grow</th><td>%.2f&times;</td></tr>',
		stockBorderGap, stockGrow) or "")
	.. "</table></div>")

w('<div class="col"><h2>Clustered</h2>')
w(string.format('<svg viewBox="0 0 %.2f %.2f" class="panel"><use href="#ground"/>'
	.. '<g id="clustered"></g></svg>', panelW, panelH))
w('<table class="stats" id="statTable"></table></div>')
w("</div>")

w([[<p class="legend">
<span><span style="color:#8c8378">&#9679;</span> unclustered or isolated</span>
<span>ringed = cluster centre</span>
<span>dotted = where a town moved from</span>
<span>thin lines = the mod's own stitching, not the engine's proposal</span>
</p>]])

-- Data
w("<script>")
w(string.format("const PW=%.2f,PH=%.2f;", panelW, panelH))
w(string.format("const BOX={x0:%.2f,y0:%.2f,sx:%.2f,sy:%.2f};",
	terrain.minX, terrain.minY,
	terrain.maxX - terrain.minX, terrain.maxY - terrain.minY))
w("const STOCK={t:[" .. numbers(stockFlat) .. "],l:[" .. numbers(stockLinks) .. "]};")
w("const RADII=[" .. numbers(radiusByIndex) .. "];")
w("const BORDERS=[" .. numbers(borderByIndex) .. "];")
w(string.format("const ISO_SCALE=%.3f,ISO_BORDER=%.3f;",
	core.ISOLATED_SIZE_SCALE, math.sqrt(core.ISOLATED_SIZE_SCALE)))
w("const COLOURS=" .. jsList(map.CLUSTER_COLOURS) .. ";")
w("const LABELS=[")
w(jsList({ "2", "3", "4", "5", "6", "8" }) .. ",")
w(jsList({ "Equal", "Mild", "Varied", "Lopsided" }) .. ",")
w(jsList({ "30%", "45%", "60%", "75%", "100%" }) .. ",")
w(jsList({ "None", "5%", "10%", "20%" }) .. ",")
do
	local labels, values = {}, {}
	for i, s in ipairs(core.TOWN_SPACINGS) do
		labels[i] = string.format("%.0f m", s)
		values[i] = string.format("%.0f", s)
	end
	w(jsList(labels))
	w("];")
	w("const SPACINGS=[" .. table.concat(values, ",") .. "];")
end
w(string.format("const DIMS=[%d,%d,%d,%d,%d];",
	nCount, nVariation, nKeep, nIsolated, nSpacing))
w("const COMBOS=[" .. table.concat(combos, ",") .. "];")

-- A longer bracket than [[ ]]: the script below contains `pts[list[i]]`, whose
-- `]]` would otherwise close the string.
w([==[
const px = (x, y) => [ (x - BOX.x0) / BOX.sx * PW,
                       PH - (y - BOX.y0) / BOX.sy * PH ];
// Marker radii and border radii arrive precomputed; the sizing rules live in
// mapdata.lua only. A border of 0 means the snapshot had no measured extent.
const border = (cx, cy, r, colour) => r > 0
  ? `<circle cx="${cx.toFixed(1)}" cy="${cy.toFixed(1)}" r="${r.toFixed(1)}" `
    + `fill="${colour}" fill-opacity="0.13" stroke="${colour}" `
    + `stroke-opacity="0.55" stroke-width="0.9"/>`
  : "";

function links(list, pts) {
  let out = "";
  for (let i = 0; i < list.length; i += 2) {
    const a = pts[list[i]], b = pts[list[i + 1]];
    if (!a || !b) continue;
    out += `<line x1="${a[0].toFixed(1)}" y1="${a[1].toFixed(1)}" x2="${b[0].toFixed(1)}" `
         + `y2="${b[1].toFixed(1)}" stroke="#55504a" stroke-opacity="0.55" stroke-width="1.2"/>`;
  }
  return out;
}

function drawStock() {
  const pts = [], t = STOCK.t;
  for (let i = 0; i < t.length; i += 4) pts.push(px(t[i], t[i + 1]));
  let out = "";
  for (let i = 0, k = 0; i < t.length; i += 4, k++) {
    out += border(pts[k][0], pts[k][1], t[i+3], "#8c8378");
  }
  out += links(STOCK.l, pts);
  for (let i = 0, k = 0; i < t.length; i += 4, k++) {
    const [cx, cy] = pts[k];
    out += `<circle cx="${cx.toFixed(1)}" cy="${cy.toFixed(1)}" r="${t[i+2].toFixed(1)}" `
         + `fill="#8c8378" stroke="#241f1a" stroke-width="0.8" stroke-opacity="0.65"/>`;
  }
  document.getElementById("stock").innerHTML = out;
}

function indexOf(a, b, c, d, e) {
  return ((((a * DIMS[1] + b) * DIMS[2] + c) * DIMS[3] + d) * DIMS[4] + e);
}

function draw() {
  const idx = [0, 1, 2, 3, 4].map(i => +document.getElementById("s" + i).value - 1);
  idx.forEach((v, i) => document.getElementById("v" + i).textContent = LABELS[i][v]);

  const combo = COMBOS[indexOf(idx[0], idx[1], idx[2], idx[3], idx[4])];
  const table = document.getElementById("statTable");

  if (!combo || combo.n) {
    document.getElementById("clustered").innerHTML = "";
    table.innerHTML = `<tr><th>Result</th><td class="warn">no change</td></tr>`
                    + `<tr><th>Reason</th><td>${combo ? combo.n : "not computed"}</td></tr>`;
    return;
  }

  const t = combo.t, pts = [];
  for (let i = 0; i < t.length; i += 6) pts.push(px(t[i], t[i + 1]));

  let out = "";
  for (let i = 0, k = 0; i < t.length; i += 6, k++) {
    const kind = t[i + 3], orig = t[i + 5];
    const colour = kind === 2 ? "#8c8378" : COLOURS[(t[i + 2] - 1) % COLOURS.length];
    const r = (BORDERS[orig] ?? 0) * (kind === 2 ? ISO_BORDER : 1);
    out += border(pts[k][0], pts[k][1], r, colour);
  }
  out += links(combo.l, pts);

  for (let i = 0; i < combo.f.length; i += 3) {
    const k = combo.f[i];
    const a = px(combo.f[i + 1], combo.f[i + 2]), b = pts[k];
    out += `<line x1="${a[0].toFixed(1)}" y1="${a[1].toFixed(1)}" x2="${b[0].toFixed(1)}" `
         + `y2="${b[1].toFixed(1)}" stroke="#2b2b2b" stroke-opacity="0.17" `
         + `stroke-width="0.7" stroke-dasharray="2,3"/>`
         + `<circle cx="${a[0].toFixed(1)}" cy="${a[1].toFixed(1)}" r="1.3" `
         + `fill="#2b2b2b" fill-opacity="0.22"/>`;
  }

  for (let i = 0, k = 0; i < t.length; i += 6, k++) {
    const [cx, cy] = pts[k];
    const centre = t[i + 2], kind = t[i + 3], isCentre = t[i + 4], orig = t[i + 5];
    let r = RADII[orig] ?? 2;
    if (kind === 2) r = Math.max(1.8, r * ISO_SCALE);
    const fill = kind === 2 ? "#8c8378" : COLOURS[(centre - 1) % COLOURS.length];
    out += `<circle cx="${cx.toFixed(1)}" cy="${cy.toFixed(1)}" r="${r.toFixed(1)}" `
         + `fill="${fill}" stroke="#241f1a" stroke-width="0.8" stroke-opacity="0.65"/>`;
    if (isCentre) {
      out += `<circle cx="${cx.toFixed(1)}" cy="${cy.toFixed(1)}" r="${(r + 3.2).toFixed(1)}" `
           + `fill="none" stroke="${fill}" stroke-width="1.4"/>`;
    }
  }
  document.getElementById("clustered").innerHTML = out;

  const row = (k, v) => `<tr><th>${k}</th><td>${v}</td></tr>`;
  table.innerHTML =
      row("Clusters", `${combo.z.length} &nbsp; (${combo.z.join(" / ")})`)
    + row("Largest vs smallest", combo.sp ? combo.sp.toFixed(1) + "&times;" : "n/a")
    + row("Size ratio drawn", combo.r.toFixed(3))
    + row("Moved", combo.mv)
    + row("Left in place", combo.st)
    + row("Isolated", combo.is)
    + row("Stranded", combo.sd > 0
        ? `<span class="warn">${combo.sd}</span>` : combo.sd)
    + row("Nearest-neighbour median", combo.gm + " m")
    + row("Nearest-neighbour min", combo.gn + " m &nbsp;(floor "
        + SPACINGS[idx[4]] + " m)")
    + (combo.bg > 0
        ? row("Closest border gap", combo.bq + " m")
          + row("Borders meet once towns grow", combo.bg.toFixed(2) + "&times;")
        : "");
}

for (let i = 0; i < 5; i++) {
  document.getElementById("s" + i).addEventListener("input", draw);
}
drawStock();
draw();
]==])
w("</script>")
w("</body></html>")

local file, werr = io.open(options.out, "wb")
if file == nil then
	io.stderr:write("could not write " .. options.out .. ": " .. tostring(werr) .. "\n")
	os.exit(1)
end
file:write(table.concat(html, "\n"))
file:close()

print(string.format("%d towns, %d settings precomputed (%d no-ops)",
	#towns, computed, noops))
print("wrote " .. options.out)
