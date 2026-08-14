AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

local PHYSICS_MODEL = "models/hunter/blocks/cube025x025x025.mdl"
local SEAT_MODEL = "models/nova/airboat_seat.mdl"
local TICKS_PER_SECOND = 20
local PADDLE_SPEED = math.pi / 8
local PADDLE_SOUND_TIME = math.pi / 4
local BOAT_NATIVE_SEAT_LIFT = 0.25
local BOAT_YAW_BLEND_TIME = 1 / TICKS_PER_SECOND
local BOAT_JAVA_HEIGHT = 0.5625
local BOAT_JAVA_STEADY_IMMERSION = 0.65

local function blockScale()
	return math.max( 1, tonumber( MC and MC.BS ) or 36.5 )
end

local function javaVelocity( value )
	return value * blockScale() * TICKS_PER_SECOND
end

local function normalizeYaw( yaw )
	if math.NormalizeAngle then return math.NormalizeAngle( yaw ) end
	return ( yaw + 180 ) % 360 - 180
end

local function yawDifference( target, current )
	if math.AngleDifference then return math.AngleDifference( target, current ) end
	return normalizeYaw( target - current )
end

local function seatDriver( entity )
	local seat = entity:GetVehicleSeat()
	local driver = IsValid( seat ) and seat:GetDriver() or nil
	if IsValid( driver ) then return driver end
	seat = entity:GetPassengerSeat()
	return IsValid( seat ) and seat:GetDriver() or nil
end

local function eachSeat( entity, callback )
	local primary = entity:GetVehicleSeat()
	local passenger = entity:GetPassengerSeat()
	if IsValid( primary ) then callback( primary ) end
	if IsValid( passenger ) then callback( passenger ) end
end

local function exitMinecraftVehicleDriver( driver, reason )
	if not IsValid( driver ) then return false end
	if MC.SV and MC.SV.ExitMinecraftVehiclePlayer then
		return MC.SV.ExitMinecraftVehiclePlayer( driver, reason ) == true
	end
	driver:ExitVehicle()
	return not driver:InVehicle()
end

local function keyDown( driver, key )
	return IsValid( driver ) and driver:IsPlayer() and driver:KeyDown( key )
end

local function hideNativeSeat( seat )
	if not IsValid( seat ) then return end
	-- prop_vehicle_prisoner_pod reapplies render/solid state during Spawn(), so
	-- the hidden-seat contract must be restored afterwards as well.
	seat:SetNoDraw( true )
	seat:DrawShadow( false )
	seat:AddEffects( EF_NODRAW )
	seat:SetNotSolid( true )
	seat:SetSolid( SOLID_NONE )
	seat:SetCollisionGroup( COLLISION_GROUP_IN_VEHICLE )
end

local function entityWorldBounds( entity )
	if MC and MC.EntityWorldAABB then return MC.EntityWorldAABB( entity ) end
	return entity:WorldSpaceAABB()
end

local function setAnglesPreservingVelocity( entity, angles )
	local physics = entity:GetPhysicsObject()
	local velocity = IsValid( physics ) and physics:GetVelocity() or nil
	entity:SetAngles( angles )
	if not IsValid( physics ) then return end
	-- Entity:SetAngles resets a VPhysics object's linear velocity. Boat yaw is
	-- interpolated every rendered server frame, so failing to restore it makes
	-- the hull look correctly animated while every paddle impulse is erased.
	if velocity and physics.SetVelocityInstantaneous then physics:SetVelocityInstantaneous( velocity ) end
	if physics.SetAngleVelocityInstantaneous then physics:SetAngleVelocityInstantaneous( Vector( 0, 0, 0 ) ) end
	physics:Wake()
end

local function waterCell( bx, by, bz )
	if not MC or not MC.GetBlockState or not MC.LiquidStateMetrics then return nil end
	local stateId = MC.GetBlockState( bx, by, bz ) or 0
	local kind, _, level, falling, waterlogged = MC.LiquidStateMetrics( stateId )
	if kind ~= "water" then return nil end
	local height = MC.LiquidHeightAtCell and MC.LiquidHeightAtCell( bx, by, bz, "water" ) or 0
	return {
		stateId = stateId,
		height = height,
		surfaceZ = ( bz + height ) * blockScale(),
		level = level,
		falling = falling == true,
		source = waterlogged == true or ( math.floor( tonumber( level ) or -1 ) == 0 and falling ~= true ),
	}
