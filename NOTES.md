# Transport Fever 3 modding notes

Reverse-engineered from the shipped `api/tealdef` definitions and base game
scripts. `wiki.transportfever3.com` returns Permission Denied, so none of this
is from documentation — treat it as findings, and re-verify after game patches.

Paths below are relative to the install:
`C:\Program Files (x86)\Steam\steamapps\common\Transport Fever 3`

## Where town positions come from

A new game's towns are generated **in the menu, in C++**, not in Lua:

1. `gui/menu/new_game_or_map_settings_page.tl` builds an *empty* map with
   `app.makeEmptyMap(...)` and a `HeighmapGenerationMode` with
   `generateTowns = true`.
2. It hands both to the native `builtin.MapPreviewComp`, along with `seed`,
   `locationsConfig` and the terrain generator params.
3. The component generates heightmap + towns + industries and returns the
   finished `GameMap` via `onReady`, which stores it in `mapState`.
4. `app.startGame2(map, ...)` (line ~628) starts the game from that map.

So the `GameMap` handed to `startGame2` already contains final town positions.
Rewriting `map.towns` between step 3 and step 4 is the whole mod.

`BaseConfig.Locations.TownParamList` exposes only `townFrequency`,
`populationDensity`, `maxNumberPerArea` and `allowInRoughTerrain` — density,
never spatial pattern. There is no native clustering knob.

## Mod layout

Modelled on `mods/release/urbangames_sandbox`:

```
<modid>/
  mod.json                  modId, revision, params, pre/post/runScript, severity*
  _content.json             { "archives": null, "files": [ ... ] }  paths under content/
  _metadata/modinfo.json    name, description, authors, tags
  content/...
```

Resource names drop `content/`. Whether they also drop the extension depends on
what is doing the addressing, and getting it wrong costs a game launch:

| used by | form | example |
|---|---|---|
| script hooks in `mod.json` and `.gs.lua` | **no** extension | `<modid>::/foo.script@update` |
| `ug_require` | **with** extension | `<modid>::/foo.lua`, `::/scripts/entity_util.tl` |

The base game's own calls settle the second row - `ug_require "::/scripts/mathutil.lua"`,
`ug_require "/gui/main/react.lua"`, `ug_require "main_page.tl"` (a bare relative
name also works for a sibling file). An empty modid, as in `::/scripts/...`, means
the base game.

Dropping the extension in a `ug_require` fails at load with
`module '<modid>::/<name>' not found`, logged once per worker thread, and the
game script never runs - the mod otherwise loads and appears active, so the only
symptom is silence in the log.

Script hooks in `mod.json` use `"<modid>::/<file>.script@<fn>"`.
`preRunFn(captureParams, configDict, allModParams, baseConfig)` is where
`baseConfig.*` is tweaked — see `base/mod.script.tl:16`.

## GUI extension

`gui/main/bootstrap_game.tl` reads every generic resource of type
`react-replacement-config` and calls `<filePath>@<doReplaceFn>(api)` exactly
once, before any recipe runs. The callback gets `api.ReplaceRecipe(original,
replacement)`.

A generic resource is a `.res.lua` returning `{ type = "...", data = {...} }`.

Replacement works on **builtins** too — `GloballyReplaceRecipeBeforeInitInternal`
just writes `_react.recipeReplace[recipeId]` (`gui/main/react.lua:445`). Only
`react.CallOriginalRecipe` refuses builtins (`react.lua:459`). The dispatcher
reads the replacement table at *call* time (`react.lua:383`), so you can reach
the original by clearing your own entry around the call. `react.GetRecipeId` is
exported (`react.lua:742`).

Replacements are keyed by recipe id globally, and a replacement must itself be a
registered recipe (`react.RegisterRecipe`) or hooks inside it will run in the
caller's context.

## Lua states: mod hooks vs GUI (learned the hard way)

There is more than one Lua state, and a module must not straddle them.

A module referenced from `mod.json` (`preRunScript` / `postRunScript` /
`runScript`) is loaded in the **mod / game-init** state, on a `Load Game Pool`
thread. Requiring `::/gui/main/builtin.lua` there fails: `_react.builtin` is
empty, `DeclareBuiltinWithUserdata` logs `Missing builtin recipeId for`, and
game init aborts with `Could not init game` and a "please remove mod" dialog.

So the split is mandatory:

| file | state | referenced from | may require `::/gui/...` |
|---|---|---|---|
| `town_clustering.script.tl` | mod / game-init | `mod.json` hooks | **no** |
| `town_clustering_gui.script.tl` | GUI | `react-replacement-config` | yes |

