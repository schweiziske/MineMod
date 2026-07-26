--[[----------------------------------------------------------------------------
	mc_cluster_tool : structure grabber SWEP.
	Select world blocks (fine, box, or connected flood select) and convert
	them into one movable mc_block_cluster physics entity; aim at a cluster
	and press G to snap its blocks back onto the grid.

	Left = add / pick box corner, Right = deselect / cancel corner,
	R = toggle fine/box mode, E = flood select, G = convert or paste,
	C = clear selection.
------------------------------------------------------------------------------]]

if SERVER then AddCSLuaFile() end

local function L( key, fallback, vars )
	return MC and MC.T and MC.T( key, fallback, vars ) or fallback
end

SWEP.PrintName     = L( "weapon.mc_cluster_tool.name", "MC 结构搬运器" )
SWEP.Author        = "schweiziske"
SWEP.Purpose       = L( "weapon.mc_cluster_tool.purpose", "把选中的 Minecraft 方块变成可搬运的物理实体" )
SWEP.Instructions  = L( "weapon.mc_cluster_tool.instructions", "左键 选择  右键 取消  R 切换模式  E 连通选择  G 转换/放回  X 清空" )
SWEP.Category      = "Minecraft"

SWEP.Spawnable     = true
SWEP.AdminOnly     = false
SWEP.Slot          = 1
SWEP.SlotPos       = 8
SWEP.DrawAmmo      = false
SWEP.DrawCrosshair = true

SWEP.Base          = "weapon_base"
SWEP.ViewModel     = "models/weapons/c_toolgun.mdl"
SWEP.WorldModel    = "models/weapons/w_toolgun.mdl"
SWEP.UseHands      = true

if CLIENT then
	SWEP.WepSelectIcon = surface.GetTextureID( "vgui/entities/mc_cluster_tool" )
	SWEP.BounceWeaponIcon = false
	SWEP.DrawWeaponInfoBox = false

	function SWEP:DrawWeaponSelection( x, y, width, height, alpha )
		if not self.WepSelectIcon or self.WepSelectIcon <= 0 then return end
		local size = math.min( width, height ) * 0.70
		surface.SetDrawColor( 255, 255, 255, alpha or 255 )
		surface.SetTexture( self.WepSelectIcon )
		surface.DrawTexturedRect( x + ( width - size ) * 0.5, y + ( height - size ) * 0.5, size, size )
	end
end

SWEP.Primary   = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }
SWEP.Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" }

local STEP = 0.18

local function clientChat( msg )
	if not CLIENT then return end
	local ply = LocalPlayer()
	if IsValid( ply ) then ply:ChatPrint( "[MC] " .. msg ) end
end

local function aimedBlock()
	local ply = LocalPlayer()
	if not IsValid( ply ) then return nil end
	return MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
end

function SWEP:Initialize()
	self:SetHoldType( "pistol" )
end

function SWEP:Deploy()
	self:SetHoldType( "pistol" )
	if CLIENT then
		timer.Simple( 0, function()
			if not IsValid( self ) then return end
			clientChat( L( "weapon.mc_cluster_tool.help",
				"结构搬运器：左键选方块 (R 切换框选)，E 连通选择，G 把选区变成实体；对准实体按 G 放回网格。" ) )
		end )
	end
	return true
end

function SWEP:PrimaryAttackClient()
	if not CLIENT then return end
	local owner = self:GetOwner()
	if not IsValid( owner ) or owner ~= LocalPlayer() then return end

	if MC.ClusterAimedCluster and IsValid( MC.ClusterAimedCluster() ) then
		clientChat( L( "weapon.mc_cluster_tool.aim_paste_hint", "对准结构时按 G 放回网格" ) )
		return
	end

	local aim = aimedBlock()
	if not aim then
		clientChat( L( "weapon.mc_cluster_tool.aim_block", "请准星对准一个 MC 方块" ) )
		return
	end

	if MC.ClusterSelectMode == "box" then
		if MC.ClusterBoxClick then MC.ClusterBoxClick( aim.bx, aim.by, aim.bz ) end
	else
		if MC.ClusterSelectionAdd then MC.ClusterSelectionAdd( aim.bx, aim.by, aim.bz ) end
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

	if MC.ClusterSelectMode == "box" and MC.ClusterBoxCorner then
		MC.ClusterBoxCorner = nil
		clientChat( L( "weapon.mc_cluster_tool.corner_cancel", "已取消角点" ) )
		return
	end

	local aim = aimedBlock()
	if aim and MC.ClusterSelectionRemove and MC.ClusterSelectionRemove( aim.bx, aim.by, aim.bz ) then return end
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

