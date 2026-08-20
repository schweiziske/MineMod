-- Server-authoritative brewing-stand menus, 20 TPS brewing and persistence.

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local API = MC.API or {}
local World = API.World
local Blocks = API.Blocks
local Coords = API.Coords
local BREWING_SLOTS = MC.BrewingSlotCount and MC.BrewingSlotCount() or 5
local BREWING_TIME = MC.BrewingTime and MC.BrewingTime() or 400
local FUEL_USES = MC.BrewingFuelUses and MC.BrewingFuelUses() or 20

SV.BrewingStands = SV.BrewingStands or {}
util.AddNetworkString( "mc_brewing_state" )

if resource and resource.AddFile then
	for _, fileName in ipairs( {
		"materials/mc/gui/container/brewing_stand.png",
		"materials/mc/gui/sprites/container/brewing_stand/brew_progress.png",
		"materials/mc/gui/sprites/container/brewing_stand/bubbles.png",
		"materials/mc/gui/sprites/container/brewing_stand/fuel_length.png",
		"materials/mc/gui/sprites/container/slot/brewing_fuel.png",
		"materials/mc/gui/sprites/container/slot/potion.png",
		"sound/mc/block/brewing_stand/brew1.ogg",
		"sound/mc/block/brewing_stand/brew2.ogg",
	} ) do
		resource.AddFile( fileName )
	end
end

local function keyFor( bx, by, bz ) return MC.CellKey( bx, by, bz ) end
local function stateAt( bx, by, bz ) return MC.GetBlockState( bx, by, bz ) end

local function isBrewingStandAt( bx, by, bz )
	return MC.IsBrewingStandState and MC.IsBrewingStandState( stateAt( bx, by, bz ) ) or false
end

local function mutableBlockEntity( bx, by, bz )
	if not World or not World.GetBlockEntity then return nil end
	return World.GetBlockEntity( bx, by, bz )
end

local function revisionStamp( record )
	return type( record ) == "table" and record.revision ~= nil and record.revision or false
end

local function rememberPersistedRecord( runtime, record )
	if type( record ) ~= "table" then return false end
	runtime.record = record
	runtime.persistedRevision = revisionStamp( record )
	return true
end

local function ensureBlockEntity( bx, by, bz )
	local record = mutableBlockEntity( bx, by, bz )
	if record then return record end
	if not isBrewingStandAt( bx, by, bz ) or not Blocks
		or not Blocks.CreateDefaultBlockEntity or not World or not World.SetBlockEntity then return nil end
	local created = Blocks.CreateDefaultBlockEntity( stateAt( bx, by, bz ) )
	if type( created ) ~= "table" then return nil end
	local written = World.SetBlockEntity( bx, by, bz, created, { reason = "brewing_default" } )
	if written ~= true then return nil end
	-- The engine stamps the persisted private copy with its transaction
	-- revision; the pre-write default would immediately fail logistics CAS.
	return mutableBlockEntity( bx, by, bz ) or created
end

local function recordOverlay( runtime )
	if not World or not World.SetBlockEntity then return false end
	local saved, err = World.SetBlockEntity( runtime.bx, runtime.by, runtime.bz,
		runtime.record, { reason = "brewing_runtime" } )
	if saved == true then
		local persisted = mutableBlockEntity( runtime.bx, runtime.by, runtime.bz )
		if persisted then rememberPersistedRecord( runtime, persisted ) end
	elseif ErrorNoHalt then
		ErrorNoHalt( "[MC Brewing] overlay write failed: " .. tostring( err ) .. "\n" )
	end
	return saved == true
end

local function syncRecord( runtime, writeOverlay )
	local rebuilt = MC.BrewingRecordFromStorage( runtime.storage, runtime )
	runtime.record.type = rebuilt.type
	runtime.record.codecVersion = rebuilt.codecVersion
	runtime.record.data = rebuilt.data
	runtime.record.revision = math.max( 0, math.floor( tonumber( runtime.record.revision ) or 0 ) ) + 1
	runtime.record.dirty = true
	if writeOverlay then recordOverlay( runtime ) end
end

local function stackAt( runtime, slot ) return runtime.storage[slot + 1] end

