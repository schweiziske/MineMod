-- Opt-in GPU baker. Two slots per pack; color and LabPBR maps publish together.
-- Run the entire bake in one render callback, with no per-frame limits or yields.
local B = MC.AtlasBaker or {}
MC.AtlasBaker = B
B.caches = B.caches or {}
B.copyMaterials = B.copyMaterials or {}
local HOOK = "mc_atlas_baker"
B.packs = B.packs or {}
local PACKS = B.packs
local clock, drawUV, setColor = SysTime, surface.DrawTexturedRectUV, surface.SetDrawColor
local function notify()
	hook.Run( "MC.AtlasBakeChanged", B.Status() )
end

-- Advertise source recipes separately; only complete GPU atlases enter the registry.
function B.ListSourcePacks()
	local entries = {}
	for id, pack in pairs( PACKS ) do
		entries[#entries + 1] = { name = pack.name, title = pack.title, description = pack.description,
			preview = pack.preview, owner = pack.owner, bakeID = id, pbr = pack.pbr,
			prepared = file.Exists( "data_static/mc/atlas_bake/" .. id .. ".json", "GAME" ) }
	end
	table.sort( entries, function( a, b ) return a.name < b.name end )
	return entries
end

function B.ListPreparedPacks()
	local entries = {}
	for _, entry in ipairs( B.ListSourcePacks() ) do
		if entry.prepared then entries[#entries + 1] = entry end
	end
	return entries
end

function B.RegisterSourcePack( name, definition, owner )
	if type( name ) ~= "string" or #name > 64 or not name:match( "^[a-z0-9_%-]+$" )
		or name == "default" then
		return false, "invalid_source_pack_name"
	end
	if type( owner ) ~= "string" or #owner > 96 or not owner:match( "^[a-z0-9_%.:%-]+$" ) or owner == "mc" then
		return false, "invalid_source_pack_owner"
	end
	if type( definition ) ~= "table" then return false, "invalid_source_pack_definition" end
	local output = definition.output or name
	if type( output ) ~= "string" or #output > 64 or not output:match( "^[a-z0-9_%-]+$" ) or output == "default" then
		return false, "invalid_source_pack_output"
	end
	if definition.pbr ~= nil and type( definition.pbr ) ~= "boolean" then return false, "invalid_source_pack_pbr" end
	for field, limit in pairs( { title = 128, description = 1024 } ) do
		local value = definition[field]
		if value ~= nil and ( type( value ) ~= "string" or #value > limit or value:find( "%z" ) ) then
			return false, "invalid_source_pack_" .. field
		end
	end
	local preview = definition.preview
	if preview ~= nil and ( type( preview ) ~= "string" or #preview > 240 or not preview:match( "^[a-z0-9_/%-]+$" )
		or preview:sub( 1, 1 ) == "/" ) then return false, "invalid_source_pack_preview" end
	local previous = PACKS[name]
	if previous and previous.owner ~= owner then return false, "owned_by_" .. previous.owner end
	if previous and previous.name ~= output then return false, "source_output_changed_restart_client" end
	for id, pack in pairs( PACKS ) do
		if id ~= name and pack.name == output then return false, "source_output_already_registered" end
	end
	local registeredOwner = MC.TexturePackDefinitionOwner( output )
	if registeredOwner and registeredOwner ~= owner then return false, "owned_by_" .. registeredOwner end
	if B.job and B.job.id == name then return false, "bake_already_running" end
	local cache = B.caches[name]
	if cache and cache.plan and cache.plan.pbr ~= ( definition.pbr == true ) then return false, "sources_changed_restart_client" end
	PACKS[name] = { name = output, owner = owner, pbr = definition.pbr == true,
		title = definition.title, description = definition.description, preview = preview }
	hook.Run( "MC.TexturePackSourcesChanged", name, owner )
	B.RestorePreference()
	return true, name
end

function B.UnregisterSourcePack( name, owner )
	local pack = PACKS[name]
	if not pack then return false, "source_pack_not_registered" end
	if pack.owner ~= owner then return false, "owned_by_" .. pack.owner end
	if B.job and B.job.id == name then return false, "bake_already_running" end
	local registeredOwner = MC.TexturePackDefinitionOwner( pack.name )
	if registeredOwner then
		local ok, err = MC.UnregisterTexturePack( pack.name, owner )
		if not ok then return false, err end
	end
	PACKS[name] = nil
	-- Engine RTs cannot be deleted here. Retain the fixed cache and in-use protection.
	hook.Run( "MC.TexturePackSourcesChanged", name, owner )
	return true, name
end

function B.Status()
	local job = B.job or B.last
	if not job then return { state = "idle" } end
	return { state = job.state, serial = job.serial, loaded = job.loaded, sources = job.sourceCount, drawn = job.drawn, tiles = job.tileCount,
		elapsedMS = ( ( job.finished or clock() ) - job.started ) * 1000,
		workMS = job.workMS, heapDeltaKB = job.heapDeltaKB,
		loadMS = job.loadMS, drawMS = job.drawMS,
		error = job.error, revision = job.revision, frames = job.frames, pack = job.pack,
		-- Two RGBA8 targets per channel, with no depth buffer or mip chain.
		targetBytes = job.targetBytes, cachedSources = #job.cache.textures }
end

function B.IsBusy() return B.job ~= nil end

local function finish( state, err )
	local job = B.job
	if not job then return end
	hook.Remove( "PostRender", HOOK )
	job.state, job.error, job.finished = state, err, clock()
	job.heapDeltaKB = collectgarbage( "count" ) - job.heapStartKB
	-- Do not retain the recipe, planning arrays or decoded file strings in history.
	job.plan = nil
	B.job, B.last = nil, job
	notify()
	if job.pack ~= MC.TexturePack:GetString() then B.RestorePreference() end
	if state == "failed" then MC.Fault( "atlas_bake_failed", "%s", err ) end
end

function B.Cancel()
	if not B.job then return false, "no_bake_running" end
	finish( "cancelled" )
	return true
end

local function requireValue( value, message )
	if not value then error( message, 0 ) end
	return value
end

local function targetInUse( target )
	if not target then return false end
	local name = target:GetName()
	local texture = MC.Material:GetTexture( "$basetexture" )
	if texture and texture:GetName() == name then return true end
	local runtime = MC.RenderPackRuntime
	if runtime then
		for _, key in ipairs( { "active", "pending" } ) do
			local context = runtime[key]
			if context and context.bundle then
				for _, source in pairs( context.bundle.sources ) do if source:GetName() == name then return true end end
				for _, maps in pairs( context.bundle.runtimePBR or {} ) do
					if maps.normal:GetName() == name or maps.orm:GetName() == name then return true end
				end
			end
		end
	end
	return false
end

local function allocate( job )
	local p, cache = job.plan, job.cache
	local rt = cache.targets[job.slot]
	if not rt then
		rt = GetRenderTargetEx( "mc_" .. job.id .. "_bake_v1_" .. job.slot, p.width, p.height,
			RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 )
		cache.targets[job.slot] = rt
	end
	requireValue( rt and not rt:IsError() and rt:Width() == p.width and rt:Height() == p.height, "atlas_target_size_or_allocation" )
	if p.pbr then
		for _, channel in ipairs( { "normal", "orm" } ) do
			local pool = cache[channel]
			local target = pool[job.slot]
			if not target then
				target = GetRenderTargetEx( "mc_" .. job.id .. "_bake_v1_" .. channel .. "_" .. job.slot, p.width, p.height,
					RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 )
				pool[job.slot] = target
			end
			requireValue( target and not target:IsError() and target:Width() == p.width and target:Height() == p.height,
				"atlas_material_target_size_or_allocation" )
		end
	end
	if not B.upload then
		B.white = GetRenderTargetEx( "mc_vanilla_bake_white_v1", 8, 8,
			RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 )
		requireValue( B.white and not B.white:IsError(), "atlas_white_target" )
		render.PushRenderTarget( B.white )
		local cleared, clearError = pcall( render.Clear, 255, 255, 255, 255, false, false )
		render.PopRenderTarget()
		requireValue( cleared, clearError )
		B.upload = CreateMaterial( "mc_vanilla_bake_upload_v1", "UnlitGeneric", {
			["$basetexture"] = B.white:GetName(), ["$vertexcolor"] = 1, ["$vertexalpha"] = 1,
			["$translucent"] = 1, ["$ignorez"] = 1, ["$nofog"] = 1, ["$nocull"] = 1,
			["$no_fullbright"] = 1, ["$gammacolorread"] = 1, ["$linearwrite"] = 1,
		} )
		B.tone = Vector( 1, 1, 1 )
	end
	requireValue( B.upload and not B.upload:IsError() and B.white and not B.white:IsError(), "atlas_upload_material" )
end

local function loadSources( job )
	local p, cache = job.plan, job.cache
	for i = job.loaded + 1, job.sourceCount do
		if not cache.textures[i] then
			local bytes = file.Read( "materials/" .. p.paths[i], "GAME" )
			requireValue( type( bytes ) == "string" and #bytes <= 4194304, "missing_or_oversized_source: " .. p.paths[i] )
			requireValue( util.SHA256( bytes ) == p.hashes[i], "source_changed_rerun_prepare: " .. p.paths[i] )
			local material = Material( p.paths[i], "noclamp smooth" )
			requireValue( material and not material:IsError(), "source_material: " .. p.paths[i] )
			local texture = material:GetTexture( "$basetexture" )
			requireValue( texture and not texture:IsError(), "source_texture: " .. p.paths[i] )
			requireValue( texture:Width() == p.widths[i] and texture:Height() == p.heights[i],
				"source_texture_dimensions: " .. p.paths[i] )
			cache.textures[i] = texture
		end
		if not cache.sourceMaterials[i] then
			local texture = cache.textures[i]
			-- VGUI derives UV correction from the material's ORIGINAL mapping size.
			-- A white 1x1 seed collapses UVs even after SetTexture; share by dimensions.
			local key = texture:Width() .. "x" .. texture:Height()
			local material = B.copyMaterials[key]
			if not material then
				material = CreateMaterial( "mc_vanilla_bake_copy_v1_" .. key, "UnlitGeneric", {
					["$basetexture"] = texture:GetName(), ["$vertexcolor"] = 1, ["$vertexalpha"] = 1,
					["$translucent"] = 1, ["$ignorez"] = 1, ["$nofog"] = 1, ["$nocull"] = 1,
					["$no_fullbright"] = 1, ["$gammacolorread"] = 1, ["$linearwrite"] = 1,
				} )
				requireValue( material and not material:IsError(), "source_copy_material: " .. key )
				B.copyMaterials[key] = material
			end
			cache.sourceMaterials[i] = material
		end
		if not p.u0[i] then
			local texture = cache.textures[i]
			local du, dv = 0.5 / texture:Width(), 0.5 / texture:Height()
			local su, sv = 1 - du * 2, 1 - dv * 2
			if su == 0 then du, su = 0, 1 end
			if sv == 0 then dv, sv = 0, 1 end
			-- Undo VGUI's automatic half-texel inset, including on collapsed edge UVs.
			p.u0[i], p.v0[i] = -du / su, -dv / sv
			p.u1[i], p.v1[i] = ( p.us[i] - du ) / su, ( p.vs[i] - dv ) / sv
			p.left[i], p.right[i] = ( 0.5 / p.widths[i] - du ) / su, ( p.us[i] - 0.5 / p.widths[i] - du ) / su
			p.top[i], p.bottom[i] = ( 0.5 / p.heights[i] - dv ) / sv, ( p.vs[i] - 0.5 / p.heights[i] - dv ) / sv
		end
		job.loaded = i
	end
	cache.sourcesReady = true
end

local function replaceBlend()
	render.OverrideBlend( true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD )
end

-- Nine quads include edge/corner extrusion; source UVs select the first square frame.
-- No Color/Vector/table/string allocation and no validation in this drawing loop.
local function imageTile( cache, p, source, x, y )
	local pad, tile = p.pad, p.tile
	local u0, v0, u, v = p.u0[source], p.v0[source], p.u1[source], p.v1[source]
	local left, top, right, bottom = p.left[source], p.top[source], p.right[source], p.bottom[source]
	local material = cache.sourceMaterials[source]
	material:SetTexture( "$basetexture", cache.textures[source] )
	surface.SetMaterial( material )
	drawUV( x + pad, y + pad, tile, tile, u0, v0, u, v )
	drawUV( x + pad, y, tile, pad, u0, top, u, top )
	drawUV( x + pad, y + pad + tile, tile, pad, u0, bottom, u, bottom )
	drawUV( x, y + pad, pad, tile, left, v0, left, v )
	drawUV( x + pad + tile, y + pad, pad, tile, right, v0, right, v )
	drawUV( x, y, pad, pad, left, top, left, top )
	drawUV( x + pad + tile, y, pad, pad, right, top, right, top )
	drawUV( x, y + pad + tile, pad, pad, left, bottom, left, bottom )
	drawUV( x + pad + tile, y + pad + tile, pad, pad, right, bottom, right, bottom )
end

local function solid( x, y, size, r, g, b )
	setColor( r, g, b, 255 )
	surface.DrawTexturedRect( x, y, size, size )
end

local function drawTiles( job )
	local p, cache = job.plan, job.cache
	for i = 1, job.tileCount do
		local kind, x, y = p.kind[i], p.x[i], p.y[i]
		if kind == 1 then
			setColor( p.red[i], p.green[i], p.blue[i], 255 )
			imageTile( cache, p, p.source[i], x, y )
		elseif kind == 2 then
			setColor( 255, 255, 255, 255 )
			imageTile( cache, p, p.source[i], x, y )
			render.OverrideBlend( true, BLEND_SRC_ALPHA, BLEND_ONE_MINUS_SRC_ALPHA, BLENDFUNC_ADD,
				BLEND_ONE, BLEND_ONE_MINUS_SRC_ALPHA, BLENDFUNC_ADD )
			setColor( p.red[i], p.green[i], p.blue[i], 255 )
			imageTile( cache, p, p.overlay[i], x, y )
			replaceBlend()
		elseif kind >= 3 then
			B.upload:SetTexture( "$basetexture", B.white )
			surface.SetMaterial( B.upload )
			if kind == 3 then solid( x, y, p.stride, p.red[i], p.green[i], p.blue[i] )
			else
				local half = p.stride / 2
				solid( x, y, half, 0, 0, 0 ) solid( x + half, y + half, half, 0, 0, 0 )
				solid( x + half, y, half, 248, 0, 248 ) solid( x, y + half, half, 248, 0, 248 )
			end
		end
		job.drawn = i
	end
end

local function drawAtlasBody( job, channel )
	local cache, p = job.cache, job.plan
	local pool = channel and cache[channel] or cache.targets
	render.PushRenderTarget( pool[job.slot] ) job.pushed = true
	cam.Start2D() job.camera = true
	render.SetToneMappingScaleLinear( B.tone )
	render.OverrideAlphaWriteEnable( true, true )
	render.OverrideColorWriteEnable( true, true )
	render.PushFilterMin( TEXFILTER.POINT ) job.minFilter = true
	render.PushFilterMag( TEXFILTER.POINT ) job.magFilter = true
	replaceBlend()
	if channel then
		if channel == "normal" then render.Clear( 128, 128, 255, 255, false, false )
		else render.Clear( 0, 10, 0, 255, false, false ) end
		setColor( 255, 255, 255, 255 )
		local sources = p[channel]
		for i = 1, job.tileCount do
			local source = sources[i]
			if source ~= 0 then imageTile( cache, p, source, p.x[i], p.y[i] ) end
		end
	else
		render.Clear( 0, 0, 0, 0, false, false )
		drawTiles( job )
	end
end

local function drawAtlas( job, channel )
	local oldTone, oldClip = render.GetToneMappingScaleLinear(), DisableClipping( true )
	local ok, err = pcall( drawAtlasBody, job, channel )
	-- Restore before fault reporting (including mc_strict 1).
	render.OverrideBlend( false )
	render.OverrideAlphaWriteEnable( false )
	render.OverrideColorWriteEnable( false )
	if job.magFilter then render.PopFilterMag() end
	if job.minFilter then render.PopFilterMin() end
	render.SetToneMappingScaleLinear( oldTone )
	if job.camera then cam.End2D() end
	if job.pushed then render.PopRenderTarget() end
	job.pushed, job.camera, job.minFilter, job.magFilter = false, false, false, false
	DisableClipping( oldClip )
	if not ok then error( err, 0 ) end
end

local function publish( job )
	local cache, pack = job.cache, PACKS[job.id]
	local maps
	if job.plan.pbr then maps = { normal = cache.normal[job.slot], orm = cache.orm[job.slot] } end
	local ok, err = MC.RegisterTexturePack( job.pack, {
		title = pack.title, description = pack.description,
		preview = pack.preview, runtimeTexture = cache.targets[job.slot], runtimePBR = maps, atlasProfile = "default",
	}, pack.owner )
	requireValue( ok, err )
	cache.published = job.slot
end

local function bake( job )
	job.state = "allocating"
	allocate( job )
	job.state = "loading"
	local started = clock()
	loadSources( job )
	job.loadMS = ( clock() - started ) * 1000
	job.state = "drawing"
	started = clock()
	drawAtlas( job )
	if job.plan.pbr then drawAtlas( job, "normal" ) drawAtlas( job, "orm" ) end
	job.drawMS = ( clock() - started ) * 1000
	job.state = "publishing"
	publish( job )
end

local function runBake()
	local job, started = B.job, clock()
	if not job then return end
	-- Only defer to a render-safe entry point; never schedule another work frame.
	hook.Remove( "PostRender", HOOK )
	job.frames = 1
	local ok, err = pcall( bake, job )
	job.workMS = job.workMS + ( clock() - started ) * 1000
	if not ok then finish( "failed", tostring( err ) ) return end
	finish( "ready" )
end

function B.Start( id )
	if B.job then return false, "bake_already_running" end
	local pack = PACKS[id]
	if not pack then return false, "unknown_bake_pack" end
	local registeredOwner = MC.TexturePackDefinitionOwner( pack.name )
	if registeredOwner and registeredOwner ~= pack.owner then return false, "owned_by_" .. registeredOwner end
	if not ( MC.RegisterTexturePack and MC.GeneratedAtlas and MC.GeneratedTiles and MC.Material
		and GetRenderTargetEx and render.OverrideBlend and render.OverrideAlphaWriteEnable
		and render.OverrideColorWriteEnable and render.GetToneMappingScaleLinear and DisableClipping
		and util.SHA256 and MC.AtlasBakePlan ) then
		MC.Fault( "atlas_bake_dependencies", "Atlas baker dependencies are unavailable" )
		return false, "missing_dependencies"
	end
	local started, heap = clock(), collectgarbage( "count" )
	local bytes = file.Read( "data_static/mc/atlas_bake/" .. id .. ".json", "GAME" )
	if not bytes then return false, "source_manifest_missing:" .. id end
	if #bytes > 2097152 then return false, "manifest_too_large" end
	local cache = B.caches[id]
	if not cache then
		cache = { targets = {}, normal = {}, orm = {}, textures = {}, sourceMaterials = {} }
		B.caches[id] = cache
	end
	-- Material() caches by path for the engine session. Never pretend changed bytes reloaded.
	if cache.manifest and ( cache.manifest ~= bytes or cache.tileCatalog ~= MC.GeneratedTiles or cache.layout ~= MC.GeneratedAtlas ) then
		return false, "sources_changed_restart_client"
	end
	local p, err = cache.plan
	if not p then
		p, err = MC.AtlasBakePlan.New( util.JSONToTable( bytes ), MC.GeneratedAtlas, MC.GeneratedTiles, id, pack.pbr )
		if not p then return false, err end
	end
	if cache.sourceRevision and cache.sourceRevision ~= p.revision then return false, "sources_changed_restart_client" end
	local slot = cache.published == 1 and 2 or 1
	if targetInUse( cache.targets[slot] ) or targetInUse( cache.normal[slot] ) or targetInUse( cache.orm[slot] ) then
		return false, "previous_atlas_still_in_use"
	end
	cache.sourceRevision = p.revision
	cache.manifest, cache.plan, cache.tileCatalog, cache.layout = bytes, p, MC.GeneratedTiles, MC.GeneratedAtlas
	cache.planVersion = MC.AtlasBakePlan.VERSION
	B.serial = ( B.serial or 0 ) + 1
	B.job = { state = "queued", serial = B.serial, id = id, pack = pack.name, cache = cache, plan = p, slot = slot, started = started, heapStartKB = heap,
		loaded = cache.sourcesReady and p.sourceCount or 0, drawn = 0, sourceCount = p.sourceCount, tileCount = p.count, revision = p.revision,
		loadMS = 0, drawMS = 0,
		workMS = ( clock() - started ) * 1000, frames = 0, targetBytes = p.width * p.height * 4 * 2 * ( p.pbr and 3 or 1 ) }
	hook.Add( "PostRender", HOOK, runBake )
	notify()
	return true
end

function B.StartVanilla() return B.Start( "vanilla" ) end
function B.StartAVPBR() return B.Start( "avpbr" ) end

-- Sources may register after InitPostEntity; a saved choice still restores once available.
function B.RestorePreference()
	if not B.restoreReady or B.job then return end
	local name = MC.TexturePack:GetString()
	for id, pack in pairs( PACKS ) do
		if name == pack.name then
			if MC.TexturePackDefinitionOwner( name ) == pack.owner then return end
			local ok, err = B.Start( id )
			if not ok then MC.Fault( "atlas_bake_restore", "%s", err ) end
			return
		end
	end
end

-- Autorefresh cancels the old closure; fixed named GPU objects remain reusable.
if B.job then B.Cancel() end
for _, cache in pairs( B.caches ) do
	if cache.planVersion ~= MC.AtlasBakePlan.VERSION then
		cache.plan, cache.manifest, cache.sourcesReady = nil, nil, false
	end
end
concommand.Add( "mc_atlas_bake_vanilla", function()
	local ok, err = B.StartVanilla()
	if not ok then print( "[MC atlas bake] " .. tostring( err ) ) end
end )
concommand.Add( "mc_atlas_bake_avpbr", function()
	local ok, err = B.StartAVPBR()
	if not ok then print( "[MC atlas bake] " .. tostring( err ) ) end
end )
concommand.Add( "mc_atlas_bake_cancel", function() B.Cancel() end )
concommand.Add( "mc_atlas_bake_status", function() print( util.TableToJSON( B.Status(), true ) ) end )
hook.Add( "InitPostEntity", HOOK, function()
	B.restoreReady = true
	B.RestorePreference()
end )
