include( "shared.lua" )

ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

local PROBE_WIRE = Color( 255, 90, 70, 240 )
local PROBE_FILL = Color( 255, 90, 70, 28 )

local function blockSize()
	return MC and MC.BS or 36.5
end

local function cellWorldMin( bx, by, bz )
	if MC and MC.CellWorldMin then return MC.CellWorldMin( bx, by, bz ) end
	local bs = blockSize()
	return Vector( bx * bs, by * bs, bz * bs )
end

local function pinProbePhysicsObject( ent, phys )
	if not IsValid( ent ) then return false end
	phys = IsValid( phys ) and phys or ent:GetPhysicsObject()
	if not IsValid( phys ) then return false end

	phys:EnableMotion( false )
	phys:SetPos( ent:GetPos() )
	phys:SetAngles( ent:GetAngles() )
	return true
end

function ENT:Initialize()
	self:SetModel( "models/hunter/blocks/cube025x025x025.mdl" )
	self:DrawShadow( false )
	self:SetRenderMode( RENDERMODE_TRANSALPHA )
	self:SetColor( Color( 255, 90, 70, 80 ) )
	MC.ClientCollisionProbeEntity = self
	timer.Simple( 0, function()
		if not IsValid( self ) then return end
		if MC and MC.ApplyPendingClientCollisionProbe then MC.ApplyPendingClientCollisionProbe( self ) end
	end )
end

function ENT:ApplyProbeCell( bx, by, bz )
	bx, by, bz = math.floor( tonumber( bx ) or 0 ), math.floor( tonumber( by ) or 0 ), math.floor( tonumber( bz ) or 0 )

	local bs = blockSize()
	self.ProbeCell = { bx = bx, by = by, bz = bz }
	self.ProbeBlockSize = bs

	self:PhysicsDestroy()
	self:SetPos( cellWorldMin( bx, by, bz ) )
	self:SetAngles( angle_zero )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:SetCollisionGroup( COLLISION_GROUP_NONE )
	self:EnableCustomCollisions( true )
	self:SetCollisionBounds( Vector( 0, 0, 0 ), Vector( bs, bs, bs ) )
	self:SetRenderBounds( Vector( 0, 0, 0 ), Vector( bs, bs, bs ) )
	self:PhysicsInitBox( Vector( 0, 0, 0 ), Vector( bs, bs, bs ) )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )

	local phys = self:GetPhysicsObject()
	if IsValid( phys ) then
		pinProbePhysicsObject( self, phys )
		phys:Wake()
		return true
	end

	return false
end

function ENT:PhysicsUpdate( phys )
	pinProbePhysicsObject( self, phys )
end

function ENT:Think()
	local phys = self:GetPhysicsObject()
	if self.ProbeCell then
		phys:SetVelocity( Vector(0, 0, 0) )
        phys:SetAngleVelocity( Vector(0, 0, 0) )
		local bx = self.ProbeCell.bx
		local by = self.ProbeCell.by
		local bz = self.ProbeCell.bz

		phys:SetPos(cellWorldMin( bx, by, bz ))
		phys:SetAngles( angle_zero )
		self:SetPos( cellWorldMin( bx, by, bz ) )
		self:SetAngles( angle_zero )
		
		
	end

	self:NextThink( CurTime() )
	return true
end

function ENT:DrawTranslucent()
	local bs = self.ProbeBlockSize or blockSize()
	local mins = Vector( 0, 0, 0 )
	local maxs = Vector( bs, bs, bs )

	render.SetColorMaterial()
	render.DrawBox( self:GetPos(), self:GetAngles(), mins, maxs, PROBE_FILL, true )
	
	render.DrawWireframeBox( self:GetPos(), self:GetAngles(), mins, maxs, PROBE_WIRE, true )
end

function ENT:Draw()
	self:DrawTranslucent()
end
