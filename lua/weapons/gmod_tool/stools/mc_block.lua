--[[----------------------------------------------------------------------------
	mc_block : Sandbox toolgun front-end.
	  Left   = break aimed block
	  Right  = place selected block
	  Reload = copy aimed block into selection
------------------------------------------------------------------------------]]

TOOL.Category = "Construction"
TOOL.Name     = "#tool.mc_block.name"

TOOL.ClientConVar["block"] = "1"

local function L( key, fallback, vars )
	return MC and MC.T and MC.T( key, fallback, vars ) or fallback
end

local function blockDisplayText( blockOrID )
	local b = type( blockOrID ) == "table" and blockOrID or ( MC and MC.Blocks and MC.Blocks[blockOrID] )
	if not b then return "" end
	return MC.BlockDisplayName and MC.BlockDisplayName( b, b.dispZH or b.disp ) or b.disp
end

if CLIENT then
	if MC and MC.LocalizeToolLanguage then MC.LocalizeToolLanguage() end
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

local function selectedID( self )
	local id = math.floor( self:GetClientNumber( "block", 1 ) )
	return MC.IsValidBlock( id ) and id or 1
end

local function blockHasUse( id )
	local b = MC.Blocks and MC.Blocks[id]
	return b and b.handlers and b.handlers.OnUse ~= nil
end

local function placeTarget( ply, aim, tr, id, avoidUseBlocks )
	if not tr or not tr.Hit then return nil end
	if avoidUseBlocks and aim and blockHasUse( aim.Block ) then return nil end

	local bx, by, bz
	if aim then
		bx = aim.bx + math.Round( aim.HitNormal.x )
		by = aim.by + math.Round( aim.HitNormal.y )
		bz = aim.bz + math.Round( aim.HitNormal.z )
		tr = aim
	else
		bx, by, bz = placeCell( tr )
	end

	tr.MCBlockX, tr.MCBlockY, tr.MCBlockZ = bx, by, bz
	return bx, by, bz, MC.OrientForPlacement( ply, tr, id )
end

local function breakTarget( aim, tr )
	if aim then return aim.bx, aim.by, aim.bz end
	if not tr or not tr.Hit then return nil end
	return breakCell( tr )
end

function TOOL:LeftClick( tr )
	local ply = self:GetOwner()
	local aim = aimedBlock( ply )

	if CLIENT then
		if IsFirstTimePredicted() and ply == LocalPlayer() then
			local bx, by, bz = breakTarget( aim, tr )
			if bx and MC.CanPreviewBreak and MC.CanPreviewBreak( ply, bx, by, bz ) and MC.PredictBreakBlock then
				MC.PredictBreakBlock( bx, by, bz, ply )
			end
		end
		return true
	end

	local bx, by, bz = breakTarget( aim, tr )
	if not bx then return true end
	if not MC.SV.Break( ply, bx, by, bz ) and MC.SV.SyncBreakPlan then
		MC.SV.SyncBreakPlan( ply, bx, by, bz )
	end
	return true
end

function TOOL:RightClick( tr )
	local ply = self:GetOwner()
	local aim = aimedBlock( ply )
	local id = selectedID( self )

	if CLIENT then
		if not IsFirstTimePredicted() or ply ~= LocalPlayer() then return true end
		local bx, by, bz, orient = placeTarget( ply, aim, tr, id, true )
		local plan = bx and MC.BuildPlacementPlan and MC.BuildPlacementPlan( bx, by, bz, id, orient )
		if plan and MC.CanPreviewPlacePlan and MC.CanPreviewPlacePlan( ply, plan ) and MC.PredictSetBlock then
			MC.PredictSetBlock( bx, by, bz, id, orient )
		end
		return true
	end

	local ux, uy, uz
	if aim then
		ux, uy, uz = aim.bx, aim.by, aim.bz
	else
		ux, uy, uz = breakCell( tr )
	end
	if MC.SV.Use( ply, ux, uy, uz ) then return true end

	local bx, by, bz, orient = placeTarget( ply, aim, tr, id )
	if bx and not MC.SV.Place( ply, bx, by, bz, id, orient ) and MC.SV.SyncPlacementPlan then
		MC.SV.SyncPlacementPlan( ply, bx, by, bz, id, orient )
	end
	return true
end

function TOOL:Reload( tr )
	if CLIENT then return true end
	local ply = self:GetOwner()
	local aim = aimedBlock( ply )
	local bx, by, bz
	if aim then
		bx, by, bz = aim.bx, aim.by, aim.bz
	else
		bx, by, bz = breakCell( tr )
	end
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

		local tr = aimedBlock( ply ) or ply:GetEyeTrace()
		if not tr.Hit then return end

		local id = selectedID( self )
		local bx, by, bz = placeCell( tr )

		local orient = MC.OrientForPlacement( ply, tr, id )
		local plan = MC.BuildPlacementPlan and MC.BuildPlacementPlan( bx, by, bz, id, orient )
		if not plan or not MC.CanPreviewPlacePlan or not MC.CanPreviewPlacePlan( ply, plan ) then return end
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

		local aim = aimedBlock( ply )
		if not aim then return end
		MC.DrawBlockOutline( aim.Block, aim.Orient, aim.bx, aim.by, aim.bz, Color( 0, 0, 0, 235 ) )
	end )
end

function TOOL.BuildCPanel( panel )
	panel:Help( L( "tool.help", "左键破坏 / 右键放置 / Reload 复制方块。/fill 支持 blockstate，例如 minecraft:furnace[facing=north]。" ) )

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
		btn:SetTooltip( blockDisplayText( b ) .. ( hint ~= "" and "\n" .. hint or "" ) )
		btn.Paint = function( s, w, h )
			local cv = GetConVar( "mc_block_block" )
			local sel = cv and math.floor( cv:GetInt() ) == id
			draw.RoundedBox( 4, 0, 0, w, h, sel and Color( 70, 130, 80 ) or ( s:IsHovered() and Color( 70, 72, 80 ) or Color( 45, 47, 52 ) ) )
			MC.DrawBlockIcon( id, w * 0.5 - 20, 4, 40, 40 )
			draw.SimpleText( blockDisplayText( b ), "mc_hud_small", w * 0.5, h - 12, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		end
		btn.DoClick = function()
			RunConsoleCommand( "mc_block_block", id )
		end
	end

	panel:AddItem( scroll )
end
