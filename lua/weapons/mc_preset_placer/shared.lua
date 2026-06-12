--[[----------------------------------------------------------------------------
	mc_preset_placer : preset capture/place SWEP.
	Left = advance capture or place loaded preset, Right = undo/cancel, R = UI.

	Preset v1 is no rotation: saved block orientations are replayed as-is and the
	saved anchor is only translated to the aimed placement cell.
------------------------------------------------------------------------------]]

if SERVER then AddCSLuaFile() end

SWEP.PrintName     = "MC 预设放置器"
SWEP.Author        = "MC"
SWEP.Purpose       = "保存和放置 Minecraft 方块建筑预设"
SWEP.Instructions  = "R 打开预设界面  左键选择/放置  右键撤销"
SWEP.Category      = "MC"

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
			clientChat( "预设放置器：按 R 打开界面。新建预设用左键选四步；读取预设后左键放置。" )
		end )
	end
	return true
end

function SWEP:PrimaryAttack()
	self:SetNextPrimaryFire( CurTime() + STEP )
	local owner = self:GetOwner()
	if not IsValid( owner ) then return end

	if CLIENT and IsFirstTimePredicted() and owner == LocalPlayer() then
		if MC.PresetMode == "place" and MC.ActivePreset then
			if MC.PlaceActivePreset then MC.PlaceActivePreset() end
		else
			if MC.PresetAdvanceSelection then MC.PresetAdvanceSelection() end
		end
	end
end

function SWEP:SecondaryAttack()
	self:SetNextSecondaryFire( CurTime() + STEP )
	local owner = self:GetOwner()
	if not IsValid( owner ) then return end

	if CLIENT and IsFirstTimePredicted() and owner == LocalPlayer() and MC.PresetUndoSelection then
		MC.PresetUndoSelection()
	end
end

function SWEP:Reload()
	if CLIENT then
		if IsValid( MC.PresetManagerFrame ) and MC.PresetManagerFrame:IsVisible() then return end
		if MC.OpenPresetManager then MC.OpenPresetManager() end
	end
end

if CLIENT then
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
		local title = "MC 预设放置器"
		local hint
		local overwriteText = ( MC.PresetOverwrite == true ) and "覆盖: 开" or "覆盖: 关"
		if mode == "place" and MC.ActivePreset then
			hint = "左键放置投影   右键取消   E 切换覆盖   R 选择预设"
		elseif mode == "create" then
			if step == 0 then hint = "左键选择第一个方块   右键取消"
			elseif step == 1 then hint = "左键选择第二个方块完成范围   右键撤销"
			elseif step == 2 then hint = "左键选择基准面   右键撤销"
			elseif step == 3 then hint = "左键截图并保存   右键撤销"
			else hint = "正在保存预设..." end
		else
			hint = "R 打开预设界面"
		end

		draw.RoundedBox( 6, sw * 0.5 - 210, sh - 116, 420, 76, Color( 0, 0, 0, 175 ) )
		draw.SimpleText( title, "mc_hud", sw * 0.5, sh - 94, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		draw.SimpleText( hint, "mc_hud_small", sw * 0.5, sh - 66, Color( 225, 235, 248, 230 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		draw.SimpleText( "不旋转 v1：基准面只负责平移对齐   " .. overwriteText, "mc_hud_small", sw * 0.5, sh - 46, Color( 180, 200, 220, 190 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )

		surface.SetDrawColor( 255, 255, 255, 220 )
		surface.DrawRect( sw * 0.5 - 1, sh * 0.5 - 1, 2, 2 )
	end

	hook.Add( "PlayerBindPress", "mc_preset_overwrite_toggle", function( ply, bind, pressed )
		if not pressed or not IsValid( ply ) or ply ~= LocalPlayer() then return end
		if string.lower( tostring( bind or "" ) ) ~= "+use" then return end
		local wep = ply:GetActiveWeapon()
		if not IsValid( wep ) or wep:GetClass() ~= "mc_preset_placer" then return end
		if MC.TogglePresetOverwrite then
			MC.TogglePresetOverwrite()
			return true
		end
	end )

	hook.Add( "PostDrawTranslucentRenderables", "mc_preset_selection_outline", function( _, bSky, bSky3D )
		if bSky or bSky3D then return end
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
