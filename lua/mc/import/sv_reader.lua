-- Safe DATA reader for Phase 5 Minecraft import bundles.

MC = MC or {}
MC.Import = MC.Import or {}

local Import = MC.Import

local function cleanPath( path )
	path = string.Trim( tostring( path or "" ) )
	path = string.gsub( path, "\\", "/" )
	path = string.gsub( path, "^/+", "" )
	if path == "" or string.find( path, "..", 1, true ) then return nil end
	if not string.StartWith( path, "mc_import/" ) then path = "mc_import/" .. path end
	if not string.EndsWith( string.lower( path ), ".json" ) then path = path .. ".json" end
	return path
end

function Import.NormalizePath( path )
	return cleanPath( path )
end

local function readJSON( path )
	if not file.Exists( path, "DATA" ) then return nil, "missing_import_file:" .. path end
	local raw = file.Read( path, "DATA" )
	if not raw or raw == "" then return nil, "empty_import_file:" .. path end
	local data = util.JSONToTable( raw )
	if not istable( data ) then return nil, "invalid_import_json:" .. path end
	return data, nil, raw
end

local function partPath( manifestPath, entry )
	local path = istable( entry ) and entry.path or entry
	path = tostring( path or "" )
	if path == "" or string.find( path, "..", 1, true ) then return nil end
	path = string.gsub( path, "\\", "/" )
	if not string.StartWith( path, "mc_import/" ) then
		path = string.GetPathFromFilename( manifestPath ) .. path
	end
	return path
end

function Import.OpenBundle( manifest, manifestPath )
	if not istable( manifest ) then return nil, "invalid_bundle" end
	manifestPath = cleanPath( manifestPath )
	if not manifestPath then return nil, "invalid_import_path" end
	local source = {
		manifest = manifest,
		path = manifestPath,
		chunks = {},
		partCount = 0,
	}
	if not istable( manifest.parts ) then
		if not istable( manifest.chunks ) then return nil, "missing_import_chunks" end
		for _, chunk in ipairs( manifest.chunks ) do source.chunks[#source.chunks + 1] = chunk end
		return source
	end

	for index, entry in ipairs( manifest.parts ) do
		local path = partPath( manifestPath, entry )
		if not path then return nil, "invalid_import_part_path:" .. index end
		local part, readError, raw = readJSON( path )
		if not part then return nil, readError end
		if istable( entry ) and isstring( entry.sha256 ) and entry.sha256 ~= ""
		and util.SHA256 and util.SHA256( raw ) ~= entry.sha256 then
			return nil, "import_part_hash_mismatch:" .. index
		end
		if not istable( part.chunks ) then return nil, "invalid_import_part:" .. index end
		for _, chunk in ipairs( part.chunks ) do source.chunks[#source.chunks + 1] = chunk end
		source.partCount = source.partCount + 1
	end
	return source
end

function Import.ReadBundle( path )
	path = cleanPath( path )
	if not path then return nil, "invalid_import_path" end
	local manifest, readError = readJSON( path )
	if not manifest then return nil, readError end
	return Import.OpenBundle( manifest, path )
end
