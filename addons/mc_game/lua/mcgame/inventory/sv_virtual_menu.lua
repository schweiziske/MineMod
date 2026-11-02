--[[----------------------------------------------------------------------------
	Virtual chest menus ("menu" session kind).

	A chest-shaped screen whose upper rows are buttons owned by Lua instead of a
	block entity: shops, upgrade boards, pickers. Display slots are result-role
	and read-only, so the client never predicts them; every click runs the
	owner's onClick inside the normal container transaction, where it may count,
	remove and give items in the player rows of the same menu. A failing or
	erroring click restores the whole menu, payment included.
------------------------------------------------------------------------------]]

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV

local MENU_COLUMNS = 9
local PLAYER_SLOTS = 36
local TITLE_BYTES = 128

local CLICK_NAMES = {
	pickup = { [0] = "left", [1] = "right" },
	quick_move = { [0] = "shift" },
	throw = { [0] = "drop", [1] = "drop" },
}

local function newSessionToken( ply, record )
	local seed = table.concat( {
		tostring( record.ownerId or ply:EntIndex() ), tostring( SysTime() ),
		tostring( math.random() ), tostring( record.container.revision ), "menu",
	}, ":" )
	return util.SHA256 and util.SHA256( seed ) or util.CRC( seed )
end

local function normalizedTitle( value )
	return string.sub( tostring( value or "" ), 1, TITLE_BYTES )
end

