AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

local PHYSICS_MODEL = "models/hunter/blocks/cube025x025x025.mdl"
local SEAT_MODEL = "models/nova/airboat_seat.mdl"
local TICKS_PER_SECOND = 20
local RAIL_BASE_HEIGHT = 0.0625
local RAIL_RENDER_PITCH = math.atan( 1 / math.sqrt( 2 ) ) * 73
local COLLISION_EPSILON = 0.000001

local RAIL_EXITS = {
	north_south = { { 0, -1, 0 }, { 0, 1, 0 } },
	east_west = { { -1, 0, 0 }, { 1, 0, 0 } },
	ascending_east = { { -1, 0, -1 }, { 1, 0, 0 } },
	ascending_west = { { -1, 0, 0 }, { 1, 0, -1 } },
	ascending_north = { { 0, -1, 0 }, { 0, 1, -1 } },
	ascending_south = { { 0, -1, -1 }, { 0, 1, 0 } },
	south_east = { { 0, 1, 0 }, { 1, 0, 0 } },
	south_west = { { 0, 1, 0 }, { -1, 0, 0 } },
	north_west = { { 0, -1, 0 }, { -1, 0, 0 } },
	north_east = { { 0, -1, 0 }, { 1, 0, 0 } },
}

local CURVED_RAIL_SHAPES = {
	south_east = true,
	south_west = true,
	north_west = true,
	north_east = true,
}

local function blockScale()
	return math.max( 1, tonumber( MC and MC.BS ) or 36.5 )
end

local function javaVelocity( value )
	return value * blockScale() * TICKS_PER_SECOND
end

local function seatDriver( entity )
	local seat = entity:GetVehicleSeat()
	return IsValid( seat ) and seat:GetDriver() or nil
end

local function exitMinecraftVehicleDriver( driver, reason )
	if not IsValid( driver ) then return false end
	driver.MCAllowMinecraftVehicleExit = true
	driver:ExitVehicle()
	driver.MCAllowMinecraftVehicleExit = nil
	if driver:InVehicle() then return false end
	driver.MCMinecraftVehicleNextEnterAt = CurTime() + 0.25
	driver.MCMinecraftVehicleLastExitReason = tostring( reason or "forced" )
	return true
end

local function normalizeYaw( yaw )
	if math.NormalizeAngle then return math.NormalizeAngle( yaw ) end
	return ( yaw + 180 ) % 360 - 180
end

local function yawDifference( target, current )
	if math.AngleDifference then return math.AngleDifference( target, current ) end
	return normalizeYaw( target - current )
end

local function hideNativeSeat( seat )
	if not IsValid( seat ) then return end
	seat:SetNoDraw( true )
	seat:DrawShadow( false )
	seat:AddEffects( EF_NODRAW )
	seat:SetNotSolid( true )
	seat:SetSolid( SOLID_NONE )
	seat:SetCollisionGroup( COLLISION_GROUP_IN_VEHICLE )
end

local function railInfo( stateId )
	local blockId = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local block = blockId and MC.Blocks and MC.Blocks[blockId] or nil
	local name = block and ( block.mcid or block.name ) or ""
	if name ~= "minecraft:rail" and name ~= "rail"
	and name ~= "minecraft:powered_rail" and name ~= "powered_rail"
	and name ~= "minecraft:detector_rail" and name ~= "detector_rail"
	and name ~= "minecraft:activator_rail" and name ~= "activator_rail" then return nil end
	return {
		stateId = stateId,
		name = name,
		shape = MC.GetStateProperty and MC.GetStateProperty( stateId, "shape" ) or "north_south",
		powered = MC.GetStateProperty and MC.GetStateProperty( stateId, "powered" ) == true or false,
	}
end

local function railAt( bx, by, bz )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	local info = railInfo( stateId )
	if info then info.bx, info.by, info.bz = bx, by, bz return info end
	return nil
end

local function currentRail( position )
	local bx, by, bz = MC.WorldToCell( position )
	local below = railAt( bx, by, bz - 1 )
	if below then return below end
	return railAt( bx, by, bz )
end

local function entityWorldBounds( entity )
	if MC and MC.EntityWorldAABB then return MC.EntityWorldAABB( entity ) end
	return entity:WorldSpaceAABB()
end

local function minecartInWater( entity )
	if not MC.GetBlockState or not MC.LiquidStateMetrics then
		local contact = MC.LiquidAtPos and MC.LiquidAtPos( entity:GetPos() ) or nil
		return contact and contact.kind == "water" or false
	end
	local mins, maxs = entityWorldBounds( entity )
	local scale = blockScale()
	-- EntityFluidInteraction scans the entity AABB deflated by 0.001 blocks.
	local margin = scale * 0.001
	mins = mins + Vector( margin, margin, margin )
	maxs = maxs - Vector( margin, margin, margin )
	local minBx, maxBx = math.floor( mins.x / scale ), math.ceil( maxs.x / scale ) - 1
	local minBy, maxBy = math.floor( mins.y / scale ), math.ceil( maxs.y / scale ) - 1
	local minBz, maxBz = math.floor( mins.z / scale ), math.ceil( maxs.z / scale ) - 1
	for bz = minBz, maxBz do
		for by = minBy, maxBy do
			for bx = minBx, maxBx do
				local stateId = MC.GetBlockState( bx, by, bz ) or 0
				local kind = MC.LiquidStateMetrics( stateId )
				if kind == "water" then
					local height = MC.LiquidHeightAtCell and MC.LiquidHeightAtCell( bx, by, bz, "water" ) or 1
					if ( bz + height ) * scale >= mins.z then return true end
				end
			end
		end
	end
	return false
