recordDef = true

--- Types for `clustering_core.lua`, which is plain Lua so that the preview in
--- tools/preview can run it without a `tl` compiler. The game still type-checks
--- the caller against this file.
---
--- Add `require "clustering_core"` to all_def.tl to bring `ClusteringCore` into
--- the global environment; `tlconfig.lua` already has this directory on its
--- include path.

global record ClusteringCore
	--- One generated town on the way in. The planner only reads `x` and `y`;
	--- anything else the caller puts on the table comes back untouched on
	--- `PlannedTown.source`, which is how names, size factors and the existing
	--- entity survive the round trip without the core knowing what they are.
	record InputTown
		x : number
		y : number
	end

	--- What the planner decided about one town.
	---
	--- `kind` is "stay" (keeps the generated position), "move" (rebuilt next to a
	--- cluster, so `x`/`y` differ from `origX`/`origY`) or "isolated" (left in the
	--- country and scaled down). A town that was meant to move but found nowhere
	--- to go comes back as "stay" and is counted in `Plan.stranded`.
	record PlannedTown
		--- position in `request.towns`, before the planner sorted by distance
		index : integer
		source : ClusteringCore.InputTown
		x : number
		y : number
		--- where the generator had put it
		origX : number
		origY : number
		--- squared distance to the nearest centre at assignment time
		dist : number
		--- 1-based index into `Plan.centres`
		centre : integer
		kind : string
	end

	record Params
		clusterCount : integer
		keepFraction : number
		isolatedShare : number
		ratioLow : number
		ratioHigh : number
		--- metres between towns in a cluster; the Town Spacing slider
		spacing : number
	end

	--- Ring geometry derived from the spacing.
	record Geometry
		spacing : number
		firstRing : number
		ringStep : number
	end

	--- The three questions the planner cannot answer by itself. In game these
	--- wrap `api.engine.terrain`; offline they read a heightmap out of a snapshot,
	--- treating any sample at or below the map's `waterLevel` as water.
	record Terrain
		isValid : function(x : number, y : number) : boolean
		isWater : function(x : number, y : number) : boolean
		heightAt : function(x : number, y : number) : number
	end

	record Request
		towns : {ClusteringCore.InputTown}
		params : ClusteringCore.Params
		terrain : ClusteringCore.Terrain
	end

	record Plan
		--- every town, in the planner's own distance-sorted order
		towns : {ClusteringCore.PlannedTown}
		--- the towns chosen as cluster centres, in centre-index order
		centres : {ClusteringCore.PlannedTown}
		isolated : {ClusteringCore.PlannedTown}
		--- per-centre size weight, after the shuffle
		weights : {number}
		--- the geometric ratio drawn for this map
		ratio : number
		--- the spacing floor this plan was built with
		spacing : number
		--- the RNG state the plan ended on; used as the createTowns seed
		seed : integer
		--- resulting town count per centre
		sizes : {integer}
		total : integer
		moved : integer
		stayed : integer
		stranded : integer
	end

	CLUSTER_COUNTS : {number}
	KEEP_FRACTIONS : {number}
	ISOLATED_SHARES : {number}
	--- Town Spacing slider; index 1 is MIN_TOWN_SPACING, so the default is a no-op
	TOWN_SPACINGS : {number}
	VARIATION_RATIO_MIN : {number}
	VARIATION_RATIO_MAX : {number}

	ISOLATED_SIZE_SCALE : number

	MIN_TOWN_SPACING : number
	FIRST_RING : number
	RING_STEP : number
	MAX_RINGS : integer
	ANGLES_PER_RING : integer
	JITTER_SHARE : number
	SIZE_MIN_WEIGHT : number

	SLOPE_PROBE : number
	SLOPE_PROBE_INNER : number
	PROBE_DIRECTIONS : integer
	MAX_SLOPE_DROP : number

	--- Slider indices (1-based, as `getModParams` returns them) to real values.
	--- Takes nil, since `getModParams` has nothing for a mod whose settings have
	--- never been opened; every index then falls back to the mod.json default.
	resolveParams : function(?{string : integer}) : ClusteringCore.Params

	--- Ring geometry for a given spacing.
	geometry : function(?number) : ClusteringCore.Geometry

	--- Decide the new layout. Returns nil plus a reason when there is nothing
	--- worth doing. Mutates nothing in the world - applying the plan is the
	--- caller's job, which is what lets the preview run it.
	plan : function(request : ClusteringCore.Request) : ClusteringCore.Plan, string

	--- Is this somewhere a town could stand? Water and slope test, eight
	--- directions at two radii.
	isBuildable : function(terrain : ClusteringCore.Terrain, x : number, y : number) : boolean

	--- Derive whether the engine's connection indices are 0- or 1-based from the
	--- data. Returns the base (-1 when the sample proves nothing), then the lowest
	--- and highest index seen.
	connectionBase : function(connections : {{integer, integer}}, count : integer) : integer, integer, integer

	--- Add the shortest link between separate components until every town is
	--- reachable. Returns the augmented list, how many proposed links were out of
	--- range, and how many were added.
	stitchConnections : function(
		connections : {{integer, integer}},
		base : integer,
		xs : {number},
		ys : {number},
		count : integer) : {{integer, integer}}, integer, integer

	--- Deterministic RNG shared with the preview, so both draw the same numbers.
	nextRandom : function(rng : {string : integer}) : number
	seedFrom : function(towns : {ClusteringCore.InputTown}) : integer
	distance2 : function(ax : number, ay : number, bx : number, by : number) : number
	share : function(amount : integer, weights : {number}) : {integer}
	chooseCentres : function(
		towns : {ClusteringCore.PlannedTown},
		count : integer,
		rng : {string : integer}) : {ClusteringCore.PlannedTown}
	findSpot : function(
		terrain : ClusteringCore.Terrain,
		geom : ClusteringCore.Geometry,
		cx : number,
		cy : number,
		placed : {{number, number}},
		rng : {string : integer}) : boolean, number, number
end

recordDef = false
