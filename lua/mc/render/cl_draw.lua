-- Chunk mesh draw hooks.
------------------------------------------------------------------------- drawing
local function meshRenderingEnabled()
	return not MC.MeshRender or MC.MeshRender:GetBool()
end

MC.MeshCullMode = MC.MeshCullMode or ( CreateClientConVar and CreateClientConVar( "mc_mesh_cull_mode", "ccw", true, false,
	"MC chunk mesh cull mode: cw or ccw" ) )

local function meshCullMode()
	local cv = MC.MeshCullMode
	local mode = cv and cv.GetString and string.lower( tostring( cv:GetString() or "" ) ) or "ccw"
	if mode == "ccw" or mode == "counterclockwise" or mode == "counter-clockwise" then
		return MATERIAL_CULLMODE_CCW or 0
	end
	return MATERIAL_CULLMODE_CW or 1
end

local function setChunkMeshCullMode()
	if render.CullMode then
		render.CullMode( meshCullMode() )
		return true
	end
	return false
end

local function restoreDefaultCullMode()
	if render.CullMode then
		render.CullMode( MATERIAL_CULLMODE_CCW or 0 )
	end
end

local function resetDepthOverride()
	if render.OverrideDepthEnable then
		render.OverrideDepthEnable( false, false )
		return true
	end
	return false
end

local function forceDepthWrite()
	if render.OverrideDepthEnable then
		render.OverrideDepthEnable( true, true )
		return true
	end
	return false
end

local function safePopMeshLightmapFilter( pushedMin, pushedMag )
	if MC.PopMeshLightmapPointFilter then
		pcall( MC.PopMeshLightmapPointFilter, pushedMin, pushedMag )
	end
end

local function restoreChunkMeshRenderState( setCullMode, pushedMin, pushedMag )
	if pushedMin or pushedMag then safePopMeshLightmapFilter( pushedMin, pushedMag ) end
	if setCullMode then pcall( restoreDefaultCullMode ) end
	resetDepthOverride()
end

local function drawMeshList( list, material, writeDepth )
	if not list then return end
	local setCullMode = false
	local pushedMin, pushedMag = false, false
	local function draw()
		resetDepthOverride()
		if writeDepth then forceDepthWrite() end
		setCullMode = setChunkMeshCullMode()
		local currentMaterial = material
		render.SetMaterial( currentMaterial )
		for i = 1, #list do
			local entry = list[i]
			local meshObj = entry
			local entryMaterial = material
			local entryLightmap = false
			if type( entry ) == "table" then
				meshObj = entry.mesh
				entryMaterial = entry.material or material
				entryLightmap = entry.lightmap == true
			end
			if entryMaterial ~= currentMaterial then
				currentMaterial = entryMaterial
				render.SetMaterial( currentMaterial )
			end
			if entryLightmap and render.SetLightmapTexture and MC.GetMeshLightmapTexture then
				if MC.PushMeshLightmapPointFilter then
					pushedMin, pushedMag = MC.PushMeshLightmapPointFilter()
				end
				render.SetLightmapTexture( MC.GetMeshLightmapTexture() )
			end
			if meshObj and meshObj.Draw then meshObj:Draw() end
			if entryLightmap then
				safePopMeshLightmapFilter( pushedMin, pushedMag )
				pushedMin, pushedMag = false, false
			end
		end
	end
	local ok, err = xpcall( draw, debug and debug.traceback or tostring )
	restoreChunkMeshRenderState( setCullMode, pushedMin, pushedMag )
	if not ok then error( err ) end
end

function MC.DrawChunk( key )
	drawMeshList( MC.Meshes[key], MC.Material, true )
end

function MC.DrawChunkTranslucent( key )
	drawMeshList( MC.MeshesTrans[key], MC.MaterialTranslucent, false )
end

local function drawAllChunks( store, drawFn )
	for key, list in pairs( store or {} ) do
		if list then
			local c = MC.GetChunkByKey( key )
			if c then
				local mat = Matrix()
				mat:SetTranslation( MC.ChunkWorldOrigin( c.cx, c.cy, c.cz ) )
				cam.PushModelMatrix( mat )
					drawFn( key )
				cam.PopModelMatrix()
			end
		end
	end
end

hook.Remove( "PostDrawOpaqueRenderables", "mc_draw_chunks" )
hook.Remove( "PostDrawTranslucentRenderables", "mc_draw_chunks" )
hook.Add( "PostDrawOpaqueRenderables", "mc_draw_chunks", function( bDepth, bSky, bSky3D )
	if bSky or bSky3D then return end
	if not meshRenderingEnabled() then return end
	drawAllChunks( MC.Meshes, MC.DrawChunk )
end )
-- translucent blocks only; the bulk of the world stays in the opaque pass above
hook.Add( "PostDrawTranslucentRenderables", "mc_draw_chunks", function( bDepth, bSky, bSky3D )
	if bSky or bSky3D then return end
	if not meshRenderingEnabled() then return end
	drawAllChunks( MC.MeshesTrans, MC.DrawChunkTranslucent )
end )
