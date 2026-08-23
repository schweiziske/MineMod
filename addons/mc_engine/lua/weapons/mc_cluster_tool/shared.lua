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

-- Admin build tool: right-click is a deliberate cluster gesture, not "interact".
-- Opt out of the weapon-agnostic block-use fallback in sv_world.lua.
SWEP.MCOwnsBlockInteraction = true

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

-- Spawn menu icon: materials/entities/mc_cluster_tool.png (auto-detected).
-- Weapon-selection HUD stays on the engine default deliberately.
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

	if MC.ClusterSelectMode == "box" or MC.ClusterSelectMode == "crate" then
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

	if ( MC.ClusterSelectMode == "box" or MC.ClusterSelectMode == "crate" ) and MC.ClusterBoxCorner then
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

function SWEP:ClusterActionClient( action )
	if not CLIENT then return end
	local owner = self:GetOwner()
	if not IsValid( owner ) or owner ~= LocalPlayer() then return end
	local now = CurTime()
	local cooldown = action == "flood" and 0.3 or 0.2
	if ( self.mcNextClientClusterAction or 0 ) > now then return end
	self.mcNextClientClusterAction = now + cooldown

	if action == "convert" then
		local aimedCluster = MC.ClusterAimedCluster and MC.ClusterAimedCluster() or nil
		if IsValid( aimedCluster ) then
			if MC.ClusterSendPaste then MC.ClusterSendPaste( aimedCluster ) end
		elseif MC.ClusterSendConvert then
			MC.ClusterSendConvert()
		end
	elseif action == "clear" then
		if MC.ClusterSelectionCount and MC.ClusterSelectionCount() > 0 and MC.ClusterSelectionClear then
			MC.ClusterSelectionClear()
		end
	elseif action == "flood" then
		if MC.ClusterSelectMode == "crate" then
			clientChat( L( "weapon.mc_cluster_tool.crate_no_flood", "箱体模式只支持框选" ) )
			return
		end
		local aim = aimedBlock()
		if aim and MC.ClusterFloodSelect then
			MC.ClusterFloodSelect( aim.bx, aim.by, aim.bz )
		else
			clientChat( L( "weapon.mc_cluster_tool.aim_block", "请准星对准一个 MC 方块" ) )
		end
	end
end

local MODE_CYCLE = { fine = "box", box = "crate", crate = "fine" }

function SWEP:ToggleModeClient()
	if not CLIENT then return end
	local owner = self:GetOwner()
	if not IsValid( owner ) or owner ~= LocalPlayer() then return end

	local prev = MC.ClusterSelectMode or "fine"
	local nextMode = MODE_CYCLE[prev] or "fine"
	-- the selection survives mode switches; crate mode only changes HOW the
	-- conversion collides (single box), not what is selected
	MC.ClusterSelectMode = nextMode

	if nextMode == "box" then
		clientChat( L( "weapon.mc_cluster_tool.mode_box", "已切换到框选模式" ) )
	elseif nextMode == "crate" then
		clientChat( L( "weapon.mc_cluster_tool.mode_crate", "已切换到箱体模式 (碰撞为整箱, 适合大结构)" ) )
	else
		clientChat( L( "weapon.mc_cluster_tool.mode_fine", "已切换到细选模式" ) )
	end
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

function SWEP:Think()
	if not SERVER or not game.SinglePlayer() then return end
	local owner = self:GetOwner()
	if not IsValid( owner ) or owner:GetActiveWeapon() ~= self then return end
	if owner:KeyPressed( IN_USE ) then self:CallOnClient( "ClusterActionClient", "flood" ) end
end