end

local function waterStatus( entity )
	local mins, maxs = entityWorldBounds( entity )
	local scale = blockScale()
	local minBx, maxBx = math.floor( mins.x / scale ), math.ceil( maxs.x / scale ) - 1
	local minBy, maxBy = math.floor( mins.y / scale ), math.ceil( maxs.y / scale ) - 1
	local top = maxs.z + 0.001
	local minTopBz, maxTopBz = math.floor( maxs.z / scale ), math.ceil( top / scale ) - 1
	local sourceUnder = false
	for bz = minTopBz, maxTopBz do
		for by = minBy, maxBy do
			for bx = minBx, maxBx do
				local water = waterCell( bx, by, bz )
				if water and top < water.surfaceZ then
					if not water.source then return "under_flowing_water", maxs.z end
					sourceUnder = true
				end
			end
		end
	end
	if sourceUnder then return "under_water", maxs.z end

	local waterLevel = -math.huge
	local minBottomBz, maxBottomBz = math.floor( mins.z / scale ), math.ceil( ( mins.z + 0.001 ) / scale ) - 1
	for bz = minBottomBz, maxBottomBz do
		for by = minBy, maxBy do
			for bx = minBx, maxBx do
				local water = waterCell( bx, by, bz )
				if water then waterLevel = math.max( waterLevel, water.surfaceZ ) end
			end
		end
	end
	if waterLevel > mins.z then return "in_water", waterLevel end
	return nil, waterLevel
end

local function waterLevelAbove( entity )
	local mins, maxs = entityWorldBounds( entity )
	local scale = blockScale()
	local minBx, maxBx = math.floor( mins.x / scale ), math.ceil( maxs.x / scale ) - 1
	local minBy, maxBy = math.floor( mins.y / scale ), math.ceil( maxs.y / scale ) - 1
	local lastDisplacement = ( entity.MCVelocity and entity.MCVelocity.z or 0 ) / TICKS_PER_SECOND
	local minBz = math.floor( maxs.z / scale )
	local maxBz = math.ceil( ( maxs.z - lastDisplacement ) / scale ) - 1
	if maxBz < minBz then maxBz = minBz end
	for bz = minBz, maxBz do
		local height = 0
		for by = minBy, maxBy do
			for bx = minBx, maxBx do
				local water = waterCell( bx, by, bz )
				if water then height = math.max( height, water.height ) end
			end
		end
		if height < 1 then return ( bz + height ) * scale end
	end
	return ( maxBz + 2 ) * scale
end

local function canMoveToVerticalPosition( entity, targetZ )
	local current = entity:GetPos()
	local delta = targetZ - current.z
	local mins, maxs = entity:OBBMins(), entity:OBBMaxs()
	local trace = util.TraceHull( {
		start = current,
		endpos = current + Vector( 0, 0, delta ),
		mins = mins,
		maxs = maxs,
		filter = { entity, entity:GetVehicleSeat(), entity:GetPassengerSeat() },
		mask = MASK_SOLID,
	} )
	return trace.Hit ~= true
end

