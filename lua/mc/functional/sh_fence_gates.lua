--[[----------------------------------------------------------------------------
	MC functional block: fence gates.

	Fence gates use the complete block-state registry. Using one toggles only its
	open property, preserving facing, in_wall, powered, and future properties.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.BlockHandlers = MC.BlockHandlers or {}

MC.BlockHandlers.fence_gate = MC.BlockHandlers.fence_gate or {
	OnUse = function( ply, bx, by, bz )
		if not SERVER or not MC.SV or not MC.SV.SetBlockState then return false end

		local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or nil
		local schema = stateId and MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
		local block = schema and MC.Blocks and MC.Blocks[schema.blockId] or nil
		if not block or block.connection ~= "fence_gate" then return false end

		local open = MC.GetStateProperty and MC.GetStateProperty( stateId, "open" )
		if open == nil then return false end
		local nextState = MC.StateWith and MC.StateWith( stateId, "open", open ~= true ) or nil
		if not nextState or nextState == stateId then return false end

		local result = MC.SV.SetBlockState( bx, by, bz, nextState, {
			actor = ply,
			fx = false,
			handlers = false,
			priorityPhys = true,
			immediatePhys = true,
		} )
		local changed = result and result.ok == true and ( result.changed or 0 ) > 0
		if changed and MC.PlayDoorToggleSound then
			MC.PlayDoorToggleSound( schema.blockId, open ~= true, bx, by, bz )
		end
		return changed
	end,
}
