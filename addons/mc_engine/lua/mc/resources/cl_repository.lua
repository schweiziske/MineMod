-- Explicit, synchronous discovery. Catalogs contain data, never live ZIP handles.
MC = MC or {}
local D = MC.ResourceRepository or {revision = 0, catalog = {}, byID = {}, registered = {}}
MC.ResourceRepository = D
local Rules = MC.ResourcePackRules
local ROOT = "mc/resourcepacks/inbox"
-- Generated release metadata; never depend on the developer's out/ directory.
local TARGET = {MC.ResourceRelease.major, MC.ResourceRelease.minor}
local function clone(value, depth, seen)
	if type(value) ~= "table" then return value end
	depth, seen = depth or 0, seen or {}
	if depth > 32 or seen[value] then error("resource_metadata_depth_or_cycle", 0) end
	seen[value] = true
	local result = {} for key, item in pairs(value) do result[key] = clone(item, depth + 1, seen) end
	seen[value] = nil
	return result
end
local function nativeAvailable()
	return mcmesh and type(mcmesh.ListResourcePackSources) == "function" and type(mcmesh.OpenResourcePackSource) == "function"
		and type(mcmesh.ReadResourcePackSource) == "function" and type(mcmesh.CloseResourcePackSource) == "function"
		and type(mcmesh.ResourcePackSourceUnchanged) == "function"
end
function D.Capabilities()
	return {directory = nativeAvailable() == true or MC.ResourceDirectory ~= nil, zip = nativeAvailable() == true, mounted = true,
		synchronous = true, progressYieldSeconds=5, targetFormat = clone(TARGET), filter = "bounded_regex_subset",
		textures = MC.ResourceGeneration and MC.ResourceGeneration.Available() and "synchronous_atlas" or "prepare_only",
		models = false, gui = false, sounds = false, language = false}
end
local function close(source)
	if source.handle then
		local ok, err = mcmesh.CloseResourcePackSource(source.handle)
		source.handle = nil
		if not ok then MC.Fault("resource_source_close", "%s", tostring(err)) end
	end
end
local function bundleBytes(source)
	local bundle=source.bundle
	local bytes=file.Read(bundle.path,source.pathID)
	if type(bytes)~="string" or #bytes~=bundle.size or Rules.Hash(bytes)~=bundle.sha256 then
		return nil,"resource_source_bundle_changed:"..source.id
	end
	return bytes
end
local function read(source, path)
	if source.handle then return mcmesh.ReadResourcePackSource(source.handle, path) end
	local location = source.locations[path]
	if not location then return nil, "resource_source_missing:" .. path end
	local bytes
	if source.bundle then
		local packed,err=source.bundleBytes
		if not packed then packed,err=bundleBytes(source) end
		if not packed then return nil,err end
		local range=source.bundle.ranges[path]
		bytes=packed:sub(range[1]+1,range[1]+range[2])
	else bytes=file.Read(location,source.pathID) end
	if type(bytes) ~= "string" or #bytes > 134217728 then return nil, "resource_source_read:" .. path end
	local hash=Rules.Hash(bytes)
	if source.hashes and source.hashes[path] ~= hash then return nil, "resource_source_hash:" .. path end
	return bytes,nil,hash
end
local function json(source, path)
	local bytes, err, hash = read(source, path)
	if not bytes then return nil, err end
	if #bytes > 1048576 then return nil, "resource_pack_metadata_budget:" .. path end
	local value, parseError = Rules.DecodeJSON(bytes)
	if not value then return nil, path .. ":" .. parseError end
	return value, bytes, hash
end
local function describe(source, metadata)
	local rules, err = Rules.Descriptor(metadata, source.entries, TARGET)
	if not rules then return nil, err end
	source.rules = rules
	return {id = source.id, name = source.id, title = source.title, owner = source.owner,
		description = rules.description, revision = source.revision, formats = rules.formats,
		formatMatches = rules.formatMatches, unsupported = rules.unsupported, resourceSource = true,
		required = source.required == true, fixed = source.fixed == true, metadataOnly = source.metadataOnly,
		preview = "mc/resourcepacks/unknown"}
end