local function groundStatus( entity )
	local mins, maxs = entityWorldBounds( entity )
	local position = entity:GetPos()
	local filter = function( hit )
		if hit == entity or hit == entity:GetVehicleSeat() or hit == entity:GetPassengerSeat() then return false end
		local class = IsValid( hit ) and hit:GetClass() or ""
		return class ~= "mc_chunk" and class ~= "mc_chunk_phys" and class ~= "mc_collision_carrier"
	end
	local trace = util.TraceHull( {
		start = position,
		endpos = position - Vector( 0, 0, 1.5 ),
		mins = Vector( mins.x - position.x + 1, mins.y - position.y + 1, mins.z - position.z ),
		maxs = Vector( maxs.x - position.x - 1, maxs.y - position.y - 1, mins.z - position.z + 0.5 ),
		filter = filter,
		mask = MASK_SOLID,
	} )
	local function blockFriction( name )
		if name == "minecraft:ice" or name == "ice" or name == "minecraft:packed_ice" or name == "packed_ice"
		or name == "minecraft:frosted_ice" or name == "frosted_ice" then return 0.98 end
		if name == "minecraft:blue_ice" or name == "blue_ice" then return 0.989 end
		if name == "minecraft:slime_block" or name == "slime_block" then return 0.8 end
		if name == "minecraft:honey_block" or name == "honey_block" then return 0.4 end
		return 0.6
	end
	local frictionTotal, frictionCount = 0, 0
	if MC and MC.WorldToCell and MC.GetBlockState and MC.CellWorldMin then
		local scale = blockScale()
		-- AbstractBoat#getGroundFriction intersects a 0.001-block slice directly
		-- below the hull and averages each touching block's friction once.
		local probeMin = Vector( mins.x, mins.y, mins.z - scale * 0.001 )
		local probeMax = Vector( maxs.x, maxs.y, mins.z + scale / 65536 )
		local minBx, minBy, minBz = MC.WorldToCell( probeMin - Vector( scale, scale, scale ) )
		local maxBx, maxBy, maxBz = MC.WorldToCell( probeMax + Vector( scale, scale, scale ) )
		for bz = minBz, maxBz do
			for by = minBy, maxBy do
				for bx = minBx, maxBx do
					local stateId = MC.GetBlockState( bx, by, bz ) or 0
					if stateId ~= 0 and not ( MC.LiquidKindForState and MC.LiquidKindForState( stateId ) ) then
						local blockId = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
						local block = blockId and MC.Blocks and MC.Blocks[blockId] or nil
						local name = block and ( block.mcid or block.name ) or ""
						if name ~= "minecraft:lily_pad" and name ~= "lily_pad" then
							local boxes = MC.GetBlockCollisionBoxesForState
								and MC.GetBlockCollisionBoxesForState( stateId, bx, by, bz ) or nil
							if boxes == nil and MC.BlockHasCollisionForState
							and MC.BlockHasCollisionForState( stateId, bx, by, bz ) then
								boxes = { { 0, 0, 0, 1, 1, 1 } }
							end
							local cellMin = MC.CellWorldMin( bx, by, bz )
							local touching = false
							for _, box in ipairs( boxes or {} ) do
								local boxMin = cellMin + Vector( box[1] * scale, box[2] * scale, box[3] * scale )
								local boxMax = cellMin + Vector( box[4] * scale, box[5] * scale, box[6] * scale )
								if probeMin.x < boxMax.x and probeMax.x > boxMin.x
								and probeMin.y < boxMax.y and probeMax.y > boxMin.y
								and probeMin.z < boxMax.z and probeMax.z > boxMin.z then touching = true break end
							end
							if touching then
								frictionTotal = frictionTotal + blockFriction( name )
								frictionCount = frictionCount + 1
							end
						end
					end
				end
			end
		end
	end
	if frictionCount > 0 then return true, frictionTotal / frictionCount end
	if trace.Hit then return true, 0.6 end
	return false, 0
end

local function enableVehicleDamage( entity )
	entity:SetHealth( 1 )
	if entity.SetMaxHealth then entity:SetMaxHealth( 1 ) end
	-- A scripted base_anim can expose OnTakeDamage yet still leave Source's
	-- m_takedamage disabled. Explicitly opt in so ordinary GMod weapons and the
	-- mc_inventory combat path both reach VehicleEntity-style damage handling.
	if entity.SetSaveValue then entity:SetSaveValue( "m_takedamage", DAMAGE_YES or 2 ) end
end

function ENT:UpdateVehicleSeatPositions()
	local primary = self:GetVehicleSeat()
	local passenger = self:GetPassengerSeat()
	local scale = blockScale()
	local minecraftRideHeight = self:GetRaft() and ( 0.5625 * 0.8888889 ) or ( 0.5625 / 3 )
	local vertical = scale * ( minecraftRideHeight + BOAT_NATIVE_SEAT_LIFT )
	local primaryOccupied = IsValid( primary ) and IsValid( primary:GetDriver() )
	local passengerOccupied = IsValid( passenger ) and IsValid( passenger:GetDriver() )
	local hasTwoPassengers = primaryOccupied and passengerOccupied
	if IsValid( primary ) then
		primary:SetLocalPos( Vector( hasTwoPassengers and 0.2 * scale or 0, 0, vertical ) )
	end
	if IsValid( passenger ) then
		passenger:SetLocalPos( Vector( hasTwoPassengers and -0.6 * scale or 0, 0, vertical ) )
	end
