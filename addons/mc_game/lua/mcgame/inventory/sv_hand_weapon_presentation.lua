-- Game-layer presentation adapter for selected-item proxy SWEPs.

if not SERVER then return end

MC = MC or {}
local API = MC.API
local HandWeapon = API and API.HandWeapon
if not HandWeapon or not HandWeapon.RegisterPresentationProvider then return end

local function applyWeaponPresentation( weapon, stack )
	if not IsValid( weapon ) or not weapon.SetNW2Bool then return false end
	weapon:SetNW2Bool(
		"MCITEM_ItemFoil",
		stack and MC.ItemStackHasFoil and MC.ItemStackHasFoil( stack ) == true or false
	)
	return true
end

HandWeapon.RegisterPresentationProvider(
	"mc.game.item_foil",
	applyWeaponPresentation,
	100
)
