-- Server-authoritative furnace menus, cooking ticks and block-entity storage.

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local API = MC.API or {}
local World = API.World
local Blocks = API.Blocks
local Coords = API.Coords
local FURNACE_SLOTS = MC.FurnaceSlotCount and MC.FurnaceSlotCount() or 3

SV.Furnaces = SV.Furnaces or {}
util.AddNetworkString( "mc_furnace_state" )

local function keyFor( bx, by, bz ) return MC.CellKey( bx, by, bz ) end

local function stateAt( bx, by, bz ) return MC.GetBlockState( bx, by, bz ) end

local function blockNameAt( bx, by, bz )
	local stateId = stateAt( bx, by, bz )
	local info = MC.FurnaceStateInfo and MC.FurnaceStateInfo( stateId )
	return info and info.name or nil, stateId, info
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
	local stateId = stateAt( bx, by, bz )
	if not MC.IsFurnaceState( stateId ) then return nil end
	if not Blocks or not Blocks.CreateDefaultBlockEntity or not World or not World.SetBlockEntity then return nil end
	local created = Blocks.CreateDefaultBlockEntity( stateId )
	if type( created ) ~= "table" then return nil end
	local written = World.SetBlockEntity( bx, by, bz, created, { reason = "furnace_default" } )
	if written ~= true then return nil end
	-- SetBlockEntity commits a private copy and replaces its revision with the
	-- world transaction revision.  Keep the live runtime on that authoritative
	-- copy so a following logistics transaction does not look stale.
	return mutableBlockEntity( bx, by, bz ) or created
end

local function recordOverlay( runtime )
	if not World or not World.SetBlockEntity then return false end
	local saved, err = World.SetBlockEntity( runtime.bx, runtime.by, runtime.bz,
		runtime.record, { reason = "furnace_runtime" } )
	if saved == true then
		local persisted = mutableBlockEntity( runtime.bx, runtime.by, runtime.bz )
		if persisted then rememberPersistedRecord( runtime, persisted ) end
	elseif ErrorNoHalt then
		ErrorNoHalt( "[MC Furnace] overlay write failed: " .. tostring( err ) .. "\n" )
	end
	return saved == true
end

local function syncRecord( runtime, writeOverlay )
	local rebuilt = MC.FurnaceRecordFromStorage( runtime.storage, runtime )
	runtime.record.type = rebuilt.type
	runtime.record.codecVersion = rebuilt.codecVersion
	runtime.record.data = rebuilt.data
	runtime.record.revision = math.max( 0, math.floor( tonumber( runtime.record.revision ) or 0 ) ) + 1
	runtime.record.dirty = true
	if writeOverlay then recordOverlay( runtime ) end
end

local function stackAt( runtime, slot ) return runtime.storage[slot + 1] end
local function setStack( runtime, slot, stack ) runtime.storage[slot + 1] = MC.CopyItemStack( stack ) end

local function sendStateTo( runtime, ply )
	local entry = runtime.menus[ply]
	if not entry or not IsValid( ply ) then return end
	local session = entry.record.session
	if not session then return end
	net.Start( "mc_furnace_state" )
		net.WriteUInt( entry.menu.id, 16 )
		net.WriteString( session.token or "" )
		net.WriteBool( ( runtime.litTimeRemaining or 0 ) > 0 )
		net.WriteUInt( math.Clamp( math.floor( runtime.litTimeRemaining or 0 ), 0, 65535 ), 16 )
		net.WriteUInt( math.Clamp( math.floor( runtime.litTotalTime or 0 ), 0, 65535 ), 16 )
		net.WriteUInt( math.Clamp( math.floor( runtime.cookingTimeSpent or 0 ), 0, 65535 ), 16 )
		net.WriteUInt( math.Clamp( math.floor( runtime.cookingTotalTime or 0 ), 0, 65535 ), 16 )
	net.Send( ply )
end

local function broadcastState( runtime )
	for ply in pairs( runtime.menus ) do sendStateTo( runtime, ply ) end
end