if SERVER then
	-- Some single-player input paths run only on the server. The client retains
	-- its handlers below as a fallback; ClusterActionClient coalesces duplicates.
	hook.Add( "PlayerButtonDown", "mc_cluster_tool_singleplayer_keys", function( ply, button )
		if not game.SinglePlayer() or not IsValid( ply ) then return end
		local wep = ply:GetActiveWeapon()
		if not IsValid( wep ) or wep:GetClass() ~= "mc_cluster_tool" then return end
		if button ~= KEY_G and button ~= KEY_X then return end
		if ( wep.mcNextSinglePlayerAction or 0 ) > CurTime() then return end
		wep.mcNextSinglePlayerAction = CurTime() + 0.2
		wep:CallOnClient( "ClusterActionClient", button == KEY_G and "convert" or "clear" )
	end )
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

	hook.Add( "PlayerButtonDown", "mc_cluster_tool_keys", function( ply, button )
		if not IsValid( ply ) or ply ~= LocalPlayer() then return end
		if not activeClusterTool( ply ) or textEntryHasFocus() then return end

		if button == KEY_G then
			ply:GetActiveWeapon():ClusterActionClient( "convert" )
		elseif button == KEY_X then
			ply:GetActiveWeapon():ClusterActionClient( "clear" )
		end
	end )

	hook.Add( "PlayerBindPress", "mc_cluster_tool_flood", function( ply, bind, pressed )
		if not pressed or not IsValid( ply ) or ply ~= LocalPlayer() then return end
		if not activeClusterTool( ply ) or textEntryHasFocus() then return end

		local lower = string.lower( tostring( bind or "" ) )
		if lower == "+use" then
			ply:GetActiveWeapon():ClusterActionClient( "flood" )
			return true
		end
	end )

	------------------------------------------------------------------ HUD
	local COL_PANEL = Color( 12, 14, 18, 185 )
	local COL_ACCENT = Color( 80, 190, 255 )
	local COL_ACCENT_CRATE = Color( 255, 200, 90 )
	local COL_TEXT = Color( 235, 240, 248 )
	local COL_DIM = Color( 155, 170, 190, 225 )
	local COL_KEY_BG = Color( 42, 48, 60, 235 )
	local COL_OK = Color( 110, 235, 140 )
	local COL_BAD = Color( 255, 110, 100 )
	local COL_TRACK = Color( 255, 255, 255, 24 )

	-- [key] label chip; returns the x where the next chip starts
	local function drawKeyChip( x, y, keyText, label, labelColor )
		surface.SetFont( "mc_hud_small" )
		local kw = surface.GetTextSize( keyText )
		local keyW = kw + 12
		draw.RoundedBox( 4, x, y, keyW, 20, COL_KEY_BG )
		draw.SimpleText( keyText, "mc_hud_small", x + keyW * 0.5, y + 10, COL_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		local nx = x + keyW
		if label and label ~= "" then
			draw.SimpleText( label, "mc_hud_small", nx + 5, y + 10, labelColor or COL_DIM, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
			local lw = surface.GetTextSize( label )
			nx = nx + 5 + lw
		end
		return nx + 14
	end

	local function drawChipRow( x, y, chips )
		for _, chip in ipairs( chips ) do
			x = drawKeyChip( x, y, chip[1], chip[2], chip[3] )
		end
	end

	local function drawBar( x, y, w, h, frac, col )
		draw.RoundedBox( h * 0.5, x, y, w, h, COL_TRACK )
		frac = math.Clamp( frac or 0, 0, 1 )
		if frac > 0 then
			draw.RoundedBox( h * 0.5, x, y, math.max( h, math.floor( w * frac ) ), h, col )
		end
	end

	-- segmented mode selector; returns the x after the last tab
	local function drawModeTabs( x, y, mode )
		local tabs = {
			{ id = "fine", label = L( "weapon.mc_cluster_tool.ui_tab_fine", "细选" ) },
			{ id = "box", label = L( "weapon.mc_cluster_tool.ui_tab_box", "框选" ) },
			{ id = "crate", label = L( "weapon.mc_cluster_tool.ui_tab_crate", "箱体" ) },
		}
		local tw, th, gap = 76, 22, 4
		for i, tab in ipairs( tabs ) do
			local tx = x + ( i - 1 ) * ( tw + gap )
			local active = mode == tab.id
			local accent = tab.id == "crate" and COL_ACCENT_CRATE or COL_ACCENT
			draw.RoundedBox( 4, tx, y, tw, th,
				active and Color( accent.r, accent.g, accent.b, 65 ) or Color( 255, 255, 255, 13 ) )
			if active then
				draw.RoundedBox( 2, tx + 3, y + th - 3, tw - 6, 3, accent )
			end
			draw.SimpleText( tab.label, "mc_hud_small", tx + tw * 0.5, y + th * 0.5 - 1,
				active and COL_TEXT or COL_DIM, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		end
		return x + 3 * ( tw + gap )
	end

	function SWEP:DrawHUD()
		local sw, sh = ScrW(), ScrH()
		local mode = MC.ClusterSelectMode or "fine"
		local count = MC.ClusterSelectionCount and MC.ClusterSelectionCount() or 0
		local maxBlocks = MC.ClusterMaxBlocks and MC.ClusterMaxBlocks() or 4096
		local aimedCluster = MC.ClusterAimedCluster and MC.ClusterAimedCluster() or nil
		local ghost = IsValid( aimedCluster ) and MC.ClusterPasteGhost and MC.ClusterPasteGhost( aimedCluster ) or nil

		local panelW, panelH = 640, 104
		local x0 = math.floor( sw * 0.5 - panelW * 0.5 )
		local y0 = sh - panelH - 34
		local pad = 14
		local rowY1, rowY2, rowY3 = y0 + 12, y0 + 46, y0 + 72

		-- accent strip mirrors the 3D ghost color when aiming at a structure
		local accent = COL_ACCENT
		if IsValid( aimedCluster ) then
			accent = ( ghost and not ghost.tilted and ( ghost.blocked or 0 ) == 0 ) and COL_OK or COL_BAD
		elseif mode == "crate" then
			accent = COL_ACCENT_CRATE
		end

		draw.RoundedBox( 8, x0, y0, panelW, panelH, COL_PANEL )
		surface.SetDrawColor( accent.r, accent.g, accent.b, 235 )
		surface.DrawRect( x0 + 8, y0, panelW - 16, 2 )

		if IsValid( aimedCluster ) then
			-- entity card: what it is / how healthy / can it go back
			local blocks = aimedCluster.GetBlockCount and aimedCluster:GetBlockCount() or 0
			draw.SimpleText(
				L( "weapon.mc_cluster_tool.ui_structure", "方块结构" ) .. " · "
					.. L( "weapon.mc_cluster_tool.ui_blocks", "{n} 方块", { n = blocks } ),
				"mc_hud", x0 + pad, rowY1 + 4, COL_TEXT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
			local owner = aimedCluster.GetOwnerLabel and aimedCluster:GetOwnerLabel() or ""
			if owner ~= "" then
				draw.SimpleText( L( "weapon.mc_cluster_tool.owner", "主人 {name}", { name = owner } ),
					"mc_hud_small", x0 + panelW - pad, rowY1 + 4, COL_DIM, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER )
			end

			local maxHP = aimedCluster.GetClusterMaxHP and aimedCluster:GetClusterMaxHP() or 0
			local durLabel = L( "weapon.mc_cluster_tool.ui_durability", "耐久" )
			draw.SimpleText( durLabel, "mc_hud_small", x0 + pad, rowY2 + 3, COL_DIM, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
			surface.SetFont( "mc_hud_small" )
			local durLabelW = surface.GetTextSize( durLabel )
			local barX = x0 + pad + durLabelW + 10
			if maxHP > 0 then
				local hp = math.max( 0, aimedCluster:Health() )
				local frac = hp / maxHP
				local barCol = frac > 0.66 and COL_OK or frac > 0.33 and COL_ACCENT_CRATE or COL_BAD
				drawBar( barX, rowY2, panelW - ( barX - x0 ) - pad - 110, 7, frac, barCol )
				draw.SimpleText( hp .. " / " .. maxHP, "mc_hud_small", x0 + panelW - pad, rowY2 + 3,
					COL_DIM, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER )
			else
				draw.SimpleText( L( "weapon.mc_cluster_tool.durability_inf", "耐久 无敌" ), "mc_hud_small",
					barX, rowY2 + 3, COL_DIM, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
			end

			local status, statusCol
			if ghost and ghost.tilted then
				status = L( "weapon.mc_cluster_tool.ui_paste_tilted", "先用物理枪放平" )
				statusCol = COL_BAD
			elseif ghost and ( ghost.blocked or 0 ) > 0 then
				status = L( "weapon.mc_cluster_tool.ui_paste_blocked", "有 {n} 格被占用", { n = ghost.blocked } )
				statusCol = COL_BAD
			else
				status = L( "weapon.mc_cluster_tool.ui_paste_ok", "可放回" )
				statusCol = COL_OK
			end
			local nextX = drawKeyChip( x0 + pad, rowY3, "G",
				L( "weapon.mc_cluster_tool.ui_paste", "放回网格" ), COL_TEXT )
			draw.SimpleText( status, "mc_hud_small", nextX, rowY3 + 10, statusCol, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
		else
			-- selection panel: mode tabs + fill bar + context keybinds
			local afterTabs = drawModeTabs( x0 + pad, rowY1, mode )
			drawKeyChip( afterTabs + 4, rowY1 + 1, "R", L( "weapon.mc_cluster_tool.ui_cycle", "切换模式" ) )
			local nearFull = maxBlocks > 0 and count / maxBlocks > 0.9
			draw.SimpleText( count .. " / " .. maxBlocks, "mc_hud_small", x0 + panelW - pad, rowY1 + 11,
				nearFull and COL_ACCENT_CRATE or COL_DIM, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER )

			drawBar( x0 + pad, rowY2 + 2, panelW - pad * 2, 5, maxBlocks > 0 and count / maxBlocks or 0,
				mode == "crate" and COL_ACCENT_CRATE or COL_ACCENT )

			local chips = {}
			local LMB = L( "weapon.mc_cluster_tool.ui_key_lmb", "左键" )
			local RMB = L( "weapon.mc_cluster_tool.ui_key_rmb", "右键" )
			if mode == "fine" then
				chips[#chips + 1] = { LMB, L( "weapon.mc_cluster_tool.ui_add", "加选" ) }
				chips[#chips + 1] = { RMB, L( "weapon.mc_cluster_tool.ui_remove", "减选" ) }
				chips[#chips + 1] = { "E", L( "weapon.mc_cluster_tool.ui_flood", "连通选择" ) }
			elseif MC.ClusterBoxCorner then
				chips[#chips + 1] = { LMB, L( "weapon.mc_cluster_tool.ui_corner_b", "选对角" ) }
				chips[#chips + 1] = { RMB, L( "weapon.mc_cluster_tool.ui_corner_cancel", "取消角点" ) }
			else
				chips[#chips + 1] = { LMB, L( "weapon.mc_cluster_tool.ui_corner_a", "选第一角点" ) }
			end
			if count > 0 then
				chips[#chips + 1] = { "G", mode == "crate"
					and L( "weapon.mc_cluster_tool.ui_convert_crate", "转换(整箱)" )
					or L( "weapon.mc_cluster_tool.ui_convert", "转换" ), COL_TEXT }
				chips[#chips + 1] = { "X", L( "weapon.mc_cluster_tool.ui_clear", "清空" ) }
			end
			drawChipRow( x0 + pad, rowY3, chips )
		end

		surface.SetDrawColor( 255, 255, 255, 220 )
		surface.DrawRect( sw * 0.5 - 1, sh * 0.5 - 1, 2, 2 )
	end
end
