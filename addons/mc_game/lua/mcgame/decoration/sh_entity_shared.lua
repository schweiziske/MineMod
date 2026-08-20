-- Shared entity plumbing for Painting and ItemFrame.  The concrete entity
-- files own their Java-specific state; this module only translates the common
-- HangingEntity/BlockAttachedEntity mechanics into the game-layer API.

MC = MC or {}
MC.Decoration = MC.Decoration or {}
local D = MC.Decoration

local function api()
	return MC.API or {}
end

local function world()
	return api().World or {}
end

local function coords()
	return api().Coords or {}
end

local function liquid()
	return api().Liquid or {}
end

local function blockSize()
	local value = coords().BlockSize and coords().BlockSize() or 36.5
	return math.max( 0.001, tonumber( value ) or 36.5 )
end

local function copyVector( value )
	if not value then return nil end
	if Vector then return Vector( value.x or 0, value.y or 0, value.z or 0 ) end
	return { x = value.x or 0, y = value.y or 0, z = value.z or 0 }
end

local function addVector( a, b )
	return copyVector( { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z } )
end

local function scaleVector( a, n )
	return copyVector( { x = a.x * n, y = a.y * n, z = a.z * n } )
end

function D.DefineHangingData( ent )
	ent:NetworkVar( "Int", 0, "DecorationBX" )
	ent:NetworkVar( "Int", 1, "DecorationBY" )
	ent:NetworkVar( "Int", 2, "DecorationBZ" )
	ent:NetworkVar( "Int", 3, "DecorationDirection" )
	ent:NetworkVar( "Bool", 0, "DecorationInvisible" )
end

function D.SetHangingBlockPos( ent, bx, by, bz )
	ent:SetDecorationBX( math.floor( tonumber( bx ) or 0 ) )
	ent:SetDecorationBY( math.floor( tonumber( by ) or 0 ) )
	ent:SetDecorationBZ( math.floor( tonumber( bz ) or 0 ) )
	D.RecalculateHanging( ent )
end

function D.HangingBlockPos( ent )
	return ent:GetDecorationBX(), ent:GetDecorationBY(), ent:GetDecorationBZ()
end

function D.SetHangingDirection( ent, direction )
	local resolved = D.Direction( direction ) or D.Direction( "south" )
	if not resolved.horizontal and ent.MCDecorationKind ~= "item_frame" and ent.MCDecorationKind ~= "glow_item_frame" then
		resolved = D.Direction( "south" )
	end
	ent:SetDecorationDirection( resolved.id )
	if ent.SetAngles then
		if resolved.horizontal then
			local yaw = ({ north = 180, south = 0, west = 90, east = -90 })[resolved.name] or 0
			ent:SetAngles( Angle and Angle( 0, yaw, 0 ) or ent:GetAngles() )
		else
			local pitch = resolved.name == "up" and -90 or 90
			ent:SetAngles( Angle and Angle( pitch, 0, 0 ) or ent:GetAngles() )
		end
	end
	D.RecalculateHanging( ent )
end

function D.HangingDirection( ent )
	return D.Direction( ent:GetDecorationDirection() ) or D.Direction( "south" )
end

function D.HangingWorldCenter( ent, geometry )
	local bx, by, bz = D.HangingBlockPos( ent )
	local center = D.CellCenter( bx, by, bz )
	if not center or not geometry then return nil end
	return addVector( center, scaleVector( geometry.centerOffset, blockSize() ) )
end

function D.EntityEnginePositionForWorld( worldPosition, ent )
	if not worldPosition then return nil end
	local reference = ent.MCPlacementReference
	if IsValid and IsValid( reference ) and reference.GetPos and coords().EntityWorldPos then
		local referenceWorld = coords().EntityWorldPos( reference )
		if referenceWorld then
			local engine = reference:GetPos()
			return addVector( engine, {
				x = worldPosition.x - referenceWorld.x,
				y = worldPosition.y - referenceWorld.y,
				z = worldPosition.z - referenceWorld.z,
			} )
		end
	end
	return copyVector( worldPosition )
