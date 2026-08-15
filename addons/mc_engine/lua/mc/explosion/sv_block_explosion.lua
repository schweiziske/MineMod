--[[----------------------------------------------------------------------------
	MC : Minecraft Java 26.2 destructive explosions.

	The shared 16^3 boundary-ray selector decides which cells are reached. This
	module owns the remaining ServerExplosion order: damage entities, snapshot and
	shuffle block interactions, commit the voxel transaction, then publish client
	effects. Survival loot/TNT behavior is supplied by the game layer.
------------------------------------------------------------------------------]]

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}
MC.Explosion = MC.Explosion or {}

local SV = MC.SV
local Explosion = MC.Explosion

local TICKS_PER_SECOND = 20
local FLUID_EXPLOSION_RESISTANCE = 100
local EXPLOSION_CLIENT_RANGE = 64
local FRACTION_SCALE = 65536
local TRACE_EPSILON = 0.000001

Explosion.BlockInteractionHandlers = Explosion.BlockInteractionHandlers or {}
Explosion.KnockbackResistanceProviders = Explosion.KnockbackResistanceProviders or {}

local function validIntegrationId( identifier )
	return type( identifier ) == "string" and identifier ~= "" and #identifier <= 64
end

local function reportIntegrationError( category, identifier, message )
	local output = "[MC] explosion " .. tostring( category ) .. " integration " .. tostring( identifier )
		.. " failed: " .. tostring( message ) .. "\n"
	if ErrorNoHalt then ErrorNoHalt( output ) else print( output ) end
end

