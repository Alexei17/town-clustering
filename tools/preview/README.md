# The studio — tuning the clustering without starting a game

```powershell
.\tools\studio.ps1 -Open
```

Builds one self-contained HTML page with every mod slider on it. Moving a slider
redraws the map instantly: the stock layout on the left, the clustered one on the
right, with the numbers worth tuning against underneath.

Opening it needs nothing — no server, no network, no toolchain. Building it needs
Lua 5.4 (`winget install DEVCOM.Lua`).

## There is no second implementation

The page runs no clustering of its own. Every combination of the five sliders —
6 × 4 × 5 × 4 × 4 = 1920 — is computed when the page is built, by
`mod/town_clustering_1/content/clustering_core.lua`, the file the mod itself runs
in game. The browser only swaps between the results. Marker and border radii are
precomputed for the same reason.

That is the whole point of the core having been split out of the Teal. All 1920
take a few seconds, so a JavaScript copy of the geometry would buy nothing and
would drift from the mod exactly when it was being used to tune it.

The page comes to a few MB, most of which is the terrain and the per-combination
town positions.

## What to look at

The map panels show which towns stayed, which moved (dotted line back to where
the generator had put them), which were left isolated, and which town is each
cluster's centre.

Each town also carries a **border**: the halo around it is how far its own
buildings actually reach. The game draws borders natively and exposes no radius
to Lua, so the snapshot measures the positions of each town's buildings instead
and records the 90th percentile distance from the centre. A snapshot taken
before this existed has no borders in it; take a fresh one.

Two numbers come out of that, and they matter more than the picture:

- **Closest border gap** - how much clear ground is left between the nearest two
  towns.
- **Borders meet once towns grow** - the factor every town can grow by before
  that pair runs together.

The second is the one to tune against. Extents are measured at the *start* of a
game, when towns are at their smallest, so "do the borders overlap right now" is
almost always no and tells you nothing; what a setting really decides is how much
growth it leaves room for. Measured on a real map: the generator's own layout
tolerates about 4.2x, the 600 m floor about 1.4x, and 1300 m about 3x. A cluster
at 1.4x is one that will visibly run together part-way through a game.

Be aware of the scale when reading the halos. A town's real extent is around
200 m, and on a map 41 km across that is only a few pixels however it is drawn -
the marker is capped against the border so the ring stays visible, but the halos
are there to show you *which* towns are involved, not to be measured by eye.

The numbers under them are the part worth tuning against:

- **Nearest-neighbour median** against the `MIN_TOWN_SPACING` floor. The core's
  own comment records why this matters: taking the first spot that fit packed
  every cluster into a lattice sitting 3% above the floor, and "that reads as
  machined". A median only just above the floor means the clusters are a grid
  again.
- **Largest vs smallest**, against the table in the top-level README — Equal
  should come out near 1.2x, Lopsided near 4.5–5x.
- **Stranded**, the towns that wanted to move and found nowhere to go. More than
  a couple means the neighbourhood rules are too tight for this terrain;
  `MAX_SLOPE_DROP` is the knob.

## Snapshotting a real map

To see what a **particular seed** will look like, the game has to generate it
once — the terrain comes from a 325-node generator graph and the town placer is
native C++, so neither can be reproduced offline. The point of a snapshot is that
you pay for that once per seed rather than once per experiment.

Once per seed:

1. Enable Town Clustering and set **Debug: Map Snapshot** to **Snapshot Only**.
2. Start a new game on the seed you want. The mod records the map on the first
   tick and leaves the towns exactly where the generator put them.
3. When the log says `snapshot complete`, quit. Nothing was changed.
4. Recover it:

```powershell
.\tools\snapshot.ps1 -Name alpine -Preview
```

Then every setting is about a second:

```powershell
.\tools\preview.ps1 -Snapshot snapshots\alpine.lua -Count 6 -Variation 4 -Open
```

Set **Debug: Map Snapshot** back to Off for normal play.

What this buys: the rebuild's waits — up to 240 ticks for towns to appear and up
to 1200 for populations to settle — leave the loop entirely. They were the long
part, and they were being paid per experiment.

### Why the log, and not a file