end

function D.SetHangingEngineBounds( ent, geometry, worldCenter )
	if not geometry or not ent.SetCollisionBounds then return end
	local size = D.SizeToEngine( geometry.size )
	local half = scaleVector( size, 0.5 )
	ent:SetCollisionBounds( scaleVector( half, -1 ), half )
	if worldCenter and SERVER and ent.SetPos then
		local engineCenter = D.EntityEnginePositionForWorld( worldCenter, ent )
		if engineCenter then
			ent.MCDecorationRepositioning = true
			ent:SetPos( engineCenter )
			ent.MCDecorationRepositioning = nil
		end
	end
end

function D.RecalculateHanging( ent )
	if not ent or not ent.GetDecorationGeometry then return end
	local geometry = ent:GetDecorationGeometry( false )
	local center = D.HangingWorldCenter( ent, geometry )
	D.SetHangingEngineBounds( ent, geometry, center )
end

local function rangesForAABB( minimum, maximum, bs )
	local epsilon = math.max( 1.0e-9, bs * 1.0e-9 )
	return math.floor( minimum.x / bs ), math.max( math.floor( minimum.x / bs ), math.floor( ( maximum.x - epsilon ) / bs ) ),
		math.floor( minimum.y / bs ), math.max( math.floor( minimum.y / bs ), math.floor( ( maximum.y - epsilon ) / bs ) ),
		math.floor( minimum.z / bs ), math.max( math.floor( minimum.z / bs ), math.floor( ( maximum.z - epsilon ) / bs ) )
end

local function overlaps( aMin, aMax, bMin, bMax )
	return aMin.x < bMax.x and aMax.x > bMin.x
		and aMin.y < bMax.y and aMax.y > bMin.y
		and aMin.z < bMax.z and aMax.z > bMin.z
end

function D.WorldAABBHasCollision( minimum, maximum )
	local bs = blockSize()
	local x1, x2, y1, y2, z1, z2 = rangesForAABB( minimum, maximum, bs )
	for bx = x1, x2 do
		for by = y1, y2 do
			for bz = z1, z2 do
				local shape = world().GetCellShape and world().GetCellShape( bx, by, bz ) or nil
				if shape and shape.hasCollision ~= false then
					local boxes = shape.collisionBoxes or shape.boxes or {}
					for _, box in ipairs( boxes ) do
						local cellMin = coords().CellMin and coords().CellMin( bx, by, bz )
						if cellMin then
							local bmin = addVector( cellMin, scaleVector( { x = box[1] or 0, y = box[2] or 0, z = box[3] or 0 }, bs ) )
							local bmax = addVector( cellMin, scaleVector( { x = box[4] or 1, y = box[5] or 1, z = box[6] or 1 }, bs ) )
							if overlaps( minimum, maximum, bmin, bmax ) then return true end
						end
					end
				end
			end
		end
	end
	return false
end

local function entityAABB( ent, popBox )
	if not IsValid or not IsValid( ent ) then return nil, nil end
	if popBox and ent.GetDecorationGeometry then
		local geometry = ent:GetDecorationGeometry( true )
		local centre = D.HangingWorldCenter( ent, geometry )
		if centre and geometry then
			local size = D.SizeToEngine( geometry.size )
			local half = scaleVector( size, 0.5 )
			return centre - half, centre + half
		end
	end
	if ent.WorldSpaceAABB then return ent:WorldSpaceAABB() end
	local pos = ent:GetPos()
	local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
	return pos + mins, pos + maxs
end

function D.HangingEntityConflict( ent, allowSameType )
	if not ents or not ents.FindInBox then return false end
	-- HangingEntity#canCoexist queries the ordinary getPopBox(), not the
	-- rendered/map-sized bounding box.  ItemFrame overrides getPopBox() to
	-- always use the 0.75 frame, even when a map expands its render AABB.
	local minimum, maximum = entityAABB( ent, true )
	if not minimum or not maximum then return false end
	for _, other in ipairs( ents.FindInBox( minimum, maximum ) or {} ) do
		if other ~= ent and IsValid( other ) and other.IsMinecraftHangingDecoration then
			local sameType = other:GetClass() == ent:GetClass()
			local sameDirection = other.GetDecorationDirection and other:GetDecorationDirection() == ent:GetDecorationDirection()
			if ( not allowSameType and sameType ) or sameDirection then
				local otherMin, otherMax = entityAABB( other, true )
				if not otherMin or overlaps( minimum, maximum, otherMin, otherMax ) then return true end
			end
		end
	end
	return false
