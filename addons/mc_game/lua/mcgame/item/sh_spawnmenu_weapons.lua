-- One stable item identity carries a server-approved weapon class. Installed
-- SWEPs are discovered after bootstrap; they must not change runtime item ids.
MC.SpawnmenuWeapons = MC.SpawnmenuWeapons or { records = {}, stacks = {}, revision = 0 }
local W = MC.SpawnmenuWeapons
local ITEM = "mcswep:gmod_weapon"
local TAB = "mcswep:gmod_weapons"
local COMPONENT = "mcswep:weapon_class"
local NET = "mc_spawnmenu_weapons"
local Hand = MC.API.HandWeapon

local ok, err = MC.API.Items.Register( {
	id = ITEM, maxStack = 1, -- named by item.mcswep.gmod_weapon
	source = "mc.game", texture = "gui/gmod_logo.vmt",
} )
MC.Check( ok, "gmod_weapon_item_registration", "%s", tostring( err ) )
ok, err = MC.API.Creative.RegisterCategory( {
	id = TAB, icon = ITEM,
	background = "items", showTitle = true, canScroll = true,
} )
MC.Check( ok, "gmod_weapon_tab_registration", "%s", tostring( err ) )

function W.Class( stack )
	if type( stack ) ~= "table" or stack.item ~= ITEM then return nil end
	local components = stack.components
	local class = components and components[COMPONENT]
	return type( class ) == "string" and class or nil
end

function W.Record( stack )
	local class = W.Class( stack )
	return class and W.records[class] or nil
end

local function eligible( class, definition )
	return type( class ) == "string" and #class <= 128 and class:match( "^[%w_%.%-]+$" )
		and type( definition ) == "table" and definition.Spawnable == true
		and class ~= "mc_item_hand" and class ~= "mc_creative_placer" and class ~= "mc_inventory"
		-- MCITEM weapons are represented by their Minecraft items in the catalog.
		and string.sub( class, 1, 14 ) ~= "weapon_mcitem_" and class ~= "weapon_bmb_item_model_test"
end

function W.CanEquip( ply, class )
	local definition = list.Get( "Weapon" )[class]
	if not eligible( class, definition ) then return false, "weapon_not_spawnable" end
	if definition.AdminOnly and not ( ply:IsAdmin() or game.SinglePlayer() ) then
		return false, "weapon_admin_only"
	end
	if SERVER and gamemode.Call( "PlayerGiveSWEP", ply, class, definition ) ~= true then
		return false, "weapon_give_denied"
	end
	return true
end

local deniedAt = setmetatable( {}, { __mode = "k" } )
local function acquire( ply, class )
	local allowed, reason = W.CanEquip( ply, class )
	if not allowed then
		local now = CurTime()
		if now >= ( deniedAt[ply] or 0 ) then
			deniedAt[ply] = now + 1
			MC.Messages.Notify( ply, "inventory.weapon_equip_failed", { class = class, code = reason } )
		end
		return nil, reason
	end
	local weapon = ply:GetWeapon( class )
	if IsValid( weapon ) then return weapon end
	-- Match the Q menu: give initial ammo once, then retain the real weapon
	-- across hotbar switches so clips and addon-owned state are not reset.
	weapon = ply:Give( class )
	if not IsValid( weapon ) then
		MC.Fault( "spawnmenu_weapon_give", "Could not give %s", class )
		return nil, "weapon_give_failed"
	end
	return weapon
end

local function matches( stack )
	return W.Class( stack ) ~= nil
end