A broken mod here does not corrupt anything - the game refuses to start the
game and names the mod - but it does block loading until the mod is fixed or
removed.

## What the menu does and does not load

Confirmed by probing:

- `mod.json` **is** read in the main menu: the mod's `params` render as sliders
  on the mod settings page, the chosen indices persist to `settings.lua` under
  `mainMenuState.activeModsParamsState.<modid>`, and enabling the mod raises the
  "no achievements" warning.
- Nothing under `content/` was observed to run in the menu - not the
  `.res.lua`'s `data()`, not a `.gres.lua` shipped at a base content path.

So manifest-level activation is not the same as content being loaded. Still
open: whether content is genuinely never loaded in the menu, or whether
resource `data()` results are served from the content cache the log mentions
("Reading content cache from json for dir ..."). The `preRunFn` probe is there
to settle it.

## Open questions (Phase 0 spike)

1. ~~**Does `_reactDoReplaceRecipes` run for the menu UI state at all?**~~
   **Answered: no, and the menu cannot be modded at all.** Settled by reading
   `gui.zip` rather than by probing:

   - `react-replacement-config` is read in **exactly one file** in the whole of
     `gui.zip` — `gui/main/bootstrap_game.tl`, which defines
     `global _reactDoReplaceRecipes` and is reached only from `gui/main/game.lua`,
     the in-game entry point.
   - `gui/menu/main_menu.tl` contains none of that machinery: no `genericRep`,
     no `getAllOfType`, no bootstrap, no replacement call. Nothing on the menu
     path ever defines or calls `_reactDoReplaceRecipes`.
   - `doReplacements()` ends by setting `_react.recipeReplacementAllowed = false`,
     so even reaching `GloballyReplaceRecipeBeforeInitInternal` later is refused
     (`react.lua:446`).

   So no mod can replace a menu recipe, and the seam a menu-side approach would
   need — `builtin.MapPreviewComp`'s `onReady` storing into `mapState`, which
   `app.startGame2` then reads (`new_game_or_map_settings_page.tl:829, 846, 618,
   628`) — sits inside a menu recipe, which is the one thing that cannot be
   replaced.

   **Consequences.** Rewriting `map.towns` between generation and `startGame2`
   is not reachable, so the tick-1 rebuild is not a design choice that could be
   tidied away later: it is forced. Nor can a mod draw anything in the new game
   dialog, so a clustered preview beside the stock map preview is out. The only
   mod-reachable lever on that dialog remains a custom terrain generator
   (`.gen.lua`, confirmed in-game to appear in the dropdown), which has no town
   output and no UI.

   Seeing the clustering before starting a game therefore has to happen outside
   the game — which is what `tools/preview` is for.

   Questions 2 and 3 below are moot as a result; they are kept because they
   describe the shape of the thing that was being attempted.
2. Can a replaced builtin be called through to, via the clear/restore trick?
3. Does handing a `GameMap` back as `initialMap` make the preview draw *our*
   towns, or is `initialMap` only read at mount? Fallback is `inputMap` with
   `generateTowns = false` — flip `FEEDBACK_MODE` in the script.
4. How is `GameMap.heightmap` indexed relative to `numTilesX/numTilesY` and
   `resolution`, and what is the shape/range of `Town.sizeFactors`? The *fields*
   are now known — see "Getting a map out of the game" below — but the indexing
   itself is still only what the declaration implies, not something that has
   been read back from a running game.

A `MapPreviewComp`-level wrapper probably **cannot** read the mod's own slider
values: they live in `activeModsParamsState`, a react state threaded through the
*page*, and there is no `app`-level accessor in the menu
(`api.engine.config.getModParams()` is engine-side, in-game only). Agreed
fallback is to fork the page recipe, which has both in scope, wrapped in `pcall`
with `CallOriginalRecipe` so a patch degrades to the stock dialog.

## Terrain generators and node trees (a road not taken)

This was the first approach: a mod-supplied climate generator whose node graph
roughens everything outside a few broad basins, so the flat buildable ground the
town placer needs survives only inside them. It works, and it is the only lever
the new game dialog exposes - but it buys clustering by deforming the whole map,
and the game script supersedes it. The code and its two build tools have been
removed; the findings are kept here because they were expensive to get and
nothing else documents them.

A terrain generator is a `.gen.lua` declaring `nodeTree` + `params` (the
sliders). Mod-supplied generators **do** appear in the new game dialog's
generator dropdown - confirmed in-game - which makes this the only mod-reachable
lever on the free game dialog. It is how the "Flatter Maps" mod works.

