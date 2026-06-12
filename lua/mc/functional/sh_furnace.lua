--[[----------------------------------------------------------------------------
	MC functional block: furnace placeholder interaction.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.BlockHandlers = MC.BlockHandlers or {}

MC.BlockHandlers.furnace = MC.BlockHandlers.furnace or {
	OnUse = function( ply )
		if IsValid( ply ) then
			ply:ChatPrint( "[MC] 熔炉界面还没接物品系统，先占位。" )
		end
		return true
	end,
}
