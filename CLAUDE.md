# Town Clustering

Town Clustering is a mod for Transport Fever 3. In standard map generation towns
are distributed uniformly across the map. This mod leaves dense groups of towns
separated by empty countryside.

## How it works

Towns are placed natively in C++ while the new game dialog is open, and no mod
code runs in the menu, so there is no hook for *placing* towns differently. The
mod therefore lets generation finish untouched and then **redistributes** towns
on the first tick of the new game: the towns nearest a set of chosen cluster
centres keep their generated position, the rest are destroyed and re-created
next to a cluster, and the inter-town road network is rebuilt.

Cluster sizes follow a geometric series whose ratio is drawn per map from the
range the `cluster.variation` slider selects (`VARIATION_RATIO_MIN` ..
`VARIATION_RATIO_MAX`, floored by `SIZE_MIN_WEIGHT`), shuffled across the
centres.
Both the towns that stay and the towns that move are shared out by those
weights - weighting only the movers leaves the sizes barely a fifth apart,
because the towns that stay are spread evenly by geography.

The town count is preserved, so the player's Town Density choice still holds.
The rebuild uses the Map Editor's own town-import calls - `makeMapFromGame`,
`mapgen.createTowns`, then `makeTownDestroyCmd` / `makeTownCreateCmd`
(`gui/map_editor/map_editor.tl`, `makeTowns`).

See NOTES.md for the reverse-engineered details, including the terrain-generator
approach that was tried first and abandoned - its code has been removed, but the
node-tree findings are kept.

## Mod parameters

Declared in `mod/town_clustering_1/mod.json`; read back in the game script via
`api.engine.config.getModParams()`, which returns **1-based** indices into each
param's `values` list.

| key                | name           | values                               |
|--------------------|----------------|--------------------------------------|
| `cluster.count`    | Cluster Count  | 2 / 3 / 4 / 5 / 6 / 8                |
| `cluster.variation` | Cluster Sizes | Equal / Mild / Varied / Lopsided    |
| `cluster.keep`     | Towns Left In Place | 30% / 45% / 60% / 75% / 100%    |
| `cluster.isolated` | Isolated Towns | None / 5% / 10% / 20%                |

`cluster.keep` is the share of generated towns that keep the position the
generator gave them; the rest are moved next to a cluster. The total never
changes, so Town Density needs no adjustment. `cluster.isolated` is the share of
the moved towns left standing alone out in the country, scaled down so they read
as outlying hamlets.

There is no "cluster rate" parameter. An earlier draft specified one; it was
replaced by `cluster.keep` + `cluster.isolated`, which say the same thing in
terms the implementation can actually honour. A stale `cluster.rate`
entry may still sit in the game's `settings.lua` and is ignored.

## Layout

```
mod/town_clustering_1/      the publishable mod (deploy.ps1 installs this)
tealdef/                    this mod's .d.tl files; outside mod/ so deploy does
                            not ship a file _content.json does not list
tools/preview/              offline previewer, runs the core against a snapshot
```

## The core / game split

`content/clustering_core.lua` holds every decision about *where towns go*:
centres, cluster weights, which towns stay or move, ring-and-jitter placement,
the buildability test, and the connection stitching. It touches no `api.*`.
`content/town_clustering.script.tl` is the game half — it reads the world, hands
the core bare coordinates, and applies the plan with the engine's commands.

Changes here are meant to go upstream as pull requests, so **a new setting is
additive and its default reproduces current behaviour exactly**. `cluster.spacing`
is the worked example: `TOWN_SPACINGS[1]` is `MIN_TOWN_SPACING`, the existing
`FIRST_RING` and `RING_STEP` are kept and scaled from it by `core.geometry`, and
the game script needed no change at all because `resolveParams` reads the new
index on its own. Check a default run against the previous output before
proposing anything.

Two rules keep that seam worth having:

- **Geometry changes go in the core, not the Teal.** The previewer runs the core
  directly; anything that leaks back into the Teal stops being previewable.
- **The core never learns about the game.** The three terrain questions arrive as
  an injected adapter, and towns come back by `index` into the caller's own list,
  so `GameMap.Town` never has to cross the seam.

It is plain Lua rather than Teal so the previewer needs only a stock interpreter
(`winget install DEVCOM.Lua`); `tealdef/clustering_core.d.tl` carries the types so
the game still type-checks the caller, and `all_def.tl` requires it.

`content/snapshot.lua` sits on the same seam: it records a generated map into the
log so a seed can be replayed offline, and reaches terrain through the same
adapter, so it is testable without the game.

After changing the core, run `.\tools\studio.ps1` before deploying — it runs the
core 480 times in about a second, so a plan that breaks under some combination of
sliders shows up without a map generation. After changing `snapshot.lua` or
`from_log.lua`, run `lua tools\preview\selftest.lua`, which round-trips a snapshot
through the log format and checks what comes back.

The page builders share `tools/preview/mapdata.lua` — snapshot reading, the
terrain adapter and the ground drawing. Nothing about the clustering lives there,
and neither builder may reimplement any of it in JavaScript: the studio
precomputes every combination with the core instead, which costs a second and
keeps one implementation.

## Getting data out of a game script

There is no file writing available: `app.saveUserdata` is GUI-state only, and
`io`/`os` appear nowhere in the game's own scripts (NOTES.md). `log.message` into
`crash_dump/stdout.txt` is the only channel known to work, which is why the
snapshot is a log format with a parser rather than a file.

## Conventions

- All files are LF (`.gitattributes` pins this); `core.autocrlf` must not win.
- `mod.json` param indices are 1-based - confirmed against the stock climate
  generators in `base/content/climates.zip`, which default to index 3 of
  `[Sparse, Scattered, Medium, Dense, Packed]`. The core's `resolveParams` is the
  single place those indices become numbers, so the mod and the previewer cannot
  disagree about what an index means.
- `.gs.lua` game scripts run in the game state; never `require` anything under
  `::/gui/...` from them. `app.*` is GUI-state only and is not reachable from the
  game script either (see NOTES.md).
- New files under `content/` must be listed in `_content.json`.
