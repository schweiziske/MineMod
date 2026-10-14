-- The DLL-free source adapter deliberately accepts extracted directories only.
MC.ResourceDirectory = {}
local D = MC.ResourceDirectory
local ROOTS = {DATA = "mc/resourcepacks/inbox", GAME = "data_static/mc/resourcepacks"}
local LEGACY_ROOT = "data_static/mc/raw_resourcepacks"
local function directoryRoot(name, pathID)
	local root = ROOTS[pathID]
	-- Existing extracted addons (including AVPBR) retain their old location.
	if pathID == "GAME" and not file.IsDir(root .. "/" .. name, pathID) then return LEGACY_ROOT end
	return root
end
local function validName(name)
	return type(name)=="string" and #name>0 and #name<=240 and name~="." and name~=".."
		and not name:find('[/\\:<>"|?*%z%c]') and not name:find("[. ]$")
end
function D.List(pathID)
	pathID = pathID or "DATA"
	local root = ROOTS[pathID]
	if not root then return nil,"resource_pack_path_id" end
	if pathID == "DATA" then file.CreateDir(root) end
	local roots = pathID == "GAME" and {root, LEGACY_ROOT} or {root}
	local names, seen = {}, {}
	for _, base in ipairs(roots) do
		local _, directories = file.Find(base.."/*", pathID)
		if not directories then return nil,"resource_directory_list" end
		for _, name in ipairs(directories) do
			if validName(name) and not seen[name] then
				names[#names+1], seen[name] = name, true
			end
		end
	end
	return names
end

-- Catalog discovery needs only the pack envelope. Indexing every texture here
-- makes opening/refreshing the manager as expensive as preparing every pack.
function D.Inspect(name, pathID)
	pathID = pathID or "DATA"
	local root = ROOTS[pathID]
	if not root then return nil,"resource_pack_path_id" end
	if not validName(name) then return nil,"resource_directory_missing" end
	root = directoryRoot(name, pathID)
	local base = root .. "/" .. name
	if not file.IsDir(base,pathID) then return nil,"resource_directory_missing" end
	base = base .. "/"
	local metadataSize = file.Size(base .. "pack.mcmeta",pathID)
	if not metadataSize or metadataSize < 0 then return nil,"resource_source_missing:pack.mcmeta" end
	if metadataSize > 1048576 then return nil,"resource_pack_metadata_budget" end
	local metadata = file.Read(base .. "pack.mcmeta",pathID)
	if not metadata or #metadata ~= metadataSize then return nil,"resource_source_read:pack.mcmeta" end
	local entries, locations = {["pack.mcmeta"]=metadataSize}, {["pack.mcmeta"]=base .. "pack.mcmeta"}
	local coverSize = file.Size(base .. "pack.png",pathID)
	if coverSize and coverSize >= 0 then
		entries["pack.png"], locations["pack.png"] = coverSize, base .. "pack.png"
	end
	return {directory=name,entries=entries,locations=locations,pathID=pathID,metadataOnly=true,
		revision="metadata:" .. MC.ResourcePackRules.Hash(metadata)}
end

function D.Open(name, pathID)
	pathID = pathID or "DATA"
	local root = ROOTS[pathID]
	if not root then return nil,"resource_pack_path_id" end
	if not validName(name) then return nil,"resource_directory_missing" end
	root = directoryRoot(name, pathID)
	if not file.IsDir(root.."/"..name,pathID) then return nil,"resource_directory_missing" end
	local entries, locations, stamps, count, total = {}, {}, {}, 0, 0
	local function walk(relative, depth)
		if depth>32 then return nil,"resource_directory_depth" end
		local base=root.."/"..name.."/"..relative
		local files, dirs=file.Find(base.."*",pathID)
		if not files or not dirs then return nil,"resource_directory_list:"..relative end
		table.sort(files); table.sort(dirs)
		for _, leaf in ipairs(files) do
			local path=relative..leaf
			if not validName(leaf) or #path>512 then return nil,"resource_pack_file_path:"..path end
			local size=file.Size(base..leaf,pathID)
			if not size or size<0 or size>134217728 then return nil,"resource_source_file_budget:"..path end
			count,total=count+1,total+size
			if count>65536 or total>1073741824 then return nil,"resource_source_directory_budget" end
			entries[path],locations[path]=size,base..leaf
			stamps[#stamps+1]=path..":"..size
		end
		for _, leaf in ipairs(dirs) do
			if not validName(leaf) then return nil,"resource_pack_file_path" end
			local ok,err=walk(relative..leaf.."/",depth+1)
			if not ok then return nil,err end
		end
		return true
	end
	local ok,err=walk("",0)
	if not ok then return nil,err end
	-- The index tracks names and sizes. Snapshot validates the actual bytes of
	-- every consumed resource, so modification-time queries add no protection.
	-- Metadata also affects overlays/filtering before any textures are resolved.
	if entries["pack.mcmeta"] then
		if entries["pack.mcmeta"]>1048576 then return nil,"resource_pack_metadata_budget" end
		local metadata=file.Read(locations["pack.mcmeta"],pathID)
		if not metadata then return nil,"resource_source_read:pack.mcmeta" end
		stamps[#stamps+1]=MC.ResourcePackRules.Hash(metadata)
	end
	return {directory=name,entries=entries,locations=locations,pathID=pathID,
		revision="directory:"..MC.ResourcePackRules.Hash(table.concat(stamps,"\n"))}
end
function D.Unchanged(source)
	local current,err=D.Open(source.directory,source.pathID)
	if not current then return false,err end
	if current.revision~=source.revision then return false,"resource_source_changed:"..source.directory end
	return true
end
