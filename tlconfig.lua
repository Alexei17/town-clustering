-- Teal type-check config. Requires the `tl` compiler on PATH (not installed
-- yet on this machine); until then the game itself is the type checker, since
-- it compiles .tl at load time and reports failures to the log.
--
-- `tealdef/` holds this mod's own declarations - currently the types for
-- clustering_core.lua, which is plain Lua so tools/preview can run it without
-- a Teal compiler. It sits outside mod/ so deploy.ps1 does not ship a file
-- that is not listed in _content.json.
return {
	include_dir = {
		"C:/Program Files (x86)/Steam/steamapps/common/Transport Fever 3/api/tealdef",
		"C:/Program Files (x86)/Steam/steamapps/common/Transport Fever 3/base/tealdef",
		"mod/town_clustering_1/content",
		"tealdef",
	},
	global_env_def = "all_def"
}