function SWEP:ToggleModeClient()
	if not CLIENT then return end
	local owner = self:GetOwner()
	if not IsValid( owner ) or owner ~= LocalPlayer() then return end
	MC.ClusterSelectMode = MC.ClusterSelectMode == "box" and "fine" or "box"
	MC.ClusterBoxCorner = nil
	clientChat( MC.ClusterSelectMode == "box"
		and L( "weapon.mc_cluster_tool.mode_box", "已切换到框选模式" )
		or L( "weapon.mc_cluster_tool.mode_fine", "已切换到细选模式" ) )
end

function SWEP:Reload()
	if SERVER then
		if game.SinglePlayer() then
			if ( self.mcNextModeToggle or 0 ) > CurTime() then return end
			self.mcNextModeToggle = CurTime() + 0.25
			self:CallOnClient( "ToggleModeClient" )
		end
		return
	end
	if game.SinglePlayer() then return end
	if ( self.mcNextModeToggle or 0 ) > CurTime() then return end
	self.mcNextModeToggle = CurTime() + 0.25
	self:ToggleModeClient()
end

if CLIENT then
	function SWEP:GetPrintName()
		return L( "weapon.mc_cluster_tool.name", self.PrintName or "MC 结构搬运器" )
	end

	local function activeClusterTool( ply )
		if not IsValid( ply ) then return false end
		local wep = ply:GetActiveWeapon()
		return IsValid( wep ) and wep:GetClass() == "mc_cluster_tool"
	end

	local function textEntryHasFocus()
		local focus = vgui.GetKeyboardFocus and vgui.GetKeyboardFocus() or nil
		if not IsValid( focus ) then return false end
		local class = focus.GetClassName and focus:GetClassName() or ""
		return class == "TextEntry" or class == "DTextEntry"
	end

	local lastActionAt = 0
	local function actionDebounced()
		local now = CurTime()
		if now - lastActionAt < 0.2 then return false end
		lastActionAt = now
		return true
	end

	local function convertOrPaste()
		local aimedCluster = MC.ClusterAimedCluster and MC.ClusterAimedCluster() or nil
		if IsValid( aimedCluster ) then
			if MC.ClusterSendPaste then MC.ClusterSendPaste( aimedCluster ) end
			return
		end
		if MC.ClusterSendConvert then MC.ClusterSendConvert() end
	end

	hook.Add( "PlayerButtonDown", "mc_cluster_tool_keys", function( ply, button )
		if not IsValid( ply ) or ply ~= LocalPlayer() then return end
		if not activeClusterTool( ply ) or textEntryHasFocus() then return end

		if button == KEY_G then
			if actionDebounced() then convertOrPaste() end
		elseif button == KEY_X then
			if actionDebounced() and MC.ClusterSelectionCount and MC.ClusterSelectionCount() > 0 then
				MC.ClusterSelectionClear()
			end
		end
	end )

	local lastFloodAt = 0
	hook.Add( "PlayerBindPress", "mc_cluster_tool_flood", function( ply, bind, pressed )
		if not pressed or not IsValid( ply ) or ply ~= LocalPlayer() then return end
		if not activeClusterTool( ply ) or textEntryHasFocus() then return end

		local lower = string.lower( tostring( bind or "" ) )
		if lower == "+use" then
			local now = CurTime()
			if now - lastFloodAt < 0.3 then return true end
			lastFloodAt = now
			local aim = aimedBlock()
			if aim and MC.ClusterFloodSelect then
				MC.ClusterFloodSelect( aim.bx, aim.by, aim.bz )
			else
				clientChat( L( "weapon.mc_cluster_tool.aim_block", "请准星对准一个 MC 方块" ) )
			end
			return true
		end
	end )

	function SWEP:DrawHUD()
		local sw, sh = ScrW(), ScrH()
		local count = MC.ClusterSelectionCount and MC.ClusterSelectionCount() or 0
		local maxBlocks = MC.ClusterMaxBlocks and MC.ClusterMaxBlocks() or 4096
		local isBox = MC.ClusterSelectMode == "box"

		local title = L( "weapon.mc_cluster_tool.name", "MC 结构搬运器" )
		local modeText = isBox
			and L( "weapon.mc_cluster_tool.mode_box_label", "模式: 框选" )
			or L( "weapon.mc_cluster_tool.mode_fine_label", "模式: 细选" )
		local countText = L( "weapon.mc_cluster_tool.count", "已选 {n}/{max}", { n = count, max = maxBlocks } )

		local hint
		local aimedCluster = MC.ClusterAimedCluster and MC.ClusterAimedCluster() or nil
		local statusLine
		if IsValid( aimedCluster ) then
			local ghost = MC.ClusterPasteGhost and MC.ClusterPasteGhost( aimedCluster ) or nil
			local blocks = aimedCluster.GetBlockCount and aimedCluster:GetBlockCount() or 0
			if ghost and ghost.tilted then
				hint = L( "weapon.mc_cluster_tool.hint_tilted", "结构 ({n} 方块) 倾斜太大, 用物理枪放平后才能放回", { n = blocks } )
			elseif ghost and ghost.blocked and ghost.blocked > 0 then
				hint = L( "weapon.mc_cluster_tool.hint_blocked", "结构 ({n} 方块): 目标位置有 {b} 格被占用", { n = blocks, b = ghost.blocked } )
			else
				hint = L( "weapon.mc_cluster_tool.hint_paste", "结构 ({n} 方块): 按 G 放回网格", { n = blocks } )
			end

			local maxHP = aimedCluster.GetClusterMaxHP and aimedCluster:GetClusterMaxHP() or 0
			local durability = maxHP > 0
				and L( "weapon.mc_cluster_tool.durability", "耐久 {hp}/{max}", { hp = math.max( 0, aimedCluster:Health() ), max = maxHP } )
				or L( "weapon.mc_cluster_tool.durability_inf", "耐久 无敌" )
			local owner = aimedCluster.GetOwnerLabel and aimedCluster:GetOwnerLabel() or ""
			statusLine = durability .. ( owner ~= "" and ( "   " .. L( "weapon.mc_cluster_tool.owner", "主人 {name}", { name = owner } ) ) or "" )
		elseif isBox then
			hint = MC.ClusterBoxCorner
				and L( "weapon.mc_cluster_tool.hint_corner_b", "左键 选择对角完成框选   右键 取消角点   G 转换   X 清空" )
				or L( "weapon.mc_cluster_tool.hint_corner_a", "左键 选择第一个角点   E 连通选择   G 转换   R 细选   X 清空" )
		else
			hint = L( "weapon.mc_cluster_tool.hint_fine", "左键 加选   右键 减选   E 连通选择   G 转换   R 框选   X 清空" )
		end

		local infoLine = statusLine or ( modeText .. "   " .. countText )
		draw.RoundedBox( 6, sw * 0.5 - 300, sh - 116, 600, 76, Color( 0, 0, 0, 175 ) )
		draw.SimpleText( title, "mc_hud", sw * 0.5, sh - 94, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		draw.SimpleText( hint, "mc_hud_small", sw * 0.5, sh - 66, Color( 225, 235, 248, 230 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		draw.SimpleText( infoLine, "mc_hud_small", sw * 0.5, sh - 46, Color( 180, 200, 220, 190 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )

		surface.SetDrawColor( 255, 255, 255, 220 )
		surface.DrawRect( sw * 0.5 - 1, sh * 0.5 - 1, 2, 2 )
	end
end