end

function ENT:CreateVehicleSeat( passengerSeat )
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
	seat:SetLocalAngles( Angle( 0, -90, 0 ) )
	seat.MCMinecraftVehicle = self
	seat.MCBoatPassengerSeat = passengerSeat == true
	hideNativeSeat( seat )
	self:DeleteOnRemove( seat )
	if passengerSeat then self:SetPassengerSeat( seat ) else self:SetVehicleSeat( seat ) end
	self:UpdateVehicleSeatPositions()
	return seat
end

function ENT:EnsureVehicleSeats()
	if self.MCDestroyed then return end
	if not IsValid( self:GetVehicleSeat() ) then self:CreateVehicleSeat( false ) end
	if not IsValid( self:GetPassengerSeat() ) then self:CreateVehicleSeat( true ) end
end

function ENT:Initialize()
	self:SetModel( PHYSICS_MODEL )
	local scale = blockScale()
	local collisionMins = Vector( -0.6875 * scale, -0.6875 * scale, 0 )
	local collisionMaxs = Vector( 0.6875 * scale, 0.6875 * scale, BOAT_JAVA_HEIGHT * scale )
	self:PhysicsInitBox( collisionMins, collisionMaxs )
	self:SetCollisionBounds( collisionMins, collisionMaxs )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:SetCollisionGroup( COLLISION_GROUP_NONE )
	self:SetNotSolid( false )
	if self.RemoveSolidFlags and FSOLID_NOT_STANDABLE then self:RemoveSolidFlags( FSOLID_NOT_STANDABLE ) end
	-- Minecraft vehicles are attackable without using a health pool. A positive
	-- Source health marker lets external mcweapon traces classify this SENT;
	-- VehicleDamage below remains the authoritative destruction state.
	enableVehicleDamage( self )
	self:DrawShadow( false )
	self:SetBoatType( self:GetBoatType() ~= "" and self:GetBoatType() or "oak" )
	self:SetBoatItemName( self:GetBoatItemName() ~= "" and self:GetBoatItemName() or "minecraft:oak_boat" )
	self:SetBoatStatus( "in_air" )
	self:SetHurtDirection( 1 )
	self.MCVelocity = Vector( 0, 0, 0 )
	self.MCDeltaRotation = 0
	self.MCLastTick = CurTime()
	self.MCAccumulator = 0
	self.MCTargetYaw = normalizeYaw( self:GetAngles().y )
	self.MCSmoothedYaw = self.MCTargetYaw
	self.MCTurnStartYaw = self.MCTargetYaw
	self.MCTurnStartedAt = CurTime() - BOAT_YAW_BLEND_TIME
	self.MCUnderwaterTicks = 0
	self.MCLandFriction = 0.6
	self:CreateVehicleSeat( false )
	self:CreateVehicleSeat( true )
	local physics = self:GetPhysicsObject()
	if IsValid( physics ) then
		physics:SetMass( 40 )
		physics:SetDamping( 0.05, 4 )
		physics:EnableGravity( false )
		if physics.EnableCollisions then physics:EnableCollisions( true ) end
		physics:EnableMotion( true )
		physics:Wake()
	end
end

function ENT:ApplySmoothedYaw( current )
	local target = normalizeYaw( self.MCTargetYaw or self:GetAngles().y )
	local start = normalizeYaw( self.MCTurnStartYaw or self.MCSmoothedYaw or target )
	local fraction = math.Clamp( ( current - ( self.MCTurnStartedAt or current ) ) / BOAT_YAW_BLEND_TIME, 0, 1 )
	local yaw = normalizeYaw( start + yawDifference( target, start ) * fraction )
	self.MCSmoothedYaw = yaw
	local angles = self:GetAngles()
	if math.abs( angles.p ) > 0.001 or math.abs( angles.r ) > 0.001
	or math.abs( yawDifference( yaw, angles.y ) ) > 0.001 then
		setAnglesPreservingVelocity( self, Angle( 0, yaw, 0 ) )
	end
