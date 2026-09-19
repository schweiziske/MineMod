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

-- Slot clicks use the shared predicted brewing slot rules in cl_network.lua.
