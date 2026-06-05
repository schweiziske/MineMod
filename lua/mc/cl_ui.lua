--[[----------------------------------------------------------------------------
	MC : client UI helpers (block icons, palette picker, fonts)
------------------------------------------------------------------------------]]

MC = MC or {}

surface.CreateFont( "mc_hud", { font = "Roboto", size = 22, weight = 600 } )
surface.CreateFont( "mc_hud_small", { font = "Roboto", size = 16, weight = 500 } )

-- draw an atlas tile as a 2D rect
function MC.DrawTile( tile, x, y, w, h )
	local u0, v0, u1, v1 = MC.TileUV( tile )
	surface.SetMaterial( MC.Material )
	surface.SetDrawColor( 255, 255, 255, 255 )
	surface.DrawTexturedRectUV( x, y, w, h, u0, v0, u1, v1 )
end

-- draw a block's representative (side) icon
function MC.DrawBlockIcon( id, x, y, w, h )
	local b = MC.Blocks[id]
	if not b then return end
	MC.DrawTile( b.side, x, y, w, h )
end

-- popup grid of all blocks; onSelect( id ) fires on click
function MC.OpenPalette( onSelect )
	if IsValid( MC.PaletteFrame ) then MC.PaletteFrame:Remove() end

	local fr = vgui.Create( "DFrame" )
	fr:SetTitle( "选择方块  (Minecraft Blocks)" )
	fr:SetSize( 560, 360 )
	fr:Center()
	fr:MakePopup()
	MC.PaletteFrame = fr

	local scroll = vgui.Create( "DScrollPanel", fr )
	scroll:Dock( FILL )

	local layout = vgui.Create( "DIconLayout", scroll )
	layout:Dock( FILL )
	layout:SetSpaceX( 6 )
	layout:SetSpaceY( 6 )

	for _, id in ipairs( MC.BlockList ) do
		local b = MC.Blocks[id]
		local btn = layout:Add( "DButton" )
		btn:SetSize( 76, 92 )
		btn:SetText( "" )
		btn.Paint = function( s, w, h )
			draw.RoundedBox( 4, 0, 0, w, h, s:IsHovered() and Color( 80, 90, 110 ) or Color( 45, 47, 52 ) )
			MC.DrawBlockIcon( id, w * 0.5 - 28, 6, 56, 56 )
			draw.SimpleText( b.disp, "mc_hud_small", w * 0.5, h - 16, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		end
		btn.DoClick = function()
			surface.PlaySound( "ui/buttonclickrelease.wav" )
			onSelect( id )
			fr:Close()
		end
	end
end