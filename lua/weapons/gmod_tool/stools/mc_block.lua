--[[----------------------------------------------------------------------------
	mc_block : Sandbox toolgun front-end.
	  Left  = break aimed block
	  Right = place selected block
	  Reload= copy aimed block into selection
------------------------------------------------------------------------------]]

TOOL.Category = "Construction"
TOOL.Name     = "#tool.mc_block.name"

TOOL.ClientConVar["block"] = "1"

if CLIENT then
	language.Add( "tool.mc_block.name", "MC 方块" )
	language.Add( "tool.mc_block.desc", "放置/破坏 Minecraft 方块（IMesh 渲染，不生成实体）" )
	language.Add( "tool.mc_block.0", "左键破坏   右键放置   Reload 复制方块" )
end

local function placeCell( tr )
	return MC.WorldToCell( tr.HitPos + tr.HitNormal * 0.5 )
end
local function breakCell( tr )
	return MC.WorldToCell( tr.HitPos - tr.HitNormal * 0.5 )
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
	local id = math.floor( self:GetClientNumber( "block", 1 ) )
	local bx, by, bz = placeCell( tr )
	MC.SV.Place( ply, bx, by, bz, id )
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

function TOOL.BuildCPanel( panel )
	panel:Help( "左键破坏 / 右键放置 / Reload 复制方块。\n方块用 IMesh 渲染，每个 16³ 区块只有 1 个碰撞实体，不会卡。" )

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
		btn:SetTooltip( b.disp )
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