end

local function exitVectors( shape )
	return RAIL_EXITS[shape] or RAIL_EXITS.north_south
end

local function railPoint( rail, position )
	local exits = exitVectors( rail.shape )
	local first, second = exits[1], exits[2]
	local scale = blockScale()
	local x0 = rail.bx + 0.5 + first[1] * 0.5
	local y0 = rail.bz + RAIL_BASE_HEIGHT + first[3] * 0.5
	local z0 = rail.by + 0.5 + first[2] * 0.5
	local x1 = rail.bx + 0.5 + second[1] * 0.5
	local y1 = rail.bz + RAIL_BASE_HEIGHT + second[3] * 0.5
	local z1 = rail.by + 0.5 + second[2] * 0.5
	local px, py = position.x / scale, position.y / scale
	local xDelta, yDelta, zDelta = x1 - x0, ( y1 - y0 ) * 2, z1 - z0
	local progress
	if xDelta == 0 then progress = py - rail.by
	elseif zDelta == 0 then progress = px - rail.bx
	else progress = ( ( px - x0 ) * xDelta + ( py - z0 ) * zDelta ) * 2 end
	local x = x0 + xDelta * progress
	local y = y0 + yDelta * progress
	local z = z0 + zDelta * progress
	if yDelta < 0 then y = y + 1 elseif yDelta > 0 then y = y + 0.5 end
	return Vector( x * scale, z * scale, y * scale )
end

local function railStagePositionAfterMove( rail, position )
	local scale = blockScale()
	local ascending = string.sub( tostring( rail.shape ), 1, 10 ) == "ascending_"
	local stageBz = rail.bz + ( ascending and 1 or 0 )
	local nextBx = math.floor( position.x / scale )
	local nextBy = math.floor( position.y / scale )
	local offsetX, offsetY = nextBx - rail.bx, nextBy - rail.by
	-- OldMinecartBehavior performs its horizontal Entity.move at the rail block
	-- height (Y + 1 for slopes), then applies a lowered exit before getPos()
	-- looks up the rail in the cell that was actually entered.
	for _, exit in ipairs( exitVectors( rail.shape ) ) do
		if exit[3] ~= 0 and offsetX == exit[1] and offsetY == exit[2] then
			stageBz = stageBz + exit[3]
			break
		end
	end
	return Vector( position.x, position.y, stageBz * scale )
end

local function railSampleAfterMove( rail, position )
	local stagePosition = railStagePositionAfterMove( rail, position )
	local sampledRail = currentRail( stagePosition )
	if not sampledRail then return nil, stagePosition end
	return sampledRail, railPoint( sampledRail, stagePosition ) or stagePosition
end

local function horizontalDirection( rail )
	local exits = exitVectors( rail.shape )
	local dx, dy = exits[2][1] - exits[1][1], exits[2][2] - exits[1][2]
	local length = math.sqrt( dx * dx + dy * dy )
	return Vector( dx / length, dy / length, 0 )
end

local function railForConstraint( entity, position )
	local rail = currentRail( position )
	if rail then return rail end
	local cached = entity.MCActiveRail
	if not cached then return nil end
	-- Do not keep riding a cached rail after the supporting block was broken.
	local live = railAt( cached.bx, cached.by, cached.bz )
	if not live then return nil end
	local scale = blockScale()
	local px, py = position.x / scale, position.y / scale
	if px < live.bx - 0.35 or px > live.bx + 1.35
		or py < live.by - 0.35 or py > live.by + 1.35 then return nil end
	local aligned = railPoint( live, position )
	if not aligned or ( aligned - position ):LengthSqr() > ( scale * 0.65 ) ^ 2 then return nil end
	return live
end

local function trackTangent( rail, position )
	local horizontal = horizontalDirection( rail )
	local offset = horizontal * blockScale() * 0.25
	local before = railPoint( rail, position - offset )
	local after = railPoint( rail, position + offset )
	local tangent = before and after and after - before or horizontal
	if tangent:LengthSqr() <= 1e-7 then tangent = horizontal end
	tangent:Normalize()
	return tangent
end

local function storedVelocityOnRail( rail, velocity )
	local direction = horizontalDirection( rail )
	local along = Vector( velocity.x, velocity.y, 0 ):Dot( direction )
	return direction * along
end

local function physicalVelocityOnRail( rail, position, velocity )
	local direction = horizontalDirection( rail )
	local horizontalAlong = Vector( velocity.x, velocity.y, 0 ):Dot( direction )
	local tangent = trackTangent( rail, position )
	local horizontalLength = math.max( 1e-6, tangent:Length2D() )
	return tangent * ( horizontalAlong / horizontalLength )
end

