--[[----------------------------------------------------------------------------
	mc_placer : SWEP front-end. Runs server-side with the owner, so it talks to
	MC.SV directly (no extra net layer). Left = break, Right = place, R = palette.
------------------------------------------------------------------------------]]

if SERVER then AddCSLuaFile() end

SWEP.PrintName    = "MC 方块放置器"
SWEP.Author       = "MC"
SWEP.Purpose      = "放置 / 破坏 Minecraft 方块（用 IMesh 渲染，不生成实体）"
SWEP.Instructions = "左键破坏  右键放置  R 选择方块"
SWEP.Category     = "MC"

SWEP.Spawnable    = true
SWEP.AdminOnly    = false
SWEP.Slot         = 1
SWEP.SlotPos      = 5
SWEP.DrawAmmo     = false
SWEP.DrawCrosshair = true

SWEP.Base         = "weapon_base"
SWEP.ViewModel    = "models/weapons/c_toolgun.mdl"
SWEP.WorldModel   = "models/weapons/w_toolgun.mdl"
SWEP.UseHands     = true

SWEP.Primary   = { ClipSize = -1, DefaultClip = -1, Automatic = true,  Ammo = "none" }
SWEP.Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = true,  Ammo = "none" }

local STEP = 0.13

local function selectedID( ply )
	local id = IsValid( ply ) and ply:GetNWInt( "mc_block", 1 ) or 1
	if not MC.IsValidBlock( id ) then id = 1 end
	return id
end

local function placeCell( tr )
	return MC.WorldToCell( tr.HitPos + tr.HitNormal * 0.5 )
end
local function breakCell( tr )
	return MC.WorldToCell( tr.HitPos - tr.HitNormal * 0.5 )
end

function SWEP:Initialize()
	self:SetHoldType( "pistol" )
end

function SWEP:Deploy()
	self:SetHoldType( "pistol" )
	return true
end

function SWEP:PrimaryAttack()  -- LEFT = break
	self:SetNextPrimaryFire( CurTime() + STEP )
	local owner = self:GetOwner()
	if not IsValid( owner ) then return end
	local tr = owner:GetEyeTrace()
	if not tr.Hit then return end

	if SERVER then
		local bx, by, bz = breakCell( tr )
		if MC.SV.Break( owner, bx, by, bz ) then
			self:EmitSound( "buttons/button15.wav", 60, 120, 0.25 )
		end
	end
end

function SWEP:SecondaryAttack()  -- RIGHT = place
	self:SetNextSecondaryFire( CurTime() + STEP )
	local owner = self:GetOwner()
	if not IsValid( owner ) then return end
	local tr = owner:GetEyeTrace()
	if not tr.Hit then return end

	if SERVER then
		local bx, by, bz = placeCell( tr )
		if MC.SV.Place( owner, bx, by, bz, selectedID( owner ) ) then
			self:EmitSound( "buttons/button14.wav", 60, 150, 0.25 )
		end
	end
end

function SWEP:Reload()
	if CLIENT then
		if IsValid( MC.PaletteFrame ) and MC.PaletteFrame:IsVisible() then return end
		MC.OpenPalette( function( id )
			RunConsoleCommand( "mc_block_sel", id )
		end )
	end
end

if CLIENT then
	function SWEP:DrawHUD()
		local ply = LocalPlayer()
		local id = selectedID( ply )
		local b = MC.Blocks[id]
		if not b then return end

		local sw, sh = ScrW(), ScrH()
		local w, h = 64, 64
		local x, y = sw * 0.5 - w * 0.5, sh - 132

		draw.RoundedBox( 6, x - 8, y - 8, w + 16, h + 40, Color( 0, 0, 0, 160 ) )
		MC.DrawBlockIcon( id, x, y, w, h )
		draw.SimpleText( b.disp, "mc_hud", x + w * 0.5, y + h + 12, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP )
		draw.SimpleText( "左键破坏   右键放置   R 选择方块", "mc_hud_small", sw * 0.5, sh - 20, Color( 255, 255, 255, 190 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )

		-- crosshair dot
		surface.SetDrawColor( 255, 255, 255, 220 )
		surface.DrawRect( sw * 0.5 - 1, sh * 0.5 - 1, 2, 2 )
	end

	-- placement ghost outline
	hook.Add( "PostDrawTranslucentRenderables", "mc_ghost", function( _, bSky, bSky3D )
		if bSky or bSky3D then return end
		local ply = LocalPlayer()
		if not IsValid( ply ) or not ply:Alive() then return end
		local wep = ply:GetActiveWeapon()
		if not IsValid( wep ) or wep:GetClass() ~= "mc_placer" then return end

		local tr = ply:GetEyeTrace()
		if not tr.Hit then return end

		local bx, by, bz = placeCell( tr )
		local mn = MC.CellWorldMin( bx, by, bz )
		render.DrawWireframeBox( mn, angle_zero, vector_origin, Vector( MC.BS, MC.BS, MC.BS ), Color( 255, 255, 255, 230 ), true )
	end )
end