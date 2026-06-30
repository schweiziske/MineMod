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

local function resetColorWriteOverride()
	if render.OverrideColorWriteEnable then
		render.OverrideColorWriteEnable( false, false )
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

local function setDepthPrepassColorMask()
	if render.OverrideColorWriteEnable then
		render.OverrideColorWriteEnable( true, false )
		return true
	end
	return false
end

local function restoreChunkMeshRenderState( setCullMode )
	if setCullMode then pcall( restoreDefaultCullMode ) end
	resetColorWriteOverride()
	resetDepthOverride()
end

local function drawMeshList( list, material, writeDepth, writeColor, forceMaterial )
	if not list then return end
	local setCullMode = false
	local function draw()
		resetDepthOverride()
		resetColorWriteOverride()
		if writeDepth then forceDepthWrite() end
		if writeColor == false then setDepthPrepassColorMask() end
		setCullMode = setChunkMeshCullMode()
		local currentMaterial = material
		render.SetMaterial( currentMaterial )
		for i = 1, #list do
			local entry = list[i]
			local meshObj = entry
			local entryMaterial = material
			if type( entry ) == "table" then
				meshObj = entry.mesh
				if not forceMaterial then
					entryMaterial = entry.material or material
				end
			end
			if entryMaterial ~= currentMaterial then
				currentMaterial = entryMaterial
				render.SetMaterial( currentMaterial )
			end
			if meshObj and meshObj.Draw then meshObj:Draw() end
		end
	end
	local ok, err = xpcall( draw, debug and debug.traceback or tostring )
	restoreChunkMeshRenderState( setCullMode )
	if not ok then error( err ) end
end

local function drawGpuOpaqueDepthPrepass( list )
	if not ( MC.UsingGpuChunkShader and MC.UsingGpuChunkShader() ) then return end
	local cpuMaterial = MC.MaterialOpaqueCPU or MC.Material
	if not cpuMaterial then return end
	drawMeshList( list, cpuMaterial, true, false, true )
end

function MC.DrawChunk( key )
	local list = MC.Meshes[key]
	local material = MC.CurrentChunkMaterial and MC.CurrentChunkMaterial( false ) or MC.Material
	if material == MC.MaterialGpuLightTexture and MC.BindGpuChunkLightTexture then
		MC.BindGpuChunkLightTexture( key, material )
	end
	if material == MC.MaterialGpuOpaque or material == MC.MaterialGpuLightTexture then
		drawGpuOpaqueDepthPrepass( list )
	end
	drawMeshList( list, material, true )
end

function MC.DrawChunkTranslucent( key )
	local material = MC.CurrentChunkMaterial and MC.CurrentChunkMaterial( true ) or MC.MaterialTranslucent
	drawMeshList( MC.MeshesTrans[key], material, false )
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
