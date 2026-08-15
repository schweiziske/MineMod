-- Shared crafting-table interaction binding.  The menu itself is server-only;
-- this handler keeps block use consistent with the other functional blocks.

MC = MC or {}

local Blocks = MC.API and MC.API.Blocks

local HANDLERS = {
	OnUse = function( ply, bx, by, bz )
		if not SERVER or not MC.SV or not MC.SV.OpenCraftingTable then return false end
		return MC.SV.OpenCraftingTable( ply, bx, by, bz ) == true
	end,
}

if Blocks then Blocks.SetHandlers( "minecraft:crafting_table", HANDLERS ) end

function MC.IsCraftingTableBlock( id )
	local block = Blocks and Blocks.Resolve( id ) or nil
	return block and ( block.mcid == "minecraft:crafting_table" or block.name == "crafting_table" ) or false
end
