AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

function ENT:Initialize()
	self:SetModel( "models/hunter/blocks/cube025x025x025.mdl" )
	self:DrawShadow( false )
	self:SetUseType( SIMPLE_USE )
	-- record + physics are attached by MC.SV.SpawnCluster right after Spawn()
end

-- MC builds regularly sit outside the map's PVS (world coords go far beyond
-- the map bounds), where PVS-based transmit would never send the entity to
-- anyone. Clusters are few, so always transmitting is cheap and reliable.
function ENT:UpdateTransmitState()
	return TRANSMIT_ALWAYS
end

function ENT:SetClusterRecord( record, blob )
	self.ClusterRecord = record
	self.ClusterBlob = blob
	self:SetBlockCount( math.floor( #record.cells / 4 ) )
	self:SetSizeX( record.size[1] )
	self:SetSizeY( record.size[2] )
	self:SetSizeZ( record.size[3] )
end

function ENT:Use( activator )
	if not IsValid( activator ) or not activator:IsPlayer() then return end
	if ( self.mcNextUseInfo or 0 ) > CurTime() then return end
	self.mcNextUseInfo = CurTime() + 0.5

	local durability = ( self.ClusterMaxHealth or 0 ) > 0
		and ( math.max( 0, math.floor( self.ClusterHealth or 0 ) ) .. "/" .. self.ClusterMaxHealth )
		or "无敌"
	local info = "方块结构: " .. self:GetBlockCount() .. " 方块  耐久 " .. durability
	local owner = self:GetOwnerLabel()
	if owner ~= "" then info = info .. "  主人 " .. owner end
	local phys = self:GetPhysicsObject()
	if IsValid( phys ) and not phys:IsMotionEnabled() then info = info .. "  [已冻结]" end
	activator:ChatPrint( "[MC] " .. info )
end

function ENT:RebuildClusterPhysics( frozen )
	local record = self.ClusterRecord
	if not record then return false, "no_record" end

	local convexes, err, convexCount = MC.BuildClusterConvexes( record.cells, record.size )
	if not convexes then return false, err, convexCount end
	if not self:ApplyClusterPhysics( convexes, frozen ) then return false, "phys_apply_failed" end

	local count = math.floor( #record.cells / 4 )
	local phys = self:GetPhysicsObject()
	if IsValid( phys ) then
		local massPer = MC.Config.ClusterMassPerBlock and MC.Config.ClusterMassPerBlock:GetFloat() or 10
		phys:SetMass( math.Clamp( count * math.max( massPer, 0.1 ), 1, 50000 ) )
	end

	local hpPer = MC.Config.ClusterHealthPerBlock and MC.Config.ClusterHealthPerBlock:GetFloat() or 4
	local hp = hpPer > 0 and math.max( 50, math.floor( count * hpPer ) ) or 0
	self.ClusterMaxHealth = hp
	self.ClusterHealth = hp
	self:SetMaxHealth( hp )
	self:SetHealth( hp )
	self:SetClusterMaxHP( hp )

	-- RTT drop shadow hack (engine-style extras only): the engine's blob
	-- shadow renders the (never-drawn) placeholder model, so scale it to
	-- roughly the structure's size. The model is absent from the main view and
	-- flashlight depth because ENT:Draw never calls DrawModel; only the shadow
	-- manager reads it. Client keeps it centered via SetRenderOrigin.
	-- cube025x025x025 is ~11.81 units per side.
	if MC.ClusterEngineStyle == true then
		local maxDim = math.max( record.size[1], record.size[2], record.size[3] ) * MC.BS
		self:SetModelScale( math.Clamp( maxDim / 11.8125, 1, 512 ), 0 )
		self:DrawShadow( true )
	else
		self:SetModelScale( 1, 0 )
		self:DrawShadow( false )
	end
	return true
end

function ENT:OnTakeDamage( dmginfo )
	local phys = self:GetPhysicsObject()
	if IsValid( phys ) and phys:IsMotionEnabled() then
		phys:ApplyForceOffset( dmginfo:GetDamageForce(), dmginfo:GetDamagePosition() )
	end

	if ( self.ClusterMaxHealth or 0 ) <= 0 then return 0 end -- indestructible
	if self.ClusterDead then return 0 end
	local dmg = dmginfo:GetDamage()
	if dmg <= 0 then return 0 end

	self.ClusterHealth = ( self.ClusterHealth or self.ClusterMaxHealth ) - dmg
	self:SetHealth( math.max( 0, math.floor( self.ClusterHealth ) ) )
	if self.ClusterHealth <= 0 then
		self.ClusterDead = true
		if MC.SV and MC.SV.BreakCluster then MC.SV.BreakCluster( self, dmginfo:GetAttacker() ) end
	end
	return 0
end
