-- Feature switches for source-verified gameplay parity work.
--
-- Every checkpoint ships dark by default.  Tests opt in through container
-- options/context, while a server owner may enable the replicated switch for
-- live verification without editing code.

MC = MC or {}
MC.GameplayParity = MC.GameplayParity or {}

local Parity = MC.GameplayParity

if CreateConVar then
	local flags = FCVAR_ARCHIVE or 0
	if SERVER then flags = bit and bit.bor and bit.bor( flags, FCVAR_REPLICATED or 0, FCVAR_NOTIFY or 0 ) or flags end
	Parity.InventoryClicks = GetConVar and GetConVar( "mc_gameplay_parity_inventory_clicks" )
		or CreateConVar( "mc_gameplay_parity_inventory_clicks", "0", flags,
			"Enable source-verified AbstractContainerMenu/Screen click parity." )
end

function MC.GameplayParityInventoryClicksEnabled()
	local switch = Parity.InventoryClicks
	return switch and switch.GetBool and switch:GetBool() == true or false
end