end

function ENT:TryEnterPlayer( activator )
	if not IsValid( activator ) or not activator:IsPlayer() or not activator:Alive() then return false end
	if activator:InVehicle() then return false end
	self:EnsureVehicleSeats()
	local status = self:GetBoatStatus()
	if activator:KeyDown( IN_DUCK ) or status == "under_water" or status == "under_flowing_water" then return false end
	local primary = self:GetVehicleSeat()
	local passenger = self:GetPassengerSeat()
	for _, seat in ipairs( { primary, passenger } ) do
		if IsValid( seat ) and not IsValid( seat:GetDriver() ) then
			activator:EnterVehicle( seat )
			if activator:InVehicle() and activator:GetVehicle() == seat then
				self:UpdateVehicleSeatPositions()
				return true
			end
		end
	end
	self:UpdateVehicleSeatPositions()
	return false
end

function ENT:UpdateStatus()
	local status, waterLevel = waterStatus( self )
	if status then
		self.MCWaterLevel = waterLevel
	else
		local onLand, friction = groundStatus( self )
		if onLand then status, self.MCLandFriction = "on_land", friction else status = "in_air" end
	end
	self:SetBoatStatus( status )
	if status == "under_water" or status == "under_flowing_water" then
		self.MCUnderwaterTicks = ( self.MCUnderwaterTicks or 0 ) + 1
		if self.MCUnderwaterTicks >= 60 then
			eachSeat( self, function( seat )
				local driver = seat:GetDriver()
				if IsValid( driver ) then exitMinecraftVehicleDriver( driver, "underwater" ) end
			end )
		end
	else
		self.MCUnderwaterTicks = 0
	end
	return status
end

function ENT:FloatBoat( status, oldStatus )
	local velocity = self.MCVelocity
	local vertical = -javaVelocity( 0.04 )
	local buoyancy = 0
	local friction = 0.05
	if oldStatus == "in_air" and status ~= "in_air" and status ~= "on_land" then
		local mins, maxs = entityWorldBounds( self )
		self.MCWaterLevel = maxs.z
		local height = maxs.z - mins.z
		local scale = blockScale()
		local javaTransitionTarget = waterLevelAbove( self ) - height + scale * 0.101
		-- AbstractBoat's raw transition target sits about 0.096 block below its
		-- eventual 65%-immersed equilibrium. Apply only that steady-state
		-- correction: the renderer already contains Java's +0.375 model transform,
		-- so an additional Source lift makes the visible hull and its water probe
		-- sit too high.
		local steadyStateCorrection = height * ( 1 - BOAT_JAVA_STEADY_IMMERSION ) - scale * 0.101
		local targetZ = javaTransitionTarget + steadyStateCorrection
		if canMoveToVerticalPosition( self, targetZ ) then
			local position = self:GetPos()
			self:SetPos( Vector( position.x, position.y, targetZ ) )
			velocity.z = 0
		end
		status = "in_water"
		self:SetBoatStatus( status )
		-- Java skips the ordinary friction/gravity branch on the transition tick.
		self.MCVelocity = velocity
		return status
	elseif status == "in_water" then
		local mins, maxs = entityWorldBounds( self )
		local effectiveWaterLevel = self.MCWaterLevel or mins.z
		buoyancy = ( effectiveWaterLevel - mins.z ) / math.max( 1, maxs.z - mins.z )
		friction = 0.9
	elseif status == "under_flowing_water" then
		vertical = -javaVelocity( 0.0007 )
		friction = 0.9
	elseif status == "under_water" then
		buoyancy = 0.01
		friction = 0.45
	elseif status == "in_air" then
		friction = 0.9
	elseif status == "on_land" then
		friction = self.MCLandFriction or 0.6
		if IsValid( seatDriver( self ) ) then self.MCLandFriction = friction / 2 end
	end
	velocity = Vector( velocity.x * friction, velocity.y * friction, velocity.z + vertical )
	self.MCDeltaRotation = ( self.MCDeltaRotation or 0 ) * friction
	if buoyancy > 0 then
		velocity.z = ( velocity.z + javaVelocity( buoyancy * ( 0.04 / 0.65 ) ) ) * 0.75
	end
	self.MCVelocity = velocity
	return status
