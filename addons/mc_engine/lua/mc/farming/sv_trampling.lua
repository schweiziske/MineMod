-- FarmlandBlock.fallOn for players plus a generic server entry point for
-- non-player living entities. No BMB entity files or symbols are referenced.

MC = MC or {}
MC.SV = MC.SV or {}

local Farming = MC.Farming
local SV = MC.SV

if not Farming then return end

local cvMobGriefing = CreateConVar( "mc_farming_mob_griefing", "1", FCVAR_ARCHIVE,
	"Allow non-player living entities to trample farmland, matching Java mobGriefing." )

local function isLivingEntity( entity )
	if not IsValid( entity ) then return false end
	if entity.IsPlayer and entity:IsPlayer() then return true end
	if entity.IsNPC and entity:IsNPC() then return true end
	if entity.IsNextBot and entity:IsNextBot() then return true end
	local health = entity.Health and tonumber( entity:Health() ) or nil
	return health ~= nil and health > 0
end

local function entityJavaSizeInBlocks( entity )
	if not IsValid( entity ) or not entity.OBBMins or not entity.OBBMaxs then return 0 end
	local mins, maxs = entity:OBBMins(), entity:OBBMaxs()
	if not isvector( mins ) or not isvector( maxs ) then return 0 end
	local size = maxs - mins
	local blockSize = math.max( tonumber( MC.BS ) or 36.5, 0.001 )
	local horizontalWidth = math.max( size.x, size.y, 0 )
	return horizontalWidth * horizontalWidth * math.max( size.z, 0 )
		/ ( blockSize * blockSize * blockSize )
end

local function randomFloat()
	if math.Rand then return math.Rand( 0, 1 ) end
	return math.random()
end

function SV.TryTrampleFarmland( entity, bx, by, bz, fallDistance )
	if not isLivingEntity( entity ) then return false, "not_living" end
	bx, by, bz = math.floor( tonumber( bx ) or 0 ), math.floor( tonumber( by ) or 0 ),
		math.floor( tonumber( bz ) or 0 )
	fallDistance = math.max( 0, tonumber( fallDistance ) or 0 )
	if Farming.StateName( MC.GetBlockState( bx, by, bz ) ) ~= "minecraft:farmland" then
		return false, "not_farmland"
	end
	if not ( entity.IsPlayer and entity:IsPlayer() ) and not cvMobGriefing:GetBool() then
		return false, "mob_griefing_disabled"
	end
	if entityJavaSizeInBlocks( entity ) <= 0.512 then return false, "entity_too_small" end
	if randomFloat() >= fallDistance - 0.5 then return false, "fall_too_short" end

	local dirt = MC.DefaultBlockState( "minecraft:dirt" )
	if not dirt then return false, "dirt_state_unavailable" end
	local result = SV.ApplyBlockTransaction( {
		{ bx = bx, by = by, bz = bz, stateId = dirt },
	}, {
		actor = entity,
		fx = false,
		netMode = "bulk",
		priorityPhys = true,
		immediatePhys = true,
		compareCollision = true,
	} )
	if not result or result.ok ~= true or result.changed <= 0 then
		return false, result and result.error or "write_failed"
	end
	return true, result
end

local FallByPlayer = setmetatable( {}, { __mode = "k" } )

local function playerWorldOrigin( ply, move )
	local enginePosition = move and move.GetOrigin and move:GetOrigin() or ply:GetPos()
	return MC.EngineToWorldPos and MC.EngineToWorldPos( enginePosition, ply ) or enginePosition
end

hook.Remove( "SetupMove", "mc_farming_track_player_fall" )
hook.Add( "SetupMove", "mc_farming_track_player_fall", function( ply, move )
	if not IsValid( ply ) or not ply:IsPlayer() then return end
	local now = CurTime()
	if not ply:IsOnGround() then
		local position = playerWorldOrigin( ply, move )
		if not isvector( position ) then return end
		local state = FallByPlayer[ply]
		if not state then
			state = { apexZ = position.z, lastAirAt = now }
			FallByPlayer[ply] = state
		end
		state.apexZ = math.max( state.apexZ or position.z, position.z )
		state.lastAirAt = now
	elseif FallByPlayer[ply] and now - ( FallByPlayer[ply].lastAirAt or now ) > 0.5 then
		-- Teleports or vehicle transitions may not produce OnPlayerHitGround.
		FallByPlayer[ply] = nil
	end
end )

hook.Remove( "OnPlayerHitGround", "mc_farming_player_trample" )
hook.Add( "OnPlayerHitGround", "mc_farming_player_trample", function( ply, inWater )
	local state = FallByPlayer[ply]
	FallByPlayer[ply] = nil
	if inWater == true or not state or not IsValid( ply ) then return end
	local position = MC.EntityWorldPos and MC.EntityWorldPos( ply ) or ply:GetPos()
	if not isvector( position ) then return end
	local blockSize = math.max( tonumber( MC.BS ) or 36.5, 0.001 )
	local fallDistance = math.max( 0, ( ( state.apexZ or position.z ) - position.z ) / blockSize )
	local inset = math.max( blockSize / 4096, 0.01 )
	local bx, by, bz = MC.WorldToCell( position - Vector( 0, 0, inset ) )
	SV.TryTrampleFarmland( ply, bx, by, bz, fallDistance )
end )

hook.Add( "PlayerSpawn", "mc_farming_reset_player_fall", function( ply ) FallByPlayer[ply] = nil end )
hook.Add( "PlayerDisconnected", "mc_farming_forget_player_fall", function( ply ) FallByPlayer[ply] = nil end )

Farming.MobGriefingConVar = cvMobGriefing
