-- Game-layer presentation adapter for selected-item proxy SWEPs.

if not SERVER then return end

MC = MC or {}
MC.HandWeaponBridge = MC.HandWeaponBridge or {}

function MC.HandWeaponBridge.ApplyWeaponPresentation( weapon, stack )
	if not IsValid( weapon ) or not weapon.SetNW2Bool then return false end
	weapon:SetNW2Bool(
		"MCITEM_ItemFoil",
		stack and MC.ItemStackHasFoil and MC.ItemStackHasFoil( stack ) == true or false
	)
	return true
end