end

function ENT:ControlBoat()
	local driver = seatDriver( self )
	if not IsValid( driver ) then
		self:SetPaddleLeft( false )
		self:SetPaddleRight( false )
		return
	end
	local left = keyDown( driver, IN_MOVELEFT )
	local right = keyDown( driver, IN_MOVERIGHT )
	local forward = keyDown( driver, IN_FORWARD )
	local back = keyDown( driver, IN_BACK )
	local acceleration = 0
	-- Java's yaw axes are mirrored by the Source model transform. Positive
	-- Source yaw is a left turn here, so swap the input signs only; paddle-side
	-- state below already matches the authored model.
	if left then self.MCDeltaRotation = ( self.MCDeltaRotation or 0 ) + 1 end
	if right then self.MCDeltaRotation = ( self.MCDeltaRotation or 0 ) - 1 end
	if right ~= left and not forward and not back then acceleration = acceleration + 0.005 end
	local targetYaw = normalizeYaw( ( self.MCTargetYaw or self:GetAngles().y ) + ( self.MCDeltaRotation or 0 ) )
	self.MCTurnStartYaw = self.MCSmoothedYaw or self:GetAngles().y
	self.MCTargetYaw = targetYaw
	self.MCTurnStartedAt = CurTime()
	if forward then acceleration = acceleration + 0.04 end
	if back then acceleration = acceleration - 0.005 end
	if acceleration ~= 0 then
		self.MCVelocity = self.MCVelocity + Angle( 0, targetYaw, 0 ):Forward() * javaVelocity( acceleration )
	end
	self:SetPaddleLeft( right and not left or forward )
	self:SetPaddleRight( left and not right or forward )
end

function ENT:TickPaddles( status )
	local phases = { self:GetPaddlePhaseLeft(), self:GetPaddlePhaseRight() }
	local active = { self:GetPaddleLeft(), self:GetPaddleRight() }
	for index = 1, 2 do
		if active[index] then
			local old = phases[index] % ( math.pi * 2 )
			local nextPhase = old + PADDLE_SPEED
			if old <= PADDLE_SOUND_TIME and nextPhase >= PADDLE_SOUND_TIME then
				local eventName = ( status == "in_water" or status == "under_water" or status == "under_flowing_water" )
					and "entity.boat.paddle_water" or status == "on_land" and "entity.boat.paddle_land" or nil
				if eventName and MC.PlayJavaSoundEvent then
					local side = index == 1 and -1 or 1
					MC.PlayJavaSoundEvent( eventName, self:GetPos() + self:GetRight() * blockScale() * side,
						1, math.Rand( 0.8, 1.2 ), 72 )
				end
			end
			phases[index] = nextPhase
		else
			phases[index] = 0
		end
	end
	self:SetPaddlePhaseLeft( phases[1] )
	self:SetPaddlePhaseRight( phases[2] )
end

function ENT:PushFromPlayer( ply )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false end
	local primary = self:GetVehicleSeat()
	local passenger = self:GetPassengerSeat()
	if IsValid( primary ) and primary:GetDriver() == ply
		or IsValid( passenger ) and passenger:GetDriver() == ply then return false end

	local physics = self:GetPhysicsObject()
	local boatMins = select( 1, entityWorldBounds( self ) )
	local playerMins = select( 1, entityWorldBounds( ply ) )
	-- AbstractBoat only applies the generic push when a non-boat entity starts
	-- at or below the boat's base. A player standing on top must not launch it.
	if playerMins.z > boatMins.z + blockScale() * 0.05 then
		if IsValid( physics ) then physics:SetVelocityInstantaneous( self.MCVelocity ) end
		return true
	end

	local tick = math.floor( CurTime() * TICKS_PER_SECOND )
	self.MCPlayerPushTicks = self.MCPlayerPushTicks or {}
	local playerIndex = ply:EntIndex()
	if self.MCPlayerPushTicks[playerIndex] == tick then
		if IsValid( physics ) then physics:SetVelocityInstantaneous( self.MCVelocity ) physics:Wake() end
		return true
	end
	self.MCPlayerPushTicks[playerIndex] = tick
	local delta = ( self:GetPos() - ply:GetPos() ) / blockScale()
	delta.z = 0
	local distance = delta:Length2D()
	if distance < 0.01 then
		if IsValid( physics ) then physics:SetVelocityInstantaneous( self.MCVelocity ) end
		return true
	end
	delta = delta / distance
	if not IsValid( seatDriver( self ) ) then
		local impulse = delta * javaVelocity( math.min( 1, 1 / distance ) * 0.05 )
		self.MCVelocity = Vector( self.MCVelocity.x + impulse.x, self.MCVelocity.y + impulse.y, self.MCVelocity.z )
	end
	if IsValid( physics ) then physics:SetVelocityInstantaneous( self.MCVelocity ) physics:Wake() end
	return true
