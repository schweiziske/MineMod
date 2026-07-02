AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

local DEFAULT_CELL = { 10, 9, -334 }
local PROBE_RADIUS = 1
local PHYSICS_MODEL = "models/hunter/blocks/cube025x025x025.mdl"

local function blockSize()
	return MC and MC.BS or 36.5
end

local function cellWorldMin( bx, by, bz )
	if MC and MC.CellWorldMin then return MC.CellWorldMin( bx, by, bz ) end
	local bs = blockSize()
	return Vector( bx * bs, by * bs, bz * bs )
end

local function freezePhysicsObject( ent )
	local phys = ent:GetPhysicsObject()
	if not IsValid( phys ) then return false end
	phys:EnableMotion( false )
	phys:Wake()
	return true
end

function ENT:Initialize()
	self:SetModel( PHYSICS_MODEL )
	self:DrawShadow( false )
	self:PhysicsInit( SOLID_VPHYSICS )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )
	freezePhysicsObject( self )
end

function ENT:ApplyProbeCell( bx, by, bz )
	bx, by, bz = math.floor( tonumber( bx ) or DEFAULT_CELL[1] ),
		math.floor( tonumber( by ) or DEFAULT_CELL[2] ),
		math.floor( tonumber( bz ) or DEFAULT_CELL[3] )

	local bs = blockSize()
	self.ProbeCell = { bx = bx, by = by, bz = bz }
	self.ProbeBlockSize = bs

	local size = bs * ( PROBE_RADIUS * 2 + 1 )
	local origin = cellWorldMin( bx - PROBE_RADIUS, by - PROBE_RADIUS, bz - PROBE_RADIUS )
	self:PhysicsDestroy()
	if self:GetModel() ~= PHYSICS_MODEL then
		self:SetModel( PHYSICS_MODEL )
	end
	self:SetPos( origin )
	self:SetAngles( Angle( 0, 0, 0 ) )
	self:SetCollisionBounds( Vector( 0, 0, 0 ), Vector( size, size, size ) )
	if self.SetRenderBounds then
		self:SetRenderBounds( Vector( 0, 0, 0 ), Vector( size, size, size ) )
	end
	self:PhysicsInitBox( Vector( 0, 0, 0 ), Vector( size, size, size ) )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )

	return freezePhysicsObject( self )
end

function ENT:UpdateTransmitState()
	return TRANSMIT_ALWAYS
end

function ENT:PhysgunPickup()
	return false
end

function ENT:CanProperty( _ply, property )
	if property == "unfreeze" then return false end
end
