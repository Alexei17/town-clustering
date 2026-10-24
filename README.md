# Town Clustering

A mod for **Transport Fever 3**. The stock map generator spreads towns evenly
across the map; this mod leaves dense groups of towns separated by empty
countryside, which gives inter-city lines somewhere to actually go.

![Town Clustering](mod/town_clustering_1/_metadata/0.png)

## How it works

Towns are placed natively in C++ while the new game dialog is open, and no mod
code runs in the menu, so there is no hook for *placing* towns differently.

So the mod lets generation finish untouched and rearranges afterwards, on the
first tick of the new game:

1. Pick cluster centres by farthest-point sampling, so they spread across the
   map without needing to know the map size.
2. Give each cluster a size: weights from a geometric series, so one
   conurbation dominates, a couple are middling and one is a modest group.
3. Leave the towns nearest a centre exactly where they are, up to that
   cluster's share.
4. Rebuild each remaining town next to a cluster, on a spot checked for water,
   slope and elbow room first.
5. Leave a few out in the country and scale them down, so they read as outlying
   hamlets.
6. Lay out the inter-town road network again, stitching the clusters together so
   every town stays reachable.

**Cluster Sizes** is why the map does not look generated. Equal clusters are a
giveaway, so by default one conurbation dominates and the rest trail off. The
exact shape is drawn per map and which centre gets the big one is shuffled, so
the same setting looks different on a different seed:

| Setting  | Largest vs smallest, 40 towns in 4 clusters |
|----------|---------------------------------------------|
| Equal    | 1.2x - the same size bar rounding           |
| Mild     | 1.2x to 2x                                  |
| Varied   | 3.5x to 4x (default)                        |
| Lopsided | 4.5x to 5x - one city region, small satellites |

**The town count never changes** - towns are relocated, not deleted, so your Town
Density setting still means what it says. Terrain, rivers and industries are
left exactly as the stock generator made them.

## Settings

| Setting             | Values                       | Meaning                                               |
|---------------------|------------------------------|-------------------------------------------------------|
| Cluster Count       | 2 / 3 / 4 / 5 / 6 / 8        | How many groups to form                               |
| Cluster Sizes       | Equal / Mild / Varied / Lopsided | How much the clusters differ in size              |
| Towns Left In Place | 30% / 45% / 60% / 75% / 100% | Share that keeps its generated position; the rest move |
| Isolated Towns      | None / 5% / 10% / 20%        | Share of the moved towns left standing alone          |
| Town Spacing        | 600 / 800 / 1000 / 1300 m    | How close together towns in a cluster may stand       |
| Debug: Map Snapshot | Off / Snapshot Only / Snapshot, Then Cluster | Developer tool: record the generated map so it can be explored offline |

**Town Spacing** is worth a word, because clusters sit almost exactly on whatever
it is set to. Measured across a generated map, every cluster settled within about
40 m of the 600 m floor — the lattice `findSpot`'s comment warns about — while the
engine's own towns were a 2.6 km median apart.

What that costs is room to grow. Each town's border — how far its buildings
actually reach — is about 200 m at the start of a game, and towns grow from
there. Measured on a real map, the nearest two borders meet once every town has
grown by:

| Spacing | Closest border gap | Borders meet at growth |
|---------|--------------------|------------------------|
| as generated | 1457 m | 4.2x |
| 600 m   | 172 m | 1.4x |
| 800 m   | 385 m | 1.9x |
| 1000 m  | 525 m | 2.1x |
| 1300 m  | 882 m | 3.0x |

At the 600 m floor a cluster runs together once its towns are 40% bigger, which
is part-way through a game. 600 m is the original behaviour and the default, so
the setting changes nothing until it is moved.

Loosening it needs more buildable ground, so watch the previewer's *stranded*
count on a cramped or mountainous map.

No need to touch Town Density: the mod moves towns rather than removing them, so
the count you chose is the count you get.

