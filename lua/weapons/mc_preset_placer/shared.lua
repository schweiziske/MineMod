--[[----------------------------------------------------------------------------
	mc_preset_placer : preset capture/place SWEP.
	Left = advance capture or place loaded preset, Right = undo/cancel, R = UI.
	G rotates the loaded preset projection by 90 degree grid steps.
------------------------------------------------------------------------------]]

if SERVER then AddCSLuaFile() end

local function L( key, fallback, vars )
	return MC and MC.T and MC.T( key, fallback, vars ) or fallback
end

SWEP.PrintName     = L( "weapon.mc_preset_placer.name", "MC 预设放置器" )
SWEP.Author        = "schweiziske"
SWEP.Purpose       = L( "weapon.mc_preset_placer.purpose", "保存和放置 Minecraft 方块建筑预设" )
SWEP.Instructions  = L( "weapon.mc_preset_placer.instructions", "R 打开预设界面  左键选择/放置  右键撤销  G 旋转" )
SWEP.Category      = "Minecraft"

SWEP.Spawnable     = true
SWEP.AdminOnly     = false
SWEP.Slot          = 1
SWEP.SlotPos       = 7
SWEP.DrawAmmo      = false
SWEP.DrawCrosshair = true

SWEP.Base          = "weapon_base"
SWEP.ViewModel     = "models/weapons/c_toolgun.mdl"
SWEP.WorldModel    = "models/weapons/w_toolgun.mdl"
SWEP.UseHands      = true

if CLIENT then
	SWEP.WepSelectIcon = surface.GetTextureID( "vgui/entities/mc_preset_placer" )
	SWEP.BounceWeaponIcon = false
	SWEP.DrawWeaponInfoBox = false

	function SWEP:DrawWeaponSelection( x, y, width, height, alpha )
		local size = math.min( width, height ) * 0.70
		surface.SetDrawColor( 255, 255, 255, alpha or 255 )
		surface.SetTexture( self.WepSelectIcon )
		surface.DrawTexturedRect( x + ( width - size ) * 0.5, y + ( height - size ) * 0.5, size, size )
	end
end

SWEP.Primary   = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }
SWEP.Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }

SWEP.MCPresetSaveNet = "mc_preset_save"
SWEP.MCPresetPlaceNet = "mc_preset_place"

local STEP = 0.22

local function clientChat( msg )
	if not CLIENT then return end
	local ply = LocalPlayer()
	if IsValid( ply ) then ply:ChatPrint( "[MC] " .. msg ) end
end

function SWEP:Initialize()
	self:SetHoldType( "pistol" )
end

function SWEP:Deploy()
	self:SetHoldType( "pistol" )
	if CLIENT then
		timer.Simple( 0, function()
			if not IsValid( self ) then return end
			clientChat( L( "weapon.mc_preset_placer.help", "预设放置器：按 R 打开界面。新建预设用左键选四步；读取预设后左键放置。" ) )
		end )
	end
	return true
end

function SWEP:PrimaryAttackClient()
	if not CLIENT then return end
	local owner = self:GetOwner()
	if not IsValid( owner ) or owner ~= LocalPlayer() then return end

	if MC.PresetMode == "place" and MC.ActivePreset then
		if MC.PlaceActivePreset then MC.PlaceActivePreset() end
	else
		if MC.PresetAdvanceSelection then MC.PresetAdvanceSelection() end
	end
end

function SWEP:PrimaryAttack()
	self:SetNextPrimaryFire( CurTime() + STEP )
	local owner = self:GetOwner()
	if not IsValid( owner ) then return end

	if SERVER then
		if game.SinglePlayer() then self:CallOnClient( "PrimaryAttackClient" ) end
		return
	end
	if game.SinglePlayer() then return end
	if IsFirstTimePredicted() and owner == LocalPlayer() then
		self:PrimaryAttackClient()
	end
end

function SWEP:SecondaryAttackClient()
	if not CLIENT then return end
	local owner = self:GetOwner()
	if not IsValid( owner ) or owner ~= LocalPlayer() then return end
	if MC.PresetUndoSelection then MC.PresetUndoSelection() end
