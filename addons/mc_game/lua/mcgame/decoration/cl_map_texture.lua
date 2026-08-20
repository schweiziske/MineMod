-- MapTextureManager adapter: provider material first, cached 128x128 RT second.
if not CLIENT then return end

MC = MC or {}
MC.DecorationRenderer = MC.DecorationRenderer or {}
local R = MC.DecorationRenderer
local M = R.Mesh
local D = MC.Decoration

local SIZE = 128
local cache = R.DecorationMapTextureCache or {}
R.DecorationMapTextureCache = cache
local serial = 0

local function usableMaterial( value )
	return value ~= nil and not ( value.IsError and value:IsError() )
end

local function token( value )
	value = tostring( value or "map" )
	if util and util.CRC then return util.CRC( value ) end
	return ( string.gsub( value, "[^%w_]", "_" ) ):sub( 1, 48 )
end

local function directMaterial( data, cacheKey )
	local nested = type( data.cache ) == "table" and data.cache or nil
	local value = data.material or data.mapMaterial or data.map_material
		or nested and nested.material
	if type( value ) == "string" then
		return M.Material( "map_provider_" .. token( value ), value,
			"smooth noclamp vertexcolor vertexalpha translucent nocull" )
	end
	if usableMaterial( value ) then return value end
	local texture = data.texture or data.mapTexture or data.map_texture
	if not texture or not CreateMaterial then return nil end
	local key = "texture:" .. tostring( cacheKey or token( texture ) )
	local entry = cache[key]
	if not entry then
		serial = serial + 1
		local material = CreateMaterial( "mc_decoration_map_provider_" .. serial,
			"UnlitGeneric", { ["$basetexture"] = "color/white",
				["$vertexcolor"] = "1", ["$vertexalpha"] = "1",
				["$translucent"] = "1", ["$nolod"] = "1" } )
		entry = { material = material }
		cache[key] = entry
	end
	if usableMaterial( entry.material ) and entry.material.SetTexture then
		entry.material:SetTexture( "$basetexture", texture )
		return entry.material
	end
	return nil
end

local function ensurePixelEntry( cacheKey )
	local key = "pixels:" .. tostring( cacheKey )
	if cache[key] then return cache[key] end
	if not ( GetRenderTarget and CreateMaterial ) then return nil end
	serial = serial + 1
	local name = "mc_decoration_map_" .. token( cacheKey ) .. "_" .. serial
	local target = GetRenderTarget( name, SIZE, SIZE )
	if not target then return nil end
	local material = CreateMaterial( name .. "_material", "UnlitGeneric", {
		["$basetexture"] = target.GetName and target:GetName() or "color/white",
		["$vertexcolor"] = "1", ["$vertexalpha"] = "1",
		["$translucent"] = "1", ["$nolod"] = "1",
	} )
	if usableMaterial( material ) and material.SetTexture then
		material:SetTexture( "$basetexture", target )
	end
	local entry = { target = target, material = material }
	cache[key] = entry
	return entry
end

local function sameColor( r, g, b, a, nr, ng, nb, na )
	return r == nr and g == ng and b == nb and a == na
end

local function uploadPixels( entry, data )
	local pixels = D.DecorationMapPixels( data )
	if not pixels or not ( entry and entry.target and usableMaterial( entry.material ) ) then
		return false, 0, "pixels_missing"
	end
	if not ( render and render.PushRenderTarget and render.PopRenderTarget
	and render.Clear and cam and cam.Start2D and cam.End2D and surface
	and surface.SetDrawColor and surface.DrawRect ) then
		return false, 0, "render_target_unavailable"
	end
	local pushed, drawing, pixelCount = false, false, 0
	local ok, err = pcall( function()
		render.PushRenderTarget( entry.target, 0, 0, SIZE, SIZE )
		pushed = true
		render.Clear( 0, 0, 0, 0, true, true )
		cam.Start2D()
		drawing = true
		for row = 0, SIZE - 1 do
			local column = 0
			while column < SIZE do
				local r, g, b, a = D.DecorationMapPixelRGBA(
					D.DecorationMapPixelValue( pixels, row, column ), data.pixelFormat or data.pixel_format )
				local runEnd = column + 1
				while runEnd < SIZE do
					local nr, ng, nb, na = D.DecorationMapPixelRGBA(
						D.DecorationMapPixelValue( pixels, row, runEnd ), data.pixelFormat or data.pixel_format )
					if not sameColor( r, g, b, a, nr, ng, nb, na ) then break end
					runEnd = runEnd + 1
				end
				if r and ( tonumber( a ) or 0 ) > 0 then
					surface.SetDrawColor( r, g, b, a )
					surface.DrawRect( column, row, runEnd - column, 1 )
					pixelCount = pixelCount + runEnd - column
				end
				column = runEnd
			end
		end
		cam.End2D()
		drawing = false
		render.PopRenderTarget()
		pushed = false
	end )
	if drawing then pcall( cam.End2D ) end
	if pushed then pcall( render.PopRenderTarget ) end
	return ok, pixelCount, ok and nil or tostring( err )
end

function R.ResolveDecorationMapMaterial( data, stack, ent )
	if type( data ) ~= "table" then return nil, "provider_data_missing", 0 end
	local fallback = IsValid and IsValid( ent ) and ent.EntIndex
		and "entity:" .. tostring( ent:EntIndex() ) or nil
	local cacheKey, revision = D.DecorationMapCacheIdentity( data, stack, fallback )
	local supplied = directMaterial( data, cacheKey )
	if supplied then return supplied, "provider_material", 0, cacheKey, revision end
	if not cacheKey then return nil, "cache_key_missing", 0 end
	local entry = ensurePixelEntry( cacheKey )
	if not entry then return nil, "render_target_unavailable", 0, cacheKey, revision end
	if entry.revision ~= revision or data.dirty == true then
		local ok, count, err = uploadPixels( entry, data )
		if not ok then return nil, err or "pixel_upload_failed", 0, cacheKey, revision end
		entry.revision, entry.pixelCount = revision, count
	end
	return entry.material, "pixel_texture_cache", entry.pixelCount or 0, cacheKey, revision
end