local function publishRuntime( runtime, changedSlots, actorRecord, actorResult, actorContext )
	for ply, entry in pairs( runtime.menus ) do
		if not IsValid( ply ) or not entry.record.session then
			runtime.menus[ply] = nil
		else
			local actor = actorRecord == entry.record
			local result = actor and actorResult or { changedSlots = changedSlots or {} }
			if not actor and #result.changedSlots > 0 then
				entry.menu.revision = math.max( entry.menu.revision + 1, runtime.record.revision or 0 )
				result.revision = entry.menu.revision
			end
			if actor or #result.changedSlots > 0 then
				SV.PublishActiveInventoryCommit( entry.record, result, actor and ( actorContext or {} ) or {} )
			end
			if actor or #result.changedSlots > 0 then sendStateTo( runtime, ply ) end
		end
	end
end

local function canBurn( runtime, result )
	if not result then return false end
	local output = stackAt( runtime, 2 )
	if MC.IsEmptyItemStack( output ) then return true end
	if not MC.ItemStacksCanMerge( output, result ) then return false end
	return output.count + result.count <= MC.ItemStackMaxCount( output )
end

local function shouldTick( runtime )
	local input = stackAt( runtime, 0 )
	local fuel = stackAt( runtime, 1 )
	local recipe = MC.FindCookingRecipe and MC.FindCookingRecipe( input, runtime.recipeType )
	return ( runtime.litTimeRemaining or 0 ) > 0 or ( recipe and MC.FurnaceFuelTime( fuel ) > 0 and canBurn( runtime, recipe.result ) )
end

local function schedule( runtime )
	if not shouldTick( runtime ) or not SV.ScheduleBlockTick then return end
	SV.ScheduleBlockTick( runtime.bx, runtime.by, runtime.bz, 1 )
end