end

function D.HangingSurvives( ent, allowSameType, supportCells, fixed )
	if fixed then return true end
	local geometry = ent:GetDecorationGeometry( true )
	local center = D.HangingWorldCenter( ent, geometry )
	if not center then return false end
	local size = D.SizeToEngine( geometry.size )
	local half = scaleVector( size, 0.5 )
	local minimum, maximum = center - half, center + half
	if D.WorldAABBHasCollision( minimum, maximum ) then return false end
	if D.HangingEntityConflict( ent, allowSameType ) then return false end
	for _, cell in ipairs( supportCells or {} ) do
		local info = world().GetBlockInfo and world().GetBlockInfo( cell.bx, cell.by, cell.bz ) or nil
		local shape = world().GetCellShape and world().GetCellShape( cell.bx, cell.by, cell.bz ) or nil
		local direction = D.HangingDirection( ent )
		local diode = direction.horizontal and D.IsDiode( info )
		if not D.ShapeIsSolid( shape ) and not diode then return false end
	end
	return true
end

function D.HangingInitialize( ent, kind )
	ent.MCDecorationKind = kind
	ent.IsMinecraftHangingDecoration = true
	ent:SetDecorationDirection( D.Direction( "south" ).id )
	ent:SetDecorationInvisible( false )
	ent:SetMoveType( MOVETYPE_NONE )
	ent:SetSolid( SOLID_BBOX )
	ent:SetCollisionGroup( COLLISION_GROUP_WEAPON or COLLISION_GROUP_DEBRIS or 1 )
	ent:DrawShadow( false )
	ent:SetUseType( SIMPLE_USE )
	if ent.SetTrigger then ent:SetTrigger( false ) end
	D.RecalculateHanging( ent )
end

function D.HangingTick( ent )
	if not SERVER then return end
	ent.MCDecorationCheckInterval = ( ent.MCDecorationCheckInterval or 0 ) + 1
	if ent.MCDecorationCheckInterval == 101 then
		ent.MCDecorationCheckInterval = 0
		if not ent:IsRemoved() and not ent:SurvivesMinecraft() then
			if ent.BeforeMinecraftKill then ent:BeforeMinecraftKill() end
			if ent.DropMinecraftItem then ent:DropMinecraftItem( nil ) end
			ent:Remove()
		end
	end
end

function D.HangingMoveBreak( ent )
	-- BlockAttachedEntity#move/push immediately breaks a movable hanging
	-- entity. ItemFrame overrides both methods when its `fixed` bit is set;
	-- the SENT has no Java override, so keep the same guard here as well as in
	-- the physics callback. Never key this off a guessed MCDecorationFixed flag:
	-- the authoritative network field is GetFrameFixed().
	local fixed = ent and ent.GetFrameFixed and ent:GetFrameFixed() == true
	if not SERVER or ent.MCDecorationRepositioning or fixed then return end
	if ent:IsRemoved() then return end
	-- BlockAttachedEntity#move/#push call kill before dropItem. ItemFrame's kill
	-- has a framed-map side effect; run that side effect before the drop helper
	-- while delaying Source removal until the helper has read position/state.
	if ent.BeforeMinecraftKill then ent:BeforeMinecraftKill() end
	if ent.DropMinecraftItem then ent:DropMinecraftItem( nil ) end
	ent:Remove()
end