local function sendStateTo( runtime, ply )
	local entry = runtime.menus[ply]
	if not entry then return end
	if not IsValid( ply ) then runtime.menus[ply] = nil return end
	local session = entry.record.session
	if not session or session.container ~= entry.menu then runtime.menus[ply] = nil return end
	net.Start( "mc_brewing_state" )
		net.WriteUInt( entry.menu.id, 16 )
		net.WriteString( session.token or "" )
		net.WriteUInt( math.Clamp( math.floor( runtime.brewTime or 0 ), 0, BREWING_TIME ), 9 )
		net.WriteUInt( math.Clamp( math.floor( runtime.fuel or 0 ), 0, FUEL_USES ), 5 )
	net.Send( ply )
end

local function broadcastState( runtime )
	for ply in pairs( runtime.menus ) do sendStateTo( runtime, ply ) end
end

local function publishRuntime( runtime, changedSlots, actorRecord, actorResult, actorContext )
	for ply, entry in pairs( runtime.menus ) do
		local session = entry.record.session
		if not IsValid( ply ) or not session or session.container ~= entry.menu then
			runtime.menus[ply] = nil
		else
			local actor = actorRecord == entry.record
			local result = actor and actorResult or { changedSlots = changedSlots or {} }
			if actor then result.revision = entry.menu.revision end
			if not actor and #result.changedSlots > 0 then
				entry.menu.revision = math.max( entry.menu.revision + 1, runtime.record.revision or 0 )
				result.revision = entry.menu.revision
			end
			if actor or #result.changedSlots > 0 then
				SV.PublishActiveInventoryCommit( entry.record, result, actor and ( actorContext or {} ) or {} )
				sendStateTo( runtime, ply )
			end
		end
	end
end

local function shouldTick( runtime )
	return ( runtime.brewTime or 0 ) > 0 or ( runtime.fuel or 0 ) > 0 and MC.BrewingCanBrew( runtime.storage )
		or ( runtime.fuel or 0 ) <= 0 and MC.BrewingIsFuel( stackAt( runtime, 4 ) )
end

local function schedule( runtime )
	if not shouldTick( runtime ) or not SV.ScheduleBlockTick then return end
	SV.ScheduleBlockTick( runtime.bx, runtime.by, runtime.bz, 1 )
end

local function bottleState( runtime, stateId )
	local nextState = stateId
	if not MC.StateWith then return nextState end
	for slot = 0, 2 do
		local hasBottle = not MC.IsEmptyItemStack( stackAt( runtime, slot ) )
		nextState = MC.StateWith( nextState, "has_bottle_" .. slot, hasBottle ) or nextState
	end
	return nextState
end

local function refreshBottleState( runtime, actor )
	if not SV.ApplyBlockTransaction then return end
	local stateId = stateAt( runtime.bx, runtime.by, runtime.bz )
	local nextState = bottleState( runtime, stateId )
	if nextState == stateId then return end
	local transaction = SV.ApplyBlockTransaction( {
		{ bx = runtime.bx, by = runtime.by, bz = runtime.bz, stateId = nextState,
			blockEntity = runtime.record },
	}, { actor = actor, fx = false, netMode = "bulk", compareCollision = false } )
	if transaction and transaction.ok == true then
		local record = mutableBlockEntity( runtime.bx, runtime.by, runtime.bz )
		if record then rememberPersistedRecord( runtime, record ) end
	end
end

