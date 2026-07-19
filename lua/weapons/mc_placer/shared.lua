--[[----------------------------------------------------------------------------
	mc_placer : SWEP front-end. Runs server-side with the owner, so it talks to
	MC.SV directly. Left = break, Right = place, R = palette.
------------------------------------------------------------------------------]]

if SERVER then AddCSLuaFile() end

local function L( key, fallback, vars )
	return MC and MC.T and MC.T( key, fallback, vars ) or fallback
end

local function blockDisplayText( blockOrID )
	local b = type( blockOrID ) == "table" and blockOrID or ( MC and MC.Blocks and MC.Blocks[blockOrID] )
	if not b then return "" end
	return MC.BlockDisplayName and MC.BlockDisplayName( b, b.dispZH or b.disp ) or b.disp
end

SWEP.PrintName     = L( "weapon.mc_placer.name", "MC 方块放置器" )
SWEP.Author        = "MC"
SWEP.Purpose       = L( "weapon.mc_placer.purpose", "放置 / 破坏 Minecraft 方块（IMesh 渲染，不生成实体）" )
SWEP.Instructions  = L( "weapon.mc_placer.instructions", "左键破坏  右键放置  Reload 选择方块" )
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

	tr.MCBlockX, tr.MCBlockY, tr.MCBlockZ = bx, by, bz
	local orient = MC.OrientForPlacement( ply, tr, id )
	local stateId = MC.StateFromLegacy and MC.StateFromLegacy( id, orient ) or nil
	if not stateId then return nil end
	if MC.ResolveTorchPlacementState then
		stateId = MC.ResolveTorchPlacementState( stateId, tr.HitNormal )
		if not stateId then return nil end
	end
	if MC.ResolveFaceAttachedPlacementState then
		stateId = MC.ResolveFaceAttachedPlacementState( stateId, tr.HitNormal, ply )
		if not stateId then return nil end
	end
	if MC.ResolveSignPlacementState then
		stateId = MC.ResolveSignPlacementState( stateId, tr.HitNormal, ply, bx, by, bz )
		if not stateId then return nil end
	end
	return bx, by, bz, stateId
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
			MC.SV.SyncCell( owner, bx, by, bz ) -- undo the client's break prediction
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
		local id = selectedID( owner )
		if MC.SV.Use( owner, ux, uy, uz, id ) then return end

		local bx, by, bz, stateId = placeTarget( owner, aim, tr, id )
		if not bx then return end
		if MC.SV.PlaceState( owner, bx, by, bz, stateId ) then
			self:EmitSound( "buttons/button14.wav", 60, 150, 0.25 )
		elseif MC.SV.SyncPlacementStatePlan then
			MC.SV.SyncPlacementStatePlan( owner, bx, by, bz, stateId )
		elseif MC.SV.SyncCell then
			MC.SV.SyncCell( owner, bx, by, bz ) -- undo the client's place prediction
		end
	elseif CLIENT and not game.SinglePlayer() and IsFirstTimePredicted() and owner == LocalPlayer() then
		local id = selectedID( owner )
		local bx, by, bz, stateId = placeTarget( owner, aim, owner:GetEyeTrace(), id, true )
		local plan = bx and MC.BuildPlacementStatePlan and MC.BuildPlacementStatePlan( bx, by, bz, stateId )
		if plan and MC.CanPreviewPlacePlan( owner, plan ) and MC.PredictSetBlockState then
			MC.PredictSetBlockState( bx, by, bz, stateId )
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
	function SWEP:GetPrintName()
		return L( "weapon.mc_placer.name", self.PrintName or "MC 方块放置器" )
	end

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
		MC.DrawFittedText( blockDisplayText( b ), "mc_hud_big", { "mc_hud_fit_24", "mc_hud_fit_20", "mc_hud_fit_16" }, tx, py + 22, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, maxTextW )
		if state ~= "" then
			draw.SimpleText( state, "mc_hud_small", tx, py + 58, Color( 210, 230, 255 ), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
		end
		draw.SimpleText( L( "weapon.mc_placer.hud", "左键破坏   右键放置   Reload 选择方块" ), "mc_hud_small", sw * 0.5, sh - 20, Color( 255, 255, 255, 190 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )

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
		MC.DrawBlockOutline( aim.Block, aim.Orient, aim.bx, aim.by, aim.bz, Color( 0, 0, 0, 235 ), aim.StateId )
	end )
end
