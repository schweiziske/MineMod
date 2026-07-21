-- Client HUD for identifying entries in the Minecraft-style debug gallery.

MC = MC or {}

local GLOBAL_DESCRIPTOR = "mc_debug_gallery"
local LastRawDescriptor
local Descriptor
local LastAim

local Enabled = CreateClientConVar( "mc_debug_gallery_hud", "1", true, false,
	"Show block/state identity while aiming at an MC debug gallery entry" )
local AimDistance = CreateClientConVar( "mc_debug_gallery_aim_distance", "4096", true, false,
	"Maximum world-unit distance for the MC debug gallery inspector" )

local function updateDescriptor()
	local raw = GetGlobalString( GLOBAL_DESCRIPTOR, "" )
	if raw == LastRawDescriptor then return end
	LastRawDescriptor = raw
	Descriptor = raw ~= "" and util.JSONToTable( raw ) or nil
	MC.DebugGalleryClientDescriptor = Descriptor
end

timer.Create( "mc_debug_gallery_descriptor", 0.25, 0, updateDescriptor )
timer.Simple( 0, updateDescriptor )

local function aimedEntry()
	if not Descriptor then return nil end
	local ply = LocalPlayer()
	if not IsValid( ply ) then return nil end
	local hit = MC.TraceBlockRay and MC.TraceBlockRay(
		ply:EyePos(), ply:EyeAngles():Forward(), math.max( MC.BS * 4, AimDistance:GetFloat() )
	) or nil
	if not hit or not hit.bx then return nil end
	local index, aimedAtBase, layer = MC.DebugGalleryIndexAtCell( Descriptor, hit.bx, hit.by, hit.bz )
	if not index then return nil end
	local expectedStateId = MC.DebugGalleryEntryState( Descriptor, index )
	if expectedStateId == nil then return nil end
	local bx, by, bz = MC.DebugGalleryCell( Descriptor, index, false )
	local actualStateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or nil
	return {
		index = index,
		layer = layer or 0,
		aimedAtBase = aimedAtBase,
		expectedStateId = expectedStateId,
		actualStateId = actualStateId,
		bx = bx, by = by, bz = bz,
	}
end

local function splitStateText( stateId )
	local formatted = MC.FormatBlockState and MC.FormatBlockState( stateId ) or tostring( stateId )
	formatted = formatted or tostring( stateId )
	local name, properties = string.match( formatted, "^([^%[]+)%[(.*)%]$" )
	return name or formatted, properties
end

local function stateInfo( aim )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( aim.expectedStateId ) or nil
	local block = schema and schema.blockId and MC.Blocks and MC.Blocks[schema.blockId] or nil
	local name, properties = splitStateText( aim.expectedStateId )
	return schema, block, name, properties
end

local function wrappedPropertyLines( text, maxCharacters )
	if not text or text == "" then return {} end
	local lines = {}
	local current = ""
	for part in string.gmatch( text, "[^,]+" ) do
		local candidate = current == "" and part or ( current .. ", " .. part )
		if current ~= "" and #candidate > maxCharacters then
			lines[#lines + 1] = current
			current = part
		else
			current = candidate
		end
	end
	if current ~= "" then lines[#lines + 1] = current end
	return lines
end

hook.Add( "HUDPaint", "mc_debug_gallery_hud", function()
	if not Enabled:GetBool() or not Descriptor then LastAim = nil return end
	local aim = aimedEntry()
	LastAim = aim
	if not aim then return end
	local schema, block, name, properties = stateInfo( aim )
	local progress = math.floor( math.Clamp( tonumber( Descriptor.progress ) or 0, 0, 1 ) * 100 )
	local status = Descriptor.status == "ready" and "可审核"
		or Descriptor.status == "building" and ( "生成中 " .. progress .. "%" )
		or Descriptor.status == "clearing" and ( "清理中 " .. progress .. "%" )
		or tostring( Descriptor.status or "?" )
	local title = string.format( "调试展台 #%d / %d  ·  第 %d / %d 层  ·  %s",
		aim.index, Descriptor.count or 0, aim.layer + 1, Descriptor.layers or 1, status )
	local display = block and ( block.disp or block.name ) or name
	local lines = {
		title,
		tostring( display or name ),
		name,
	}
	for _, line in ipairs( wrappedPropertyLines( properties, 78 ) ) do lines[#lines + 1] = line end
	lines[#lines + 1] = string.format( "block id: %s    state id: %d    cell: %d %d %d",
		tostring( schema and schema.blockId or "?" ), aim.expectedStateId, aim.bx, aim.by, aim.bz )
	lines[#lines + 1] = "控制台输入 mc_debug_gallery_copy 可复制完整标识"
	if aim.actualStateId ~= aim.expectedStateId then
		lines[#lines + 1] = string.format( "警告：该位置实际 state id=%s，与展台预期不一致", tostring( aim.actualStateId ) )
	end

	surface.SetFont( "mc_debug" )
	local lineHeight = select( 2, surface.GetTextSize( "Ag" ) )
	local maxWidth = 0
	for _, line in ipairs( lines ) do maxWidth = math.max( maxWidth, surface.GetTextSize( line ) ) end
	local padding = 10
	local width = maxWidth + padding * 2
	local height = #lines * lineHeight + padding * 2
	local x = ScrW() - width - 18
	local y = 18
	draw.RoundedBox( 4, x, y, width, height, Color( 0, 0, 0, 205 ) )
	for index, line in ipairs( lines ) do
		local color = index == 1 and Color( 120, 235, 140 )
			or ( string.StartWith( line, "警告" ) and Color( 255, 180, 80 ) or color_white )
		draw.SimpleText( line, "mc_debug", x + padding, y + padding + ( index - 1 ) * lineHeight, color )
	end
end )

local function copyAimedState( printOnly )
	local aim = LastAim or aimedEntry()
	if not aim then
		chat.AddText( Color( 255, 180, 80 ), "[MC] 准星没有指向调试展台条目。" )
		return
	end
	local formatted = MC.FormatBlockState and MC.FormatBlockState( aim.expectedStateId ) or tostring( aim.expectedStateId )
	local report = string.format( "#%d layer=%d %s @ %d %d %d (state=%d)",
		aim.index, aim.layer + 1, tostring( formatted ), aim.bx, aim.by, aim.bz, aim.expectedStateId )
	if not printOnly and SetClipboardText then SetClipboardText( report ) end
	print( "[MC debug gallery] " .. report )
	chat.AddText( Color( 120, 235, 140 ), "[MC] ", color_white,
		printOnly and report or ( "已复制: " .. report ) )
end

concommand.Add( "mc_debug_gallery_copy", function() copyAimedState( false ) end )
concommand.Add( "mc_debug_gallery_info", function() copyAimedState( true ) end )
