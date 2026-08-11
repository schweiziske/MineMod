MC = MC or {}

net.Receive( "mc_furnace_state", function()
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local lit = net.ReadBool()
	local litTimeRemaining = net.ReadUInt( 16 )
	local litTotalTime = net.ReadUInt( 16 )
	local cookingTimeSpent = net.ReadUInt( 16 )
	local cookingTotalTime = net.ReadUInt( 16 )
	local state = MC.ClientInventory
	local session = state and state.session
	if not session or session.containerId ~= containerId or session.token ~= token then return end
	session.furnaceState = {
		lit = lit,
		litTimeRemaining = litTimeRemaining,
		litTotalTime = litTotalTime,
		cookingTimeSpent = cookingTimeSpent,
		cookingTotalTime = cookingTotalTime,
		receivedAt = RealTime(),
	}
	if hook and hook.Run then hook.Run( "MCFurnaceStateChanged", session.furnaceState, state ) end
end )