local function tickRuntime( runtime, stateId, logicTick )
	local input, fuel = stackAt( runtime, 0 ), stackAt( runtime, 1 )
	local recipe = MC.FindCookingRecipe and MC.FindCookingRecipe( input, runtime.recipeType )
	local result = recipe and recipe.result or nil
	local before = {}
	for slot = 1, FURNACE_SLOTS do before[slot] = MC.CopyItemStack( runtime.storage[slot] ) end
	local wasLit = ( runtime.litTimeRemaining or 0 ) > 0
	if wasLit then runtime.litTimeRemaining = math.max( 0, runtime.litTimeRemaining - 1 ) end
	if recipe and canBurn( runtime, result ) then
		if runtime.litTimeRemaining <= 0 and MC.FurnaceFuelTime( fuel ) > 0 then
			runtime.litTimeRemaining = MC.FurnaceFuelTime( fuel )
			runtime.litTotalTime = runtime.litTimeRemaining
			local remainder = MC.FurnaceFuelRemainder and MC.FurnaceFuelRemainder( fuel )
			if fuel.count > 1 then setStack( runtime, 1, MC.CopyItemStack( fuel, fuel.count - 1 ) )
			else setStack( runtime, 1, remainder ) end
		end
		if runtime.litTimeRemaining > 0 then
			runtime.cookingTotalTime = recipe.cookingTime
			runtime.cookingTimeSpent = runtime.cookingTimeSpent + 1
			if runtime.cookingTimeSpent >= runtime.cookingTotalTime then
				local output = stackAt( runtime, 2 )
				if MC.IsEmptyItemStack( output ) then setStack( runtime, 2, result )
				else setStack( runtime, 2, MC.CopyItemStack( output, output.count + result.count ) ) end
				setStack( runtime, 0, input.count > 1 and MC.CopyItemStack( input, input.count - 1 ) or nil )
				runtime.cookingTimeSpent = 0
				runtime.recipeUses = ( runtime.recipeUses or 0 ) + 1
			end
		end
	elseif runtime.cookingTimeSpent > 0 then
		runtime.cookingTimeSpent = math.max( 0, runtime.cookingTimeSpent - 2 )
	end

	local isLit = ( runtime.litTimeRemaining or 0 ) > 0
	local nextState = stateId
	if isLit ~= wasLit and MC.StateWith then nextState = MC.StateWith( stateId, "lit", isLit ) or stateId end
	local changed = {}
	for slot = 1, FURNACE_SLOTS do
		if not MC.ItemStacksEqual( before[slot], runtime.storage[slot] ) then changed[#changed + 1] = slot - 1 end
	end
	local progressChanged = logicTick == nil or logicTick % 4 == 0
	local persisted = #changed > 0 or isLit ~= wasLit or progressChanged
	if persisted then syncRecord( runtime, progressChanged or #changed > 0 ) end
	if #changed > 0 then publishRuntime( runtime, changed ) end
	if progressChanged or #changed > 0 or isLit ~= wasLit then broadcastState( runtime ) end
	schedule( runtime )
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
	local runtime = SV.Furnaces[key]
	if runtime then return runtime end
	if not create then return nil end
	local name, stateId, info = blockNameAt( bx, by, bz )
	if not name then return nil end
	local record = ensureBlockEntity( bx, by, bz )
	if not record or not MC.FurnaceStorageFromRecord then return nil end
	local data = record.data or {}
	runtime = {
		bx = bx, by = by, bz = bz, key = key, record = record,
		persistedRevision = revisionStamp( record ),
		storage = MC.FurnaceStorageFromRecord( record ), menus = {},
		recipeType = info.recipeType, litTimeRemaining = tonumber( data.litTimeRemaining ) or 0,
		litTotalTime = tonumber( data.litTotalTime ) or 0,
		cookingTimeSpent = tonumber( data.cookingTimeSpent ) or 0,
		cookingTotalTime = tonumber( data.cookingTotalTime ) or 0,
		recipeUses = tonumber( data.recipeUses ) or 0,
	}
	SV.Furnaces[key] = runtime
	schedule( runtime )
	return runtime
end

-- Controlled logistics adapter: external container transfers must mutate the
-- same runtime storage menus and furnace ticks use, then publish those slots.
function SV.LogisticsFurnaceRuntimeAt( bx, by, bz, create )
	return runtimeAt( bx, by, bz, create == true )
end

function SV.LogisticsCommitFurnaceRuntime( runtime, changedSlots, options )
	if type( runtime ) ~= "table" or type( changedSlots ) ~= "table" then return false, "invalid_furnace_commit" end
	options = type( options ) == "table" and options or {}
	if type( options.storage ) == "table" then
		for slot = 1, FURNACE_SLOTS do runtime.storage[slot] = MC.CopyItemStack( options.storage[slot] ) end
	end
	if type( options.state ) == "table" then
		runtime.litTimeRemaining = options.state.litTimeRemaining or runtime.litTimeRemaining
		runtime.litTotalTime = options.state.litTotalTime or runtime.litTotalTime
		runtime.cookingTimeSpent = options.state.cookingTimeSpent or 0
		runtime.cookingTotalTime = options.state.cookingTotalTime or 0
		runtime.recipeUses = options.state.recipeUses or runtime.recipeUses
	end
	if type( options.record ) == "table" then rememberPersistedRecord( runtime, options.record ) end
	local inputChanged = false
	for _, slot in ipairs( changedSlots ) do if slot == 0 then inputChanged = true break end end
	if inputChanged then
		local recipe = MC.FindCookingRecipe and MC.FindCookingRecipe( stackAt( runtime, 0 ), runtime.recipeType ) or nil
		runtime.cookingTimeSpent = 0
		runtime.cookingTotalTime = recipe and recipe.cookingTime or 0
	end
	if not options.persisted then syncRecord( runtime, true ) end
	schedule( runtime )
	publishRuntime( runtime, changedSlots )
	broadcastState( runtime )
	return true
end

local function tableStillValid( ply, runtime )
	if not IsValid( ply ) or not ply:Alive() then return false end
	local name = blockNameAt( runtime.bx, runtime.by, runtime.bz )
	if not name then return false end
	local reach = MC.Config and MC.Config.Reach and MC.Config.Reach:GetFloat() or 0
	return reach <= 0 or not MC.ReachAllowsEye
		or MC.ReachAllowsEye( MC.API.Coords.EntityEyeWorldPos( ply ), runtime.bx, runtime.by, runtime.bz, reach )
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
		{ index = 0, storage = runtime.storage, storageIndex = 1, group = "furnace_input", meta = { role = "input" },
			mayPlace = function( _, stack ) return MC.FindCookingRecipe( stack, runtime.recipeType ) ~= nil end },
		{ index = 1, storage = runtime.storage, storageIndex = 2, group = "furnace_fuel", meta = { role = "fuel" },
			mayPlace = function( _, stack ) return MC.FurnaceFuelTime( stack ) > 0 end },
		{ index = 2, storage = runtime.storage, storageIndex = 3, group = "furnace_result", meta = { role = "result" },
			mayPlace = function() return false end },
	}
	local playerOffset = FURNACE_SLOTS
	local playerDefinitions, playerMap, menuMap, hotbar = playerSlots( record.storage, playerOffset )
	for _, definition in ipairs( playerDefinitions ) do slots[#slots + 1] = definition end
	local menu, err = MC.NewInventoryContainer( {
		id = record.nextContainerId or 2, kind = runtime.recipeType == "minecraft:blasting" and "blast_furnace" or "furnace",
		revision = math.max( record.container.revision or 0, runtime.record.revision or 0 ), slots = slots,
		hotbarSlots = hotbar,
		transferRules = {
			furnace_input = { targets = { "main", "hotbar" } }, furnace_fuel = { targets = { "main", "hotbar" } },
			furnace_result = { targets = { "main", "hotbar" } },
			main = { resolve = function( _, source ) return MC.FindCookingRecipe( source, runtime.recipeType ) and { "furnace_input" }
				or MC.FurnaceFuelTime( source ) > 0 and { "furnace_fuel" } or { "hotbar" } end },
			hotbar = { resolve = function( _, source ) return MC.FindCookingRecipe( source, runtime.recipeType ) and { "furnace_input" }
				or MC.FurnaceFuelTime( source ) > 0 and { "furnace_fuel" } or { "main" } end },
		}, context = { player = ply, furnace = true },
	} )
	if not menu then return nil, err end
	record.nextContainerId = ( menu.id + 1 ) % 65535
	if record.nextContainerId == 0 or record.nextContainerId == 1 then record.nextContainerId = 2 end
	menu.playerOffset, menu.playerMenuMap, menu.menuPlayerMap = playerOffset, playerMap, menuMap
	menu.furnaceSlots, menu.furnaceRuntime = FURNACE_SLOTS, runtime
	local furnaceTargets = {}
	for index = 0, 35 do furnaceTargets[#furnaceTargets + 1] = playerMap[index] end
	menu.furnace = { inputSlot = 0, fuelSlot = 1, resultSlot = 2,
		playerTargets = furnaceTargets, recipeType = runtime.recipeType,
		resultTargets = MC.ContainerResolveTargets( menu, { "hotbar", "main" }, true ) }
	menu.takeResult = MC.FurnaceTakeResult
	menu.onCommit = function( committed, result, context )
		local furnaceChanged, playerChanged = false, false
		for _, index in ipairs( result.changedSlots or {} ) do
			if index < FURNACE_SLOTS then furnaceChanged = true else playerChanged = true end
		end
		if furnaceChanged then
			local inputChanged = false
			for _, index in ipairs( result.changedSlots or {} ) do
				if index == 0 then inputChanged = true break end
			end
			local input = stackAt( runtime, 0 )
			local recipe = MC.FindCookingRecipe( input, runtime.recipeType )
			if inputChanged then
				runtime.cookingTimeSpent, runtime.cookingTotalTime = 0, recipe and recipe.cookingTime or 0
			end
			syncRecord( runtime, true )
			schedule( runtime )
		end
		committed.revision = math.max( committed.revision, record.container.revision or 0, runtime.record.revision or 0 )
		record.container.revision, record.revision = committed.revision, committed.revision
		if playerChanged then record.dirty = true end
		if playerChanged and SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( record ) end
		publishRuntime( runtime, furnaceChanged and { 0, 1, 2 } or {}, record, result, context )
	end
	return menu
end

function SV.OpenFurnace( ply, bx, by, bz )
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
		token = util.SHA256 and util.SHA256( table.concat( { ply:EntIndex(), SysTime(), math.random(), menu.kind }, ":" ) ) or util.CRC( tostring( SysTime() ) ),
		kind = menu.kind, container = menu, creative = false, openedAt = CurTime(), lastActionId = nil,
		playerOffset = menu.playerOffset, furnaceSlots = FURNACE_SLOTS, furnace = true,
		validate = function() return tableStillValid( ply, runtime ) end,
		onClose = function() runtime.menus[ply] = nil end,
	}
	record.session = session
	runtime.menus[ply] = { record = record, menu = menu }
	if SV.SendActiveInventoryOpen then SV.SendActiveInventoryOpen( ply, record, menu.kind ) end
	sendStateTo( runtime, ply )
	return true
end

function SV.DropFurnaceContents( actor, bx, by, bz, blockEntity )
	local runtime = runtimeAt( bx, by, bz, false )
	local storage = runtime and runtime.storage or MC.FurnaceStorageFromRecord( blockEntity )
	for slot = 1, FURNACE_SLOTS do
		local stack = storage and storage[slot]
		if not MC.IsEmptyItemStack( stack ) and SV.SpawnItemDrop then
			SV.SpawnItemDrop( MC.CellWorldCenter( bx, by, bz ), MC.CopyItemStack( stack ), actor )
		end
	end
	if runtime then
		for ply in pairs( runtime.menus ) do if IsValid( ply ) then SV.ClosePlayerInventory( ply, "furnace_removed" ) end end
		SV.Furnaces[runtime.key] = nil
	end
end

function SV.FurnaceTickAt( context )
	local runtime = runtimeAt( context.bx, context.by, context.bz, true )
	if not runtime then return nil end
	return tickRuntime( runtime, context.stateId, context.logicTick )
end

MC.RegisterBlockUpdateHandler( "minecraft:furnace", { OnScheduledTick = SV.FurnaceTickAt } )
MC.RegisterBlockUpdateHandler( "minecraft:blast_furnace", { OnScheduledTick = SV.FurnaceTickAt } )

local function warmBlockEntities( cx, cy, cz )
	for key, runtime in pairs( SV.Furnaces ) do
		if runtime.bx == nil then SV.Furnaces[key] = nil end
	end
	if not World or not World.ForEachBlockEntity then return end
	World.ForEachBlockEntity( "minecraft:furnace", function( bx, by, bz )
		if cx ~= nil and Coords and Coords.CellToChunk then
			local entryCX, entryCY, entryCZ = Coords.CellToChunk( bx, by, bz )
			if entryCX ~= cx or entryCY ~= cy or entryCZ ~= cz then return end
		end
		local name = blockNameAt( bx, by, bz )
		if name then runtimeAt( bx, by, bz, true ) end
	end )
end
local function warmChunk( _, cx, cy, cz ) warmBlockEntities( cx, cy, cz ) end
hook.Add( "MC.ChunkHydrated", "mc_furnace_chunk_warm", warmChunk )
hook.Add( "MC.WorldLoaded", "mc_furnace_world_warm", function() warmBlockEntities() end )
local function clearFurnaceRuntime()
	for _, runtime in pairs( SV.Furnaces ) do
		for ply in pairs( runtime.menus or {} ) do
			if IsValid( ply ) and SV.ClosePlayerInventory then SV.ClosePlayerInventory( ply, "world_changed" ) end
		end
	end
	SV.Furnaces = {}
end
hook.Add( "MC.PreWorldLoad", "mc_furnace_world_reset", clearFurnaceRuntime )
hook.Add( "MC.WorldCleared", "mc_furnace_world_clear", clearFurnaceRuntime )
hook.Add( "MC.BlocksChanged", "mc_furnace_menu_validity", function( changes )
	for _, change in ipairs( changes or {} ) do
		local key = keyFor( change.bx, change.by, change.bz )
		local runtime = SV.Furnaces[key]
		if runtime and not blockNameAt( runtime.bx, runtime.by, runtime.bz ) then
			for ply in pairs( runtime.menus ) do if IsValid( ply ) then SV.ClosePlayerInventory( ply, "furnace_unavailable" ) end end
			SV.Furnaces[key] = nil
		end
	end
end )
