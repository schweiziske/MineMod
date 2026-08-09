--[[----------------------------------------------------------------------------
    Server-side transient crafting menus.

    Player inventory crafting is the 2x2 InventoryMenu.  A placed crafting
    table uses the same container implementation with a 3x3 grid; only the
    slot layout and validity callback differ.  Neither grid is persisted.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local INVENTORY_SIZE = 36

local function playerSlotDefinitions( storage, offset )
	local definitions = {}
	offset = math.floor( tonumber( offset ) or 0 )
	for index = 0, INVENTORY_SIZE - 1 do
		definitions[#definitions + 1] = {
			index = offset + index,
			storage = storage,
			storageIndex = index + 1,
			group = index < 9 and "hotbar" or "main",
		}
	end
	return definitions
end

local function playerTargets( offset )
	local targets = {}
	for index = 0, 8 do targets[#targets + 1] = offset + index end
	for index = 9, 35 do targets[#targets + 1] = offset + index end
	return targets
end

local function selectedChanged( record, changedSlots, offset )
	local selectedIndex = offset + math.Clamp( math.floor( tonumber( record.selected ) or 0 ), 0, 8 )
	for _, index in ipairs( changedSlots or {} ) do
		if index == selectedIndex then return true end
	end
	return false
end

local function blockNameAt( bx, by, bz )
	if not MC.GetBlock then return nil end
	local id = MC.GetBlock( bx, by, bz )
	local block = MC.Blocks and MC.Blocks[id]
	return block and ( block.mcid or block.name ) or nil
end

local function tableStillValid( ply, bx, by, bz )
	if not IsValid( ply ) or not ply:Alive() then return false end
	if blockNameAt( bx, by, bz ) ~= "minecraft:crafting_table" then return false end
	local reach = MC.Config and MC.Config.Reach and MC.Config.Reach:GetFloat() or 0
	return reach <= 0 or not MC.ReachAllowsEye
		or MC.ReachAllowsEye( ply:EyePos(), bx, by, bz, reach )
end

local function buildMenu( ply, record, width, height, kind, tablePosition )
	local inputCount = width * height
	local resultStorage, inputStorage = {}, {}
	local resultSlot = 0
	local inputSlots = {}
	local slots = {
		{
			index = resultSlot,
			storage = resultStorage,
			storageIndex = 1,
			group = "result",
			mayPlace = function() return false end,
			meta = { role = "result" },
		},
	}
	for index = 0, inputCount - 1 do
		local menuIndex = index + 1
		inputSlots[index + 1] = menuIndex
		slots[#slots + 1] = {
			index = menuIndex,
			storage = inputStorage,
			storageIndex = index + 1,
			group = "crafting",
			meta = { role = "input", position = index },
		}
	end
	local playerOffset = inputCount + 1
	for _, definition in ipairs( playerSlotDefinitions( record.storage, playerOffset ) ) do slots[#slots + 1] = definition end

	local menu, err = MC.NewInventoryContainer( {
		id = kind == "player" and record.container.id or ( record.nextContainerId or 2 ),
		kind = kind,
		revision = record.container.revision,
		slots = slots,
		hotbarSlots = (function()
			local map = {}
			for button = 0, 8 do map[button + 1] = playerOffset + button end
			return map
		end)(),
		transferRules = {
			crafting = { targets = { "hotbar", "main" } },
			main = { targets = { "crafting" } },
			hotbar = { targets = { "crafting" } },
		},
		context = { player = ply, crafting = true },
	} )
	if not menu then return nil, err end
	if kind ~= "player" then
		record.nextContainerId = ( menu.id + 1 ) % 65535
		if record.nextContainerId == 0 or record.nextContainerId == 1 then record.nextContainerId = 2 end
	end

	menu.crafting = {
		width = width,
		height = height,
		resultSlot = resultSlot,
		inputSlots = inputSlots,
		playerOffset = playerOffset,
		playerTargets = playerTargets( playerOffset ),
		tablePosition = tablePosition,
	}
	menu.playerOffset = playerOffset
	menu.craftingWidth = width
	menu.craftingHeight = height
	menu.resultSlot = resultSlot
	menu.beforeCommit = function( committed )
		return MC.CraftingRefreshResult( committed )
	end
	menu.takeResult = MC.CraftingTakeResult
	local refreshed, refreshError = MC.CraftingRefreshResult( menu )
	if not refreshed then return nil, refreshError or "crafting_result_refresh_failed" end

	menu.onCommit = function( committed, result, context )
		-- The menu and the persistent player container share the player storage
		-- table.  Keep their revisions monotonic even when only the transient
		-- grid changed, so a close/reopen cannot accept an old action.
		local playerChanged = false
		for _, index in ipairs( result.changedSlots or {} ) do
			if index >= playerOffset then playerChanged = true break end
		end
		committed.revision = math.max( committed.revision, record.container.revision )
		record.container.revision = committed.revision
		record.revision = committed.revision
		if playerChanged then
			record.dirty = true
			if selectedChanged( record, result.changedSlots, playerOffset ) and SV.UpdatePlayerHeldNetwork then
				SV.UpdatePlayerHeldNetwork( record )
			end
		end
		if SV.PublishActiveInventoryCommit then
			SV.PublishActiveInventoryCommit( record, result, context or {} )
		end
	end
	return menu, playerOffset
end

function SV.BuildPlayerCraftingMenu( ply, record )
	return buildMenu( ply, record, 2, 2, "player", nil )
end

function SV.BuildCraftingTableMenu( ply, record, bx, by, bz )
	return buildMenu( ply, record, 3, 3, "crafting_table", { bx = bx, by = by, bz = bz } )
end

function SV.OpenCraftingTable( ply, bx, by, bz )
	if not IsValid( ply ) or not ply:Alive() then return false, "invalid_player" end
	if not tableStillValid( ply, bx, by, bz ) then return false, "crafting_table_unavailable" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply ) or nil
	if not record then return false, "inventory_not_loaded" end
	if record.session and SV.ClosePlayerInventory then SV.ClosePlayerInventory( ply, "switch" ) end
	local menu, playerOffsetOrError = SV.BuildCraftingTableMenu( ply, record, bx, by, bz )
	if not menu then return false, playerOffsetOrError end
	local now = CurTime()
	menu.cursor = MC.CopyItemStack( record.carried )
	record.carried = nil
	record.session = {
		token = util.SHA256 and util.SHA256( table.concat( { ply:EntIndex(), SysTime(), math.random(), "crafting_table" }, ":" ) )
			or util.CRC( tostring( ply:EntIndex() ) .. tostring( SysTime() ) ),
		kind = "crafting_table",
		container = menu,
		creative = false,
		openedAt = now,
		lastActionId = nil,
		crafting = true,
		craftingWidth = 3,
		craftingHeight = 3,
		resultSlot = 0,
		playerOffset = playerOffsetOrError,
		chestSlots = 0,
		validate = function() return tableStillValid( ply, bx, by, bz ) end,
	}
	return SV.SendActiveInventoryOpen and SV.SendActiveInventoryOpen( ply, record, "crafting_table" ) or true
end

function SV.CloseCraftingMenu( record, session, context )
	if not record or not session or not session.crafting or not session.container then return false end
	local menu = session.container
	local stacks = MC.CraftingClearInputs( menu )
	local base = record.container
	local snapshot = MC.ContainerSnapshot( base )
	local targets = {}
	for index = 0, INVENTORY_SIZE - 1 do targets[#targets + 1] = index end
	for _, stack in ipairs( stacks ) do
		local remaining = select( 1, MC.ContainerMoveStackTo( base, stack, targets, context or {} ) )
		if not MC.IsEmptyItemStack( remaining ) and SV.SpawnItemDrop then
			local position = IsValid( record.owner ) and record.owner:GetShootPos() or Vector( 0, 0, 0 )
			SV.SpawnItemDrop( position, remaining, record.owner )
		end
	end
	local changed = MC.ContainerChangedSlots( base, snapshot )
	if #changed > 0 then
		base.revision = math.max( base.revision + 1, menu.revision )
		record.revision = base.revision
		record.dirty = true
		if SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( record ) end
	end
	return #changed > 0
end

hook.Add( "MC.BlocksChanged", "mc_crafting_menu_block_validity", function()
	for ply, record in pairs( SV.PlayerInventories or {} ) do
		local session = record and record.session
		if session and session.kind == "crafting_table" and type( session.validate ) == "function" then
			local called, valid = pcall( session.validate )
			if not called or valid ~= true then
				SV.ClosePlayerInventory( ply, "container_unavailable" )
			end
		end
	end
end )