local function orderedIntegrationIds( registry )
	local identifiers = {}
	for identifier in pairs( registry ) do identifiers[#identifiers + 1] = identifier end
	table.sort( identifiers )
	return identifiers
end

-- Destructive block interactions are deliberately two-phase: game-layer
-- handlers inspect the old states/Block Entities during Prepare, while Commit
-- runs only after the authoritative removal transaction succeeds.
function Explosion.RegisterBlockInteractionHandler( identifier, definition )
	if not validIntegrationId( identifier ) then return false, "invalid_block_interaction_id" end
	if type( definition ) ~= "table" or not isfunction( definition.Prepare )
		or not isfunction( definition.Commit ) then
		return false, "invalid_block_interaction_handler"
	end
	Explosion.BlockInteractionHandlers[identifier] = definition
	return true
end

function Explosion.UnregisterBlockInteractionHandler( identifier )
	if not validIntegrationId( identifier ) or Explosion.BlockInteractionHandlers[identifier] == nil then return false end
	Explosion.BlockInteractionHandlers[identifier] = nil
	return true
end

-- Providers return an additive 0..1 resistance contribution. The engine owns
-- the generic attribute/NW value; armor, enchantments and status effects remain
-- in the game layer.
function Explosion.RegisterKnockbackResistanceProvider( identifier, callback )
	if not validIntegrationId( identifier ) then return false, "invalid_knockback_provider_id" end
	if not isfunction( callback ) then return false, "invalid_knockback_provider" end
	Explosion.KnockbackResistanceProviders[identifier] = callback
	return true
end

function Explosion.UnregisterKnockbackResistanceProvider( identifier )
	if not validIntegrationId( identifier )
		or Explosion.KnockbackResistanceProviders[identifier] == nil then return false end
	Explosion.KnockbackResistanceProviders[identifier] = nil
	return true
end

local function blockSize()
	return math.max( 1, tonumber( MC.BS ) or 36.5 )
end

local function stateInfo( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	local blockId = schema and schema.blockId or MC.LegacyFromState and MC.LegacyFromState( stateId ) or nil
	local block = blockId and MC.Blocks and MC.Blocks[blockId] or nil
	local name = schema and schema.name or block and ( block.mcid or block.name ) or nil
	if name and not string.find( name, ":", 1, true ) then name = "minecraft:" .. name end
	return name, block, blockId, schema
end

local function defaultResistance( stateId )
	if stateId == 0 then return nil end
	local _, _, blockId = stateInfo( stateId )
	local resistance = blockId and MC.BlockExplosionResistance
		and tonumber( MC.BlockExplosionResistance( blockId ) ) or nil
	local liquidKind = MC.LiquidKindForState and MC.LiquidKindForState( stateId ) or nil
	if liquidKind == "water" or liquidKind == "lava" then
		resistance = math.max( tonumber( resistance ) or 0, FLUID_EXPLOSION_RESISTANCE )
	end
	return resistance
end

local function shuffle( values )
	for index = #values, 2, -1 do
		local other = math.random( 1, index )
		values[index], values[other] = values[other], values[index]
	end
end

local function copyVector( value )
	return Vector( value.x, value.y, value.z )
end

local function axisStep( position, direction, cell, size )
	if math.abs( direction ) <= TRACE_EPSILON then return 0, math.huge, math.huge end
	local step = direction > 0 and 1 or -1
	local boundary = ( direction > 0 and cell + 1 or cell ) * size
	local tMax = ( boundary - position ) / direction
	if tMax < 0 then tMax = 0 end
	return step, tMax, size / math.abs( direction )
end

local function rayAxisSlab( position, direction, minimum, maximum, nearDistance, farDistance )
	if math.abs( direction ) <= TRACE_EPSILON then
		if position < minimum or position > maximum then return nil end
		return nearDistance, farDistance
	end
	local near = ( minimum - position ) / direction
	local far = ( maximum - position ) / direction
	if near > far then near, far = far, near end
	if near > nearDistance then nearDistance = near end
	if far < farDistance then farDistance = far end
	if nearDistance - farDistance > TRACE_EPSILON then return nil end
	return nearDistance, farDistance
end

local function rayIntersectsBox( startPosition, direction, maxDistance, minimum, maximum )
	local nearDistance, farDistance = 0, maxDistance
	nearDistance, farDistance = rayAxisSlab(
		startPosition.x, direction.x, minimum.x, maximum.x, nearDistance, farDistance )
	if not nearDistance then return false end
	nearDistance, farDistance = rayAxisSlab(
		startPosition.y, direction.y, minimum.y, maximum.y, nearDistance, farDistance )
	if not nearDistance then return false end
	nearDistance, farDistance = rayAxisSlab(
		startPosition.z, direction.z, minimum.z, maximum.z, nearDistance, farDistance )
	return nearDistance ~= nil and farDistance >= -TRACE_EPSILON
		and nearDistance <= maxDistance + TRACE_EPSILON
end

local function collisionBoxes( stateId, bx, by, bz )
	local boxes = MC.GetBlockCollisionBoxesForState
		and MC.GetBlockCollisionBoxesForState( stateId, bx, by, bz ) or nil
	if boxes == nil and MC.BlockHasCollisionForState
	and MC.BlockHasCollisionForState( stateId, bx, by, bz ) then
		return { { 0, 0, 0, 1, 1, 1 } }
	end
	return boxes
end

-- ClipContext.Block.COLLIDER + Fluid.NONE. The ordinary MC.TraceBlockRay path
-- intentionally uses selection/model boxes, so explosion exposure keeps its
-- own collider-only DDA instead of changing player targeting semantics.
local function colliderSegmentBlocked( startPosition, endPosition )
	local delta = endPosition - startPosition
	local maxDistance = delta:Length()
	if maxDistance <= TRACE_EPSILON then return false end
	local direction = delta / maxDistance
	local size = blockSize()
	local bx, by, bz = math.floor( startPosition.x / size ), math.floor( startPosition.y / size ), math.floor( startPosition.z / size )
	local stepX, maxX, deltaX = axisStep( startPosition.x, direction.x, bx, size )
	local stepY, maxY, deltaY = axisStep( startPosition.y, direction.y, by, size )
	local stepZ, maxZ, deltaZ = axisStep( startPosition.z, direction.z, bz, size )
	local distance = 0
	local maxSteps = math.ceil( maxDistance / size ) * 3 + 8

	for _ = 1, maxSteps do
		local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
		if stateId ~= 0 and distance <= maxDistance then
			local minimum = MC.CellWorldMin and MC.CellWorldMin( bx, by, bz )
				or Vector( bx * size, by * size, bz * size )
			for _, box in ipairs( collisionBoxes( stateId, bx, by, bz ) or {} ) do
				local boxMinimum = minimum + Vector( box[1] * size, box[2] * size, box[3] * size )
				local boxMaximum = minimum + Vector( box[4] * size, box[5] * size, box[6] * size )
				if rayIntersectsBox( startPosition, direction, maxDistance, boxMinimum, boxMaximum ) then
					return true
				end
			end
		end

		if maxX <= maxY and maxX <= maxZ then
			distance = maxX
			if distance > maxDistance then break end
			bx, maxX = bx + stepX, maxX + deltaX
		elseif maxY <= maxZ then
			distance = maxY
			if distance > maxDistance then break end
			by, maxY = by + stepY, maxY + deltaY
		else
			distance = maxZ
			if distance > maxDistance then break end
			bz, maxZ = bz + stepZ, maxZ + deltaZ
		end
	end
	return false
end

local function entityWorldPosition( entity )
	return MC.EntityWorldPos and MC.EntityWorldPos( entity ) or entity:GetPos()
end

local function entityWorldAABB( entity )
	if MC.EntityWorldAABB then return MC.EntityWorldAABB( entity ) end
	return entity:WorldSpaceAABB()
end

local function entityExplosionOrigin( entity )
	if entity:GetClass() == "mc_primed_tnt" then return entityWorldPosition( entity ) end
	if MC.EntityEyeWorldPos and entity.EyePos then return MC.EntityEyeWorldPos( entity ) end
	if entity.EyePos then return entity:EyePos() end
	local minimum, maximum = entityWorldAABB( entity )
	return Vector( ( minimum.x + maximum.x ) * 0.5, ( minimum.y + maximum.y ) * 0.5,
		( minimum.z + maximum.z ) * 0.5 )
end

local function entityIsSpectator( entity )
	if not entity:IsPlayer() then return false end
	if TEAM_SPECTATOR ~= nil and entity.Team and entity:Team() == TEAM_SPECTATOR then return true end
	return entity.GetObserverMode and OBS_MODE_NONE ~= nil and entity:GetObserverMode() ~= OBS_MODE_NONE
end

local function entityIsCreative( entity )
	return entity:IsPlayer() and SV.PlayerIsCreative and SV.PlayerIsCreative( entity ) == true
end

local function explosionKnockbackResistance( entity, center, radius, options )
	local resistance = entity.GetNWFloat
		and tonumber( entity:GetNWFloat( "mc_explosion_knockback_resistance", 0 ) ) or 0
	for _, identifier in ipairs( orderedIntegrationIds( Explosion.KnockbackResistanceProviders ) ) do
		local callback = Explosion.KnockbackResistanceProviders[identifier]
		local ok, contribution = pcall( callback, entity, center, radius, options )
		if not ok then
			reportIntegrationError( "knockback", identifier, contribution )
		elseif isnumber( contribution ) then
			resistance = resistance + contribution
		end
	end
	return math.Clamp( tonumber( resistance ) or 0, 0, 1 )
end

Explosion.GetKnockbackResistance = explosionKnockbackResistance

local function seenPercent( center, entity )
	local minimum, maximum = entityWorldAABB( entity )
	local size = blockSize()
	local width = math.max( 0, ( maximum.x - minimum.x ) / size )
	local height = math.max( 0, ( maximum.z - minimum.z ) / size )
	local depth = math.max( 0, ( maximum.y - minimum.y ) / size )
	local stepX = 1 / ( width * 2 + 1 )
	local stepY = 1 / ( depth * 2 + 1 )
	local stepZ = 1 / ( height * 2 + 1 )
	local offsetX = ( 1 - math.floor( 1 / stepX ) * stepX ) * size * 0.5
	-- Java's Z axis maps to MCSWEP's horizontal Y axis; Source Z is Java Y.
	local offsetDepth = ( 1 - math.floor( 1 / stepY ) * stepY ) * size * 0.5
	local hits, count = 0, 0
	local xx = 0
	while xx <= 1 + TRACE_EPSILON do
		local yy = 0
		while yy <= 1 + TRACE_EPSILON do
			local zz = 0
			while zz <= 1 + TRACE_EPSILON do
				local from = Vector(
					minimum.x + ( maximum.x - minimum.x ) * math.min( xx, 1 ) + offsetX,
					minimum.y + ( maximum.y - minimum.y ) * math.min( yy, 1 ) + offsetDepth,
					minimum.z + ( maximum.z - minimum.z ) * math.min( zz, 1 )
				)
				if not colliderSegmentBlocked( from, center ) then hits = hits + 1 end
				count = count + 1
				zz = zz + stepZ
			end
			yy = yy + stepY
		end
		xx = xx + stepX
	end
	return count > 0 and hits / count or 0
end

Explosion.GetSeenPercent = seenPercent

local function damageAttacker( source, actor )
	if IsValid( actor ) then return actor end
	if IsValid( source ) then return source end
	return game.GetWorld()
end

local function reportDamageError( message )
	local output = "[MC] Minecraft explosion damage failed: " .. tostring( message ) .. "\n"
	if ErrorNoHalt then ErrorNoHalt( output ) else print( output ) end
end

local function takeExplosionDamage( entity, damage, direction, center, source, actor )
	if not DamageInfo then return false end
	local info = DamageInfo()
	if not info then return false end
	info:SetDamage( damage )
	info:SetDamageType( DMG_BLAST or 64 )
	info:SetAttacker( damageAttacker( source, actor ) )
	info:SetInflictor( IsValid( source ) and source or damageAttacker( source, actor ) )
	if info.SetDamagePosition then info:SetDamagePosition( center ) end
	if info.SetReportedPosition then info:SetReportedPosition( center ) end
	-- Java applies explosion push separately from hurtServer. Keep Source's own
	-- damage-force response out of the equation so the exact push below is not
	-- doubled for physics entities.
	if info.SetDamageForce then info:SetDamageForce( vector_origin ) end

	SV.MinecraftExplosionDamageDepth = ( tonumber( SV.MinecraftExplosionDamageDepth ) or 0 ) + 1
	local ok, damageError = pcall( entity.TakeDamageInfo, entity, info )
	SV.MinecraftExplosionDamageDepth = math.max( 0, ( tonumber( SV.MinecraftExplosionDamageDepth ) or 1 ) - 1 )
	if not ok then reportDamageError( damageError ) return false end
	return true
end

local function applyExplosionPush( entity, direction, power )
	if power <= 0 or not IsValid( entity ) then return end
	local blockVelocity = direction * power
	if entity.MCAddExplosionVelocity then
		local ok, pushError = pcall( entity.MCAddExplosionVelocity, entity, blockVelocity )
		if not ok then reportDamageError( pushError ) end
		return
	end

	local sourceVelocity = blockVelocity * blockSize() * TICKS_PER_SECOND
	local physics = entity.GetPhysicsObject and entity:GetPhysicsObject() or nil
	if IsValid( physics ) then
		physics:SetVelocity( physics:GetVelocity() + sourceVelocity )
		physics:Wake()
		if isvector( entity.MCVelocity ) then entity.MCVelocity = entity.MCVelocity + sourceVelocity end
	elseif entity.SetVelocity then
		entity:SetVelocity( sourceVelocity )
	end
end

local function aabbOverlaps( minimum, maximum, queryMinimum, queryMaximum )
	return maximum.x >= queryMinimum.x and minimum.x <= queryMaximum.x
		and maximum.y >= queryMinimum.y and minimum.y <= queryMaximum.y
		and maximum.z >= queryMinimum.z and minimum.z <= queryMaximum.z
end

local function damageEntities( center, radius, options )
	if radius < 0.00001 or not ents or not ents.GetAll then return 0, {} end
	local source = IsValid( options.source ) and options.source or nil
	local actor = IsValid( options.actor ) and options.actor or nil
	local doubleRadius = radius * 2
	local size = blockSize()
	local queryReach = ( doubleRadius + 1 ) * size
	local queryMinimum = center - Vector( queryReach, queryReach, queryReach )
	local queryMaximum = center + Vector( queryReach, queryReach, queryReach )
	local damaged, hits = 0, {}

	for _, entity in ipairs( ents.GetAll() ) do
		local eligible = IsValid( entity ) and entity ~= source and entity ~= game.GetWorld()
		if eligible then
			local class = entity:GetClass()
			eligible = class ~= "mc_chunk" and class ~= "mc_chunk_phys" and class ~= "mc_collision_carrier"
		end
		if eligible and entityIsSpectator( entity ) then eligible = false end
		if eligible then
			local minimum, maximum = entityWorldAABB( entity )
			eligible = aabbOverlaps( minimum, maximum, queryMinimum, queryMaximum )
		end
		if eligible and isfunction( options.shouldIgnoreEntity ) then
			local ok, ignored = pcall( options.shouldIgnoreEntity, entity, center, radius, options )
			if not ok then reportIntegrationError( "entity-filter", "options", ignored )
			elseif ignored == true then eligible = false end
		end
		if eligible then
			local entityPosition = entityWorldPosition( entity )
			local distance = entityPosition:Distance( center ) / ( doubleRadius * size )
			if distance <= 1 then
				local origin = entityExplosionOrigin( entity )
				local direction = origin - center
				if direction:LengthSqr() > TRACE_EPSILON then direction:Normalize()
				else direction = Vector( 0, 0, 0 ) end
				local exposure = seenPercent( center, entity )
				local impact = ( 1 - distance ) * exposure
				local minecraftDamage = ( ( impact * impact + impact ) * 0.5 ) * 7 * doubleRadius + 1
				local damageScale = options.entityDamageScale
				if isfunction( damageScale ) then
					local ok, resolved = pcall(
						damageScale, entity, minecraftDamage, center, radius, options )
					if not ok then
						reportIntegrationError( "entity-damage-scale", "options", resolved )
						damageScale = 1
					elseif resolved == false then
						damageScale = 0
					else
						damageScale = tonumber( resolved ) or 1
					end
				else
					damageScale = tonumber( damageScale ) or 1
				end
				local damage = minecraftDamage * math.max( 0, damageScale )
				local didDamage = false
				if damage > 0 and not entityIsCreative( entity ) then
					didDamage = takeExplosionDamage( entity, damage, direction, center, source, actor )
					if didDamage then damaged = damaged + 1 end
				end
				local resistance = explosionKnockbackResistance( entity, center, radius, options )
				local knockback = impact * ( 1 - resistance )
				local creativeFlying = entityIsCreative( entity ) and entity.GetMoveType
					and entity:GetMoveType() == MOVETYPE_NOCLIP
				if not creativeFlying then applyExplosionPush( entity, direction, knockback ) end
					hits[#hits + 1] = {
					entity = entity,
					distance = distance,
					exposure = exposure,
					impact = impact,
					minecraftDamage = minecraftDamage,
					damage = damage,
					knockback = knockback,
					damaged = didDamage,
				}
				if isfunction( options.onEntityHit ) then
					local ok, hitError = pcall( options.onEntityHit, entity, hits[#hits], options )
					if not ok then reportIntegrationError( "entity-hit", "options", hitError ) end
				end
			end
		end
	end
	return damaged, hits
end

local SOUL_FIRE_BASE = {
	["minecraft:soul_sand"] = true,
	["minecraft:soul_soil"] = true,
}

local function blockNameForState( stateId )
	local name = stateInfo( stateId )
	return name
end

local function solidRenderAt( bx, by, bz )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	if not stateId or stateId == 0 then return false end
	if MC.BlockIsFullCubeForState then
		return MC.BlockIsFullCubeForState( stateId, bx, by, bz ) == true
	end
	local _, block = stateInfo( stateId )
	return block and block.solid == true and block.transparent ~= true or false
end

local function explosionFireStateAt( bx, by, bz )
	local belowState = MC.GetBlockState and MC.GetBlockState( bx, by, bz - 1 ) or 0
	local fireName = SOUL_FIRE_BASE[blockNameForState( belowState )]
		and "minecraft:soul_fire" or "minecraft:fire"
	return MC.ParseBlockState and MC.ParseBlockState( fireName ) or nil
end

-- ServerExplosion#createFire iterates the exact calculated position list after
-- block interactions: 1/3 chance, target air, solid-render block below, then
-- BaseFireBlock.getState (normal fire or soul fire). Keep this as a second
-- transaction so the explosion removal commit and its loot/TNT callbacks stay
-- atomic even if fire placement is unavailable.
local function createExplosionFire( selected )
	if not SV.ApplyBlockTransaction then return nil, "block_transaction_unavailable" end
	local placements = {}
	for _, cell in ipairs( selected ) do
		local inBounds = not SV.WorldBoundsOK or SV.WorldBoundsOK( cell.bx, cell.by, cell.bz )
		if inBounds and math.random( 1, 3 ) == 1
		and ( MC.GetBlockState and MC.GetBlockState( cell.bx, cell.by, cell.bz ) or 0 ) == 0
		and solidRenderAt( cell.bx, cell.by, cell.bz - 1 ) then
			local stateId = explosionFireStateAt( cell.bx, cell.by, cell.bz )
			if stateId and stateId ~= 0 then
				placements[#placements + 1] = {
					bx = cell.bx, by = cell.by, bz = cell.bz, stateId = stateId,
				}
			end
		end
	end
	if #placements == 0 then return { ok = true, changed = 0, changes = {} } end
	local transaction = SV.ApplyBlockTransaction( placements, {
		actor = nil,
		fx = false,
		handlers = true,
		blockUpdates = true,
		compareCollision = true,
		validateChange = function( info )
			if info.oldStateId ~= 0 then return false, "explosion_fire_target_changed" end
			if not solidRenderAt( info.bx, info.by, info.bz - 1 ) then
				return false, "explosion_fire_support_changed"
			end
			return true
		end,
	} )
	if not transaction or transaction.ok ~= true then
		return transaction, transaction and transaction.error or "explosion_fire_failed"
	end
	return transaction
end

local function prepareBlockInteractions( snapshots, radius, options )
	local prepared
	for _, identifier in ipairs( orderedIntegrationIds( Explosion.BlockInteractionHandlers ) ) do
		local definition = Explosion.BlockInteractionHandlers[identifier]
		local ok, plan = xpcall( function()
			return definition.Prepare( snapshots, radius, options )
		end, debug.traceback )
		if not ok then
			reportIntegrationError( "block-prepare", identifier, plan )
		elseif plan ~= nil then
			prepared = prepared or {}
			prepared[#prepared + 1] = { identifier = identifier, definition = definition, plan = plan }
		end
	end
	return prepared
end

local function commitBlockInteractions( prepared, transaction, snapshots, radius, options )
	local results = {}
	for index = 1, #( prepared or {} ) do
		local entry = prepared[index]
		local ok, result = xpcall( function()
			return entry.definition.Commit( entry.plan, transaction, snapshots, radius, options )
		end, debug.traceback )
		if not ok then reportIntegrationError( "block-commit", entry.identifier, result )
		elseif result ~= nil then results[entry.identifier] = result end
	end
	return results
end

local function splitNetworkCoordinate( value, size )
	local blocks = value / size
	local cell = math.floor( blocks )
	local fraction = math.Clamp( math.floor( ( blocks - cell ) * FRACTION_SCALE ), 0, FRACTION_SCALE - 1 )
	return cell, fraction
end

local function sendExplosionEffects( center, radius, blockCount, options, deferUntilStateStream )
	if not net or not net.Start or not player or not player.GetAll then return 0 end
	local size = blockSize()
	local rangeSqr = ( EXPLOSION_CLIENT_RANGE * size ) ^ 2
	local recipients = {}
	for _, ply in ipairs( player.GetAll() ) do
		if IsValid( ply ) and entityWorldPosition( ply ):DistToSqr( center ) < rangeSqr then
			recipients[#recipients + 1] = ply
		end
	end
	if #recipients == 0 then return 0 end
	local bx, fx = splitNetworkCoordinate( center.x, size )
	local by, fy = splitNetworkCoordinate( center.y, size )
	local bz, fz = splitNetworkCoordinate( center.z, size )
	local coordinateBits = MC.Net and tonumber( MC.Net.COORD_BITS ) or 20
	local packetBlockCount = math.Clamp( math.floor( tonumber( blockCount ) or 0 ), 0, 4294967295 )
	local large = radius >= 2 and options.interactsWithBlocks ~= false
	local function sendPacket( target )
		net.Start( "mc_explosion_fx" )
			net.WriteInt( bx, coordinateBits )
			net.WriteUInt( fx, 16 )
			net.WriteInt( by, coordinateBits )
			net.WriteUInt( fy, 16 )
			net.WriteInt( bz, coordinateBits )
			net.WriteUInt( fz, 16 )
			net.WriteFloat( radius )
			net.WriteUInt( packetBlockCount, 32 )
			net.WriteBool( large )
		net.Send( target )
		return true
	end
	-- Destructive explosions use the paced state stream. Append the effects to
	-- that same reliable queue so the client observes the removed cells before
	-- ClientExplosionTracker performs its required target-is-air particle test.
	if deferUntilStateStream == true and SV.EnqueueReliableNet
	and SV.EnqueueReliableNet( recipients, 48, sendPacket, false ) then
		return #recipients
	end
	sendPacket( recipients )
	return #recipients
end

function SV.ApplyMinecraftExplosion( center, radius, options )
	if not isvector( center ) then return false, "invalid_center" end
	radius = tonumber( radius ) or 0
	if radius <= 0 then return false, "invalid_radius" end
	options = istable( options ) and options or {}
	if not Explosion.SelectJavaExplosionCells then return false, "explosion_selector_unavailable" end

	local customResistance = options.blockResistance
	local selected, selectionError = Explosion.SelectJavaExplosionCells( center, radius, {
		inBounds = function( bx, by, bz )
			return not SV.WorldBoundsOK or SV.WorldBoundsOK( bx, by, bz )
		end,
		resistance = function( stateId, bx, by, bz, remainingPower )
			if isfunction( customResistance ) then
				local value = customResistance( stateId, bx, by, bz, remainingPower, options )
				if value ~= nil then return value end
			end
			return defaultResistance( stateId )
		end,
		shouldSelect = function( stateId, bx, by, bz, remainingPower )
			if isfunction( options.shouldBlockExplode ) then
				return options.shouldBlockExplode( stateId, bx, by, bz, remainingPower, options ) ~= false
			end
			return true
		end,
	} )
	if not selected then return false, selectionError or "selection_failed" end

	local damagedCount, entityHits = 0, {}
	if options.affectsEntities ~= false then
		damagedCount, entityHits = damageEntities( center, radius, options )
	end
	local blockCount = #selected
	local snapshots, snapshotByKey, removals = {}, {}, {}
	if options.interactsWithBlocks ~= false then
		shuffle( selected )
		for _, cell in ipairs( selected ) do
			local stateId = MC.GetBlockState and MC.GetBlockState( cell.bx, cell.by, cell.bz ) or 0
			if stateId ~= 0 then
				local name, _, blockId = stateInfo( stateId )
				local snapshot = {
					bx = cell.bx, by = cell.by, bz = cell.bz,
					stateId = stateId,
					name = name, blockId = blockId,
					blockEntity = MC.GetBlockEntity and MC.GetBlockEntity( cell.bx, cell.by, cell.bz ) or nil,
				}
				snapshots[#snapshots + 1] = snapshot
				snapshotByKey[MC.CellKey( cell.bx, cell.by, cell.bz )] = snapshot
				removals[#removals + 1] = { bx = cell.bx, by = cell.by, bz = cell.bz, stateId = 0 }
			end
		end
	end
	local preparedInteractions = prepareBlockInteractions( snapshots, radius, options )

	local transaction = { ok = true, changed = 0, changes = {} }
	if #removals > 0 then
		if not SV.ApplyBlockTransaction then return false, "block_transaction_unavailable" end
		transaction = SV.ApplyBlockTransaction( removals, {
			actor = nil,
			fx = false,
			handlers = true,
			compareCollision = true,
			explosionMeshThrottle = true,
			netPaced = true,
			stateStream = true,
			deferPhys = true,
			validateChange = function( info )
				local snapshot = snapshotByKey[MC.CellKey( info.bx, info.by, info.bz )]
				if snapshot then return info.oldStateId == snapshot.stateId, "explosion_state_changed" end
				return false, "explosion_snapshot_missing"
			end,
		} )
	end

	local transactionOK = transaction and transaction.ok == true
	local blockInteractions = transactionOK
		and commitBlockInteractions( preparedInteractions, transaction, snapshots, radius, options ) or {}
	local fireTransaction, fireError = { ok = true, changed = 0, changes = {} }, nil
	if transactionOK and options.createFire == true then
		fireTransaction, fireError = createExplosionFire( selected )
		if not fireTransaction or fireTransaction.ok ~= true then
			reportIntegrationError( "fire", "options", fireError or "explosion_fire_failed" )
		end
	end
	local recipients = sendExplosionEffects(
		center, radius, blockCount, options, transactionOK and #removals > 0 )
	local details = {
		center = copyVector( center ),
		radius = radius,
		selected = selected,
		blockCount = blockCount,
		snapshots = snapshots,
		removed = transactionOK and ( transaction.changed or 0 ) or 0,
		damagedEntities = damagedCount,
		entityHits = entityHits,
		blockInteractions = blockInteractions,
		createdFire = fireTransaction and fireTransaction.ok == true and ( fireTransaction.changed or 0 ) or 0,
		fireTransaction = fireTransaction,
		fireError = fireError,
		recipients = recipients,
		transaction = transaction,
	}
	if isfunction( options.onFinished ) then
		local finishedOK, finishedError = pcall( options.onFinished, details, options )
		if not finishedOK then reportIntegrationError( "finished", "options", finishedError ) end
	end
	if not transactionOK then return false, transaction and transaction.error or "explosion_transaction_failed", details end
	return true, details
end