end

function SWEP:SecondaryAttack()
	self:SetNextSecondaryFire( CurTime() + STEP )
	local owner = self:GetOwner()
	if not IsValid( owner ) then return end

	if SERVER then
		if game.SinglePlayer() then self:CallOnClient( "SecondaryAttackClient" ) end
		return
	end
	if game.SinglePlayer() then return end
	if IsFirstTimePredicted() and owner == LocalPlayer() then
		self:SecondaryAttackClient()
	end
end

-- In single-player weapon input is handled by the server realm. Keep the UI
-- opener client-only, but explicitly bridge Reload across realms there.
function SWEP:OpenPresetManagerClient()
	if not CLIENT then return end
	if IsValid( MC.PresetManagerFrame ) and MC.PresetManagerFrame:IsVisible() then return end
	if MC.OpenPresetManager then MC.OpenPresetManager() end
end

function SWEP:Reload()
	if SERVER then
		if game.SinglePlayer() then self:CallOnClient( "OpenPresetManagerClient" ) end
		return
	end
	if game.SinglePlayer() then return end
	self:OpenPresetManagerClient()
end

if CLIENT then
	function SWEP:GetPrintName()
		return L( "weapon.mc_preset_placer.name", self.PrintName or "MC 预设放置器" )
	end

	local function activePresetPlacer( ply )
		if not IsValid( ply ) then return false end
		local wep = ply:GetActiveWeapon()
		return IsValid( wep ) and wep:GetClass() == "mc_preset_placer"
	end

	local function textEntryHasFocus()
		local focus = vgui.GetKeyboardFocus and vgui.GetKeyboardFocus() or nil
		if not IsValid( focus ) then return false end
		local class = focus.GetClassName and focus:GetClassName() or ""
		return class == "TextEntry" or class == "DTextEntry"
	end

	local lastRotateAt = 0
	local function cyclePresetRotationDebounced()
		if not MC.CyclePresetRotation then return false end
		local now = CurTime()
		if now - lastRotateAt < 0.08 then return true end
		lastRotateAt = now
		MC.CyclePresetRotation()
		return true
	end

	local function drawFallbackCellBox( cell, color )
		local base = MC.CellWorldMin( cell.bx, cell.by, cell.bz )
		render.DrawWireframeBox( base, angle_zero, vector_origin, Vector( MC.BS, MC.BS, MC.BS ), color, true )
	end

	local function drawCellOutline( cell, color )
		if not cell then return end
		local id = MC.GetBlock( cell.bx, cell.by, cell.bz )
		if id ~= 0 and MC.DrawBlockOutline then
			MC.DrawBlockOutline( id, MC.GetBlockOrient( cell.bx, cell.by, cell.bz ), cell.bx, cell.by, cell.bz, color )
		else
			drawFallbackCellBox( cell, color )
		end
	end

	local function drawSelectionBox( a, b )
		if not a or not b then return end
		local minx, maxx = math.min( a.bx, b.bx ), math.max( a.bx, b.bx )
		local miny, maxy = math.min( a.by, b.by ), math.max( a.by, b.by )
		local minz, maxz = math.min( a.bz, b.bz ), math.max( a.bz, b.bz )
		local base = MC.CellWorldMin( minx, miny, minz )
		local maxs = Vector( ( maxx - minx + 1 ) * MC.BS, ( maxy - miny + 1 ) * MC.BS, ( maxz - minz + 1 ) * MC.BS )
		render.DrawWireframeBox( base, angle_zero, vector_origin, maxs, Color( 80, 180, 255, 235 ), true )
	end

	function SWEP:DrawHUD()
		local sw, sh = ScrW(), ScrH()
		local mode = MC.PresetMode or "idle"
		local step = MC.PresetSelectionStep or 0
		local title = L( "weapon.mc_preset_placer.title", "MC 预设放置器" )
		local hint
		local overwriteText = ( MC.PresetOverwrite == true ) and L( "weapon.mc_preset_placer.overwrite_on", "覆盖: 开" ) or L( "weapon.mc_preset_placer.overwrite_off", "覆盖: 关" )
		local rotationDeg = MC.PresetRotationDegrees and MC.PresetRotationDegrees( MC.PresetRotation or 0 ) or ( ( MC.PresetRotation or 0 ) * 90 )
		local rotationText = L( "weapon.mc_preset_placer.rotation", "旋转: {degrees} deg", { degrees = rotationDeg } )
		if mode == "place" and MC.ActivePreset then
			hint = L( "weapon.mc_preset_placer.place_hint", "左键放置投影   右键取消   E 覆盖   G 旋转   R 预设" )
		elseif mode == "create" then
			if step == 0 then hint = L( "weapon.mc_preset_placer.step0", "左键选择第一个方块   右键取消" )
			elseif step == 1 then hint = L( "weapon.mc_preset_placer.step1", "左键选择第二个方块完成范围   右键撤销" )
			elseif step == 2 then hint = L( "weapon.mc_preset_placer.step2", "左键选择基准面   右键撤销" )
			elseif step == 3 then hint = L( "weapon.mc_preset_placer.step3", "左键截图并保存   右键撤销" )
			else hint = L( "weapon.mc_preset_placer.saving", "正在保存预设..." ) end
		else
			hint = L( "weapon.mc_preset_placer.open", "R 打开预设界面" )
		end

		draw.RoundedBox( 6, sw * 0.5 - 270, sh - 116, 540, 76, Color( 0, 0, 0, 175 ) )
		draw.SimpleText( title, "mc_hud", sw * 0.5, sh - 94, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		draw.SimpleText( hint, "mc_hud_small", sw * 0.5, sh - 66, Color( 225, 235, 248, 230 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		draw.SimpleText( rotationText .. "   " .. overwriteText, "mc_hud_small", sw * 0.5, sh - 46, Color( 180, 200, 220, 190 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )

		surface.SetDrawColor( 255, 255, 255, 220 )
		surface.DrawRect( sw * 0.5 - 1, sh * 0.5 - 1, 2, 2 )
	end

	hook.Add( "PlayerBindPress", "mc_preset_overwrite_toggle", function( ply, bind, pressed )
		if not pressed or not IsValid( ply ) or ply ~= LocalPlayer() then return end
		if not activePresetPlacer( ply ) or textEntryHasFocus() then return end

		local lower = string.lower( tostring( bind or "" ) )
		if lower == "+use" and MC.TogglePresetOverwrite then
			MC.TogglePresetOverwrite()
			return true
		end
		if lower == "+grenade1" then return cyclePresetRotationDebounced() end
	end )

	hook.Add( "PlayerButtonDown", "mc_preset_rotation_key", function( ply, button )
		if button ~= KEY_G then return end
		if not IsValid( ply ) or ply ~= LocalPlayer() then return end
		if not activePresetPlacer( ply ) or textEntryHasFocus() then return end
		cyclePresetRotationDebounced()
	end )

	hook.Add( "PostDrawTranslucentRenderables", "mc_preset_selection_outline", function( _, bSky, bSky3D )
		-- bSky (DF_DRAWSKYBOX) is also true on the main pass on 2D-sky maps; skip only the 3D skybox pass
		if bSky3D then return end
		local ply = LocalPlayer()
		if not IsValid( ply ) or not ply:Alive() then return end
		local wep = ply:GetActiveWeapon()
		if not IsValid( wep ) or wep:GetClass() ~= "mc_preset_placer" then return end
		if MC.PresetMode ~= "create" then return end

		local selection = MC.PresetSelection or {}
		drawCellOutline( selection.a, Color( 70, 210, 255, 240 ) )
		drawCellOutline( selection.b, Color( 70, 255, 150, 240 ) )
		drawSelectionBox( selection.a, selection.b )
		drawCellOutline( selection.anchor, Color( 255, 220, 80, 255 ) )
	end )
end
