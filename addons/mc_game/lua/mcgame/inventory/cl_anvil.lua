-- Client anvil state/rename transport. Inventory clicks stay on the ordinary
-- ordered action channel; this module never sends an ItemStack result.

MC = MC or {}

local function emit( eventName, ... )
	if hook and hook.Run then hook.Run( eventName, ... ) end
end

net.Receive( "mc_anvil_state", function()
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local renameText = net.ReadString()
	local renameExplicit = net.ReadBool()
	local cost = net.ReadUInt( 32 )
	local resultAvailable = net.ReadBool()
	local tooExpensive = net.ReadBool()
	local errorCode = net.ReadString()
	local state = MC.ClientInventory
	local session = state and state.session
	if not session or session.kind ~= "anvil" or session.containerId ~= containerId or session.token ~= token then return end
	session.anvilState = {
		renameText = renameText,
		renameExplicit = renameExplicit,
		cost = cost,
		resultAvailable = resultAvailable,
		tooExpensive = tooExpensive,
		error = errorCode ~= "" and errorCode or nil,
		receivedAt = RealTime(),
	}
	emit( "MCAnvilStateChanged", session.anvilState, state )
end )

function MC.RequestAnvilRename( value )
	local state = MC.ClientInventory
	local session = state and state.session
	if not session or session.kind ~= "anvil" then return false, "anvil_not_open" end
	local filtered, err = MC.AnvilValidateName( value )
	if not filtered then return false, err or "invalid_name" end
	if #filtered > 256 then return false, "name_payload_too_large" end
	net.Start( "mc_anvil_rename" )
		net.WriteUInt( session.containerId, 16 )
		net.WriteString( session.token )
		net.WriteString( filtered )
	net.SendToServer()
	return true
end

-- Anvil output is a server-only calculation. Restore the authoritative mirror
-- while keeping the ordered action queue intact; pumpActions in cl_network.lua
-- still sends every click, but no pending anvil result transaction is replayed.
local rebuildPrediction = MC.RebuildClientPrediction
function MC.RebuildClientPrediction( silent )
	local state = MC.ClientInventory
	local session = state and state.session
	if not session or session.kind ~= "anvil" then
		return rebuildPrediction and rebuildPrediction( silent ) == true or false
	end
	local authoritative, menu = state.authoritative, state.menu
	if not authoritative or not menu then return false end
	for index = 1, menu.slotCount do menu.slots[index] = MC.CopyItemStack( authoritative.menuSlots[index] ) end
	state.slots = {}
	for index = 1, 36 do state.slots[index] = MC.CopyItemStack( authoritative.playerSlots[index] ) end
	state.equipment = {}
	for slot, stack in pairs( authoritative.equipment or {} ) do state.equipment[slot] = MC.CopyItemStack( stack ) end
	state.revision, state.selected = authoritative.revision, authoritative.selected
	state.cursor = MC.CopyItemStack( authoritative.cursor )
	state.predictedContainer = nil
	state.predictedRevision = authoritative.revision
	if not silent then
		emit( "MC.InventoryMenuChanged", nil, state.revision, state )
		emit( "MC.InventoryChanged", nil, state.revision, state )
		emit( "MC.EquipmentChanged", nil, state.revision, state )
		emit( "MC.InventoryCursorChanged", state.cursor, state )
	end
	return true
end
