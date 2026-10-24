recordDef = true

--- Types for `snapshot.lua`, which writes a map out through the log so that
--- tools/preview can replay it. Plain Lua for the same reason the clustering core
--- is: the offline side runs it without a Teal compiler.
---
--- Add `require "snapshot"` to all_def.tl to bring this into the global
--- environment.

global record TownClusteringSnapshot
	--- Format version carried in the `begin` line; from_log.lua refuses anything
	--- it does not know.
	VERSION : integer

	--- Terrain sample spacing, metres.
	STEP : number

	--- Terrain rows emitted per tick. The whole grid is a few hundred thousand
	--- terrain queries; doing it in one tick would freeze the game.
	ROWS_PER_TICK : integer

	--- Map extent, found by probing `isValid` outwards from a point known to be
	--- on the map. Returns minX, minY, maxX, maxY.
	bounds : function(
		isValid : function(x : number, y : number) : boolean,
		x : number,
		y : number) : number, number, number, number

	--- Sample counts across and up, for those bounds. Returns cols, rows.
	grid : function(
		minX : number,
		minY : number,
		maxX : number,
		maxY : number,
		?number) : integer, integer

	beginLine : function(
		minX : number,
		minY : number,
		step : number,
		cols : integer,
		rows : integer,
		waterLevel : number) : string

	townLine : function(x : number, y : number, size : number, name : string) : string

	--- Median, 90th percentile and furthest of a list of distances.
	percentiles : function({number}) : number, number, number

	--- One town's measured extent; `index` matches the order of the town lines.
	areaLine : function(
		index : integer,
		buildings : integer,
		p50 : number,
		p90 : number,
		furthest : number) : string

	--- One terrain row: the heights line and the water-mask line beside it.
	rowLines : function(
		terrain : ClusteringCore.Terrain,
		minX : number,
		minY : number,
		step : number,
		cols : integer,
		iy : integer) : string, string

	endLine : function(townCount : integer) : string
end

recordDef = false