-- EntityFluidInteraction#update scans Entity#getFluidInteractionBox, which is
-- the bounding box deflated by 0.001 block, and considers water present when
-- a water surface reaches that box. Keep this query read-only and API-backed.
function D.EntityTouchesMinecraftWater( ent )
	if not IsValid or not IsValid( ent ) then return false end
	local getBounds = coords().EntityWorldAABB
	local getLiquid = liquid().GetAt
	if type( getBounds ) ~= "function" or type( getLiquid ) ~= "function" then return false end
	local minimum, maximum = getBounds( ent )
	if not minimum or not maximum then return false end
	local bs = blockSize()
	local inset = bs * 0.001
	local x0, y0, z0 = math.floor( ( minimum.x + inset ) / bs ),
		math.floor( ( minimum.y + inset ) / bs ), math.floor( ( minimum.z + inset ) / bs )
	local x1, y1, z1 = math.ceil( ( maximum.x - inset ) / bs ) - 1,
		math.ceil( ( maximum.y - inset ) / bs ) - 1, math.ceil( ( maximum.z - inset ) / bs ) - 1
	for bx = x0, x1 do
		for by = y0, y1 do
			for bz = z0, z1 do
				local state = getLiquid( bx, by, bz )
				local surface = state and ( bz + ( tonumber( state.height ) or 0 ) ) * bs or nil
				if state and state.kind == "water" and surface >= minimum.z + inset then return true end
			end
		end
	end
	return false
end

local function exactExplosionDirectSource( damageInfo, context )
	local direct = context and context.directSourceEntity or nil
	if IsValid and IsValid( direct ) then return direct end
	-- MC's explosion engine sets the CTakeDamageInfo inflictor to options.source.
	-- Require the game-owned marker so a source-less explosion whose inflictor
	-- falls back to its indirect actor is never misclassified as a direct source.
	if not ( MC.SV and ( tonumber( MC.SV.MinecraftExplosionDamageDepth ) or 0 ) > 0 ) then return nil end
	local inflictor = damageInfo and damageInfo.GetInflictor and damageInfo:GetInflictor() or nil
	if IsValid and IsValid( inflictor ) and inflictor.MCExplosionDirectSource == true then return inflictor end
	return nil
end

function D.BlockAttachedIgnoresExplosion( damageInfo, context )
	context = type( context ) == "table" and context or {}
	if context.explosion ~= true then return false end
	if context.directSourceInWater ~= nil then return context.directSourceInWater == true end
	local direct = exactExplosionDirectSource( damageInfo, context )
	return direct ~= nil and D.EntityTouchesMinecraftWater( direct ) == true
end

-- DamageSource tags are data-driven in Java. Source's CTakeDamageInfo only
-- carries coarse bit flags, so decoration entities consume an optional
-- game-owned metadata record first and derive only the two safe broad facts
-- (blast == explosion, burn == on_fire) when no record exists. Unknown source
-- kinds deliberately stay unknown; they must not be promoted to a player
-- attack or an armor-stand projectile by class-name guesswork.
local DAMAGE_TAGS = {
	byPassesInvulnerability = {
		["minecraft:out_of_world"] = true, ["minecraft:generic_kill"] = true,
	},
	alwaysKills = {
		["minecraft:arrow"] = true, ["minecraft:trident"] = true,
		["minecraft:fireball"] = true, ["minecraft:wither_skull"] = true,
		["minecraft:wind_charge"] = true,
	},
	canBreak = {
		["minecraft:player_explosion"] = true,
		["minecraft:player_attack"] = true, ["minecraft:spear"] = true,
		["minecraft:mace_smash"] = true,
	},
	ignites = {
		["minecraft:in_fire"] = true, ["minecraft:campfire"] = true,
	},
	burns = { ["minecraft:on_fire"] = true },
	explosions = {
		["minecraft:fireworks"] = true, ["minecraft:explosion"] = true,
		["minecraft:player_explosion"] = true,
		["minecraft:bad_respawn_point"] = true,
	},
}

local function canonicalDamageType( value )
	if value == nil then return nil end
	value = string.lower( tostring( value ) )
	if value == "" then return nil end
	if not string.find( value, ":", 1, true ) then value = "minecraft:" .. value end
	return value
end

