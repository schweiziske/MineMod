include( "shared.lua" )

ENT.RenderGroup = RENDERGROUP_BOTH

function ENT:Initialize()
	self:TryClusterData()
end

-- The payload can arrive before this entity exists client-side (spawn push
-- races the entity snapshot); cl_block_cluster.lua parks it in
-- MC.ClusterPendingRecords for us to claim here.
function ENT:TryClusterData()
	if self.ClusterRecord then return end

	local pending = MC.ClusterPendingRecords and MC.ClusterPendingRecords[self:EntIndex()] or nil
	if pending and pending.expires > CurTime() then
		MC.ClusterPendingRecords[self:EntIndex()] = nil
		self:ApplyClusterRecord( pending.record )
		return
	end

	self:ApplyNetworkedBounds()
	self:RequestClusterData()
end

-- Size arrives through the datatable, so bounds and aim OBB tests work even
-- before the cell payload does. Render origin is pinned to the structure's
-- center: the entity origin sits at the min corner, and the engine positions
-- the RTT drop shadow (cast by the invisible scaled placeholder model) at the
-- render origin. Bounds are centered around it to keep culling correct.
function ENT:ApplyNetworkedBounds()
	local sx, sy, sz
	local record = self.ClusterRecord
	if record then
		sx, sy, sz = record.size[1], record.size[2], record.size[3]
	else
		sx, sy, sz = self:GetSizeX(), self:GetSizeY(), self:GetSizeZ()
	end
	if not sx or sx <= 0 or sy <= 0 or sz <= 0 then return end

	if MC.ClusterEngineStyle == true then
		local half = Vector( sx * MC.BS * 0.5, sy * MC.BS * 0.5, sz * MC.BS * 0.5 )
		self:SetRenderOrigin( self:LocalToWorld( half ) )
		self:SetRenderBounds( -half, half )
	else
		self:SetRenderBounds( vector_origin, Vector( sx * MC.BS, sy * MC.BS, sz * MC.BS ) )
	end
end

function ENT:RequestClusterData()
	if ( self.ClusterNextRequest or 0 ) > CurTime() then return end
	self.ClusterNextRequest = CurTime() + 3
	net.Start( "mc_cluster_data_req" )
		net.WriteUInt( self:EntIndex(), 16 )
	net.SendToServer()
end

function ENT:Think()
	if not self.ClusterRecord then
		self:TryClusterData()
		self:SetNextClientThink( CurTime() + 1 )
		return true
	end

	self:ApplyNetworkedBounds()
	self:UpdatePredictionMirror()
	self:SetNextClientThink( CurTime() )
	return true
end

function ENT:FreeClusterMeshes()
	local built = self.ClusterMeshes
	if not built then return end
	for _, list in pairs( built ) do
		for _, entry in ipairs( list ) do
			if entry.mesh then entry.mesh:Destroy() end
		end
	end
	self.ClusterMeshes = nil
end

function ENT:ApplyClusterRecord( record )
	self.ClusterRecord = record
	self:FreeClusterMeshes()
	self.ClusterMeshes = MC.BuildClusterMeshes and MC.BuildClusterMeshes( record ) or nil
	self:ApplyNetworkedBounds()

	-- Client prediction collision, same pattern as the mc_chunk shell: player
	-- movement is predicted locally, and custom server physics never reaches
	-- the client, so without this local mirror players fall straight through
	-- (worst on moving clusters, e.g. balloon-lifted). The mirror stays
	-- frozen and is teleported to the interpolated transform every tick.
	-- Client prediction collision (mc_chunk pattern), but only while the
	-- entity RESTS. IVP treats the frozen mirror as static geometry, and
	-- moving static geometry is its most expensive operation — teleporting
	-- the mirror along every frame cost ~470 fps while the cluster moved.
	-- So: destroyed the moment the entity moves (no collision beats
	-- wrongly-placed collision; riding a moving cluster is
	-- server-authoritative anyway), rebuilt in place once it settles.
	self.ClusterMirrorConvexes = MC.ClusterCollisionConvexes and MC.ClusterCollisionConvexes( record ) or nil
	self.ClusterLastMovePos = self:GetPos()
	self.ClusterLastMoveAng = self:GetAngles()
	self.ClusterLastMoveTime = 0
	self:RebuildPredictionMirror()
