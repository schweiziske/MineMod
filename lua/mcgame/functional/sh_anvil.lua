-- Shared anvil interaction binding. The transient inventory transaction and
-- rename transport live in sv_anvil.lua/cl_anvil.lua.

MC = MC or {}
MC.BlockHandlers = MC.BlockHandlers or {}

local ANVIL_BLOCKS = {
	anvil = true,
	chipped_anvil = true,
	damaged_anvil = true,
}

MC.BlockHandlers.anvil = MC.BlockHandlers.anvil or {
	OnUse = function( ply, bx, by, bz )
		if not SERVER or not MC.SV or not MC.SV.OpenAnvil then return false end
		return MC.SV.OpenAnvil( ply, bx, by, bz ) == true
	end,
}

for _, block in pairs( MC.Blocks or {} ) do
	if ANVIL_BLOCKS[block.name] then
		block.handlers = MC.BlockHandlers.anvil
		block.handlerName = "anvil"
	end
end

function MC.IsAnvilBlock( id )
	local block = MC.Blocks and MC.Blocks[tonumber( id )]
	return block and ANVIL_BLOCKS[block.name] == true or false
end
