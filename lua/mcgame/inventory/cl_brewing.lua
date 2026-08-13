-- Brewing progress transport. Clicks use the ordinary ordered inventory channel.

MC = MC or {}

local function emit( eventName, ... )
	if hook and hook.Run then hook.Run( eventName, ... ) end
end

net.Receive( "mc_brewing_state", function()
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local brewTime = net.ReadUInt( 9 )
	local fuel = net.ReadUInt( 5 )
	local state = MC.ClientInventory
	local session = state and state.session
	if not session or session.kind ~= "brewing_stand"
	or session.containerId ~= containerId or session.token ~= token then return end
	session.brewingState = {
		brewTime = brewTime,
		fuel = fuel,
		receivedAt = RealTime(),
	}
	emit( "MCBrewingStateChanged", session.brewingState, state )
end )

-- The brewing stand has no client-created result slot. Keep every click queued
-- and displayed against the authoritative mirror until its server delta arrives.
local rebuildPrediction = MC.RebuildClientPrediction
function MC.RebuildClientPrediction( silent )
	local state = MC.ClientInventory
	local session = state and state.session
	if not session or session.kind ~= "brewing_stand" then
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
