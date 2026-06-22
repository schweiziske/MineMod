-- Chunk mesh draw hooks.
------------------------------------------------------------------------- drawing
local function meshRenderingEnabled()
	return not MC.MeshRender or MC.MeshRender:GetBool()
end

local function drawMeshList( list, material )
	if not list then return end
	render.SetMaterial( material )
	for i = 1, #list do
		list[i]:Draw()
	end
end

function MC.DrawChunk( key )
	drawMeshList( MC.Meshes[key], MC.Material )
end

function MC.DrawChunkTranslucent( key )
	drawMeshList( MC.MeshesTrans[key], MC.MaterialTranslucent )
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