local function cover(source, entry)
	if not source.entries["pack.png"] then return end
	local size = source.entries["pack.png"]
	if type(size) == "number" and size > 4194304 then entry.previewError = "resource_pack_cover_png_budget" return end
	local bytes, err = read(source, "pack.png")
	if not bytes then entry.previewError = err return end
	if #bytes > 4194304 or #bytes < 33 or bytes:sub(1,8) ~= "\137PNG\13\10\26\10" then
		entry.previewError = "resource_pack_cover_png_budget" return
	end
	local function uint32(offset)
		local a,b,c,d = bytes:byte(offset,offset+3)
		return ((a*256+b)*256+c)*256+d
	end
	local w,h = uint32(17),uint32(21)
	if w < 1 or h < 1 or w > 1024 or h > 1024 then entry.previewError = "resource_pack_cover_dimensions" return end
	if mcmesh and mcmesh.CreateAtlasSprite then
		local decoded, reason = mcmesh.CreateAtlasSprite(bytes,{width=w,height=h,mip=0,padding=0,strategy=1,frames={0},alphaBias=0,item=false})
		if not decoded then entry.previewError = "resource_pack_cover_decode:" .. tostring(reason) return end
		local released, releaseError = mcmesh.ReleaseAtlasSprite(decoded.id)
		if not released then error("resource_pack_cover_release:" .. tostring(releaseError),0) end
	end
	local path = "mc/resourcepacks/previews/" .. Rules.Hash(bytes)
	file.CreateDir("mc/resourcepacks/previews")
	if not file.Exists(path .. ".png", "DATA") then file.Write(path .. ".png", bytes) end
	if file.Read(path .. ".png", "DATA") ~= bytes then entry.previewError = "resource_pack_cover_write" return end
	entry.preview = "../data/" .. path
end

