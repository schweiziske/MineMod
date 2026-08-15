-- Shared chest block handler binding.  The authoritative menu lives in the
-- server module; this file only attaches the lifecycle/use callbacks to every
-- generated chest block after the block catalog has been registered.

MC = MC or {}
MC.BlockHandlers = MC.BlockHandlers or {}

local CHEST_BLOCK_NAMES = {
	chest = true,
	trapped_chest = true,
	copper_chest = true,
	exposed_copper_chest = true,
	weathered_copper_chest = true,
	oxidized_copper_chest = true,
	waxed_copper_chest = true,
	waxed_exposed_copper_chest = true,
	waxed_weathered_copper_chest = true,
	waxed_oxidized_copper_chest = true,
}

local function dropContents( context )
	if not SERVER or not context or not context.oldBlockEntity then return end
	if MC.SV and MC.SV.DropChestContents then
		MC.SV.DropChestContents( context.actor, context.bx, context.by, context.bz, context.oldBlockEntity )
	end
end

MC.BlockHandlers.chest = MC.BlockHandlers.chest or {
	OnUse = function( ply, bx, by, bz )
		if not SERVER or not MC.SV or not MC.SV.OpenChest then return false end
		return MC.SV.OpenChest( ply, bx, by, bz ) == true
	end,
	OnRemoved = dropContents,
	OnReplaced = function( context ) dropContents( context ) end,
}

for _, block in pairs( MC.Blocks or {} ) do
	if CHEST_BLOCK_NAMES[block.name] then
		block.handlers = MC.BlockHandlers.chest
		block.handlerName = "chest"
	end
end

function MC.IsChestBlock( id )
	local block = MC.Blocks and MC.Blocks[id]
	return block and CHEST_BLOCK_NAMES[block.name] == true or false
end
