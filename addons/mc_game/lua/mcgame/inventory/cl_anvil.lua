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
	local canTake = net.ReadBool()
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
		canTake = canTake,
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

-- cl_network predicts ordinary input slots and stops replay at a result take;
-- experience spending and the anvil result remain server transactions.