end

local MIRROR_SETTLE_DELAY = 0.3

function ENT:RebuildPredictionMirror()
	local convexes = self.ClusterMirrorConvexes
	if not convexes then return end
	self:ApplyClusterPhysics( convexes, true )
	-- MOVETYPE_VPHYSICS on the CLIENT hands the entity's motion to the
	-- local physics object and kills network interpolation (snapshot-rate
	-- stutter); NONE keeps normal interpolation.
	self:SetMoveType( MOVETYPE_NONE )
	self.ClusterMirrorAlive = true
end

function ENT:DestroyPredictionMirror()
	if not self.ClusterMirrorAlive then return end
	self.ClusterMirrorAlive = false
	self:PhysicsDestroy()
end

function ENT:UpdatePredictionMirror()
	local pos, ang = self:GetPos(), self:GetAngles()
	local moved = not self.ClusterLastMovePos
		or pos:DistToSqr( self.ClusterLastMovePos ) > 0.01
		or ang ~= self.ClusterLastMoveAng
	if moved then
		self.ClusterLastMovePos = pos
		self.ClusterLastMoveAng = ang
		self.ClusterLastMoveTime = CurTime()
		self:DestroyPredictionMirror()
		return
	end
	if not self.ClusterMirrorAlive and CurTime() - self.ClusterLastMoveTime > MIRROR_SETTLE_DELAY then
		self:RebuildPredictionMirror()
	end
end

local function drawMeshList( self, list )
	if not list or #list == 0 then return end

	local tinted, alpha = false, false
	if MC.ClusterEngineStyle == true then
		-- colour tool support (engine-style extras only)
		local color = self:GetColor()
		tinted = color.r ~= 255 or color.g ~= 255 or color.b ~= 255
		alpha = color.a < 255
		if tinted then render.SetColorModulation( color.r / 255, color.g / 255, color.b / 255 ) end
		if alpha then render.SetBlend( color.a / 255 ) end
	elseif MC.ClusterLightRGB then
		-- classic style: modulate the unlit mesh with sampled voxel light
		local lr, lg, lb = MC.ClusterLightRGB( self )
		if lr ~= 1 or lg ~= 1 or lb ~= 1 then
			tinted = true
			render.SetColorModulation( lr, lg, lb )
		end
	end

	cam.PushModelMatrix( self:GetWorldTransformMatrix() )
	for _, entry in ipairs( list ) do
		render.SetMaterial( entry.material )
		entry.mesh:Draw()
	end
	cam.PopModelMatrix()

	if tinted then render.SetColorModulation( 1, 1, 1 ) end
	if alpha then render.SetBlend( 1 ) end
end

-- The sandbox physgun halo re-renders the held entity to build its outline.
-- That pass calls this Draw again and composites it additively, which blows
-- the whole mesh out (overexposure). Halos only work for models; skip the
-- pass entirely.
local function inHaloPass( self )
	return halo and halo.RenderedEntity and halo.RenderedEntity() == self
end

function ENT:Draw()
	if inHaloPass( self ) then return end
	local built = self.ClusterMeshes
	if not built then
		self:TryClusterData()
		return
	end
	self:ApplyNetworkedBounds() -- follow the moving entity (shadow + culling)
	drawMeshList( self, built.opaque )
end

function ENT:DrawTranslucent()
	if inHaloPass( self ) then return end
	local built = self.ClusterMeshes
	if not built then return end
	drawMeshList( self, built.translucent )
end

-- Keep a short-lived snapshot so break FX arriving after the entity's
-- removal still know where and what to burst.
function ENT:OnRemove()
	if self.ClusterRecord then
		MC.ClusterRecentRemoved = MC.ClusterRecentRemoved or {}
		MC.ClusterRecentRemoved[self:EntIndex()] = {
			record = self.ClusterRecord,
			matrix = self:GetWorldTransformMatrix(),
			expires = CurTime() + 5,
		}
	end
	self:PhysicsDestroy()
	self:FreeClusterMeshes()
end