-- Player rows are walked hotbar first, as Inventory#add places new stacks.
local function playerIndices( offset )
	local indices = {}
	for index = 0, PLAYER_SLOTS - 1 do indices[#indices + 1] = offset + index end
	return indices
end

local ClickContext = {}
ClickContext.__index = ClickContext

function ClickContext:Count( item )
	local total = 0
	for _, index in ipairs( self.playerSlots ) do
		local stack = MC.ContainerGetStack( self.container, index )
		if stack and stack.item == item then total = total + stack.count end
	end
	return total
end

-- All or nothing: returns false without touching any slot when short.
function ClickContext:Remove( item, count )
	count = math.floor( tonumber( count ) or 0 )
	if count <= 0 then return true end
	if self:Count( item ) < count then return false end
	for _, index in ipairs( self.playerSlots ) do
		local stack = MC.ContainerGetStack( self.container, index )
		if stack and stack.item == item then
			local take = math.min( stack.count, count )
			MC.ContainerSetStack( self.container, index,
				stack.count > take and MC.CopyItemStack( stack, stack.count - take ) or nil )
			count = count - take
			if count <= 0 then break end
		end
	end
	return true
end

-- Merges into matching stacks first, then fills empty slots. Returns the
-- remainder that did not fit (nil when everything fit).
function ClickContext:Give( input )
	local stack, err = MC.NormalizeItemStack( input )
	if not stack then return nil, err end
	local remaining = stack
	for pass = 1, 2 do
		for _, index in ipairs( self.playerSlots ) do
			if not remaining then return nil end
			local slot = MC.ContainerGetSlot( self.container, index )
			local existing = MC.InventorySlotGet( slot )
			if pass == 1 and existing and MC.ItemStacksCanMerge( existing, remaining )
			or pass == 2 and not existing then
				remaining = MC.InventorySlotInsert( slot, remaining, remaining.count, self.context )
			end
		end
	end
	return remaining
end

function ClickContext:SetSlot( index, stack )
	return self.menu:SetSlotInTransaction( index, stack )
end

function ClickContext:GetSlot( index )
	return MC.CopyItemStack( MC.ContainerGetStack( self.container, index ) )
end

-- Runs on the next tick, after this click committed and its delta was sent.
-- Use it for side effects outside the menu (equipment, world, chat).
function ClickContext:After( callback )
	if isfunction( callback ) then self.after[#self.after + 1] = callback end
end

function ClickContext:Close()
	self.closeRequested = true
end

local Menu = {}
Menu.__index = Menu

function Menu:IsOpen()
	local record = self.record
	return IsValid( self.player ) and record.session ~= nil and record.session.container == self.container
end

function Menu:SetSlotInTransaction( index, stack )
	index = math.floor( tonumber( index ) or -1 )
	if index < 0 or index >= self.size then return false, "invalid_menu_slot" end
	local normalized, err = MC.NormalizeItemStack( stack )
	if stack ~= nil and not normalized then return false, err end
	self.storage[index + 1] = normalized
	return true
end

-- Outside a click: change display slots and publish them immediately.
function Menu:SetSlots( slots )
	if not self:IsOpen() then return false, "menu_closed" end
	local changed = {}
	for index, stack in pairs( slots ) do
		local before = self.storage[index + 1]
		local ok, err = self:SetSlotInTransaction( index, stack )
		if not ok then return false, err end
		if not MC.ItemStacksEqual( before, self.storage[index + 1] ) then changed[#changed + 1] = index end
	end
	if #changed == 0 then return true end
	self.container.revision = math.max( self.container.revision, self.record.container.revision ) + 1
	SV.PublishActiveInventoryCommit( self.record, { changedSlots = changed, revision = self.container.revision }, {} )
	return true
end

function Menu:SetSlot( index, stack )
	return self:SetSlots( { [index] = stack } )
end

function Menu:Close( reason )
	if not self:IsOpen() then return false end
	return SV.ClosePlayerInventory( self.player, reason or "menu_closed" )
end

local function runClick( menu, slotIndex, button, context, mode )
	local click = CLICK_NAMES[mode] and CLICK_NAMES[mode][button] or "left"
	local ctx = setmetatable( {
		player = menu.player, menu = menu, container = menu.container, context = context,
		playerSlots = menu.playerSlots, after = {}, closeRequested = false,
	}, ClickContext )
	local called, accepted, err = pcall( menu.onClick, ctx, slotIndex, click )
	if not called then
		MC.Fault( "virtual_menu_click_error", "%s: %s", menu.id, tostring( accepted ) )
		return false, "menu_click_error"
	end
	if accepted == false then return false, err or "menu_click_rejected" end
	if #ctx.after > 0 or ctx.closeRequested then
		timer.Simple( 0, function()
			for _, callback in ipairs( ctx.after ) do
				local ok, callbackError = pcall( callback, menu.player, menu )
				if not ok then MC.Fault( "virtual_menu_after_error", "%s: %s", menu.id, tostring( callbackError ) ) end
			end
			if ctx.closeRequested then menu:Close( "menu_closed" ) end
		end )
	end
	return true
end

-- definition: { id, title, rows 1..6, slots = { [0..rows*9-1] = stack },
--               onClick( ctx, slotIndex, click ) -> false[, err] to roll back,
--               onClose( ply, reason ), validate( ply ) -> boolean }
function SV.OpenVirtualMenu( ply, definition )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return nil, "invalid_player" end
	if type( definition ) ~= "table" then return nil, "invalid_menu" end
	local id = tostring( definition.id or "" )
	if id == "" or #id > 96 then return nil, "invalid_menu_id" end
	local rows = math.floor( tonumber( definition.rows ) or 3 )
	if rows < 1 or rows > 6 then return nil, "invalid_menu_rows" end
	if not isfunction( definition.onClick ) then return nil, "invalid_menu_click" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply ) or nil
	if not record then return nil, "inventory_not_loaded" end

	local size = rows * MENU_COLUMNS
	local storage = {}
	for index, stack in pairs( definition.slots or {} ) do
		index = tonumber( index )
		if not index or index < 0 or index >= size or index ~= math.floor( index ) then return nil, "invalid_menu_slot" end
		local normalized, err = MC.NormalizeItemStack( stack )
		if stack ~= nil and not normalized then return nil, err end
		storage[index + 1] = normalized
	end

	if record.session and SV.ClosePlayerInventory then SV.ClosePlayerInventory( ply, "switch" ) end
	local slots = {}
	for index = 0, size - 1 do
		slots[#slots + 1] = {
			index = index, storage = storage, storageIndex = index + 1, group = "menu_display",
			readOnly = true, meta = { role = "result" },
		}
	end
	for index = 0, PLAYER_SLOTS - 1 do
		slots[#slots + 1] = {
			index = size + index, storage = record.storage, storageIndex = index + 1,
			group = index < 9 and "hotbar" or "main",
		}
	end
	local hotbar = {}
	for button = 0, 8 do hotbar[button + 1] = size + button end
	local container, err = MC.NewInventoryContainer( {
		id = record.nextContainerId or 2,
		kind = "menu",
		revision = record.container.revision,
		slots = slots,
		hotbarSlots = hotbar,
		transferRules = {
			main = { targets = { "hotbar" } },
			hotbar = { targets = { "main" } },
		},
	} )
	if not container then return nil, err end
	record.nextContainerId = ( container.id + 1 ) % 65535
	if record.nextContainerId == 0 or record.nextContainerId == 1 then record.nextContainerId = 2 end

	local menu = setmetatable( {
		id = id, player = ply, record = record, container = container, storage = storage,
		size = size, playerSlots = playerIndices( size ), onClick = definition.onClick,
	}, Menu )
	container.context = { player = ply, menu = true }
	container.takeResult = function( _, slotIndex, button, _, context, mode )
		return runClick( menu, slotIndex, button, context, mode )
	end
	container.onCommit = function( _, result, context )
		for _, index in ipairs( result.changedSlots or {} ) do
			if index >= size then
				record.container.revision = record.container.revision + 1
				record.revision = record.container.revision
				record.dirty = true
				if SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( record ) end
				break
			end
		end
		SV.PublishActiveInventoryCommit( record, result, context or {} )
	end

	container.cursor = MC.CopyItemStack( record.carried )
	record.carried = nil
	local validate, onClose = definition.validate, definition.onClose
	record.session = {
		token = newSessionToken( ply, record ),
		kind = "menu",
		title = normalizedTitle( definition.title ),
		container = container,
		creative = false,
		openedAt = CurTime(),
		lastActionId = nil,
		playerOffset = size,
		chestSlots = size,
		validate = function()
			if not IsValid( ply ) or not ply:Alive() then return false end
			if not isfunction( validate ) then return true end
			local ok, valid = pcall( validate, ply )
			return ok and valid ~= false
		end,
		onClose = function( _, _, reason )
			if isfunction( onClose ) then onClose( ply, reason ) end
		end,
	}
	if not SV.SendActiveInventoryOpen( ply, record, "menu" ) then
		record.session = nil
		return nil, "menu_open_failed"
	end
	return menu
end