end

function ENT:PushNearbyPlayers()
	if not ents or not ents.FindInBox then return end
	local mins, maxs = entityWorldBounds( self )
	local scale = blockScale()
	local inflate = scale * 0.2
	mins = mins - Vector( inflate, inflate, -scale * 0.01 )
	maxs = maxs + Vector( inflate, inflate, -scale * 0.01 )
	for _, entity in ipairs( ents.FindInBox( mins, maxs ) ) do
		if entity:IsPlayer() then self:PushFromPlayer( entity ) end
	end
end

function ENT:MinecraftTick()
	self:EnsureVehicleSeats()
	self:UpdateVehicleSeatPositions()
	local oldStatus = self:GetBoatStatus()
	local status = self:UpdateStatus()
	status = self:FloatBoat( status, oldStatus ) or status
	self:ControlBoat()
	self:TickPaddles( status )
	self:PushNearbyPlayers()
	local physics = self:GetPhysicsObject()
	if IsValid( physics ) then
		physics:SetVelocityInstantaneous( self.MCVelocity )
		physics:Wake()
	end
	self:SetVehicleDamage( math.max( 0, self:GetVehicleDamage() - 1 ) )
end

function ENT:StabilizeUpright()
	local angles = self:GetAngles()
	if math.abs( angles.p ) > 0.001 or math.abs( angles.r ) > 0.001 then
		setAnglesPreservingVelocity( self, Angle( 0, angles.y, 0 ) )
	end
	local physics = self:GetPhysicsObject()
	if IsValid( physics ) and physics.SetAngleVelocityInstantaneous then
		physics:SetAngleVelocityInstantaneous( Vector( 0, 0, 0 ) )
	end
end

function ENT:Think()
	local current = CurTime()
	self:StabilizeUpright()
	self:ApplySmoothedYaw( current )
	local elapsed = math.Clamp( current - ( self.MCLastTick or current ), 0, 0.25 )
	self.MCLastTick = current
	self.MCAccumulator = math.min( 0.25, ( self.MCAccumulator or 0 ) + elapsed )
	while self.MCAccumulator >= 1 / TICKS_PER_SECOND do
		self.MCAccumulator = self.MCAccumulator - 1 / TICKS_PER_SECOND
		self:MinecraftTick()
	end
	self:ApplySmoothedYaw( current )
	self:StabilizeUpright()
	self:NextThink( current )
	return true
end

function ENT:PhysicsCollide( data )
	if data and self:PushFromPlayer( data.HitEntity ) then return end
	local physics = self:GetPhysicsObject()
	if IsValid( physics ) then self.MCVelocity = physics:GetVelocity() end
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
	eachSeat( self, function( seat )
		local driver = seat:GetDriver()
		if IsValid( driver ) then exitMinecraftVehicleDriver( driver, "destroyed" ) end
	end )
	if not suppressDrop and MC.SV and MC.SV.SpawnItemDrop then
		MC.SV.SpawnItemDrop( self:GetPos(), { item = self:GetBoatItemName(), count = 1 }, attacker, {
			pickupDelay = 0.5,
			velocity = Vector( 0, 0, javaVelocity( 0.1 ) ),
		} )
	end
	self:Remove()
end

function ENT:OnRemove()
	eachSeat( self, function( seat ) seat:Remove() end )
end