local function publish( records )
	local stacks, ordered = {}, {}
	for class in pairs( records ) do ordered[#ordered + 1] = class end
	table.sort( ordered, function( a, b )
		local left, right = records[a], records[b]
		if left.category ~= right.category then return left.category < right.category end
		return a < b
	end )
	for _, class in ipairs( ordered ) do
		stacks[#stacks + 1] = { item = ITEM, count = 1, components = { [COMPONENT] = class } }
		local registered, reason = Hand.RegisterWeaponAdapter( class, {
			acquire = acquire, matches = matches, retain = true, ownsFirstPerson = true,
		} )
		MC.Check( registered, "gmod_weapon_adapter", "%s: %s", class, tostring( reason ) )
	end
	W.records, W.stacks = records, stacks
	W.revision = W.revision + 1
	MC.RegisterCreativeStackProvider( "mc.game.spawnmenu_weapons", function( key, entries )
		if key == TAB or key == "search" then
			for _, stack in ipairs( W.stacks ) do
				entries[#entries + 1] = stack
			end
		end
		return entries
	end, 100 )
end

Hand.RegisterResolver( "mc.game.spawnmenu_weapons", function( stack )
	local class = W.Class( stack )
	if class and W.records[class] then return class end
end, 50 )

if SERVER then
	local nextRequest = setmetatable( {}, { __mode = "k" } )
	local sentRevision = setmetatable( {}, { __mode = "k" } )
	local function refresh()
		local records = {}
		local changed = false
		local count = 0
		for class, definition in pairs( list.Get( "Weapon" ) ) do
			if eligible( class, definition ) then
				records[class] = {
					class = class, title = tostring( definition.PrintName or class ):sub( 1, 256 ),
					category = tostring( definition.Category or "Other" ):sub( 1, 128 ),
					icon = tostring( definition.IconOverride or "entities/" .. class .. ".png" ):sub( 1, 240 ),
					adminOnly = definition.AdminOnly == true,
				}
				count = count + 1
				local old, new = W.records[class], records[class]
				if not old or old.title ~= new.title or old.category ~= new.category
				or old.icon ~= new.icon or old.adminOnly ~= new.adminOnly then changed = true end
			end
		end
		if changed or count ~= #W.stacks or W.revision == 0 then publish( records ) end
	end
	local function sendCatalog( ply, force )
		if not force and sentRevision[ply] == W.revision then return end
		sentRevision[ply] = W.revision
		local rows = W.stacks
		-- Small reliable pages keep even large addon collections below net's limit.
		local pageCount = math.max( 1, math.ceil( #rows / 32 ) )
		for page = 1, pageCount do
			local first, last = ( page - 1 ) * 32 + 1, math.min( page * 32, #rows )
			net.Start( NET )
				net.WriteUInt( W.revision, 32 )
				net.WriteUInt( page, 16 )
				net.WriteUInt( pageCount, 16 )
				net.WriteUInt( math.max( 0, last - first + 1 ), 6 )
				for index = first, last do
					local record = W.Record( rows[index] )
					net.WriteString( record.class )
					net.WriteString( record.title )
					net.WriteString( record.category )
					net.WriteString( record.icon )
					net.WriteBool( record.adminOnly )
				end
			net.Send( ply )
		end
	end
	net.Receive( NET, function( _, ply )
		local now = CurTime()
		if now < ( nextRequest[ply] or 0 ) then return end
		nextRequest[ply] = now + 2
		refresh()
		sendCatalog( ply )
	end )
	hook.Add( "InitPostEntity", "mc_spawnmenu_weapon_catalog", refresh )
	hook.Add( "OnReloaded", "mc_spawnmenu_weapon_catalog", function()
		refresh()
		for _, ply in ipairs( player.GetHumans() ) do sendCatalog( ply, true ) end
	end )
else
	local pending
	local receivedRevision
	net.Receive( NET, function()
		local revision, page, count = net.ReadUInt( 32 ), net.ReadUInt( 16 ), net.ReadUInt( 16 )
		local rows = net.ReadUInt( 6 )
		if page == 1 then pending = { revision = revision, page = 0, records = {} } end
		if not pending or pending.revision ~= revision or page ~= pending.page + 1 then return end
		for _ = 1, rows do
			local class, title, category, icon = net.ReadString(), net.ReadString(), net.ReadString(), net.ReadString()
			pending.records[class] = { class = class, title = title, category = category,
				icon = icon, adminOnly = net.ReadBool() }
		end
		pending.page = page
		if page == count then
			if receivedRevision ~= revision then publish( pending.records ) receivedRevision = revision end
			pending = nil
		end
	end )
	local function requestCatalog()
		if not IsValid( LocalPlayer() ) then return end
		net.Start( NET )
		net.SendToServer()
	end
	hook.Add( "InitPostEntity", "mc_spawnmenu_weapon_catalog", requestCatalog )
	hook.Add( "MC.InventoryOpened", "mc_spawnmenu_weapon_catalog", requestCatalog )
end
