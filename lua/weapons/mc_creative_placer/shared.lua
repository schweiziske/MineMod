--[[----------------------------------------------------------------------------
	mc_creative_placer : SWEP front-end with a Minecraft-style creative inventory.
	Left = break, Right = place, R = categorized creative block picker.
------------------------------------------------------------------------------]]

if SERVER then AddCSLuaFile() end

SWEP.PrintName     = "MC 创造方块放置器"
SWEP.Author        = "MC"
SWEP.Purpose       = "放置 / 破坏 Minecraft 方块，并从创造物品栏选择方块"
SWEP.Instructions  = "左键破坏  右键放置  Reload 创造物品栏"
SWEP.Category      = "MC"

SWEP.Spawnable     = true
SWEP.AdminOnly     = false
SWEP.Slot          = 1
SWEP.SlotPos       = 6
SWEP.DrawAmmo      = false
SWEP.DrawCrosshair = true

SWEP.Base          = "weapon_base"
SWEP.ViewModel     = "models/weapons/c_toolgun.mdl"
SWEP.WorldModel    = "models/weapons/w_toolgun.mdl"
SWEP.UseHands      = true

SWEP.Primary   = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" }
SWEP.Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" }

local STEP = 0.13

local function defaultSelectedID()
	local resolved = MC.ResolveBlock and MC.ResolveBlock( "minecraft:stone" ) or nil
	local id = resolved and resolved.id or 1
	if not MC.IsValidBlock( id ) then id = 1 end
	return id
end

local function selectedID( ply )
	if CLIENT and MC.GetCreativeHotbarSelectedID then
		local hotbarID = MC.GetCreativeHotbarSelectedID( ply )
		if MC.IsValidBlock( hotbarID ) then return hotbarID end
	end
	local fallback = defaultSelectedID()
	local id = IsValid( ply ) and ply:GetNWInt( "mc_block", fallback ) or fallback
	if not MC.IsValidBlock( id ) then id = fallback end
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

local function blockHasUse( id )
	local b = MC.Blocks and MC.Blocks[id]
	return b and b.handlers and b.handlers.OnUse ~= nil
end

local function placeTarget( ply, aim, fallbackTrace, id, avoidUseBlocks )
	local tr = aim or fallbackTrace
	if not tr or not tr.Hit then return nil end
	if avoidUseBlocks and aim and blockHasUse( aim.Block ) then return nil end

	local bx, by, bz
	if aim then
		bx = aim.bx + math.Round( aim.HitNormal.x )
		by = aim.by + math.Round( aim.HitNormal.y )
		bz = aim.bz + math.Round( aim.HitNormal.z )
	else
		bx, by, bz = placeCell( tr )
	end

	local orient = MC.OrientForPlacement( ply, tr, id )
	return bx, by, bz, orient
end

local function breakTarget( ply, aim, fallbackTrace )
	if aim then return aim.bx, aim.by, aim.bz end
	local tr = fallbackTrace
	if not tr or not tr.Hit then return nil end
	return breakCell( tr )
end

function SWEP:Initialize()
	self:SetHoldType( "pistol" )
end

function SWEP:Deploy()
	self:SetHoldType( "pistol" )
	if CLIENT and MC.EnsureCreativeHotbar then
		MC.EnsureCreativeHotbar()
		if MC.SyncCreativeHotbarSelection then MC.SyncCreativeHotbarSelection( true ) end
	end
	return true
end

