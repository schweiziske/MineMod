-- The DLL-free source adapter deliberately accepts extracted directories only.
MC.ResourceDirectory = {}
local D = MC.ResourceDirectory
local ROOTS = {DATA = "mc/resourcepacks/inbox", GAME = "data_static/mc/raw_resourcepacks"}
local function validName(name)
	return type(name)=="string" and #name>0 and #name<=240 and name~="." and name~=".."
		and not name:find('[/\\:<>"|?*%z%c]') and not name:find("[. ]$")
end
function D.List(pathID)
	pathID = pathID or "DATA"
	local root = ROOTS[pathID]
	if not root then return nil,"resource_pack_path_id" end
	if pathID == "DATA" then file.CreateDir(root) end
	local _, directories = file.Find(root.."/*", pathID)
	if not directories then return nil,"resource_directory_list" end
	local names = {}
	for _, name in ipairs(directories) do
		if validName(name) then names[#names+1]=name end
	end
	return names
end
function D.Open(name, pathID)
	pathID = pathID or "DATA"
	local root = ROOTS[pathID]
	if not root then return nil,"resource_pack_path_id" end
	if not validName(name) or not file.IsDir(root.."/"..name,pathID) then return nil,"resource_directory_missing" end
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
			stamps[#stamps+1]=path..":"..size..":"..tostring(file.Time(base..leaf,pathID))
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
	-- Metadata affects overlays/filtering even if timestamps have only second
	-- precision. Consumed resources get independent content hashes in Snapshot.
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
