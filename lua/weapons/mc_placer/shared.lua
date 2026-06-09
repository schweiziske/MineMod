--[[----------------------------------------------------------------------------
	mc_placer : SWEP front-end. Runs server-side with the owner, so it talks to
	MC.SV directly. Left = break, Right = place, R = palette.
------------------------------------------------------------------------------]]

if SERVER then AddCSLuaFile() end

SWEP.PrintName     = "MC 方块放置器"
SWEP.Author        = "MC"
SWEP.Purpose       = "放置 / 破坏 Minecraft 方块（IMesh 渲染，不生成实体）"
SWEP.Instructions  = "左键破坏  右键放置  Reload 选择方块"
SWEP.Category      = "MC"

SWEP.Spawnable     = true
SWEP.AdminOnly     = false
SWEP.Slot          = 1
SWEP.SlotPos       = 5
SWEP.DrawAmmo      = false
SWEP.DrawCrosshair = true

SWEP.Base          = "weapon_base"
SWEP.ViewModel     = "models/weapons/c_toolgun.mdl"
SWEP.WorldModel    = "models/weapons/w_toolgun.mdl"
SWEP.UseHands      = true

SWEP.Primary   = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" }
SWEP.Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" }

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

local function aimedBlock( ply )
	return MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
end

function SWEP:Initialize()
	self:SetHoldType( "pistol" )
end

function SWEP:Deploy()
	self:SetHoldType( "pistol" )
	return true
end

function SWEP:PrimaryAttack()
	self:SetNextPrimaryFire( CurTime() + STEP )
	local owner = self:GetOwner()
	if not IsValid( owner ) then return end
	local aim = aimedBlock( owner )

	if SERVER then
		local bx, by, bz
		if aim then
			bx, by, bz = aim.bx, aim.by, aim.bz
		else
			local tr = owner:GetEyeTrace()
			if not tr.Hit then return end
			bx, by, bz = breakCell( tr )
		end
		if MC.SV.Break( owner, bx, by, bz ) then
			self:EmitSound( "buttons/button15.wav", 60, 120, 0.25 )
		end
	end
end

function SWEP:SecondaryAttack()
	self:SetNextSecondaryFire( CurTime() + STEP )
	local owner = self:GetOwner()
	if not IsValid( owner ) then return end
	local aim = aimedBlock( owner )

	if SERVER then
		local tr = aim or owner:GetEyeTrace()
		if not tr.Hit then return end
		local ux, uy, uz
		if aim then
			ux, uy, uz = aim.bx, aim.by, aim.bz
		else
			ux, uy, uz = breakCell( tr )
		end
		if MC.SV.Use( owner, ux, uy, uz ) then return end

		local bx, by, bz
		if aim then
			bx = aim.bx + math.Round( aim.HitNormal.x )
			by = aim.by + math.Round( aim.HitNormal.y )
			bz = aim.bz + math.Round( aim.HitNormal.z )
		else
			bx, by, bz = placeCell( tr )
		end
		local id = selectedID( owner )
		local orient = MC.OrientForPlacement( owner, tr, id )
		if MC.SV.Place( owner, bx, by, bz, id, orient ) then
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
		local tr = aimedBlock( ply ) or ply:GetEyeTrace()
		local orient = tr.Hit and MC.OrientForPlacement( ply, tr, id ) or MC.DefaultOrient( id )
		local state = MC.BlockStateText( id, orient )
		local w, h = 64, 64
		local panelW = 320
		local panelH = state ~= "" and 118 or 96
		local px = sw * 0.5 - panelW * 0.5
		local py = sh - panelH - 44
		local x, y = px + 18, py + ( panelH - h ) * 0.5
		local tx = x + w + 18
		local maxTextW = panelW - ( tx - px ) - 18

		draw.RoundedBox( 6, px, py, panelW, panelH, Color( 0, 0, 0, 175 ) )
		MC.DrawBlockIcon( id, x, y, w, h )
		MC.DrawFittedText( b.disp, "mc_hud_big", { "mc_hud_fit_24", "mc_hud_fit_20", "mc_hud_fit_16" }, tx, py + 22, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, maxTextW )
		if state ~= "" then
			draw.SimpleText( state, "mc_hud_small", tx, py + 58, Color( 210, 230, 255 ), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
		end
		draw.SimpleText( "左键破坏   右键放置   Reload 选择方块", "mc_hud_small", sw * 0.5, sh - 20, Color( 255, 255, 255, 190 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )

		surface.SetDrawColor( 255, 255, 255, 220 )
		surface.DrawRect( sw * 0.5 - 1, sh * 0.5 - 1, 2, 2 )
	end

	hook.Add( "PostDrawTranslucentRenderables", "mc_ghost", function( _, bSky, bSky3D )
		if bSky or bSky3D then return end
		local ply = LocalPlayer()
		if not IsValid( ply ) or not ply:Alive() then return end
		local wep = ply:GetActiveWeapon()
		if not IsValid( wep ) or wep:GetClass() ~= "mc_placer" then return end

		local aim = aimedBlock( ply )
		if not aim then return end
		MC.DrawBlockOutline( aim.Block, aim.Orient, aim.bx, aim.by, aim.bz, Color( 0, 0, 0, 235 ) )
	end )
end