The snapshot goes out through `log.message` into `crash_dump/stdout.txt`, which
looks odd until you try the alternatives:

- `app.saveUserdata` would be ideal, but `app` is **GUI-state only** — no script
  under `base/` outside `gui.zip` touches `app.*` — so a game script cannot reach
  it. Getting at it needs a GUI-state script hung off `react-replacement-config`,
  and that is the part of the API where a mistake blocks game loading until the
  mod is removed.
- `io` and `os` appear **nowhere** in any of the game's shipped scripts, so
  whether they survive the sandbox is unknown and could not be checked without a
  game launch.

The log is the one channel the mod already relies on and that is known to work. A
385×385 grid costs about 0.9 MB of log, which is nothing, and `from_log.lua` reads
it back exactly — `selftest.lua` checks the round trip.

### Not the Map Editor

The Map Editor looks like the obvious no-code route, and it is **wrong for a
specific seed**. Its terrain generation sets `mode.generateTowns = false`, and it
places towns through a separate path driven by an explicit count
(`numTownsToAdd`), where the new game dialog uses `generateTowns = true` with the
Town Density parameters (`townFrequency`, `populationDensity`,
`maxNumberPerArea`). Terrain for a given seed should match; the town positions
come from different inputs and will not reliably be the ones your new game would
produce.

Its *Export Towns & Industries* is still a perfectly good way to get **a** real
map to tune against in general — the previewer reads that file shape directly,
since `app.saveUserdata` writes a plain Lua table. Just do not expect it to
answer "what will this seed give me".

## Snapshot format

```lua
return {
  -- exactly the game's own export shape; `{ x = , y = }` also works
  towns = {
    { position = { x = 1200, y = 3400 }, name = "Ashford",
      sizeFactors = { 1.0, 1.0, 1.0 },
      -- optional: the town's measured built radius, metres from its centre
      extent = { buildings = 48, p50 = 210.4, p90 = 383.1, furthest = 512.7 } },
  },
  industries = {},          -- ignored by the previewer

  -- optional
  terrain = {
    originX = 0, originY = 0,
    cols = 385, rows = 385,  -- samples
    step = 32,               -- metres between samples
    waterLevel = 0,          -- GameMap.waterLevel
    heights = { ... },       -- row-major, cols * rows entries
    water = { [0] = "0010...", ... },  -- optional, one 0/1 string per row
  },
}
```

`water` is the engine's own `isOnWater` answers, recorded when the map was
dumped. When it is there the previewer uses it, because that is the question the
clustering actually asks; without it, water is inferred from height against
`waterLevel`, which is close but is a guess. The page says which it used.

## Testing the snapshot path

```powershell
lua tools\preview\selftest.lua
```

Emits a snapshot of the synthetic map in the mod's own log format, parses it
back, and checks the towns, heights and water mask survived. Worth running after
touching either `snapshot.lua` or `from_log.lua`, since the real thing costs a
game start to test and a format mistake would not surface until then.

## Fidelity

Exact — it is the same code, reached through the same slider indices:

- which towns become centres, and the farthest-point sampling that picks them
- cluster size weights, the ratio drawn per map, and the shuffle across centres
- which towns stay, move or are left isolated
- ring-and-jitter placement, the spacing floor, and the deterministic RNG
- the buildability test, **when the snapshot carries terrain**

Not exact:

- **Roads.** `getDefaultTownConnections` is the engine's, and is not available
  offline. The thin lines are the mod's *own* stitching (`stitchConnections`) run
  over an empty proposal, so the long links between clusters are real; the short
  roads inside a cluster are the engine's business and only approximated.
- **What the engine then does.** Towns that are created but never grow — the
  empty-town sweep in phase 2 — cannot be predicted from geometry. A town shown
  here may still come out empty in game.
- **Tie-breaks.** Two `table.sort` calls in the core compare values that can tie.
  PUC Lua sorts the same way in both places, so this has not been seen to differ,
  but it is the first thing to suspect if a preview and a game run ever disagree.

## Requirements

Lua 5.4 (`winget install DEVCOM.Lua`, which also brings LuaRocks — handy if you
later want `tl` for real Teal type-checking against `tlconfig.lua`). Nothing
else; the previewer writes plain HTML and SVG and has no dependencies.
