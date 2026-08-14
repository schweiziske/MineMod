-- Shared TNT block identification. Server behavior is installed by
-- inventory/sv_tnt.lua after the inventory transaction helpers are available.

MC = MC or {}

function MC.IsTntState( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and schema.name == "minecraft:tnt" or false
end

function MC.IsTntBlockId( blockId )
	local block = MC.Blocks and MC.Blocks[tonumber( blockId ) or -1] or nil
	return block and block.mcid == "minecraft:tnt" or false
end
