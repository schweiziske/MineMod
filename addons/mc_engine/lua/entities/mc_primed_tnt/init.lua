AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

local TICKS_PER_SECOND = 20
local TICK_INTERVAL = 1 / TICKS_PER_SECOND
local COLLISION_EPSILON = 0.000001

local function blockSize()
	return math.max( 1, tonumber( MC and MC.BS ) or 36.5 )
end

local function setWorldPosition( entity, position )
	if MC and MC.SetEntityEnginePos then return MC.SetEntityEnginePos( entity, position ) end
	entity:SetPos( position )
	return true
end

local function worldPosition( entity )
	return MC and MC.EntityWorldPos and MC.EntityWorldPos( entity ) or entity:GetPos()
end

local function entityBounds( position )
	local size = blockSize()
	return position + Vector( -0.49 * size, -0.49 * size, 0 ),
		position + Vector( 0.49 * size, 0.49 * size, 0.98 * size )
end

local function collisionBoxes( stateId, bx, by, bz )
	local boxes = MC and MC.GetBlockCollisionBoxesForState
		and MC.GetBlockCollisionBoxesForState( stateId, bx, by, bz ) or nil
	if boxes == nil and MC and MC.BlockHasCollisionForState
	and MC.BlockHasCollisionForState( stateId, bx, by, bz ) then
		return { { 0, 0, 0, 1, 1, 1 } }
	end
	return boxes
end

local function expandedBounds( minimum, maximum, movement )
	return Vector(
		math.min( minimum.x, minimum.x + movement.x ),
		math.min( minimum.y, minimum.y + movement.y ),
		math.min( minimum.z, minimum.z + movement.z )
	), Vector(
		math.max( maximum.x, maximum.x + movement.x ),
		math.max( maximum.y, maximum.y + movement.y ),
		math.max( maximum.z, maximum.z + movement.z )
	)
end

local function collectBlockColliders( minimum, maximum )
	if not MC or not MC.GetBlockState then return {} end
	local size = blockSize()
	local minBx, minBy, minBz = math.floor( minimum.x / size ), math.floor( minimum.y / size ), math.floor( minimum.z / size )
	local maxBx, maxBy, maxBz = math.floor( maximum.x / size ), math.floor( maximum.y / size ), math.floor( maximum.z / size )
	local colliders = {}
	for bz = minBz, maxBz do
		for by = minBy, maxBy do
			for bx = minBx, maxBx do
				local stateId = MC.GetBlockState( bx, by, bz ) or 0
				if stateId ~= 0 then
					local base = MC.CellWorldMin and MC.CellWorldMin( bx, by, bz )
						or Vector( bx * size, by * size, bz * size )
					for _, box in ipairs( collisionBoxes( stateId, bx, by, bz ) or {} ) do
						colliders[#colliders + 1] = {
							minimum = base + Vector( box[1] * size, box[2] * size, box[3] * size ),
							maximum = base + Vector( box[4] * size, box[5] * size, box[6] * size ),
						}
					end
				end
			end
		end
	end
	return colliders
end

local function projectionsOverlap( minimum, maximum, otherMinimum, otherMaximum, first, second )
	return maximum[first] > otherMinimum[first] + COLLISION_EPSILON
		and minimum[first] < otherMaximum[first] - COLLISION_EPSILON
		and maximum[second] > otherMinimum[second] + COLLISION_EPSILON
		and minimum[second] < otherMaximum[second] - COLLISION_EPSILON
end

local function clipAxisAgainstBlocks( minimum, maximum, colliders, axis, amount )
	if math.abs( amount ) <= COLLISION_EPSILON then return 0 end
	local first, second
	if axis == "x" then first, second = "y", "z"
	elseif axis == "y" then first, second = "x", "z"
	else first, second = "x", "y" end
	local clipped = amount
	for _, collider in ipairs( colliders ) do
		if projectionsOverlap( minimum, maximum, collider.minimum, collider.maximum, first, second ) then
			if clipped > 0 and maximum[axis] <= collider.minimum[axis] + COLLISION_EPSILON then
				clipped = math.min( clipped, math.max( 0, collider.minimum[axis] - maximum[axis] ) )
			elseif clipped < 0 and minimum[axis] >= collider.maximum[axis] - COLLISION_EPSILON then
				clipped = math.max( clipped, math.min( 0, collider.maximum[axis] - minimum[axis] ) )
			end
		end
	end
	return clipped
end

local function traceFilter( entity )
	return function( hit )
		if hit == entity then return false end
		local class = IsValid( hit ) and hit:GetClass() or ""
		return class ~= "mc_chunk" and class ~= "mc_chunk_phys" and class ~= "mc_collision_carrier"
	end
end

local function clipAxisAgainstGMod( entity, enginePosition, axis, amount )
	if math.abs( amount ) <= COLLISION_EPSILON or not util or not util.TraceHull then return amount end
	local size = blockSize()
	local movement = Vector( 0, 0, 0 )
	movement[axis] = amount
	local trace = util.TraceHull( {
		start = enginePosition,
		endpos = enginePosition + movement,
		mins = Vector( -0.49 * size, -0.49 * size, 0 ),
		maxs = Vector( 0.49 * size, 0.49 * size, 0.98 * size ),
		filter = traceFilter( entity ),
		mask = MASK_SOLID,
	} )
	if not trace.Hit then return amount end
	if trace.StartSolid then return 0 end
	return amount * math.Clamp( tonumber( trace.Fraction ) or 0, 0, 1 )
end

local function translateBounds( minimum, maximum, axis, amount )
	minimum[axis] = minimum[axis] + amount
	maximum[axis] = maximum[axis] + amount
end