local function railRenderPitch( rail, yaw )
	if not rail or string.sub( tostring( rail.shape ), 1, 10 ) ~= "ascending_" then return 0 end
	local exits = exitVectors( rail.shape )
	local dx = exits[2][1] - exits[1][1]
	local dy = exits[2][2] - exits[1][2]
	local dz = exits[2][3] - exits[1][3]
	local horizontal = math.sqrt( dx * dx + dy * dy )
	if horizontal <= 0 then return 0 end
	local facing = Angle( 0, yaw or 0, 0 ):Forward()
	if facing.x * dx + facing.y * dy < 0 then dz = -dz end
	return dz > 0 and -RAIL_RENDER_PITCH or RAIL_RENDER_PITCH
end

local function solidConductorAt( bx, by, bz )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	if stateId == 0 or MC.LiquidKindForState and MC.LiquidKindForState( stateId ) then return false end
	if MC.BlockVisualIsFullCube then
		local visual = MC.ResolveBlockStateVisual and MC.ResolveBlockStateVisual( stateId, bx, by, bz ) or nil
		if visual then return MC.BlockVisualIsFullCube( visual, bx, by, bz ) == true end
	end
	local blockId = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	return blockId and MC.BlockIsFullCube and MC.BlockIsFullCube( blockId, MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0 ) or false
end

local function blockCollisionBoxes( stateId, bx, by, bz )
	local boxes = MC.GetBlockCollisionBoxesForState
		and MC.GetBlockCollisionBoxesForState( stateId, bx, by, bz ) or nil
	if boxes == nil and MC.BlockHasCollisionForState
	and MC.BlockHasCollisionForState( stateId, bx, by, bz ) then
		return { { 0, 0, 0, 1, 1, 1 } }
	end
	return boxes
end

local function expandedBounds( minimum, maximum, movement )
	return Vector(
		math.min( minimum.x, minimum.x + movement.x ),
		math.min( minimum.y, minimum.y + movement.y ),
		minimum.z
	), Vector(
		math.max( maximum.x, maximum.x + movement.x ),
		math.max( maximum.y, maximum.y + movement.y ),
		maximum.z
	)
end

