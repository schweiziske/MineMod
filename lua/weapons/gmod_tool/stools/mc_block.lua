--[[----------------------------------------------------------------------------
	mc_block : Sandbox toolgun front-end.
	  Left   = break aimed block
	  Right  = place selected block
	  Reload = copy aimed block into selection
------------------------------------------------------------------------------]]

TOOL.Category = "Construction"
TOOL.Name     = "#tool.mc_block.name"

TOOL.ClientConVar["block"] = "1"

if CLIENT then
	language.Add( "tool.mc_block.name", "MC 方块" )
	language.Add( "tool.mc_block.desc", "放置 / 破坏 Minecraft 方块（IMesh 渲染，不生成实体）" )
	language.Add( "tool.mc_block.0", "左键破坏   右键放置   Reload 复制方块" )
end

local function placeCell( tr )
	return MC.WorldToCell( tr.HitPos + tr.HitNormal * 0.5 )
end

local function breakCell( tr )
	return MC.WorldToCell( tr.HitPos - tr.HitNormal * 0.5 )
end

local function selectedID( self )
	local id = math.floor( self:GetClientNumber( "block", 1 ) )
	return MC.IsValidBlock( id ) and id or 1
end

function TOOL:LeftClick( tr )
	if CLIENT then return true end
	local ply = self:GetOwner()
	local bx, by, bz = breakCell( tr )
	MC.SV.Break( ply, bx, by, bz )
	return true
end

function TOOL:RightClick( tr )
	if CLIENT then return true end
	local ply = self:GetOwner()
	local ux, uy, uz = breakCell( tr )
	if MC.SV.Use( ply, ux, uy, uz ) then return true end

	local id = selectedID( self )
	local bx, by, bz = placeCell( tr )
	MC.SV.Place( ply, bx, by, bz, id, MC.OrientForPlacement( ply, tr, id ) )
	return true
end

function TOOL:Reload( tr )
	if CLIENT then return true end
	local ply = self:GetOwner()
	local bx, by, bz = breakCell( tr )
	local id = MC.GetBlock( bx, by, bz )
	if id ~= 0 then
		ply:ConCommand( "mc_block_block " .. id )
	end
	return true
end

if CLIENT then
	function TOOL:DrawHUD()
		local ply = LocalPlayer()
		if not IsValid( ply ) then return end

		local tr = ply:GetEyeTrace()
		if not tr.Hit then return end

		local id = selectedID( self )
		local bx, by, bz = placeCell( tr )
		if not MC.CanPreviewPlace( ply, bx, by, bz ) then return end

		local orient = MC.OrientForPlacement( ply, tr, id )
		local state = MC.BlockStateText( id, orient )
		if state == "" then return end

		draw.SimpleText( state, "mc_hud_small", ScrW() * 0.5, ScrH() * 0.5 + 24, Color( 210, 230, 255 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP )
	end

	hook.Add( "PostDrawTranslucentRenderables", "mc_tool_ghost", function( _, bSky, bSky3D )
		if bSky or bSky3D then return end
		local ply = LocalPlayer()
		if not IsValid( ply ) or not ply:Alive() then return end
		local wep = ply:GetActiveWeapon()
		if not IsValid( wep ) or wep:GetClass() ~= "gmod_tool" then return end
		local mode = GetConVar( "gmod_toolmode" )
		if not mode or mode:GetString() ~= "mc_block" then return end

		local tr = ply:GetEyeTrace()
		if not tr.Hit then return end

		local bx, by, bz = placeCell( tr )
		if not MC.CanPreviewPlace( ply, bx, by, bz ) then return end

		local cv = GetConVar( "mc_block_block" )
		local id = cv and math.floor( cv:GetInt() ) or 1
		if not MC.IsValidBlock( id ) then id = 1 end
		local orient = MC.OrientForPlacement( ply, tr, id )
		MC.DrawBlockGhost( id, orient, bx, by, bz, Color( 255, 255, 255, 230 ) )
	end )
end

function TOOL.BuildCPanel( panel )
	panel:Help( "左键破坏 / 右键放置 / Reload 复制方块。/fill 支持 blockstate，例如 minecraft:furnace[facing=north]。" )

	local scroll = vgui.Create( "DScrollPanel" )
	scroll:SetTall( 360 )

	local layout = vgui.Create( "DIconLayout", scroll )
	layout:Dock( FILL )
	layout:SetSpaceX( 4 )
	layout:SetSpaceY( 4 )

	for _, id in ipairs( MC.BlockList ) do
		local b = MC.Blocks[id]
		local btn = layout:Add( "DButton" )
		btn:SetSize( 58, 72 )
		btn:SetText( "" )
		local hint = MC.BlockStateHint( id )
		btn:SetTooltip( b.disp .. ( hint ~= "" and "\n" .. hint or "" ) )
		btn.Paint = function( s, w, h )
			local cv = GetConVar( "mc_block_block" )
			local sel = cv and math.floor( cv:GetInt() ) == id
			draw.RoundedBox( 4, 0, 0, w, h, sel and Color( 70, 130, 80 ) or ( s:IsHovered() and Color( 70, 72, 80 ) or Color( 45, 47, 52 ) ) )
			MC.DrawBlockIcon( id, w * 0.5 - 20, 4, 40, 40 )
			draw.SimpleText( b.disp, "mc_hud_small", w * 0.5, h - 12, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		end
		btn.DoClick = function()
			RunConsoleCommand( "mc_block_block", id )
			surface.PlaySound( "ui/buttonclickrelease.wav" )
		end
	end

	panel:AddItem( scroll )
end
