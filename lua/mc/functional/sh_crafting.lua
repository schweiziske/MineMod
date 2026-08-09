-- Shared crafting-table interaction binding.  The menu itself is server-only;
-- this handler keeps block use consistent with the other functional blocks.

MC = MC or {}
MC.BlockHandlers = MC.BlockHandlers or {}

MC.BlockHandlers.crafting_table = MC.BlockHandlers.crafting_table or {
	OnUse = function( ply, bx, by, bz )
		if not SERVER or not MC.SV or not MC.SV.OpenCraftingTable then return false end
		return MC.SV.OpenCraftingTable( ply, bx, by, bz ) == true
	end,
}

for _, block in pairs( MC.Blocks or {} ) do
	if block.mcid == "minecraft:crafting_table" or block.name == "crafting_table" then
		block.handlers = MC.BlockHandlers.crafting_table
		block.handlerName = "crafting_table"
	end
end

function MC.IsCraftingTableBlock( id )
	local block = MC.Blocks and MC.Blocks[id]
	return block and ( block.mcid == "minecraft:crafting_table" or block.name == "crafting_table" ) or false
end
