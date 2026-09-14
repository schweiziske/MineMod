-- Opt-in GPU readback. No world rebuilds, repairs or persistent frame work.
MC = MC or {}
local A = MC.RenderAtlasAudit or {}
MC.RenderAtlasAudit = A
local G, P, R, L = MC.RenderPackGeometry, MC.RenderPackResources, MC.RenderL2Resources, MC.RenderPackRuntime
local requireValue, floor = R.Require, math.floor
local HOOK, PATH = "mc_render_atlas_audit", "mc/render_atlas_audit.json"

local function rgba( pixel )
	return { pixel % 256, floor( pixel / 256 ) % 256, floor( pixel / 65536 ) % 256, floor( pixel / 16777216 ) }
end

local function capture( target, inspect, clear )
	local pushed, camera = false, false
	local ok, err = pcall( function()
		render.PushRenderTarget( target ) pushed = true
		cam.Start2D() camera = true
		if clear then render.Clear( clear[1], clear[2], clear[3], clear[4], false, false ) end
		render.CapturePixels()
		inspect()
	end )
	local errors = {}
	local function restore( active, fn )
		if not active then return end
		local restored, why = pcall( fn )
		if not restored then errors[#errors + 1] = tostring( why ) end
	end
	restore( camera, cam.End2D )
	restore( pushed, render.PopRenderTarget )
	requireValue( #errors == 0, "render_atlas_audit_restore", table.concat( errors, "; " ) )
	if not ok then error( err, 0 ) end
end

local function newComparison()
	return { checked = 0, mismatches = 0, channels = { 0, 0, 0, 0 }, examples = {}, zeroShade = 0 }
end

local function compare( result, x, y, expected, context )
	local r, g, b, a = render.ReadPixel( x, y )
	local actual, wanted = { r, g, b, a }, rgba( expected )
	local mismatch = false
	result.checked = result.checked + 1
	for channel = 1, 4 do
		if actual[channel] ~= wanted[channel] then
			result.channels[channel] = result.channels[channel] + 1
			mismatch = true
		end
	end
	if mismatch then
		result.mismatches = result.mismatches + 1
		if #result.examples < 12 then
			result.examples[#result.examples + 1] = { x = x, y = y, expected = wanted,
				actual = { r or -1, g or -1, b or -1, a or -1 }, context = context }
		end
	end
end

local function checkReadback( report )
	if not A.control then
		A.control = GetRenderTargetEx( "mc_render_atlas_audit_control_v1", 2048, 2048,
			RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 )
	end
	requireValue( A.control and not A.control:IsError() and A.control:Width() == 2048 and A.control:Height() == 2048,
		"render_atlas_audit_control", "could not create independent readback control target" )
	report.control = newComparison()
	-- Independent clears test RGBA and the area outside the game viewport.
	for _, color in ipairs( { { 37, 109, 211, 173 }, { 211, 37, 109, 91 } } ) do
		local packed = color[1] + color[2] * 256 + color[3] * 65536 + color[4] * 16777216
		capture( A.control, function()
			for _, xy in ipairs( { { 0, 0 }, { 2047, 0 }, { 0, 2047 }, { 2047, 2047 }, { 1023, 1023 } } ) do
				compare( report.control, xy[1], xy[2], packed, "clear control" )
			end
		end, color )
	end
	requireValue( report.control.mismatches == 0, "render_atlas_audit_readback",
		"known-color control failed; live atlas readback is not trustworthy" )
end

local function textureInfo( texture )
	if not texture then return { missing = true } end
	return { name = texture:GetName(), width = texture:Width(), height = texture:Height() }
end

local function audit( report )
	requireValue( render.CapturePixels and render.ReadPixel and render.Clear,
		"render_atlas_audit_api", "GPU audit requires CapturePixels, ReadPixel and Clear" )
	local c = L.active
	requireValue( c ~= nil, "render_atlas_audit_runtime", "no active L2 runtime" )
	report.build, report.pack = L.Status().build, c.pack
	report.screenWidth, report.screenHeight = ScrW(), ScrH()
	checkReadback( report )
	report.atlasTexture, report.lightmapTexture = textureInfo( P.shared.atlas ), textureInfo( P.shared.lightmap )
	local parts, seen, materials = {}, {}, {}
	for key, sections in pairs( c.sections ) do
		if L.ChunkCurrent( key ) then
			for index, section in pairs( sections ) do
				for _, data in ipairs( section.resources ) do
					if not seen[data] then
						seen[data] = true
						parts[#parts + 1] = { data = data, chunk = tostring( key ), section = index }
					end
				end
				for _, entries in pairs( section.passes ) do
					for _, entry in ipairs( entries ) do materials[entry.material] = true end
				end
			end
		else report.staleChunks = report.staleChunks + 1 end
	end
	table.sort( parts, function( a, b ) return a.data.firstQuad < b.data.firstQuad end )
	local endQuad = 0
	for _, part in ipairs( parts ) do
		local data = part.data
		if data.firstQuad < endQuad then report.overlaps = report.overlaps + 1 end
		endQuad = math.max( endQuad, data.firstQuad + data.quadCount )
	end
	for material in pairs( materials ) do
		local atlas, lightmap = material:GetTexture( "$texture1" ), material:GetTexture( "$texture2" )
		local valid = atlas and lightmap and R.SameTexture( atlas, P.shared.atlas ) and R.SameTexture( lightmap, P.shared.lightmap )
		report.materials[#report.materials + 1] = { name = material:GetName(), valid = valid == true,
			atlas = textureInfo( atlas ), lightmap = textureInfo( lightmap ) }
		if not valid then report.bindingMismatches = report.bindingMismatches + 1 end
	end
	capture( P.shared.atlas, function()
		for _, part in ipairs( parts ) do
			local data = part.data
			local pixels = G.auditPixels[data]
			report.parts = report.parts + 1
			report.quads = report.quads + data.quadCount
			if pixels then
				requireValue( #pixels == data.quadCount * 4, "render_atlas_audit_pixels", "captured part length changed" )
				report.capturedParts = report.capturedParts + 1
				local context = { chunk = part.chunk, section = part.section, firstQuad = data.firstQuad, quads = data.quadCount }
				for i = 1, #pixels do
					local offset = data.firstQuad * 4 + i - 1
					if floor( pixels[i] / 65536 ) % 256 == 0 then report.atlas.zeroShade = report.atlas.zeroShade + 1 end
					compare( report.atlas, offset % 2048, floor( offset / 2048 ), pixels[i], context )
				end
			else report.missingQuads = report.missingQuads + data.quadCount end
		end
	end )
	requireValue( P.shared.lightmapPixels and not P.shared.lightmapUploadPending,
		"render_atlas_audit_lightmap", "no successfully published lightmap bytes" )
	capture( P.shared.lightmap, function()
		for i = 1, 256 do compare( report.lightmap, ( i - 1 ) % 16, floor( ( i - 1 ) / 16 ),
			P.shared.lightmapPixels[i], "global lightmap" ) end
	end )
	if report.atlas.mismatches > 0 or report.lightmap.mismatches > 0 or report.bindingMismatches > 0 or report.overlaps > 0 then
		report.status = "mismatch"
	elseif report.missingQuads > 0 or report.parts == 0 or report.staleChunks > 0 then
		report.status = "incomplete"
	else report.status = "bytes_match" end
end

local function run()
	hook.Remove( "PostRender", HOOK )
	A.queued = false
	local started = SysTime()
	local report = { status = "failed", parts = 0, quads = 0, capturedParts = 0, missingQuads = 0,
		staleChunks = 0, overlaps = 0, bindingMismatches = 0, materials = {}, atlas = newComparison(), lightmap = newComparison() }
	local ok, err = pcall( audit, report )
	local code
	if not ok then
		code = type( err ) == "table" and err.code or "render_atlas_audit_failed"
		report.error = type( err ) == "table" and err.message or tostring( err )
	end
	report.elapsedMS = ( SysTime() - started ) * 1000
	A.last = report
	print( string.format( "[MC atlas audit] build=%s elapsedMS=%.2f", report.build or "-", report.elapsedMS ) )
	print( string.format( "[MC atlas audit] status=%s parts=%d/%d quads=%d missingQuads=%d overlaps=%d bindings=%d",
		report.status, report.capturedParts, report.parts, report.quads, report.missingQuads, report.overlaps, report.bindingMismatches ) )
	for _, name in ipairs( { "control", "atlas", "lightmap" } ) do
		local result = report[name]
		if result then
			print( string.format( "[MC atlas audit] %s checked=%d mismatches=%d RGBA=%s CPUzeroShade=%d",
				name, result.checked, result.mismatches, table.concat( result.channels, "/" ), result.zeroShade ) )
			for i = 1, math.min( 3, #result.examples ) do
				local example = result.examples[i]
				print( string.format( "[MC atlas audit] %s (%d,%d) expected=%s actual=%s",
					name, example.x, example.y, table.concat( example.expected, "/" ), table.concat( example.actual, "/" ) ) )
			end
		end
	end
	local saved, why = pcall( function()
		file.CreateDir( "mc" )
		local json = util.TableToJSON( report, true )
		requireValue( type( json ) == "string", "render_atlas_audit_json", "could not encode audit report" )
		file.Write( PATH, json )
		requireValue( file.Read( PATH, "DATA" ) == json, "render_atlas_audit_write", "could not verify saved audit report" )
	end )
	if saved then print( "[MC atlas audit] report=garrysmod/data/" .. PATH )
	else L.QueueFault( "render_atlas_audit_save", why ) end
	if not ok then L.QueueFault( code, report.error )
	elseif report.status == "mismatch" then
		L.QueueFault( "render_atlas_audit_mismatch", "GPU bytes, active bindings or atlas allocation differ; see audit report" )
	end
	L.ReportFaults()
end

concommand.Add( "mc_render_atlas_audit", function( _, _, args )
	local action = args[1]
	if #args == 1 and action == "arm" then
		hook.Remove( "PostRender", HOOK )
		A.queued, A.last = false, nil
		G.auditPixels = setmetatable( {}, { __mode = "k" } )
		print( "[MC atlas audit] armed: capture future uploads only; no rebuild queued" )
	elseif #args == 1 and action == "off" then
		hook.Remove( "PostRender", HOOK )
		G.auditPixels, A.last, A.queued = nil, nil, false
		print( "[MC atlas audit] off: captures released, pending check cancelled" )
	elseif #args == 1 and action == "check" then
		if not G.auditPixels then print( "[MC atlas audit] run arm before loading the test world" ) return end
		if A.queued then print( "[MC atlas audit] check already queued" ) return end
		A.queued = true
		hook.Add( "PostRender", HOOK, run )
		print( "[MC atlas audit] one readback queued; may stall this frame; not a performance benchmark" )
	else print( "Usage: mc_render_atlas_audit arm|check|off" ) end
end )
