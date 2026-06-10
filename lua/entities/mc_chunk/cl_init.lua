include( "shared.lua" )

ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:Initialize()
	self:DrawShadow( false )
	self:EnsureKey()

	-- local-space render bounds covering the whole chunk (entity sits at chunk origin)
	local w = MC.ChunkWorld
	self:SetRenderBounds( Vector( 0, 0, 0 ), Vector( w, w, MC.ChunkWorldH ) )

	-- clientside collision for smooth local-player movement prediction, using the
	-- same recipe as the server (VPHYSICS + custom collisions) so traces/movement
	-- actually hit the convex mesh instead of the bounding box
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )

	MC.ChunkEnts[ self.ChunkKey ] = self
	MC.MarkChunkPhysDirty( self.ChunkKey )      -- build collision once data is present
	if not MC.Meshes[ self.ChunkKey ] and not ( MC.MeshesTrans and MC.MeshesTrans[ self.ChunkKey ] ) then
		MC.MarkChunkDirty( self.ChunkKey )       -- build mesh if data arrived first
	end
end

function ENT:Draw()
end

-- chunk meshes draw via the PostDrawOpaqueRenderables / PostDrawTranslucentRenderables
-- hooks in cl_render.lua; the entity itself draws nothing
function ENT:DrawTranslucent() end

function ENT:OnRemove()
	local key = self.ChunkKey
	if key and MC.ChunkEnts[ key ] == self then
		MC.ChunkEnts[ key ] = nil
	end
end

-- keep the clientside collision frozen at the chunk origin (parity with the
-- server): under MOVETYPE_VPHYSICS this stops prediction physics from drifting
-- the entity away from where the mesh is drawn
function ENT:PhysicsUpdate() end