function D.DamageTagsForType( value )
	local id = canonicalDamageType( value )
	if not id then return nil end
	return {
		damageTypeId = id,
		bypassesInvulnerability = DAMAGE_TAGS.byPassesInvulnerability[id] == true,
		alwaysKills = DAMAGE_TAGS.alwaysKills[id] == true,
		canBreak = DAMAGE_TAGS.canBreak[id] == true,
		ignites = DAMAGE_TAGS.ignites[id] == true,
		burns = DAMAGE_TAGS.burns[id] == true,
		explosion = DAMAGE_TAGS.explosions[id] == true,
		isPlayerAttack = id == "minecraft:player_attack"
			or id == "minecraft:spear" or id == "minecraft:mace_smash",
	}
end

local function metadataForDamage( entity, damageInfo )
	local server = MC.SV
	if server and server.GetCombatDamageContext then
		local value = server.GetCombatDamageContext( entity, damageInfo )
		if type( value ) == "table" then return value end
	end
	return nil
end

function D.DecorationDamageContext( entity, damageInfo )
	local metadata = metadataForDamage( entity, damageInfo ) or {}
	local output = {}
	for key, value in pairs( metadata ) do output[key] = value end
	local tags = D.DamageTagsForType( output.damageTypeId )
	if tags then
		for key, value in pairs( tags ) do
			if output[key] == nil then output[key] = value end
		end
	end
	-- A blast is safe to classify as an explosion for the decoration branch;
	-- it is not safe to classify it as player_explosion (that distinction is
	-- supplied by an explicit metadata producer when available).
	if output.explosion == nil and damageInfo and damageInfo.IsDamageType
		and DMG_BLAST ~= nil and damageInfo:IsDamageType( DMG_BLAST ) then
		output.explosion = true
	end
	-- A raw Source burn flag is only used for the Java on_fire branch. Fire
	-- contact paths provide the exact in_fire/campfire metadata above; an
	-- unlabelled slow-burn flag is intentionally not treated as igniting.
	if output.burns == nil and damageInfo and damageInfo.IsDamageType
		and DMG_BURN ~= nil and damageInfo:IsDamageType( DMG_BURN ) then
		output.burns = true
	end
	return output
end

-- The Java checks below are game-mode / gamerule concepts.  There is no
-- engine-side gamerule table in this addon, so keep the adapter explicit:
-- absent capability means the permissive vanilla default (mobGriefing=true),
-- while a game-mode API can still provide the exact mayBuild result.
function D.MobGriefingEnabled()
	local query = MC.API and MC.API.GameRules and MC.API.GameRules.Get
	if type( query ) == "function" then
		local ok, value = pcall( query, "minecraft:mob_griefing" )
		if ok and value ~= nil then return value == true end
	end
	return true
end

function D.PlayerMayBuild( ply )
	if not IsValid or not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() then return true end
	local gameMode = MC.API and MC.API.GameMode
	if gameMode and gameMode.Get then
		local mode = gameMode.Get( ply )
		if mode == "spectator" or mode == "adventure" then return false end
		return true
	end
	if ply.GetNW2Bool and ply:GetNW2Bool( "mc_adventure_no_build", false ) then return false end
	return true
end

function D.EncodeNetworkStack( ent, stack, setters )
	setters = setters or {}
	local empty = not stack or ( tonumber( stack.count ) or 0 ) <= 0
	if setters.name then setters.name( ent, empty and "" or tostring( stack.item or "" ) ) end
	if setters.count then setters.count( ent, empty and 0 or math.max( 1, math.floor( tonumber( stack.count ) or 1 ) ) ) end
	if setters.damage then setters.damage( ent, empty and 0 or math.max( 0, math.floor( tonumber( stack.damage ) or 0 ) ) ) end
	local components = ""
	if not empty and type( stack.components ) == "table" and util and util.TableToJSON then
		components = util.TableToJSON( stack.components, false ) or ""
		if #components > 480 then components = "" end
	end
	if setters.components then setters.components( ent, components ) end
end