local function axisOrder( movement )
	-- Direction.axisStepOrder compares Java X/Z. MineMod maps Java Y to
	-- Source Z and Java Z to Source Y.
	if math.abs( movement.x ) < math.abs( movement.y ) then return { "z", "y", "x" } end
	return { "z", "x", "y" }
end

local function moveMinecraft( entity, movement )
	local position = worldPosition( entity )
	local minimum, maximum = entityBounds( position )
	local sweepMinimum, sweepMaximum = expandedBounds( minimum, maximum, movement )
	local colliders = collectBlockColliders( sweepMinimum, sweepMaximum )
	local resolved = Vector( 0, 0, 0 )
	local collided = { x = false, y = false, z = false }
	local enginePosition = entity:GetPos()

	for _, axis in ipairs( axisOrder( movement ) ) do
		local wanted = movement[axis]
		local amount = clipAxisAgainstBlocks( minimum, maximum, colliders, axis, wanted )
		amount = clipAxisAgainstGMod( entity, enginePosition + resolved, axis, amount )
		resolved[axis] = amount
		translateBounds( minimum, maximum, axis, amount )
		collided[axis] = math.abs( wanted - amount ) > COLLISION_EPSILON
	end

	setWorldPosition( entity, position + resolved )
	return resolved, collided, collided.z and movement.z < 0
end

function ENT:Initialize()
	local size = blockSize()
	self:SetModel( "models/hunter/blocks/cube025x025x025.mdl" )
	self:SetMoveType( MOVETYPE_NONE )
	self:SetSolid( SOLID_BBOX )
	self:SetCollisionBounds(
		Vector( -0.49 * size, -0.49 * size, 0 ),
		Vector( 0.49 * size, 0.49 * size, 0.98 * size )
	)
	self:SetCollisionGroup( COLLISION_GROUP_DEBRIS )
	self:DrawShadow( false )
	self:SetArmed( false )
	self:SetFuseTicks( self:GetFuseTicks() > 0 and self:GetFuseTicks() or 80 )
	self:SetExplosionPower( self:GetExplosionPower() > 0 and self:GetExplosionPower() or 4 )
	self.MCDeltaMovement = Vector( 0, 0, 0 )
	self.MCLastTick = CurTime()
	self.MCAccumulator = 0
	self:NextThink( CurTime() )
end

function ENT:ArmMinecraftTnt( options )
	if self:GetArmed() then return false, "already_armed" end
	options = istable( options ) and options or {}
	self:SetFuseTicks( math.max( 1, math.floor( tonumber( options.fuse ) or 80 ) ) )
	self:SetExplosionPower( math.Clamp( tonumber( options.power ) or 4, 0, 128 ) )
	if isvector( options.velocity ) then
		self.MCDeltaMovement = Vector( options.velocity.x, options.velocity.y, options.velocity.z )
	else
		local angle = math.Rand( 0, math.pi * 2 )
		self.MCDeltaMovement = Vector( -math.sin( angle ) * 0.02, -math.cos( angle ) * 0.02, 0.2 )
	end
	self.MCLastTick = CurTime()
	self.MCAccumulator = 0
	self:SetArmed( true )
	return true
end

function ENT:MCAddExplosionVelocity( velocity )
	if not isvector( velocity ) then return false end
	self.MCDeltaMovement = ( self.MCDeltaMovement or vector_origin ) + velocity
	return true
end

function ENT:MinecraftTick()
	if not self:GetArmed() then return true end
	local velocity = self.MCDeltaMovement or Vector( 0, 0, 0 )
	velocity = Vector( velocity.x, velocity.y, velocity.z - 0.04 )
	local _, collided, onGround = moveMinecraft( self, velocity * blockSize() )
	if collided.x then velocity.x = 0 end
	if collided.y then velocity.y = 0 end
	if collided.z then velocity.z = 0 end
	velocity = velocity * 0.98
	if onGround then
		velocity.x = velocity.x * 0.7
		velocity.y = velocity.y * 0.7
		velocity.z = velocity.z * -0.5
	end
	self.MCDeltaMovement = velocity

	local fuse = self:GetFuseTicks() - 1
	self:SetFuseTicks( fuse )
	if fuse <= 0 then
		self:SetArmed( false )
		local explosionPosition = worldPosition( self ) + Vector( 0, 0, blockSize() * 0.0625 )
		local owner = IsValid( self.MCExplosionOwner ) and self.MCExplosionOwner or self:GetOwner()
		if MC and MC.SV and MC.SV.ApplyMinecraftExplosion then
			MC.SV.ApplyMinecraftExplosion( explosionPosition, self:GetExplosionPower(), {
				source = self,
				actor = IsValid( owner ) and owner or nil,
				interaction = "tnt",
				dropDecay = true,
				interactsWithBlocks = true,
			} )
		end
		self:Remove()
		return false
	end
	return true
end

function ENT:Think()
	local current = CurTime()
	if not self:GetArmed() then self:NextThink( current + TICK_INTERVAL ) return true end
	local elapsed = math.Clamp( current - ( self.MCLastTick or current ), 0, 0.25 )
	self.MCLastTick = current
	self.MCAccumulator = math.min( 0.25, ( self.MCAccumulator or 0 ) + elapsed )
	while self.MCAccumulator >= TICK_INTERVAL do
		self.MCAccumulator = self.MCAccumulator - TICK_INTERVAL
		if self:MinecraftTick() == false or not IsValid( self ) then return end
	end
	self:NextThink( current )
	return true
end

function ENT:OnTakeDamage()
	-- PrimedTnt#hurtServer always returns false. Explosion push is applied by the
	-- explosion system through MCAddExplosionVelocity, independently of damage.
	return 0
end
