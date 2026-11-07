-- Release data, never developer out/ assets. PNG bytes remain original and are
-- verified against the shipped index when consumed by the repository.
MC.ResourceDefaults = MC.ResourceDefaults or {}
local B = MC.ResourceDefaults
local ROOT = "data_static/mc/raw_default/"
local MATERIAL_ROOT = "materials/mc/resourcepacks/default/"
function B.Ensure()
	local raw = file.Read(ROOT .. "manifest.json", "GAME")
	if not raw then B.error = "resource_default_sources_missing" return nil, B.error end
	local digest = MC.ResourcePackRules.Hash(raw)
	if digest == B.digest and MC.ResourceRepository.registered.mc_default_raw then return true end
	local manifest, err = MC.ResourcePackRules.DecodeJSON(raw)
	if not manifest then B.error = err return nil, err end
	if (manifest.schema ~= 1 and manifest.schema ~= 2) or type(manifest.files) ~= "table" or not MC.ResourcePackRules.Array(manifest.tiles,4096)
		or #manifest.tiles == 0 or type(manifest.format) ~= "table" then
		B.error = "resource_default_manifest" return nil, B.error
	end
	local files = {}
	for path in pairs(manifest.files) do
		local location = ROOT .. path
		if manifest.schema == 1 then
			if path:sub(-4) == ".png" and file.Exists(MATERIAL_ROOT .. path, "GAME") then
				location = MATERIAL_ROOT .. path
			elseif path:sub(-7) == ".mcmeta" and file.Exists(location .. ".json", "GAME") then
				location = location .. ".json"
			end
		end
		files[path] = location
	end
	local bundle
	if manifest.schema==2 then
		if type(manifest.bundle)~="table" or manifest.bundle.path~="payload.dat" then
			B.error="resource_default_bundle" return nil,B.error
		end
		bundle={path=ROOT..manifest.bundle.path,size=manifest.bundle.size,sha256=manifest.bundle.sha256,ranges=manifest.bundle.ranges}
	end
	for index, tile in ipairs(manifest.tiles) do
		if type(tile) ~= "table" or tile.tile ~= index-1 or type(tile.name) ~= "string"
			or not MC.ResourcePackRules.Identifier(tile.resource) or type(tile.tint) ~= "table" then
			B.error = "resource_default_tile" return nil, B.error
		end
		for channel=1,3 do
			local v=tile.tint[channel]
			if type(v)~="number" or v~=math.floor(v) or v<0 or v>255 then B.error="resource_default_tint" return nil,B.error end
		end
		if tile.overlay and not MC.ResourcePackRules.Identifier(tile.overlay) then B.error="resource_default_overlay" return nil,B.error end
	end
	local ok, reason = MC.ResourceRepository.Register("mc_default_raw", {title="Minecraft base sources",
		metadata={pack={min_format=manifest.format,max_format=manifest.format,description="Required original texture sources"}},
		files=files, hashes=manifest.files, bundle=bundle, pathID="GAME", required=true, fixed=true}, "mc.resourcepacks")
	if not ok then B.error=reason return nil,reason end
	B.digest, B.tiles, B.error = digest, manifest.tiles, nil
	return true
end