-- Mounted adapters map pack-relative files to validated GAME/DATA locators.
-- Descriptors and byte locations are copied at registration; no caller callbacks.
function D.Register(id, definition, owner)
	if type(id) ~= "string" or #id > 64 or not id:match("^[a-z0-9_%-]+$") or id:match("^local_") or id:match("^mounted_") then return false, "resource_pack_invalid_id" end
	if type(owner) ~= "string" or #owner > 96 or not owner:match("^[a-z0-9_%.:%-]+$") then return false, "resource_pack_invalid_owner" end
	if type(definition) ~= "table" or type(definition.files) ~= "table" or type(definition.metadata) ~= "table" then return false, "resource_pack_definition" end
	if definition.pathID ~= "GAME" and definition.pathID ~= "DATA" then return false, "resource_pack_path_id" end
	for _, key in ipairs({"required", "fixed"}) do
		if definition[key] ~= nil and type(definition[key]) ~= "boolean" then return false, "resource_pack_" .. key end
	end
	if definition.title ~= nil and (type(definition.title) ~= "string" or #definition.title > 128 or definition.title:find("%z")) then return false, "resource_pack_title" end
	local previous = D.registered[id]
	if previous and previous.owner ~= owner then return false, "owned_by_" .. previous.owner end
	local entries, locations, count = {}, {}, 0
	local hashes
	if definition.hashes ~= nil then
		if type(definition.hashes) ~= "table" then return false, "resource_pack_hashes" end
		hashes = {}
	end
	for path, location in pairs(definition.files) do
		if type(path) ~= "string" or type(location) ~= "string" or #location > 512
			or not Rules.Identifier("mc:" .. path) or not Rules.Identifier("mc:" .. location) then return false, "resource_pack_file_path" end
		count = count + 1 if count > 65536 then return false, "resource_pack_entry_budget" end
		entries[path], locations[path] = true, location
		if hashes then
			local hash = definition.hashes[path]
			if type(hash) ~= "string" or #hash ~= 64 or not hash:match("^[a-f0-9]+$") then return false, "resource_pack_hash" end
			hashes[path] = hash
		end
	end
	local bundle
	if definition.bundle~=nil then
		local input=definition.bundle
		if not hashes or type(input)~="table" or type(input.path)~="string" or not Rules.Identifier("mc:"..input.path)
			or type(input.sha256)~="string" or #input.sha256~=64 or not input.sha256:match("^[a-f0-9]+$")
			or type(input.size)~="number" or input.size~=math.floor(input.size) or input.size<0 or input.size>134217728
			or type(input.ranges)~="table" then return false,"resource_pack_bundle" end
		bundle={path=input.path,size=input.size,sha256=input.sha256,ranges={}}
		local covered={}
		for path in pairs(entries) do
			local range=input.ranges[path]
			if type(range)~="table" or type(range[1])~="number" or type(range[2])~="number"
				or range[1]~=math.floor(range[1]) or range[2]~=math.floor(range[2]) or range[1]<0 or range[2]<1
				or range[1]>input.size-range[2] then return false,"resource_pack_bundle_range" end
			local row={range[1],range[2]}
			bundle.ranges[path]=row;covered[#covered+1]=row
		end
		table.sort(covered,function(a,b) return a[1]<b[1] end)
		local ending=0
		for _,range in ipairs(covered) do
			if range[1]~=ending then return false,"resource_pack_bundle_coverage" end
			ending=ending+range[2]
		end
		if ending~=input.size then return false,"resource_pack_bundle_coverage" end
	end
	local copied, metadata = pcall(clone, definition.metadata)
	if not copied then return false, tostring(metadata) end
	local source = {id = id, title = definition.title or id, owner = owner, entries = entries, locations = locations,
		pathID = definition.pathID, metadata = metadata, required = definition.required, fixed = definition.fixed, hashes = hashes,bundle=bundle}
	local entry, err = describe(source, source.metadata)
	if not entry then return false, err end
	-- Content hashes are computed when preparing; this revision identifies the
	-- registration itself and must never stand in for a content-addressed cache key.
	D.registrationSerial = (D.registrationSerial or 0) + 1
	source.revision = "mounted:" .. D.registrationSerial
	D.registered[id] = source
	return true
end
function D.Unregister(id, owner)
	local source = D.registered[id]
	if not source then return false, "resource_pack_not_registered" end
	if source.owner ~= owner then return false, "owned_by_" .. source.owner end
	if source.required then return false, "resource_pack_required" end
	D.registered[id] = nil
	return true
end
function D.GetCatalog()
	return {revision = D.revision, entries = clone(D.catalog), capabilities = D.Capabilities(), error = D.error, baseError = D.baseError}
end
function D.Refresh()
	-- Source descriptors give adjacent mounted directories stable public pack IDs.
	-- They do not register an atlas before the runtime bake has completed.
	if MC.TexturePackDiscovery then MC.TexturePackDiscovery.Scan("source") end
	D.baseError = nil
	if MC.ResourceDefaults then
		local ok, err = MC.ResourceDefaults.Ensure()
		if not ok then D.baseError = err end
	end
	local catalog, byID = {}, {}
	for id, source in pairs(D.registered) do
		local entry, err = describe(source, source.metadata)
		if not entry then return nil, err end
		cover(source,entry)
		catalog[#catalog + 1], byID[id] = entry, entry
	end
	D.error = nil
	local adapters = {}
	if nativeAvailable() then
		adapters[#adapters+1] = {prefix="local_", pathID="DATA", list=mcmesh.ListResourcePackSources, open=mcmesh.OpenResourcePackSource}
	elseif MC.ResourceDirectory then
		adapters[#adapters+1] = {prefix="local_", pathID="DATA", list=MC.ResourceDirectory.List, open=MC.ResourceDirectory.Open}
	end
	-- Addons ship the same extracted tree as the DATA inbox. Always use Lua for
	-- GAME locators, even when native I/O is installed (it only owns the inbox).
	if MC.ResourceDirectory then
		adapters[#adapters+1] = {prefix="mounted_", pathID="GAME", list=MC.ResourceDirectory.List, open=MC.ResourceDirectory.Open}
	end
	for _, adapter in ipairs(adapters) do
		if adapter.pathID == "DATA" then file.CreateDir(ROOT) end
		local names, err
		names,err=adapter.list(adapter.pathID)
		if not names then D.error = err
		else
			table.sort(names)
			for _, name in ipairs(names) do
				local id = adapter.prefix .. util.SHA256(name):sub(1, 24)
				local descriptor
				if adapter.pathID == "GAME" and MC.TexturePackDiscovery then
					descriptor = MC.TexturePackDiscovery.directories[name]
				end
				if descriptor then id = descriptor.id end
				if byID[id] then return nil, "resource_catalog_duplicate:" .. id end
				local title = descriptor and descriptor.title or name
				local source, openError
				if MC.ResourceDirectory and (adapter.pathID == "GAME" or file.IsDir(ROOT .. "/" .. name,"DATA")) then
					source,openError=MC.ResourceDirectory.Inspect(name,adapter.pathID)
					-- The native adapter also accepts one wrapping directory. Keep
					-- that legacy layout available when no root envelope exists.
					if not source and adapter.pathID == "DATA" and nativeAvailable()
						and openError == "resource_source_missing:pack.mcmeta" then
						source,openError=adapter.open(name,adapter.pathID)
					end
				else source,openError=adapter.open(name,adapter.pathID) end
				local entry
				if source then
					source.id, source.title, source.owner = id, title, "mc.resourcepacks"
					local ok, result, parseError = pcall(function()
						local metadata, reason = json(source, "pack.mcmeta")
						if not metadata then return nil, reason end
						local value, problem = describe(source, metadata)
						if value then cover(source,value) end
						return value, problem
					end)
					close(source)
					if not ok then
						MC.Fault("resource_catalog_internal", "%s", tostring(result))
						openError = tostring(result)
					else entry, openError = result, parseError end
				end
				if not entry then entry = {id = id, name = id, title = title, owner = "mc.resourcepacks", resourceSource = true, error = openError} end
				entry.locator = name
				entry.pathID = adapter.pathID
				catalog[#catalog + 1], byID[id] = entry, entry
			end
		end
	end
	table.sort(catalog, function(a, b) return a.id < b.id end)
	D.catalog, D.byID, D.revision = catalog, byID, D.revision + 1
	hook.Run("MC.ResourcePackCatalogChanged", D.revision)
	return D.GetCatalog()
end

function D.ValidateSelection(ids, revision, confirmed)
	if revision ~= D.revision then return nil, "resource_catalog_changed" end
	if not Rules.Array(ids, 64) then return nil, "resource_selection_invalid" end
	local selection, seen = {}, {}
	for _, id in ipairs(ids) do
		if type(id) ~= "string" or seen[id] then return nil, "resource_selection_duplicate_or_invalid" end
		local entry = D.byID[id]
		if not entry then return nil, "resource_pack_missing:" .. id end
		if entry.error then return nil, id .. ":" .. entry.error end
		if not entry.formatMatches and (type(confirmed) ~= "table" or confirmed[id] ~= entry.revision) then return nil, "resource_pack_format_confirmation:" .. id end
		seen[id], selection[#selection + 1] = true, id
	end
	-- Required fixed sources are deterministic bottom layers. Full legacy atlases
	-- do not enter this catalog and are never treated as partial resource packs.
	for _, entry in ipairs(D.catalog) do
		if entry.required and not seen[entry.id] then selection[#selection + 1], seen[entry.id] = entry.id, true end
	end
	for index, id in ipairs(selection) do
		local entry = D.byID[id]
		if entry.fixed and entry.required and index ~= #selection then return nil, "resource_pack_fixed_bottom:" .. id end
	end
	if #selection == 0 then return nil, "resource_selection_empty" end
	return selection
end

local Snapshot = {} Snapshot.__index = Snapshot
function Snapshot:Close()
	if self.closed then return end
	self.closed = true
	for _, source in ipairs(self.packs) do close(source) source.bundleBytes=nil end
end
function Snapshot:Resolve(id)
	if self.closed then return nil, "resource_snapshot_closed" end
	return Rules.Resolve(self.packs, id)
end
function Snapshot:Read(id)
	local resolved, err = self:Resolve(id)
	if not resolved then return nil, err end
	local source = self.packs[resolved.index]
	local bytes,hash
	bytes, err, hash = read(source, resolved.path)
	if not bytes then return nil, err end
	local metadata
	if resolved.metadataIndex then
		local metaSource = self.packs[resolved.metadataIndex]
		local raw,metaHash
		metadata, raw, metaHash = json(metaSource, resolved.metadataPath)
		if not metadata then return nil, raw end
		self.consumed[metaSource.id .. "/" .. resolved.metadataPath] = {source = metaSource, path = resolved.metadataPath, hash = metaHash or Rules.Hash(raw)}
	end
	self.consumed[source.id .. "/" .. resolved.path] = {source = source, path = resolved.path, hash = hash or Rules.Hash(bytes)}
	return bytes, metadata, resolved
end
function Snapshot:Validate()
	if self.closed then return false, "resource_snapshot_closed" end
	if self.catalogRevision ~= D.revision then return false, "resource_catalog_changed" end
	for _, source in ipairs(self.packs) do
		if source.handle then
			local ok, err = mcmesh.ResourcePackSourceUnchanged(source.handle)
			if not ok then return false, err or "resource_source_changed:" .. source.id end
		elseif source.directory then
			local ok,err=MC.ResourceDirectory.Unchanged(source)
			if not ok then return false,err end
		elseif D.registered[source.id] ~= (source.registered or source) then return false, "resource_registration_changed:" .. source.id
		elseif source.bundle then
			local bytes,err=bundleBytes(source)
			if not bytes then return false,err end
		end
	end
	for _, consumed in pairs(self.consumed) do
		-- A whole-bundle digest already validated every immutable snapshot byte.
		if not consumed.source.bundle then
		local bytes, err, hash = read(consumed.source, consumed.path)
		if not bytes then return false, err end
		if (hash or Rules.Hash(bytes)) ~= consumed.hash then return false, "resource_source_changed:" .. consumed.path end
		end
	end
	return true
end

-- LabPBR companions belong to the exact color layer (including an overlay).
-- Absence is neutral; do not borrow another pack's material for replaced color.
function Snapshot:ReadCompanion(origin, suffix)
	if self.closed then return nil, "resource_snapshot_closed" end
	if suffix ~= "_n" and suffix ~= "_s" then return nil, "resource_companion_suffix" end
	local source = self.packs[origin.index]
	local path = origin.path:sub(1, -5) .. suffix .. ".png"
	if not source.entries[path] then return false end
	local bytes, err, hash = read(source, path)
	if not bytes then return nil, err end
	self.consumed[source.id .. "/" .. path] = {source = source, path = path, hash = hash or Rules.Hash(bytes)}
	local metadata
	if source.entries[path .. ".mcmeta"] then
		local raw,metaHash
		metadata, raw, metaHash = json(source, path .. ".mcmeta")
		if not metadata then return nil, raw end
		self.consumed[source.id .. "/" .. path .. ".mcmeta"] = {source = source, path = path .. ".mcmeta", hash = metaHash or Rules.Hash(raw)}
	end
	return bytes, metadata
end
function Snapshot:ContentKey()
	local parts = {"rules:" .. Rules.VERSION, "format:" .. TARGET[1] .. "." .. TARGET[2]}
	for _, pack in ipairs(self.packs) do parts[#parts + 1] = pack.id .. ":" .. pack.revision end
	local keys = {} for key in pairs(self.consumed) do keys[#keys + 1] = key end table.sort(keys)
	for _, key in ipairs(keys) do parts[#parts + 1] = key .. ":" .. self.consumed[key].hash end
	return Rules.Hash(table.concat(parts, "\n"))
end
function D.OpenSelection(ids, revision, confirmed)
	local selection, err = D.ValidateSelection(ids, revision, confirmed)
	if not selection then return nil, err end
	local snapshot = setmetatable({packs = {}, consumed = {}, catalogRevision = revision, selection = selection}, Snapshot)
	for _, id in ipairs(selection) do
		local entry, source = D.byID[id], D.registered[id]
		if not source then
			-- Native directory opens hash every file, even unused models/sounds.
			-- Directory snapshots instead validate the index plus consumed bytes;
			-- native ZIP I/O and pixel/hash acceleration remain independent.
			if entry.metadataOnly then source,err=MC.ResourceDirectory.Open(entry.locator,entry.pathID)
			elseif entry.pathID == "GAME" then source,err=MC.ResourceDirectory.Open(entry.locator,"GAME")
			elseif nativeAvailable() then source,err=mcmesh.OpenResourcePackSource(entry.locator)
			elseif MC.ResourceDirectory then source,err=MC.ResourceDirectory.Open(entry.locator)
			else snapshot:Close() return nil,"resource_source_unavailable" end
			if source then
				source.id, source.owner, source.title = id, entry.owner, entry.title
				snapshot.packs[#snapshot.packs + 1] = source
				if not entry.metadataOnly and source.revision ~= entry.revision then err = "resource_source_changed:" .. id
				else
					local metadata, hash
					metadata, err, hash = json(source, "pack.mcmeta")
					if metadata then
						-- A catalog confirms metadata/format, not a previously scanned
						-- texture tree. The selected source is fully indexed here.
						if entry.metadataOnly and "metadata:" .. hash ~= entry.revision then err = "resource_source_changed:" .. id
						else source.rules, err = Rules.Descriptor(metadata, source.entries, TARGET) end
					end
				end
			end
		else
			if source.revision ~= entry.revision then err = "resource_registration_changed:" .. id end
			if source.bundle and not err then
				local registered=source
				source={} for key,value in pairs(registered) do source[key]=value end
				source.registered=registered
				source.bundleBytes,err=bundleBytes(source)
			end
			snapshot.packs[#snapshot.packs + 1] = source
		end
		if not source or err then snapshot:Close() return nil, err end
	end
	return snapshot
end
