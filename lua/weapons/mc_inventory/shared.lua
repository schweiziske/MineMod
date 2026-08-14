--[[----------------------------------------------------------------------------
    Independent Minecraft inventory SWEP.

    mc_item_hand remains responsible for world break/place interaction.  This
    SWEP only owns the inventory entry point and its lifecycle, so changing
    tools cannot accidentally leave a stale inventory session or drag state.
------------------------------------------------------------------------------]]

if SERVER then AddCSLuaFile() end

SWEP.PrintName = "Minecraft Inventory"
SWEP.Author = "schweiziske"
SWEP.Purpose = "Open the Minecraft inventory and crafting screens"
SWEP.Instructions = "Reload opens or closes the Minecraft inventory"
SWEP.Category = "Minecraft"
SWEP.Spawnable = true
SWEP.AdminOnly = false
SWEP.Slot = 0
SWEP.SlotPos = 5
SWEP.DrawAmmo = false
SWEP.DrawCrosshair = false
SWEP.UseHands = false
SWEP.ViewModel = ""
SWEP.WorldModel = ""
SWEP.DrawViewModel = false
SWEP.DrawWorldModel = false
SWEP.Primary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }
SWEP.Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }

local TOGGLE_COOLDOWN = 0.25

function SWEP:Initialize()
	self:SetHoldType( "normal" )
	self.MCNextToggle = 0
end

function SWEP:Deploy()
	self:SetHoldType( "normal" )
	return true
end

function SWEP:ToggleInventoryClient()
	if not CLIENT then return false end
	local now = RealTime()
	if now < ( self.MCNextToggle or 0 ) then return false end
	self.MCNextToggle = now + TOGGLE_COOLDOWN
	return MC.InventoryUI and MC.InventoryUI.ToggleFromWeapon
		and MC.InventoryUI.ToggleFromWeapon( self ) == true
end

function SWEP:Reload()
	if SERVER then
		if game.SinglePlayer() then self:CallOnClient( "ToggleInventoryClient" ) end
		return true
	end
	self:ToggleInventoryClient()
	return true
end

function SWEP:PrimaryAttack()
	self:SetNextPrimaryFire( CurTime() + 0.2 )
end

function SWEP:SecondaryAttack()
	self:SetNextSecondaryFire( CurTime() + 0.2 )
	local owner = self:GetOwner()
	if IsValid( owner ) and MC and MC.TryInteractMinecraftVehicle then
		MC.TryInteractMinecraftVehicle( owner )
	end
end

function SWEP:Holster()
	if CLIENT and MC.InventoryUI and MC.InventoryUI.CloseFromWeapon then
		MC.InventoryUI.CloseFromWeapon( "holster" )
	end
	return true
end

function SWEP:OnRemove()
	if CLIENT and MC.InventoryUI and MC.InventoryUI.CloseFromWeapon then
		MC.InventoryUI.CloseFromWeapon( "weapon_removed" )
	end
end

function SWEP:Think()
	if CLIENT then
		local owner = self:GetOwner()
		if not IsValid( owner ) or not owner:Alive() then
			if MC.InventoryUI and MC.InventoryUI.CloseFromWeapon then MC.InventoryUI.CloseFromWeapon( "owner_invalid" ) end
		end
	end
	end