A node tree (`.tree.lua`, ~139KB for temperate) is a saved node-editor graph:
a flat list of nodes linked **by name**, which makes splicing easy.

```lua
{
    color = { ... },
    inputs = { in1 = { key = "out", nodeName = "<other node>" }, },
    layerType = "add_map",
    name = "<unique>",
    params = { ... },
    position = { x, y, },
}
```

Temperate has 325 nodes across 45 layerTypes. Outputs are only
`height_map_output`, `output_biomes` and `assets_output` - **there is no town
output**, so a generator can only shape terrain and let the placer react.

Sliders enter the graph as `param_number` nodes with `params = { key = "mountains" }`,
matching a `params` entry in the `.gen.lua`. Node params can also be driven by
wires: some stock `map_clamp_map` nodes take `from`/`to` as inputs rather than
params. That is the route to a real "cluster count" slider.

There is an in-game node editor (`menu.mapEditor.nodeEditor.window`, button in
the Map Editor game bar; `local/autosave.tree.lua.bak` is its scratch file).

### Gotcha: output keys are not always "out"

An input references a producer as `{ key = <output name>, nodeName = <node> }`.
Most nodes publish their result as `out`, but the `gui/node_editor/*.node`
subgraph types do not:

| producing layerType | output key |
|---|---|
| `gui/node_editor/remap_number.node` | `output` |
| `gui/node_editor/combine_point.node` | `point` |
| everything else seen so far | `out` |

Using the wrong key fails during generation with
`Assertion 'it != map.end()' failed` (`map_util.h:22`, `Get`) - the same
message you get for a missing parameter, with nothing naming the node at
fault. The valid output keys per layerType can be derived from how the stock
trees use them, which is worth doing before handing a tree to the game.

### Driving node params from a slider

A `.gen.lua` slider reaches the graph as a `param_number` node whose `params.key`
matches the slider key. It outputs a **normalised 0..1**, which the stock trees
then map onto a useful range with `gui/node_editor/remap_number.node`
(`params a_x/a_y` = input range, `b_x/b_y` = output range, `clamp`).

Most node params can also be driven by a wire instead of a literal, but only
where the node actually exposes that input. Useful cases found by scanning all
four stock trees:

| node | wireable inputs seen |
|---|---|
| `ridged_noise_map` | `baseFreq`, `gain`, `lacunarity`, `numOctaves`, `seed` |
| `map_clamp_map` | `in1`, `from`, `to` (`from`/`to` are **points**) |
| `distance_map` | `threshold` |
| `white_noise_map` | `probability` |
| `mul_number` / `add_number` | `in1`, `in2` |

`constant_number`, `constant_point`, `constant_map` and `param_number` never
take inputs - they are pure sources. To turn numbers into a point (needed for
`map_clamp_map.from`/`to`) use `gui/node_editor/combine_point.node`, which takes
`x` and `y` as numbers.

`normalize_map` (`params range_x/range_y`) is worth using after any noise node
whose natural output range you do not know, so downstream thresholds are
meaningful.

### Gotcha: required inputs

A node missing a required input crashes map generation with an unhelpful
`GraphException: Missing input data`
(`layer_generator_util.cpp:142`, `DataHolder::StartTask`) - taking the whole
game down from the new game dialog.

`voronoi_noise_map` looks like the obvious tool for clusters but **requires a
`cellIndex` input** (all four stock trees wire one) and it is not clear what a
valid cell-index map is. `fractal_noise_map` needs only `seed`, so basins are
built from low-frequency noise instead.

Each layerType's required inputs can likewise be inferred from stock usage, and
a generated tree is worth validating against them before the game ever sees it:
both of these failure modes take the game down from the new game dialog with a
message that names no node.

## Environment