local function collectBlockColliders( minimum, maximum )
	if not MC.GetBlockState then return {} end
	local scale = blockScale()
	local minBx = math.floor( minimum.x / scale )
	local minBy = math.floor( minimum.y / scale )
	local minBz = math.floor( minimum.z / scale )
	local maxBx = math.floor( maximum.x / scale )
	local maxBy = math.floor( maximum.y / scale )
	local maxBz = math.floor( maximum.z / scale )
	local colliders = {}
	for bz = minBz, maxBz do
		for by = minBy, maxBy do
			for bx = minBx, maxBx do
				local stateId = MC.GetBlockState( bx, by, bz ) or 0
				if stateId ~= 0 and not ( MC.LiquidKindForState and MC.LiquidKindForState( stateId ) ) then
					local cellMin = MC.CellWorldMin and MC.CellWorldMin( bx, by, bz )
						or Vector( bx * scale, by * scale, bz * scale )
					for _, box in ipairs( blockCollisionBoxes( stateId, bx, by, bz ) or {} ) do
						colliders[#colliders + 1] = {
							minimum = cellMin + Vector( box[1] * scale, box[2] * scale, box[3] * scale ),
							maximum = cellMin + Vector( box[4] * scale, box[5] * scale, box[6] * scale ),
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
	local first, second = axis == "x" and "y" or "x", "z"
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

local function translateBounds( minimum, maximum, axis, amount )
	minimum[axis] = minimum[axis] + amount
	maximum[axis] = maximum[axis] + amount
end

local function resolveRailBlockMovement( rail, aligned, movement )
	local scale = blockScale()
	-- OldMinecartBehavior sets the cart to the rail block Y (Y + 1 for an
	-- ascending shape), performs a horizontal Entity.move, and only afterwards
	-- samples getPos() to put the cart on the slope. Reproducing that collision
	-- stage prevents the 0.98-wide Source hull from catching the upper terrain
	-- lip while it continuously travels down or up a one-block slope.
	local ascending = string.sub( tostring( rail.shape ), 1, 10 ) == "ascending_"
	local stagePosition = Vector( aligned.x, aligned.y, ( rail.bz + ( ascending and 1 or 0 ) ) * scale )
	-- Java's 0.98-wide box leaves only 0.01 block of mathematical clearance at
	-- the outside of a curve. Source's continuous VPhysics/contact epsilon can
	-- consume that gap even though the Java centerline is valid. Use a 0.48
	-- horizontal half-width only for this manual curved-rail block sweep; the
	-- entity's physical/player collision box remains the exact Java 0.49.
	local collisionHalfWidth = CURVED_RAIL_SHAPES[rail.shape] and 0.48 or 0.49
	local minimum = stagePosition + Vector( -collisionHalfWidth * scale, -collisionHalfWidth * scale, 0 )
	local maximum = stagePosition + Vector( collisionHalfWidth * scale, collisionHalfWidth * scale, 0.7 * scale )
	local sweepMinimum, sweepMaximum = expandedBounds( minimum, maximum, movement )
	local colliders = collectBlockColliders( sweepMinimum, sweepMaximum )
	local resolved = Vector( 0, 0, 0 )
	local blocked = false
	local order = math.abs( movement.x ) < math.abs( movement.y ) and { "y", "x" } or { "x", "y" }
	for _, axis in ipairs( order ) do
		local amount = movement[axis]
		local clipped = clipAxisAgainstBlocks( minimum, maximum, colliders, axis, amount )
		resolved[axis] = clipped
		translateBounds( minimum, maximum, axis, clipped )
		if math.abs( clipped - amount ) > COLLISION_EPSILON then blocked = true end
	end
	return resolved, blocked
end

local function enableVehicleDamage( entity )
	entity:SetHealth( 1 )
	if entity.SetMaxHealth then entity:SetMaxHealth( 1 ) end
	-- base_anim does not consistently opt into engine damage merely because it
	-- implements OnTakeDamage. This makes ordinary GMod weapons reach the same
	-- VehicleEntity damage path used by mc_inventory.
	if entity.SetSaveValue then entity:SetSaveValue( "m_takedamage", DAMAGE_YES or 2 ) end
end

function ENT:CreateVehicleSeat()
	local seat = ents.Create( "prop_vehicle_prisoner_pod" )
	if not IsValid( seat ) then return nil end
	seat:SetModel( SEAT_MODEL )
	seat:SetKeyValue( "vehiclescript", "scripts/vehicles/prisoner_pod.txt" )
	seat:SetKeyValue( "limitview", "0" )
	seat:SetPos( self:GetPos() )
	seat:SetAngles( self:GetAngles() )
	seat:Spawn()
	seat:Activate()
	seat:SetParent( self )
	seat:SetLocalPos( Vector( 0, 0, blockScale() * 0.1875 ) )
	seat:SetLocalAngles( Angle( 0, -90, 0 ) )
	seat.MCMinecraftVehicle = self
	hideNativeSeat( seat )
	self:DeleteOnRemove( seat )
	self:SetVehicleSeat( seat )
	return seat
end

function ENT:EnsureVehicleSeat()
	if self.MCDestroyed then return end
	if not IsValid( self:GetVehicleSeat() ) then self:CreateVehicleSeat() end
end

function ENT:Initialize()
	self:SetModel( PHYSICS_MODEL )
	local scale = blockScale()
	local collisionMins = Vector( -0.49 * scale, -0.49 * scale, 0 )
	local collisionMaxs = Vector( 0.49 * scale, 0.49 * scale, 0.7 * scale )
	self:PhysicsInitBox( collisionMins, collisionMaxs )
	self:SetCollisionBounds( collisionMins, collisionMaxs )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:SetCollisionGroup( COLLISION_GROUP_NONE )
	self:SetNotSolid( false )
	if self.SetCustomCollisionCheck then self:SetCustomCollisionCheck( true ) end
	if self.RemoveSolidFlags and FSOLID_NOT_STANDABLE then self:RemoveSolidFlags( FSOLID_NOT_STANDABLE ) end
	enableVehicleDamage( self )
	self:DrawShadow( false )
	self:SetMinecartItemName( self:GetMinecartItemName() ~= "" and self:GetMinecartItemName() or "minecraft:minecart" )
	self:SetHurtDirection( 1 )
	self.MCVelocity = Vector( 0, 0, 0 )
	self.MCLastTick = CurTime()
	self.MCAccumulator = 0
	self.MCLastPosition = self:GetPos()
	self.MCFlipped = false
	self.MCYawFlipLockedUntil = 0
	self.MCActiveRail = nil
	self:SetMotionSpeed( 0 )
	self:CreateVehicleSeat()
	local physics = self:GetPhysicsObject()
	if IsValid( physics ) then
		physics:SetMass( 40 )
		physics:SetDamping( 0, 4 )
		physics:EnableGravity( false )
		if physics.EnableCollisions then physics:EnableCollisions( true ) end
		physics:EnableMotion( true )
		physics:Wake()
	end
end

function ENT:ConstrainRailPhysics( rail, physicalVelocity )
	rail = rail or railForConstraint( self, self:GetPos() )
	if not rail then return false end
	local physics = self:GetPhysicsObject()
	if not IsValid( physics ) then return false end
	local position = self:GetPos()
	local aligned = railPoint( rail, position )
	if not aligned then return false end
	local motion = physicalVelocityOnRail( rail, position, physicalVelocity or physics:GetVelocity() )
	local correction = ( aligned - position ) * TICKS_PER_SECOND
	local maxCorrection = javaVelocity( 0.25 )
	if correction:LengthSqr() > maxCorrection * maxCorrection then
		correction:Normalize()
		correction:Mul( maxCorrection )
	end
	physics:SetVelocityInstantaneous( motion + correction )
	physics:Wake()
	self.MCActiveRail = rail
	return true
end

function ENT:TryEnterPlayer( activator )
	if not IsValid( activator ) or not activator:IsPlayer() or not activator:Alive() then return false end
	if activator:InVehicle() or activator:KeyDown( IN_DUCK ) then return false end
	self:EnsureVehicleSeat()
	local seat = self:GetVehicleSeat()
	if not IsValid( seat ) or IsValid( seat:GetDriver() ) then return false end
	activator:EnterVehicle( seat )
	return activator:InVehicle() and activator:GetVehicle() == seat
end

function ENT:ApplyRiderIntent( rail )
	local driver = seatDriver( self )
	if not IsValid( driver ) then return false end
	local forward = driver:KeyDown( IN_FORWARD )
	local back = driver:KeyDown( IN_BACK )
	local view = Angle( 0, driver:EyeAngles().y, 0 )
	local viewForward, viewRight = view:Forward(), view:Right()
	if forward ~= back and self.MCVelocity:Length2DSqr() >= javaVelocity( 0.1 ) ^ 2 then
		local desired = viewForward
		if back then desired = -desired end
		-- Vanilla only applies the 0.001 nudge once the cart is slow. Let the
		-- opposite longitudinal key brake toward that threshold first; this keeps
		-- native GMod vehicle input usable without turning a derailed cart into a car.
		if self.MCVelocity:Dot( desired ) < -javaVelocity( 0.01 ) then
			self.MCVelocity = Vector( self.MCVelocity.x * 0.8, self.MCVelocity.y * 0.8, 0 )
		end
		return false
	end
	if self.MCVelocity:Length2DSqr() >= javaVelocity( 0.1 ) ^ 2 then return false end
	local wish = Vector( 0, 0, 0 )
	if forward then wish = wish + viewForward end
	if back then wish = wish - viewForward end
	if driver:KeyDown( IN_MOVERIGHT ) then wish = wish + viewRight end
	if driver:KeyDown( IN_MOVELEFT ) then wish = wish - viewRight end
	wish.z = 0
	if wish:LengthSqr() <= 0 then return false end
	wish:Normalize()
	self.MCVelocity = self.MCVelocity + wish * javaVelocity( 0.001 )
	return true
end

function ENT:MoveAlongTrack( rail, underwater )
	local velocity = self.MCVelocity
	local currentPosition = self:GetPos()
	local oldRailPosition = railPoint( rail, currentPosition )
	local slide = javaVelocity( 0.0078125 ) * ( underwater and 0.2 or 1 )
	if rail.shape == "ascending_east" then velocity.x = velocity.x - slide
	elseif rail.shape == "ascending_west" then velocity.x = velocity.x + slide
	elseif rail.shape == "ascending_north" then velocity.y = velocity.y + slide
	elseif rail.shape == "ascending_south" then velocity.y = velocity.y - slide end

	local direction = horizontalDirection( rail )
	if velocity:Dot( direction ) < 0 then direction = -direction end
	local speed = math.min( javaVelocity( 2 ), velocity:Length2D() )
	velocity.x, velocity.y = direction.x * speed, direction.y * speed
	self.MCVelocity = velocity
	local riderPushed = self:ApplyRiderIntent( rail )

	local poweredRail = rail.name == "minecraft:powered_rail" or rail.name == "powered_rail"
	if poweredRail and not rail.powered and not riderPushed then
		local speedLength = self.MCVelocity:Length2D()
		if speedLength < javaVelocity( 0.03 ) then self.MCVelocity = Vector( 0, 0, 0 )
		else self.MCVelocity = Vector( self.MCVelocity.x * 0.5, self.MCVelocity.y * 0.5, 0 ) end
	end

	local aligned = railPoint( rail, currentPosition ) or currentPosition
	local maxSpeed = javaVelocity( underwater and 0.2 or 0.4 )
	local moveScale = IsValid( seatDriver( self ) ) and 0.75 or 1
	local motion = Vector( math.Clamp( self.MCVelocity.x * moveScale, -maxSpeed, maxSpeed ),
		math.Clamp( self.MCVelocity.y * moveScale, -maxSpeed, maxSpeed ), 0 )
	local resolvedDisplacement, blockCollision = resolveRailBlockMovement( rail, aligned, motion / TICKS_PER_SECOND )
	local actualMotion = resolvedDisplacement * TICKS_PER_SECOND
	local horizontalPosition = aligned + resolvedDisplacement
	local sampledRail, projectedPosition = railSampleAfterMove( rail, horizontalPosition )
	if blockCollision then
		-- Entity.restituteMovementAfterCollisions uses zero bounciness for an
		-- ordinary minecart, so a genuine block obstruction clears its horizontal
		-- delta instead of reflecting it. Powered rails may accelerate it again
		-- after this point, exactly as in OldMinecartBehavior.
		self.MCVelocity = Vector( 0, 0, 0 )
	end
	local slowdown = IsValid( seatDriver( self ) ) and 0.997 or 0.96
	if underwater then slowdown = slowdown * 0.95 end
	self.MCVelocity = Vector( self.MCVelocity.x * slowdown, self.MCVelocity.y * slowdown, 0 )
	if oldRailPosition and sampledRail and projectedPosition then
		local slopeSpeed = ( oldRailPosition.z - projectedPosition.z ) / blockScale() * javaVelocity( 0.05 )
		local horizontalSpeed = self.MCVelocity:Length2D()
		if horizontalSpeed > 0 and horizontalSpeed + slopeSpeed > 0 then
			local scale = ( horizontalSpeed + slopeSpeed ) / horizontalSpeed
			self.MCVelocity = Vector( self.MCVelocity.x * scale, self.MCVelocity.y * scale, 0 )
		end
	end
	-- OldMinecartBehavior redirects the stored movement toward the block that
	-- the cart entered after this tick's move. This is what lets a fast cart
	-- enter a curve without carrying the previous diagonal across another cell.
	local nextBx, nextBy = math.floor( horizontalPosition.x / blockScale() ),
		math.floor( horizontalPosition.y / blockScale() )
	if nextBx ~= rail.bx or nextBy ~= rail.by then
		local nextSpeed = self.MCVelocity:Length2D()
		self.MCVelocity = Vector( nextSpeed * ( nextBx - rail.bx ), nextSpeed * ( nextBy - rail.by ), 0 )
	end

	if poweredRail and rail.powered then
		local speedLength = self.MCVelocity:Length2D()
		if speedLength > javaVelocity( 0.01 ) then
			self.MCVelocity = self.MCVelocity + self.MCVelocity:GetNormalized() * javaVelocity( 0.06 )
		elseif rail.shape == "east_west" then
			if solidConductorAt( rail.bx - 1, rail.by, rail.bz ) then self.MCVelocity.x = javaVelocity( 0.02 )
			elseif solidConductorAt( rail.bx + 1, rail.by, rail.bz ) then self.MCVelocity.x = -javaVelocity( 0.02 ) end
		elseif rail.shape == "north_south" then
			if solidConductorAt( rail.bx, rail.by - 1, rail.bz ) then self.MCVelocity.y = javaVelocity( 0.02 )
			elseif solidConductorAt( rail.bx, rail.by + 1, rail.bz ) then self.MCVelocity.y = -javaVelocity( 0.02 ) end
		end
	end

	-- Java aligns to the rail before moving, but its client interpolation hides
	-- that 20 TPS correction. Driving VPhysics toward the exact next rail point
	-- over the full tick preserves the same path while avoiding visible/server
	-- teleports for the parented prisoner-pod camera.
	local targetPosition = projectedPosition or horizontalPosition
	local trackMotion = ( targetPosition - aligned ) * TICKS_PER_SECOND
	local correction = ( aligned - currentPosition ) * TICKS_PER_SECOND
	local maxCorrection = javaVelocity( 0.25 )
	if correction:LengthSqr() > maxCorrection * maxCorrection then
		correction:Normalize()
		correction:Mul( maxCorrection )
	end
	local physicalMotion = trackMotion + correction
	local physics = self:GetPhysicsObject()
	if IsValid( physics ) then
		physics:SetVelocityInstantaneous( physicalMotion )
		physics:Wake()
	end
	self.MCRailBlockCollision = blockCollision
	self.MCRailPhysicalVelocity = trackMotion
	if sampledRail then self.MCActiveRail = sampledRail end
	self:SetMotionSpeed( actualMotion:Length2D() / javaVelocity( 1 ) )
end

function ENT:ComeOffTrack( underwater )
	self.MCRailBlockCollision = false
	self.MCRailPhysicalVelocity = nil
	local maxSpeed = javaVelocity( underwater and 0.2 or 0.4 )
	local velocity = self.MCVelocity
	velocity.x = math.Clamp( velocity.x, -maxSpeed, maxSpeed )
	velocity.y = math.Clamp( velocity.y, -maxSpeed, maxSpeed )
	velocity.z = velocity.z - javaVelocity( underwater and 0.005 or 0.04 )
	local physics = self:GetPhysicsObject()
	local onGround = util.TraceHull( {
		start = self:GetPos(), endpos = self:GetPos() - Vector( 0, 0, 2 ),
		mins = Vector( -0.45 * blockScale(), -0.45 * blockScale(), 0 ),
		maxs = Vector( 0.45 * blockScale(), 0.45 * blockScale(), 0.01 * blockScale() ),
		filter = { self, self:GetVehicleSeat() }, mask = MASK_SOLID,
	} ).Hit
	local motion = velocity
	if onGround then
		motion = motion * 0.5
		self.MCVelocity = motion
	else
		-- AbstractMinecart moves with the full gravity-adjusted velocity, then
		-- stores 0.95 air drag for the following tick.
		self.MCVelocity = motion * 0.95
	end
	if IsValid( physics ) then physics:SetVelocityInstantaneous( motion ) physics:Wake() end
	self:SetMotionSpeed( motion:Length2D() / javaVelocity( 1 ) )
end

function ENT:ActivateRail( rail )
	if not rail or not rail.powered then return end
	if rail.name ~= "minecraft:activator_rail" and rail.name ~= "activator_rail" then return end
	local driver = seatDriver( self )
	if IsValid( driver ) then exitMinecraftVehicleDriver( driver, "activator_rail" ) end
	if self:GetHurtUntil() <= CurTime() then
		self:SetHurtDirection( -self:GetHurtDirection() )
		self:SetHurtUntil( CurTime() + 0.5 )
		self:SetVehicleDamage( 50 )
	end
end

function ENT:UpdateRotation( rail )
	local delta = self:GetPos() - ( self.MCLastPosition or self:GetPos() )
	self.MCLastPosition = self:GetPos()
	-- OldMinecartBehavior compares block-space movement against 0.001 and keeps
	-- a persistent flipped bit when direction crosses 180 degrees. The extra
	-- short lock prevents near-zero Source physics jitter from toggling that bit
	-- back and forth while S is braking through zero.
	if delta:Length2DSqr() > blockScale() ^ 2 * 0.001 then
		local angles = self:GetAngles()
		angles.p = 0
		local candidateYaw = delta:Angle().y + ( self.MCFlipped and 180 or 0 )
		local difference = yawDifference( candidateYaw, angles.y )
		if difference < -170 or difference >= 170 then
			if CurTime() >= ( self.MCYawFlipLockedUntil or 0 ) then
				candidateYaw = candidateYaw + 180
				self.MCFlipped = not self.MCFlipped
				self.MCYawFlipLockedUntil = CurTime() + 2
			else
				candidateYaw = angles.y
			end
		end
		angles.y = normalizeYaw( candidateYaw )
		angles.r = 0
		self:SetAngles( angles )
	end
	self:SetRailPitch( railRenderPitch( rail, self:GetAngles().y ) )
end

function ENT:MinecraftTick()
	self:EnsureVehicleSeat()
	local underwater = minecartInWater( self )
	local rail = railForConstraint( self, self:GetPos() )
	local onRails = rail ~= nil
	if self:GetOnRails() ~= onRails then
		self:SetOnRails( onRails )
		if self.CollisionRulesChanged then self:CollisionRulesChanged() end
	end
	if rail then
		self.MCActiveRail = rail
		self:MoveAlongTrack( rail, underwater )
		self:ActivateRail( rail )
	else
		self.MCActiveRail = nil
		self:ComeOffTrack( underwater )
	end
	self:PushNearbyPlayers()
	self:UpdateRotation( rail )
	self:SetVehicleDamage( math.max( 0, self:GetVehicleDamage() - 1 ) )
end

function ENT:PushFromPlayer( ply )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() or IsValid( seatDriver( self ) ) then return false end
	local tick = math.floor( CurTime() * TICKS_PER_SECOND )
	self.MCPlayerPushTicks = self.MCPlayerPushTicks or {}
	local playerIndex = ply:EntIndex()
	if self.MCPlayerPushTicks[playerIndex] == tick then
		local rail = railForConstraint( self, self:GetPos() )
		if rail then
			self:ConstrainRailPhysics( rail )
			return true
		end
		return false
	end

	local delta = ( self:GetPos() - ply:GetPos() ) / blockScale()
	delta.z = 0
	local distance = delta:Length2D()
	if distance < 0.01 then return false end
	delta = delta / distance
	local pushStrength = javaVelocity( math.min( 1, 1 / distance ) * 0.05 )
	local rail = railForConstraint( self, self:GetPos() )
	local impulse = delta * pushStrength
	if rail then
		local direction = horizontalDirection( rail )
		impulse = direction * delta:Dot( direction ) * pushStrength
	end
	self.MCPlayerPushTicks[playerIndex] = tick
	if rail then
		self.MCVelocity = storedVelocityOnRail( rail, self.MCVelocity ) + impulse
	else
		self.MCVelocity = Vector( self.MCVelocity.x + impulse.x, self.MCVelocity.y + impulse.y, self.MCVelocity.z )
	end
	local physics = self:GetPhysicsObject()
	if IsValid( physics ) then
		if rail then self:ConstrainRailPhysics( rail, physics:GetVelocity() + impulse )
		else physics:AddVelocity( impulse ) physics:Wake() end
	end
	return true
end

function ENT:PushNearbyPlayers()
	if IsValid( seatDriver( self ) ) or not ents or not ents.FindInBox then return end
	local mins, maxs = entityWorldBounds( self )
	local inflate = blockScale() * 0.2
	mins = mins - Vector( inflate, inflate, 0 )
	maxs = maxs + Vector( inflate, inflate, 0 )
	for _, entity in ipairs( ents.FindInBox( mins, maxs ) ) do
		if entity:IsPlayer() then self:PushFromPlayer( entity ) end
	end
end

function ENT:StabilizeUpright()
	local angles = self:GetAngles()
	if math.abs( angles.p ) > 0.001 or math.abs( angles.r ) > 0.001 then
		self:SetAngles( Angle( 0, angles.y, 0 ) )
	end
	local physics = self:GetPhysicsObject()
	if IsValid( physics ) and physics.SetAngleVelocityInstantaneous then
		physics:SetAngleVelocityInstantaneous( Vector( 0, 0, 0 ) )
	end
end

function ENT:Think()
	local current = CurTime()
	self:StabilizeUpright()
	local elapsed = math.Clamp( current - ( self.MCLastTick or current ), 0, 0.25 )
	self.MCLastTick = current
	self.MCAccumulator = math.min( 0.25, ( self.MCAccumulator or 0 ) + elapsed )
	while self.MCAccumulator >= 1 / TICKS_PER_SECOND do
		self.MCAccumulator = self.MCAccumulator - 1 / TICKS_PER_SECOND
		self:MinecraftTick()
	end
	local rail = railForConstraint( self, self:GetPos() )
	if rail then self:ConstrainRailPhysics( rail ) end
	self:StabilizeUpright()
	self:NextThink( current )
	return true
end

function ENT:PushOtherMinecart( other )
	if not IsValid( other ) or other:GetClass() ~= "mc_minecart" then return false end
	local scale = blockScale()
	local delta = ( other:GetPos() - self:GetPos() ) / scale
	delta.z = 0
	local distance = delta:Length2D()
	if distance < 0.01 then return false end
	delta = delta / distance
	local facing = self:GetForward()
	facing.z = 0
	if facing:Length2DSqr() > 0 then facing:Normalize() end
	if math.abs( delta:Dot( facing ) ) < 0.8 then return false end

	local tick = math.floor( CurTime() * TICKS_PER_SECOND )
	self.MCMinecartCollisionTicks = self.MCMinecartCollisionTicks or {}
	other.MCMinecartCollisionTicks = other.MCMinecartCollisionTicks or {}
	local otherIndex = other:EntIndex()
	local selfIndex = self:EntIndex()
	if self.MCMinecartCollisionTicks[otherIndex] == tick or other.MCMinecartCollisionTicks[selfIndex] == tick then
		local ourRail = railForConstraint( self, self:GetPos() )
		local theirRail = railForConstraint( other, other:GetPos() )
		if ourRail then self:ConstrainRailPhysics( ourRail ) end
		if theirRail and other.ConstrainRailPhysics then other:ConstrainRailPhysics( theirRail ) end
		return true
	end
	self.MCMinecartCollisionTicks[otherIndex] = tick
	other.MCMinecartCollisionTicks[selfIndex] = tick

	local impulse = delta * javaVelocity( math.min( 1, 1 / distance ) * 0.05 )
	local ours = self.MCVelocity or Vector( 0, 0, 0 )
	local theirs = other.MCVelocity or Vector( 0, 0, 0 )
	local averageX = ( ours.x + theirs.x ) * 0.5
	local averageY = ( ours.y + theirs.y ) * 0.5
	self.MCVelocity = Vector( ours.x * 0.2 + averageX - impulse.x,
		ours.y * 0.2 + averageY - impulse.y, ours.z )
	other.MCVelocity = Vector( theirs.x * 0.2 + averageX + impulse.x,
		theirs.y * 0.2 + averageY + impulse.y, theirs.z )
	local ourRail = railForConstraint( self, self:GetPos() )
	local theirRail = railForConstraint( other, other:GetPos() )
	if ourRail then self.MCVelocity = storedVelocityOnRail( ourRail, self.MCVelocity ) end
	if theirRail then other.MCVelocity = storedVelocityOnRail( theirRail, other.MCVelocity ) end
	local physics = self:GetPhysicsObject()
	if IsValid( physics ) then
		if ourRail then self:ConstrainRailPhysics( ourRail, self.MCVelocity )
		else physics:SetVelocityInstantaneous( self.MCVelocity ) physics:Wake() end
	end
	local otherPhysics = other:GetPhysicsObject()
	if IsValid( otherPhysics ) then
		if theirRail and other.ConstrainRailPhysics then other:ConstrainRailPhysics( theirRail, other.MCVelocity )
		else otherPhysics:SetVelocityInstantaneous( other.MCVelocity ) otherPhysics:Wake() end
	end
	return true
end

function ENT:PhysicsCollide( data )
	if data and self:PushOtherMinecart( data.HitEntity ) then return end
	if data and self:PushFromPlayer( data.HitEntity ) then return end
	local physics = self:GetPhysicsObject()
	if IsValid( physics ) then
		local collisionVelocity = physics:GetVelocity()
		local rail = railForConstraint( self, self:GetPos() )
		if rail then
			self.MCVelocity = storedVelocityOnRail( rail, collisionVelocity )
			self:ConstrainRailPhysics( rail, collisionVelocity )
		else
			self.MCVelocity = collisionVelocity
		end
		self:SetMotionSpeed( self.MCVelocity:Length2D() / javaVelocity( 1 ) )
	end
end

function ENT:ApplyMinecraftVehicleDamage( damageInfo )
	if self.MCDestroyed then return 0 end
	local damage = math.max( 0, tonumber( damageInfo:GetDamage() ) or 0 )
	if damage <= 0 then return 0 end
	self.MCVehicleDamageSerial = ( self.MCVehicleDamageSerial or 0 ) + 1
	self:SetHealth( 1 )
	local attacker = damageInfo:GetAttacker()
	local creative = IsValid( attacker ) and attacker:IsPlayer() and MC.SV and MC.SV.PlayerIsCreative and MC.SV.PlayerIsCreative( attacker )
	self:SetHurtDirection( -self:GetHurtDirection() )
	self:SetHurtUntil( CurTime() + 0.5 )
	self:SetVehicleDamage( self:GetVehicleDamage() + damage * 10 )
	if creative or self:GetVehicleDamage() > 40 then self:DestroyVehicle( attacker, creative == true ) end
	return damage
end

function ENT:OnTakeDamage( damageInfo )
	return self:ApplyMinecraftVehicleDamage( damageInfo )
end

function ENT:DestroyVehicle( attacker, suppressDrop )
	if self.MCDestroyed then return end
	self.MCDestroyed = true
	local driver = seatDriver( self )
	if IsValid( driver ) then exitMinecraftVehicleDriver( driver, "destroyed" ) end
	if MC.RunEvent then
		MC.RunEvent( "MC.MinecraftVehicleDestroyed", self, {
			dropItem = self:GetMinecartItemName(),
			position = Vector( self:GetPos().x, self:GetPos().y, self:GetPos().z ),
			velocity = Vector( 0, 0, javaVelocity( 0.1 ) ),
			attacker = attacker,
			suppressDrop = suppressDrop == true,
		} )
	end
	self:Remove()
end

function ENT:OnRemove()
	local seat = self:GetVehicleSeat()
	if IsValid( seat ) then seat:Remove() end
end