function SWEP:PrimaryAttack()
	self:SetNextPrimaryFire( CurTime() + STEP )
	local owner = self:GetOwner()
	if not IsValid( owner ) then return end
	local aim = aimedBlock( owner )

	if SERVER then
		local bx, by, bz = breakTarget( owner, aim, owner:GetEyeTrace() )
		if not bx then return end
		if MC.SV.Break( owner, bx, by, bz ) then
			self:EmitSound( "buttons/button15.wav", 60, 120, 0.25 )
		elseif MC.SV.SyncBreakPlan then
			MC.SV.SyncBreakPlan( owner, bx, by, bz )
		elseif MC.SV.SyncCell then
			MC.SV.SyncCell( owner, bx, by, bz )
		end
	elseif CLIENT and not game.SinglePlayer() and IsFirstTimePredicted() and owner == LocalPlayer() then
		local bx, by, bz = breakTarget( owner, aim, owner:GetEyeTrace() )
		if bx and MC.CanPreviewBreak and MC.CanPreviewBreak( owner, bx, by, bz ) and MC.PredictBreakBlock then
			MC.PredictBreakBlock( bx, by, bz, owner )
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

		local id = selectedID( owner )
		local bx, by, bz, orient = placeTarget( owner, aim, tr, id )
		if not bx then return end
		if MC.SV.Place( owner, bx, by, bz, id, orient ) then
			self:EmitSound( "buttons/button14.wav", 60, 150, 0.25 )
		elseif MC.SV.SyncPlacementPlan then
			MC.SV.SyncPlacementPlan( owner, bx, by, bz, id, orient )
		elseif MC.SV.SyncCell then
			MC.SV.SyncCell( owner, bx, by, bz )
		end
	elseif CLIENT and not game.SinglePlayer() and IsFirstTimePredicted() and owner == LocalPlayer() then
		local id = selectedID( owner )
		if MC.CreativeHotbarSelectionSynced and not MC.CreativeHotbarSelectionSynced( owner, id ) then return end
		local bx, by, bz, orient = placeTarget( owner, aim, owner:GetEyeTrace(), id, true )
		local plan = bx and MC.BuildPlacementPlan and MC.BuildPlacementPlan( bx, by, bz, id, orient )
		if plan and MC.CanPreviewPlacePlan and MC.CanPreviewPlacePlan( owner, plan ) and MC.PredictSetBlock then
			MC.PredictSetBlock( bx, by, bz, id, orient )
		end
	end
end

function SWEP:Reload()
	if CLIENT then
		if IsValid( MC.CreativeFrame ) and MC.CreativeFrame:IsVisible() then return end
		MC.OpenCreativeInventory( function( id )
			MC.SetCreativeHotbarSlot( MC.GetCreativeHotbarSelectedSlot(), id )
		end, { closeOnSelect = false } )
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
		local slotSize = 54
		local hotbarY = sh - slotSize - 22
		local panelW = 380
		local panelH = state ~= "" and 118 or 96
		local px = sw * 0.5 - panelW * 0.5
		local py = hotbarY - panelH - 14
		local x, y = px + 18, py + ( panelH - h ) * 0.5
		local tx = x + w + 18
		local maxTextW = panelW - ( tx - px ) - 18

		draw.RoundedBox( 6, px, py, panelW, panelH, Color( 0, 0, 0, 175 ) )
		MC.DrawMinecraftBlockIcon( id, x, y, w, h )
		MC.DrawFittedText( b.disp, "mc_hud_big", { "mc_hud_fit_24", "mc_hud_fit_20", "mc_hud_fit_16" }, tx, py + 22, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, maxTextW )
		if state ~= "" then
			draw.SimpleText( state, "mc_hud_small", tx, py + 58, Color( 210, 230, 255 ), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
		end
		if MC.DrawCreativeHotbar then
			MC.DrawCreativeHotbar( sw * 0.5, hotbarY, { slotSize = slotSize } )
		end
		draw.SimpleText( "左键破坏   右键放置   中键取块   Reload 创造物品栏", "mc_hud_small", sw * 0.5, sh - 10, Color( 255, 255, 255, 190 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )

		surface.SetDrawColor( 255, 255, 255, 220 )
		surface.DrawRect( sw * 0.5 - 1, sh * 0.5 - 1, 2, 2 )
	end

	hook.Add( "PostDrawTranslucentRenderables", "mc_creative_ghost", function( _, bSky, bSky3D )
		if bSky or bSky3D then return end
		local ply = LocalPlayer()
		if not IsValid( ply ) or not ply:Alive() then return end
		local wep = ply:GetActiveWeapon()
		if not IsValid( wep ) or wep:GetClass() ~= "mc_creative_placer" then return end

		local aim = aimedBlock( ply )
		if not aim then return end
		MC.DrawBlockOutline( aim.Block, aim.Orient, aim.bx, aim.by, aim.bz, Color( 0, 0, 0, 235 ) )
	end )
end