- TF3 is Steam appid **3493540**.
- User mods: `C:\Program Files (x86)\Steam\userdata\<id>\3493540\local\mods\`
  (`staging_area\` beside it is the other mod source, the one the exe's
  `--validate StagingArea,<mod>` CLI refers to).
- Log: `...\3493540\local\crash_dump\stdout.txt`.
- The exe also exposes `--validate`, `--validate-all`, `--and-cook`, `--exec`
  and `--script`, not yet explored.
- No Lua or Teal toolchain is installed, so `tlconfig.lua` is for an editor;
  the game compiles `.tl` at load time and reports failures to the log.

## Rebuilding town roads from a game script (learned the hard way)

`api.cmd.makeTownConnectWithIndustriesCmd(entities, connections, keep)` takes a
`keep` flag. `keep = false` means *remove the existing streets first*, then lay
out a fresh network.

Do not pass `false` from a game script in a running game. It crashed TF3
build 40408 with an access violation on the **Simulation Thread**
(`TransportFever3.exe+0xA4BD7`, read of a freed pointer) about three seconds
after the command was sent, with the minidump recorded while the engine was
still printing `Init streets add proposal error` lines for that same command.

The Map Editor uses `keep = false` safely because nothing is simulating there.
By the time a game script's first tick has created towns and waited for them to
appear, the world has buildings, industries and people in it, and removing every
street leaves the engine holding stale references.

`keep = true` adds the missing links instead and is the only safe option here.
The cost is cosmetic: `makeTownDestroyCmd` takes a town's own streets with it,
but an inter-town road that led to a destroyed town can survive as a stub.

### Connection indices are the engine's, not Lua's

`getDefaultTownConnections` returns "indices into the vector townEntities", and
that vector is C++ - the indices are **0-based**, while every list on the Lua
side is 1-based. Appending a 1-based pair to the returned list and sending it
back crashed the simulation thread twice, in the same engine function
(`TransportFever3.exe+0xA4BD7` and `+0xA4BE3`), reading out of range - the second
time from `0xFFFFFFFFFFFFFFFF`, which is what running off the end of that vector
looks like. Both crashes landed at the very end of the street layout, exactly
where the appended links sat.

Treating the engine's own indices as 1-based is quietly wrong in the other
direction: a guard of `index >= 1` drops every connection that touches town 0,
which invents components that are not really separate.

The mod now derives the base from the data instead of assuming: a zero anywhere
proves 0-based, a value equal to the town count proves 1-based, and if neither
appears the sample proves nothing and it sends the engine's proposal unaltered.

Two more things worth knowing about that command:

- `api.engine.mapgen.getDefaultTownConnections` is a **proposal**, not a
  complete network. The Map Editor merges it into the connections it already has
  ("Propose Default Connections", `gui/map_editor/map_editor.tl`). On a
  clustered map it leaves each cluster as its own island.
- Even a fully connected proposal is not a fully connected map. The engine
  refuses individual links with `Too Much Incline` or `Collision` and logs
  `Towns 'A' and 'B'  NOT connected`. The stock generator hits this too.

## Creating towns from a game script

`gui/map_editor/map_editor.tl` (`makeTowns`) is the worked example:

```
api.engine.terrain.makeMapFromGame(false, true, false, false)  -- current towns
api.engine.mapgen.createTowns(seed, desired)                   -- {toRemove, toAdd}
api.cmd.makeTownDestroyCmd / api.cmd.makeTownCreateCmd
```

A `GameMap.Town` carrying its `existing` entity is left alone; one without it is
built fresh. Any town in the world the list no longer names comes back in
`toRemove`. `makeMapFromGame` fills in names, `sizeFactors` and
`landUse2CargoNeeds`, so a relocated town can inherit its own identity instead of
having those fields invented.

Creation is asynchronous and not fast: 18 towns took about two and a half
minutes of game ticks to appear on a medium map.

## Getting a map out of the game (for offline work)

Found while building `tools/preview`, which runs the clustering against a map
that was generated once instead of generating one per attempt.

### `GameMap` carries everything the clustering needs

From `api/tealdef/api/type.d.tl`:

```
heightmap : {number}
numTilesX : integer     -- tiles of 256 m x 256 blocks
numTilesY : integer
levels : integer
offsetZ : number
waterLevel : number
climateId : string
resolution : Vec3f
towns : {GameMap.Town}
industries : {GameMap.Industry}
townConnections : {{integer, integer}}
```

Two of those matter more than they look:

- **`waterLevel`** means water does not need a separate mask. Rivers and lakes
  are carved into the terrain and filled to this height, so `isOnWater(p)` is
  reproducible offline as `heightAt(p) <= waterLevel`. That is what lets the
  core's buildability test run outside the game unchanged.
- **`townConnections`** is on the map itself, so the road network is available
  without calling `getDefaultTownConnections`.

`makeMapFromGame(withHeightmap, withTowns, withIndustries, withAssets)` is the
way to fill one in from a running game; the mod passes `false` for the heightmap
because it asks the engine about terrain point by point instead.

### The Map Editor already exports towns to disk

`gui/map_editor/map_editor.tl` (in `base/content/gui.zip`) has import/export for
both heightmaps and towns+industries. The towns side writes a **plain Lua
table**, which is why `local/towns_industries/` exists:

```lua
app.saveUserdata("towns_industries", name, {
    towns = { { name =, position = { x =, y = }, sizeFactors =,
                landUse2CargoNeedsCategories = }, ... },
    industries = { { position =, angle =, onWater =, tag =, fileName = }, ... },
})
```

`landUse2CargoNeedsCategories` keys are `"res"`, `"com"`, `"ind"` on the way out
and are mapped back to `LandUseType` on the way in. Import skips any entry whose
position fails `isValidCoordinate`.

So a generated map's towns can be had with no mod code at all, and the file can
be read straight into a tool — it is already Lua.

The heightmap side is `app.writeHeightmap(map, path, writeStl, sixteenBits,
biomesData)`, which writes an **image**, not numbers, and the export dialog has
its own water-level slider that the encoding is relative to. Decoding it was not
attempted; dumping `GameMap.heightmap` numerically through `saveUserdata` is the
cheaper route.

### `app` is GUI-state only

`app.saveUserdata` / `loadUserdata` / `getAllUserdata` / `removeUserdata` and
`writeHeightmap` all live on `app`, and **no script under `base/` outside
`gui.zip` touches `app.*`** — checked across `scripts.zip`, `game_mechanics.zip`,
`base.zip` and `economy.zip`.

A game script therefore cannot be assumed to reach it. Writing a snapshot from
the mod needs a GUI-state script hung off `react-replacement-config` (see "GUI
extension" above), in the state that is allowed to require `::/gui/...`. Not
written yet — the Map Editor's own export covers the towns in the meantime.

### Writing a file from a game script: you cannot, so use the log

Three channels were considered for getting a snapshot out of a running game:

| channel | verdict |
|---|---|
| `app.saveUserdata` | GUI-state only; unreachable from a game script |
| `io.*` / `os.*` | **no occurrence anywhere** in `scripts.zip`, `game_mechanics.zip`, `base.zip` or `gui.zip` — no precedent, and unverifiable without launching |
| `log.message` | already used by this mod, known to work |

So the snapshot goes out as log lines into `crash_dump/stdout.txt` and is read
back by `tools/preview/from_log.lua`. It looks crude and it is completely
reliable: a 385x385 terrain grid is about 0.9 MB of log, and the round trip is
covered by `tools/preview/selftest.lua`.

The grid is sampled through `api.engine.terrain.getHeightAt` and `isOnWater`
rather than taken from `GameMap.heightmap`, which sidesteps open question 4
entirely — no assumption about heightmap indexing is needed, and `isOnWater` is
recorded as the engine's own answer instead of being inferred from `waterLevel`.

Map extent comes from bisecting `isValidCoordinate` outwards from a town, for the
same reason: `numTilesX`/`resolution` would require knowing how the heightmap is
laid out.

### The Map Editor does not place towns the way a new game does

Worth knowing before trusting an editor export to represent a seed:

- The editor's terrain generation sets `mode.generateTowns = false`
  (`map_editor.tl`, the heightmap `computeMode`).
- Its towns come from `TownIndustryGenerationMode.numTownsToAdd` — an explicit
  count.
- The new game dialog instead uses `HeighmapGenerationMode.generateTowns = true`,
  driven by the Town Density parameters (`townFrequency`, `populationDensity`,
  `maxNumberPerArea`).

Different inputs, so for a given seed the editor's town positions are not
reliably the ones a new game would produce. Terrain should match. The editor is
fine for tuning against *a* real map; it cannot answer "what will this seed give
me".

### Town borders are native; measure the buildings instead

The game draws a border around each town, and there is no radius behind it that
Lua can read. The only handle is `showTownBorders`, a boolean on a construction
menu's `hudIcons` (`gui/construction/construction_menu.d.tl:163`, "only working
when componentTypes contains TOWN"), used by `town_builder_tool.script.tl`. The
engine draws it; nothing returns a number.

`Engine.Component.Town` has `sizeFactors`, `initialLandUseCapacities` and
`capacityScalingFactor`, but no extent, and `TownBuildingSystem` exposes
capacities and building lists rather than any geometry.

What does work is measuring it. `townBuildingSystem.getTown2BuildingMap()` gives
each town's buildings, and `entity_util.getPosition` gives each building a
position, so the spread of a town's own buildings around its centre *is* its
extent. The snapshot records the 50th, 90th and furthest distance per town; the
previewer draws the 90th, because one outlying building would put a border well
outside anything that reads as the town.

This is measured on the generator's towns, before anything is moved. A relocated
town keeps its name and `sizeFactors`, so its measured extent travels with it and
is a fair estimate of what it will spread to at its new position.