local function tickRuntime( runtime, stateId, logicTick )
	local before = {}
	for slot = 1, BREWING_SLOTS do before[slot] = MC.CopyItemStack( runtime.storage[slot] ) end
	local oldBrewTime, oldFuel = runtime.brewTime or 0, runtime.fuel or 0
	local advanced = MC.BrewingAdvance( runtime.storage, runtime )
	for slot = 1, BREWING_SLOTS do runtime.storage[slot] = MC.CopyItemStack( advanced.storage[slot] ) end
	runtime.brewTime, runtime.fuel = advanced.brewTime, advanced.fuel
	runtime.ingredientItem = advanced.ingredientItem
	if #advanced.drops > 0 and SV.SpawnItemDrop then
		local position = MC.CellWorldCenter( runtime.bx, runtime.by, runtime.bz )
		for _, stack in ipairs( advanced.drops ) do SV.SpawnItemDrop( position, stack, nil ) end
	end
	if advanced.brewed then
		local sounds = { "mc/block/brewing_stand/brew1.ogg", "mc/block/brewing_stand/brew2.ogg" }
		sound.Play( sounds[math.random( #sounds )], MC.CellWorldCenter( runtime.bx, runtime.by, runtime.bz ), 75, 100, 1 )
	end

	local changed = {}
	for slot = 1, BREWING_SLOTS do
		if not MC.ItemStacksEqual( before[slot], runtime.storage[slot] ) then changed[#changed + 1] = slot - 1 end
	end
	local progressChanged = oldBrewTime ~= runtime.brewTime or oldFuel ~= runtime.fuel
	if #changed > 0 or progressChanged then syncRecord( runtime, #changed > 0 or logicTick == nil or logicTick % 4 == 0 ) end
	if #changed > 0 then publishRuntime( runtime, changed ) end
	if progressChanged or #changed > 0 then broadcastState( runtime ) end
	schedule( runtime )

	local nextState = bottleState( runtime, stateId )
	if nextState ~= stateId then
		return {
			cells = { { bx = runtime.bx, by = runtime.by, bz = runtime.bz, stateId = nextState,
				blockEntity = runtime.record } },
			afterTransaction = function()
				local record = mutableBlockEntity( runtime.bx, runtime.by, runtime.bz )
				if record then rememberPersistedRecord( runtime, record ) end
			end,
		}
	end
	return nil
end

local function runtimeAt( bx, by, bz, create )
	local key = keyFor( bx, by, bz )
	local runtime = SV.BrewingStands[key]
	if runtime then return runtime end
	if not create or not isBrewingStandAt( bx, by, bz ) then return nil end
	local record = ensureBlockEntity( bx, by, bz )
	if not record or not MC.BrewingStorageFromRecord then return nil end
	local data = record.data or {}
	runtime = {
		bx = bx, by = by, bz = bz, key = key, record = record,
		persistedRevision = revisionStamp( record ),
		storage = MC.BrewingStorageFromRecord( record ), menus = {},
		brewTime = tonumber( data.brewTime ) or 0,
		fuel = tonumber( data.fuel ) or 0,
	}
	local loadedIngredient = runtime.storage[4]
	runtime.ingredientItem = runtime.brewTime > 0 and not MC.IsEmptyItemStack( loadedIngredient )
		and loadedIngredient.item or nil
	SV.BrewingStands[key] = runtime
	if SV.ScheduleBlockTick then SV.ScheduleBlockTick( bx, by, bz, 1 ) end
	return runtime
end

-- Controlled logistics adapter: Hopper/Dropper writes share the live brewing
-- runtime, including bottle block-state refresh and every open menu.
function SV.LogisticsBrewingRuntimeAt( bx, by, bz, create )
	return runtimeAt( bx, by, bz, create == true )
end

function SV.LogisticsCommitBrewingRuntime( runtime, changedSlots, options )
	if type( runtime ) ~= "table" or type( changedSlots ) ~= "table" then return false, "invalid_brewing_commit" end
	options = type( options ) == "table" and options or {}
	if type( options.storage ) == "table" then
		for slot = 1, BREWING_SLOTS do runtime.storage[slot] = MC.CopyItemStack( options.storage[slot] ) end
	end
	if type( options.state ) == "table" then
		runtime.brewTime = options.state.brewTime or 0
		runtime.fuel = options.state.fuel or 0
	end
	if type( options.record ) == "table" then rememberPersistedRecord( runtime, options.record ) end
	if not options.persisted then
		syncRecord( runtime, true )
		refreshBottleState( runtime )
	end
	schedule( runtime )
	publishRuntime( runtime, changedSlots )
	broadcastState( runtime )
	return true
end

local function tableStillValid( ply, runtime )
	if not IsValid( ply ) or not ply:Alive() or not isBrewingStandAt( runtime.bx, runtime.by, runtime.bz ) then return false end
	local reach = MC.Config and MC.Config.Reach and MC.Config.Reach:GetFloat() or 0
	return reach <= 0 or not MC.ReachAllowsEye
		or MC.ReachAllowsEye( ply:EyePos(), runtime.bx, runtime.by, runtime.bz, reach )
end

local function playerSlots( storage, offset )
	local definitions, map, reverse, hotbar = {}, {}, {}, {}
	for index = 0, 35 do
		local menuIndex = offset + index
		definitions[#definitions + 1] = { index = menuIndex, storage = storage, storageIndex = index + 1,
			group = index < 9 and "hotbar" or "main" }
		map[index], reverse[menuIndex] = menuIndex, index
		if index < 9 then hotbar[index + 1] = menuIndex end
	end
	return definitions, map, reverse, hotbar
end

local function buildMenu( ply, record, runtime )
	local slots = {
		{ index = 0, storage = runtime.storage, storageIndex = 1, group = "brewing_bottles", maxStack = 1,
			mayPlace = function( _, stack ) return MC.BrewingIsBottle( stack ) end },
		{ index = 1, storage = runtime.storage, storageIndex = 2, group = "brewing_bottles", maxStack = 1,
			mayPlace = function( _, stack ) return MC.BrewingIsBottle( stack ) end },
		{ index = 2, storage = runtime.storage, storageIndex = 3, group = "brewing_bottles", maxStack = 1,
			mayPlace = function( _, stack ) return MC.BrewingIsBottle( stack ) end },
		{ index = 3, storage = runtime.storage, storageIndex = 4, group = "brewing_ingredient",
			mayPlace = function( _, stack ) return MC.BrewingIsIngredient( stack ) end },
		{ index = 4, storage = runtime.storage, storageIndex = 5, group = "brewing_fuel",
			mayPlace = function( _, stack ) return MC.BrewingIsFuel( stack ) end },
	}
	local playerOffset = BREWING_SLOTS
	local playerDefinitions, playerMap, menuMap, hotbar = playerSlots( record.storage, playerOffset )
	for _, definition in ipairs( playerDefinitions ) do slots[#slots + 1] = definition end
	local function playerTargets( fallback )
		return function( container, source )
			if MC.BrewingIsFuel( source ) then
				local fuelSlot = MC.ContainerGetSlot( container, 4 )
				local existing = fuelSlot and MC.InventorySlotGet( fuelSlot ) or nil
				local fuelHasRoom = MC.IsEmptyItemStack( existing ) or MC.ItemStacksCanMerge( existing, source )
					and existing.count < MC.InventorySlotLimit( fuelSlot, source )
				if fuelHasRoom then return { "brewing_fuel" } end
				return { "brewing_ingredient" }
			end
			if MC.BrewingIsIngredient( source ) then return { "brewing_ingredient" } end
			if MC.BrewingIsBottle( source ) then return { "brewing_bottles" } end
			return { fallback }
		end
	end
	local menu, err = MC.NewInventoryContainer( {
		id = record.nextContainerId or 2, kind = "brewing_stand",
		revision = math.max( record.container.revision or 0, runtime.record.revision or 0 ),
		slots = slots, hotbarSlots = hotbar,
		transferRules = {
			brewing_bottles = { targets = { "hotbar", "main" }, reverse = true },
			brewing_ingredient = { targets = { "hotbar", "main" }, reverse = true },
			brewing_fuel = { targets = { "hotbar", "main" }, reverse = true },
			main = { resolve = playerTargets( "hotbar" ) },
			hotbar = { resolve = playerTargets( "main" ) },
		},
		context = { player = ply, brewing = true },
	} )
	if not menu then return nil, err end
	record.nextContainerId = ( menu.id + 1 ) % 65535
	if record.nextContainerId == 0 or record.nextContainerId == 1 then record.nextContainerId = 2 end
	menu.playerOffset, menu.playerMenuMap, menu.menuPlayerMap = playerOffset, playerMap, menuMap
	menu.brewingSlots, menu.brewingRuntime = BREWING_SLOTS, runtime
	menu.onCommit = function( committed, result, context )
		local brewingChanged, playerChanged = false, false
		for _, index in ipairs( result.changedSlots or {} ) do
			if index < BREWING_SLOTS then brewingChanged = true else playerChanged = true end
		end
		if brewingChanged then
			syncRecord( runtime, true )
			refreshBottleState( runtime, context and context.player or ply )
			if SV.ScheduleBlockTick then SV.ScheduleBlockTick( runtime.bx, runtime.by, runtime.bz, 1 ) end
		end
		committed.revision = math.max( committed.revision, record.container.revision or 0, runtime.record.revision or 0 )
		record.container.revision, record.revision = committed.revision, committed.revision
		if playerChanged then record.dirty = true end
		if playerChanged and SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( record ) end
		publishRuntime( runtime, brewingChanged and { 0, 1, 2, 3, 4 } or {}, record, result, context )
		if brewingChanged then broadcastState( runtime ) end
	end
	return menu
end

function SV.OpenBrewingStand( ply, bx, by, bz )
	if not IsValid( ply ) or not ply:Alive() then return false end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply ) or nil
	if not record then return false end
	local runtime = runtimeAt( bx, by, bz, true )
	if not runtime or not tableStillValid( ply, runtime ) then return false end
	if record.session and SV.ClosePlayerInventory then SV.ClosePlayerInventory( ply, "switch" ) end
	local menu, err = buildMenu( ply, record, runtime )
	if not menu then return false, err end
	menu.cursor = MC.CopyItemStack( record.carried )
	record.carried = nil
	local session = {
		token = util.SHA256 and util.SHA256( table.concat( { ply:EntIndex(), SysTime(), math.random(), menu.kind }, ":" ) )
			or util.CRC( tostring( SysTime() ) ),
		kind = menu.kind, container = menu, creative = false, openedAt = CurTime(), lastActionId = nil,
		playerOffset = menu.playerOffset, brewingSlots = BREWING_SLOTS, brewing = true,
		playerMenuMap = menu.playerMenuMap, menuPlayerMap = menu.menuPlayerMap,
		validate = function() return tableStillValid( ply, runtime ) end,
		onClose = function() runtime.menus[ply] = nil end,
	}
	record.session = session
	runtime.menus[ply] = { record = record, menu = menu }
	if SV.SendActiveInventoryOpen then SV.SendActiveInventoryOpen( ply, record, menu.kind ) end
	sendStateTo( runtime, ply )
	return true
end

function SV.DropBrewingContents( actor, bx, by, bz, blockEntity )
	local runtime = runtimeAt( bx, by, bz, false )
	local storage = runtime and runtime.storage or MC.BrewingStorageFromRecord( blockEntity )
	for slot = 1, BREWING_SLOTS do
		local stack = storage and storage[slot]
		if not MC.IsEmptyItemStack( stack ) and SV.SpawnItemDrop then
			SV.SpawnItemDrop( MC.CellWorldCenter( bx, by, bz ), MC.CopyItemStack( stack ), actor )
		end
	end
	if runtime then
		for ply in pairs( runtime.menus ) do
			if IsValid( ply ) then SV.ClosePlayerInventory( ply, "brewing_stand_removed" ) end
		end
		SV.BrewingStands[runtime.key] = nil
	end
end

function SV.BrewingTickAt( context )
	local runtime = runtimeAt( context.bx, context.by, context.bz, true )
	if not runtime then return nil end
	return tickRuntime( runtime, context.stateId, context.logicTick )
end

MC.RegisterBlockUpdateHandler( "minecraft:brewing_stand", { OnScheduledTick = SV.BrewingTickAt } )

local function warmBlockEntities( cx, cy, cz )
	if not World or not World.ForEachBlockEntity then return end
	World.ForEachBlockEntity( "minecraft:brewing_stand", function( bx, by, bz )
		if cx ~= nil and Coords and Coords.CellToChunk then
			local entryCX, entryCY, entryCZ = Coords.CellToChunk( bx, by, bz )
			if entryCX ~= cx or entryCY ~= cy or entryCZ ~= cz then return end
		end
		runtimeAt( bx, by, bz, true )
	end )
end
local function warmChunk( _, cx, cy, cz ) warmBlockEntities( cx, cy, cz ) end
hook.Add( "MC.ChunkHydrated", "mc_brewing_chunk_warm", warmChunk )
hook.Add( "MC.WorldLoaded", "mc_brewing_world_warm", function() warmBlockEntities() end )

local function clearBrewingRuntime()
	for _, runtime in pairs( SV.BrewingStands ) do
		for ply in pairs( runtime.menus or {} ) do
			if IsValid( ply ) and SV.ClosePlayerInventory then SV.ClosePlayerInventory( ply, "world_changed" ) end
		end
	end
	SV.BrewingStands = {}
end
hook.Add( "MC.PreWorldLoad", "mc_brewing_world_reset", clearBrewingRuntime )
hook.Add( "MC.WorldCleared", "mc_brewing_world_clear", clearBrewingRuntime )
hook.Add( "MC.BlocksChanged", "mc_brewing_menu_validity", function( changes )
	for _, change in ipairs( changes or {} ) do
		local runtime = SV.BrewingStands[keyFor( change.bx, change.by, change.bz )]
		if runtime and not isBrewingStandAt( runtime.bx, runtime.by, runtime.bz ) then
			for ply in pairs( runtime.menus ) do
				if IsValid( ply ) then SV.ClosePlayerInventory( ply, "brewing_stand_unavailable" ) end
			end
			SV.BrewingStands[runtime.key] = nil
		end
	end
end )