## Installing
The easiest way is to subscribe to the mod through [mod.io](https://mod.io/g/transportfever3/m/town-clustering).

```powershell
.\deploy.ps1
```

Then restart the game - mods are read at startup. Enable *Town Clustering* in the
mod list before starting a new game.

The mod only needs to be active when the game starts; afterwards it does nothing
and can safely be removed from the savegame. Adding it to an established save does 
nothing at all - it refuses to run once more than ten game days have passed, rather 
than rebuild towns out from under you.

## Publishing

Publishing goes through the in-game mod manager (mod.io), which only reads the
**staging area** - not the mods folder:

```powershell
.\deploy.ps1 -Staging     # copy to staging_area\
.\deploy.ps1 -Validate    # copy, then run the game's own mod validator
```

Then open the Mod Manager in-game, validate and publish from the staging entry.
The validator grades PC and console separately, so a mod that is fine on PC can
still report console-only problems.

`mod.json` → `url` and `_metadata/modinfo.json` → `url` stay empty until the
mod.io page exists; fill both in afterwards.

`_metadata/0.png` is the listing image, 1920×1080 to match the shipped mods. It
is a drawn illustration, **not a screenshot** - see below.

## Repository layout

```
mod/town_clustering_1/      the publishable mod; deploy.ps1 installs this
  mod.json                  manifest: id, revision, params, severities
  _content.json             content file list
  _metadata/modinfo.json    name, summary, description, authors, tags
  _metadata/0.png           listing image (1920×1080)
  content/town_clustering.gs.lua     registers the game script
  content/clustering_core.lua        the clustering itself, with no game API
  content/snapshot.lua               records a generated map into the log
  content/town_clustering.script.tl  the game half: world in, commands out
tealdef/                      types for those two; outside mod/ so they are not shipped
art/listing-pruned.png      listing image for the older pruning behaviour
tools/make_listing_image.ps1  redraws the listing image
tools/studio.ps1              interactive: all four sliders on one page
tools/snapshot.ps1            recovers a logged map snapshot for the previewer
tools/preview/                the studio builder, shared map handling,
                              the snapshot reader and a self-test
NOTES.md                    reverse-engineered TF3 modding notes
```

`clustering_core.lua` holds every decision about *where towns go*; the Teal file
reads the world, hands it the towns and applies what comes back. The core touches
no `api.*`, which is what lets the previewer run the real algorithm rather than a
copy of it. It is plain Lua rather than Teal so that the previewer needs only a
stock interpreter.

### The listing image

`tools/make_listing_image.ps1` draws it with GDI+, so it can be regenerated
rather than re-edited by hand. It is a stylised map, not a capture of the game -
there is no real screenshot in this repository yet. Two variants:

```powershell
.\tools\make_listing_image.ps1 -Variant arrows   # towns pulled together (current 0.png)
.\tools\make_listing_image.ps1 -Variant pruned   # towns between clusters struck out
```

`arrows` is the accurate one, and is what `0.png` holds: the mod really does move
towns together, and keeps the count the same. `pruned` depicts the earlier
behaviour, when towns between the clusters were deleted outright; it is kept
because it shows more plainly where the empty countryside comes from.

Replace either with a real annotated in-game screenshot when there is one.

## Previewing without starting a game

Trying a setting in game costs a map generation plus a few minutes of ticks while
towns build and the mod waits to see which came out empty. The studio runs the
clustering against a map that was generated once, and puts every slider on one
page: the stock layout on the left, the clustered one on the right, redrawn as
you move a slider.

```powershell
.\tools\studio.ps1 -Open
```

It runs `clustering_core.lua` itself, so what it shows is what the mod will do.
Every slider combination — 1920 of them, a few seconds — is precomputed and baked
into one self-contained page, so there is no JavaScript copy of the algorithm to
drift from the mod, and no server or network is needed to open it.

Under the maps are the numbers worth tuning against: the nearest-neighbour median
against the spacing floor (a median only just above the floor means the clusters
have become a lattice again), largest-vs-smallest against the table above, how
many towns were stranded, and how much the towns can grow before their borders
run together.

With no snapshot it uses a synthetic map, so it runs out of the box.

### Previewing a particular seed

A seed's terrain and town positions can only come from the game: the terrain is a
325-node generator graph and the placer is native C++. So the game generates it
**once**, and every experiment after that is offline.

1. Set **Debug: Map Snapshot** to *Snapshot Only* and start a new game on that seed. The
   mod records the map on the first tick and leaves the towns alone.
2. When the log says `snapshot complete`, quit. Nothing was changed.
3. Recover it and look:

```powershell
.\tools\snapshot.ps1 -Name alpine -Preview
.\tools\studio.ps1 -Snapshot snapshots\alpine.lua -Open
```

The rebuild's waits — up to 240 ticks for towns to appear, up to 1200 for
populations to settle — leave the loop entirely, instead of being paid once per
setting you want to try. Set **Debug: Map Snapshot** back to Off for normal play.

The snapshot travels through the log rather than a file because `app.saveUserdata`
is GUI-state only and `io`/`os` appear nowhere in the game's own scripts; see
`tools/preview/README.md`.

Needs Lua 5.4: `winget install DEVCOM.Lua`.

## Development

The game compiles `.tl` at load time and reports failures to
`crash_dump/stdout.txt`. `tlconfig.lua` is there for editor type-checking against
the game's shipped `tealdef` definitions, plus this mod's own
`tealdef/clustering_core.d.tl`; it needs `tl` on PATH, which the Lua install
above can supply through LuaRocks.

The mod logs with the prefix `[town-clustering]`. If that prefix never appears in
the log, the game script never ran.

## How this was built

Written with [Claude Code](https://claude.com/claude-code), in a back-and-forth with the author: 
the author played the game, decided what the mod should do and judged every result; Claude Code 
was used for reverse engineering, wrote the Teal and the tooling, and read the crash dumps.

Everything in NOTES.md was derived from the game's shipped
`tealdef` definitions, its own Lua and Teal under `base/` and `mods/release/`,
and the logs and minidumps in `crash_dump/` - including the two access
violations that the connection-index bug turned out to be.

The listing image is drawn by a script in `tools/` rather than painted, for the
same reason: so it can be regenerated and reviewed rather than fiddled with.

## Licence

MIT - see [LICENSE](LICENSE).