function D.DecodeNetworkStack( ent, getters )
	getters = getters or {}
	local name = getters.name and getters.name( ent ) or ""
	local count = getters.count and getters.count( ent ) or 0
	if name == "" or count <= 0 then return nil end
	local components
	local encoded = getters.components and getters.components( ent ) or ""
	if encoded ~= "" and util and util.JSONToTable then
		local decoded = util.JSONToTable( encoded )
		if type( decoded ) == "table" then components = decoded end
	end
	return {
		item = name,
		count = math.max( 1, math.floor( tonumber( count ) or 1 ) ),
		damage = getters.damage and math.max( 0, math.floor( tonumber( getters.damage( ent ) ) or 0 ) ) or nil,
		components = components,
	}
end

function D.CreativePlayer( ply )
	return IsValid and IsValid( ply ) and MC.SV and MC.SV.PlayerHasInfiniteMaterials
		and MC.SV.PlayerHasInfiniteMaterials( ply ) == true or false
end

function D.EntityDropsEnabled()
	if MC.RunEvent then
		local result = MC.RunEvent( "MC.EntityDropsEnabled" )
		if result ~= nil then return result == true end
	end
	return true
end

-- ItemFrame#interact asks MapItemSavedData whether a tracked map is already
-- displayed by 256 frames.  The map saved-data store is not part of the
-- game-layer API yet; keep the required conservative default (unknown means
-- allow) and expose the exact missing capability in the handoff document.
function D.MapTrackedCountOverLimit( stack, limit )
	local query = MC.API and MC.API.Maps and MC.API.Maps.IsTrackedCountOverLimit
	if type( query ) == "function" then
		local ok, result = pcall( query, stack, tonumber( limit ) or 256 )
		if ok and result ~= nil then return result == true end
	end
	return false
end

function D.NotifyAnalogOutputChanged( ent, previous )
	if not SERVER then return end
	local output = ent and ent.GetAnalogOutput and ent:GetAnalogOutput() or 0
	if MC.RunEvent then
		MC.RunEvent( "MC.DecorationAnalogOutputChanged", ent, output, previous )
		local bx, by, bz = D.HangingBlockPos( ent )
		MC.RunEvent( "MC.EntityAnalogOutputChanged", ent, bx, by, bz, output, previous )
	end
end

function D.NotifyFramedMapRemoved( ent, stack )
	if not SERVER or not stack or not D.HasMap( stack ) then return end
	if MC.RunEvent then MC.RunEvent( "MC.DecorationMapRemoved", ent, MC.CopyItemStack( stack ) ) end
end

function D.PlayDecorationSound( eventName, ent, volume, pitch )
	local position = D.WorldFromEntity( ent ) or ent:GetPos()
	local soundApi = api().Sound
	if soundApi and soundApi.Play then
		soundApi.Play( eventName, position, { volume = volume or 1, pitch = pitch or 1, soundLevel = 72 } )
	end
end

function D.SampleDecorationLight( position, glow )
	local light = api().Light
	if glow then
		-- ItemFrameRenderer uses packed light 0xF000F0 for ordinary glow items
		-- and 0xF000D2 for maps. The mesh adapter cannot submit packed light, so
		-- use the equivalent fullbright RGB while preserving the source constant
		-- in the caller's branch.
		return 1, 1, 1
	end
	if light and light.SampleRGB then
		local r, g, b = light.SampleRGB( position, 0 )
		return r or 1, g or r or 1, b or r or 1
	end
	return 1, 1, 1
end

function D.SpawnDecorationDrop( ent, stack, offsetDirection, causedBy )
	if not SERVER or not stack or not MC.SV or not MC.SV.SpawnItemDrop then return nil end
	local pos = ent:GetPos()
	local direction = D.HangingDirection( ent ) or { x = 0, y = 0, z = 0 }
	if offsetDirection ~= false then
		pos = pos + Vector( direction.x, direction.y, direction.z ) * ( blockSize() * 0.15 )
	end
	return MC.SV.SpawnItemDrop( pos, stack, causedBy, { noMerge = false, pickupDelay = 0.0 } )
end
