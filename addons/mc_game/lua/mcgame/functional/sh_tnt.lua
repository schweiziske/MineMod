-- Shared TNT block identification. Server behavior is installed by
-- inventory/sv_tnt.lua after the inventory transaction helpers are available.

MC = MC or {}

local Blocks = MC.API and MC.API.Blocks

function MC.IsTntState( stateId )
	local name = Blocks and Blocks.Name( stateId ) or nil
	return name == "minecraft:tnt"
end

function MC.IsTntBlockId( blockId )
	local block = Blocks and Blocks.Resolve( tonumber( blockId ) or -1 ) or nil
	return block and block.mcid == "minecraft:tnt" or false
end
