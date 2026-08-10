AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

local HULL_MIN = Vector( -1.5, -1.5, -1.5 )
local HULL_MAX = Vector( 1.5, 1.5, 1.5 )

local function validOwner( ent )
	local owner = ent:GetOwner()
	return IsValid( owner ) and owner:IsPlayer() and owner:Alive()
end

local function traceFilter( ent, ignoreOwner )
	local owner = ent:GetOwner()
	return function( hit )
		if hit == ent then return false end
		if ignoreOwner and hit == owner then return false end
		return true
	end
end

function ENT:Initialize()
	self:SetModel( "models/hunter/blocks/cube025x025x025.mdl" )
	self:SetModelScale( 0.05, 0 )
	self:SetMoveType( MOVETYPE_NONE )
	self:SetSolid( SOLID_NONE )
	self:SetCollisionGroup( COLLISION_GROUP_DEBRIS )
	self:DrawShadow( false )
	self.MCVelocity = Vector( 0, 0, 0 )
	self.MCLastThink = CurTime()
	self.MCCreatedAt = CurTime()
	self.MCLifetime = 10
	self.MCGravity = 0
	self.MCDamage = 0
	self.MCPickup = false
	self.MCSourceStack = nil
	self.MCInfinite = false
	self.MCIgnoreOwnerUntil = CurTime() + 0.15
	self:SetProjectileVelocity( self.MCVelocity )
end

function ENT:Launch( velocity, options )
	options = istable( options ) and options or {}
	if not isvector( velocity ) then return false, "invalid_projectile_velocity" end
	self.MCVelocity = Vector( velocity.x, velocity.y, velocity.z )
	self.MCLastThink = CurTime()
	self.MCCreatedAt = CurTime()
	self.MCLifetime = math.min( 120, math.max( 0.25, tonumber( options.lifetime ) or self.MCLifetime or 10 ) )
	self.MCGravity = math.max( 0, tonumber( options.gravity ) or 0 )
	self.MCDamage = math.max( 0, tonumber( options.damage ) or 0 )
	self.MCPickup = options.pickup == true
	self.MCInfinite = options.infinite == true
	self.MCSourceStack = MC.CopyItemStack and MC.CopyItemStack( options.sourceStack ) or nil
	self.MCIgnoreOwnerUntil = CurTime() + math.max( 0, tonumber( options.ignoreOwnerFor ) or 0.15 )
	self:SetProjectileCritical( options.critical == true )
	self:SetProjectileVelocity( self.MCVelocity )
	if self.MCVelocity:LengthSqr() > 0 then self:SetAngles( self.MCVelocity:Angle() ) end
	return true
end

function ENT:Impact( trace )
	if self.MCImpactHandled then return end
	self.MCImpactHandled = true
	if MC.SV and MC.SV.HandleProjectileImpact then
		MC.SV.HandleProjectileImpact( self, trace )
	else
		self:Remove()
	end
end

function ENT:Think()
	local now = CurTime()
	if now - ( self.MCCreatedAt or now ) >= ( self.MCLifetime or 10 ) then
		self:Remove()
		return
	end
	local dt = math.Clamp( now - ( self.MCLastThink or now ), 0, 0.1 )
	self.MCLastThink = now
	if dt <= 0 then self:NextThink( now + 0.01 ) return true end

	local velocity = self.MCVelocity or Vector( 0, 0, 0 )
	local acceleration = Vector( 0, 0, -math.max( 0, tonumber( self.MCGravity ) or 0 ) )
	local nextVelocity = velocity + acceleration * dt
	local nextPosition = self:GetPos() + ( velocity + nextVelocity ) * ( dt * 0.5 )
	local ignoreOwner = now < ( self.MCIgnoreOwnerUntil or 0 )
	local trace = util.TraceHull( {
		start = self:GetPos(), endpos = nextPosition,
		mins = HULL_MIN, maxs = HULL_MAX,
		filter = traceFilter( self, ignoreOwner ), mask = MASK_SHOT,
	} )
	if trace.Hit then
		self:Impact( trace )
		return
	end
	self:SetPos( nextPosition )
	self.MCVelocity = nextVelocity
	self:SetProjectileVelocity( nextVelocity )
	if nextVelocity:LengthSqr() > 1 then self:SetAngles( nextVelocity:Angle() ) end
	self:NextThink( now + 0.01 )
	return true
end

