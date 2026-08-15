-- Client enchanting-table state, option request helper and the animated
-- block-entity book. Inventory stacks remain on the ordinary authoritative
-- inventory transport; this file never constructs an enchanted result.

if not CLIENT then return end

MC = MC or {}

local STATE_VERSION = 1
local API = MC.API or {}
local World = API.World or {}
local Blocks = API.Blocks or {}
local Coords = API.Coords or {}
local Light = API.Light or {}
local I18n = API.I18n or {}
local BLOCK_ENTITY_TYPE = "minecraft:enchanting_table"
local resolvedTable = type( Blocks.Resolve ) == "function" and Blocks.Resolve( "minecraft:enchanting_table" ) or nil
local ENCHANTING_TABLE_BLOCK_ID = resolvedTable and resolvedTable.id or nil
local BS = type( Coords.BlockSize ) == "function" and tonumber( Coords.BlockSize() ) or 36.5
local MODEL_SCALE = BS / 16
local UP = Vector( 0, 0, 1 )
local MAX_RENDER_DISTANCE_SQR = ( BS * 64 ) ^ 2
local PLAYER_RANGE_SQR = ( BS * 3 ) ^ 2
local BOOK_MATERIAL = Material( "mc/entity/enchantment/enchanting_table_book.png",
	"alphatest vertexcolor vertexalpha nocull" )

local function emit( eventName, ... )
	if hook and hook.Run then hook.Run( eventName, ... ) end
end

net.Receive( "mc_enchanting_state", function()
	local version = net.ReadUInt( 8 )
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local revision = net.ReadUInt( 32 )
	local bookshelfCount = net.ReadUInt( 4 )
	local options, decodeError = {}, nil
	for optionIndex = 0, 2 do
		local cost = net.ReadUInt( 32 )
		local clue = net.ReadString()
		local clueLevel = net.ReadUInt( 8 )
		local available = net.ReadBool()
		local errorCode = net.ReadString()
		if #clue > 128 or #errorCode > 96 then decodeError = "invalid_enchanting_state" end
		options[optionIndex + 1] = {
			index = optionIndex,
			cost = cost,
			lapisCost = optionIndex + 1,
			clue = clue ~= "" and clue or nil,
			clueLevel = clueLevel,
			available = available,
			error = errorCode ~= "" and errorCode or nil,
		}
	end
	local state = MC.ClientInventory
	local session = state and state.session
	if version ~= STATE_VERSION or decodeError or not session or session.kind ~= "enchanting_table"
	or session.containerId ~= containerId or session.token ~= token then return end
	if session.enchantingState and revision < ( session.enchantingState.revision or 0 ) then return end
	session.enchantingState = {
		revision = revision,
		bookshelfCount = bookshelfCount,
		options = options,
		receivedAt = RealTime(),
	}
	emit( "MCEnchantingStateChanged", session.enchantingState, state )
end )

function MC.RequestEnchantingOption( optionIndex )
	local state = MC.ClientInventory
	local session = state and state.session
	if not session or session.kind ~= "enchanting_table" then return false, "enchanting_table_not_open" end
	optionIndex = math.floor( tonumber( optionIndex ) or -1 )
	if optionIndex < 0 or optionIndex > 2 then return false, "invalid_enchantment_option" end
	local option = session.enchantingState and session.enchantingState.options
		and session.enchantingState.options[optionIndex + 1] or nil
	if not option or option.available ~= true then return false, option and option.error or "enchantment_unavailable" end
	if not MC.QueueInventoryMenuButton then return false, "menu_button_transport_unavailable" end
	return MC.QueueInventoryMenuButton( optionIndex )
end

local ROMAN = {
	[1] = "I", [2] = "II", [3] = "III", [4] = "IV", [5] = "V",
	[6] = "VI", [7] = "VII", [8] = "VIII", [9] = "IX", [10] = "X",
}

local function titleWord( word )
	return string.upper( string.sub( word, 1, 1 ) ) .. string.sub( word, 2 )
end

function MC.EnchantingClueName( enchantmentId, level )
	enchantmentId = tostring( enchantmentId or "" )
	level = math.max( 0, math.floor( tonumber( level ) or 0 ) )
	if MCITEM and type( MCITEM.EnchantmentLevelName ) == "function" then
		local called, value = pcall( MCITEM.EnchantmentLevelName, enchantmentId, level )
		if called and isstring( value ) and value ~= "" then return value end
	end
	local path = string.match( enchantmentId, "^[^:]+:(.+)$" ) or enchantmentId
	path = string.gsub( path, "_", " " )
	path = string.gsub( path, "%S+", titleWord )
	if level > 0 then path = path .. " " .. ( ROMAN[level] or tostring( level ) ) end
	return path ~= "" and path or ( type( I18n.Language ) == "function" and I18n.Language() == "zh_cn"
		and "未知附魔" or "Unknown Enchantment" )
end

function MC.EnchantingOptionTooltipLines( option )
	if type( option ) ~= "table" or not option.clue then return nil end
	local chinese = type( I18n.Language ) == "function" and I18n.Language() == "zh_cn"
	local lines = {
		{ text = ( chinese and "可能的附魔：" or "Enchantment clue: " )
			.. MC.EnchantingClueName( option.clue, option.clueLevel ), color = Color( 255, 255, 255 ) },
		{ text = "", color = Color( 255, 255, 255 ) },
	}
	if option.error == "not_enough_experience" then
		lines[#lines + 1] = {
			text = ( chinese and "需要等级 " or "Level requirement: " ) .. tostring( option.cost or 0 ),
			color = Color( 255, 85, 85 ),
		}
	else
		local lapis = math.max( 1, math.floor( tonumber( option.lapisCost ) or ( tonumber( option.index ) or 0 ) + 1 ) )
		lines[#lines + 1] = {
			text = chinese and ( "青金石：" .. lapis ) or ( lapis == 1 and "1 Lapis Lazuli" or lapis .. " Lapis Lazuli" ),
			color = option.error == "not_enough_lapis" and Color( 255, 85, 85 ) or Color( 170, 170, 170 ),
		}
		lines[#lines + 1] = {
			text = chinese and ( "消耗等级：" .. lapis ) or ( lapis == 1 and "1 Enchantment Level" or lapis .. " Enchantment Levels" ),
			color = Color( 170, 170, 170 ),
		}
	end
	return lines
end

-- Small GUI representation for the blank book area in the vanilla container
-- texture. The world model below uses the real 64x32 texture and full six-part
-- geometry; this intentionally stays cheap inside Derma.
function MC.DrawEnchantingBook2D( centerX, centerY, open, flip, scale )
	scale = math.max( 1, tonumber( scale ) or 1 )
	open = math.Clamp( tonumber( open ) or 0, 0, 1 )
	local spread = ( 5 + 12 * open ) * scale
	local height = ( 12 + 3 * open ) * scale
	local spineY = centerY + 4 * scale
	local topY = spineY - height
	local leftX, rightX = centerX - spread, centerX + spread
	draw.NoTexture()
	surface.SetDrawColor( 44, 25, 35, 95 )
	surface.DrawPoly( {
		{ x = leftX - 2 * scale, y = spineY + 3 * scale }, { x = rightX + 2 * scale, y = spineY + 3 * scale },
		{ x = rightX, y = spineY + 6 * scale }, { x = leftX, y = spineY + 6 * scale },
	} )
	surface.SetDrawColor( 86, 38, 74, 255 )
	surface.DrawPoly( {
		{ x = centerX, y = topY + scale }, { x = leftX - scale, y = topY + 3 * scale },
		{ x = leftX, y = spineY + 2 * scale }, { x = centerX, y = spineY },
	} )
	surface.DrawPoly( {
		{ x = centerX, y = topY + scale }, { x = rightX + scale, y = topY + 3 * scale },
		{ x = rightX, y = spineY + 2 * scale }, { x = centerX, y = spineY },
	} )
	surface.SetDrawColor( 224, 205, 158, 255 )
	surface.DrawPoly( {
		{ x = centerX, y = topY + 2 * scale }, { x = leftX + scale, y = topY + 4 * scale },
		{ x = leftX + 2 * scale, y = spineY }, { x = centerX, y = spineY - scale },
	} )
	surface.DrawPoly( {
		{ x = centerX, y = topY + 2 * scale }, { x = rightX - scale, y = topY + 4 * scale },
		{ x = rightX - 2 * scale, y = spineY }, { x = centerX, y = spineY - scale },
	} )
	local page = math.Clamp( ( tonumber( flip ) or 0 ) % 1, 0, 1 )
	local pageX = centerX + ( page * 2 - 1 ) * spread * 0.72
	surface.SetDrawColor( 244, 229, 188, 230 )
	surface.DrawPoly( {
		{ x = centerX, y = topY + 3 * scale }, { x = pageX, y = topY + 5 * scale },
		{ x = pageX, y = spineY - scale }, { x = centerX, y = spineY - 2 * scale },
	} )
end

local Entries = {}
local RenderEntriesDirty = true
local NextRebuildAttempt = 0
local LastAnimationTick = CurTime()

local function cellKey( bx, by, bz )
	return tostring( bx ) .. ":" .. tostring( by ) .. ":" .. tostring( bz )
end

local function isEnchantingTableState( stateId )
	if not ENCHANTING_TABLE_BLOCK_ID or type( Blocks.StateBlockId ) ~= "function" then return false end
	return Blocks.StateBlockId( stateId ) == ENCHANTING_TABLE_BLOCK_ID
end

local function removeEntry( key )
	Entries[key] = nil
end

local function newEntry( bx, by, bz )
	return {
		key = cellKey( bx, by, bz ), bx = bx, by = by, bz = bz,
		time = 0, flip = 0, oFlip = 0, flipT = 0, flipA = 0,
		open = 0, oOpen = 0, rot = 0, oRot = 0, tRot = 0,
		nextLightAt = 0,
	}
end

local function addEntry( bx, by, bz, destination )
	destination = destination or Entries
	local key = cellKey( bx, by, bz )
	local entry = Entries[key]
	if entry then
		entry.bx, entry.by, entry.bz = bx, by, bz
		destination[key] = entry
		return entry
	end
	entry = newEntry( bx, by, bz )
	destination[key] = entry
	return entry
end

local function rebuildEntries()
	if type( World.ForEachBlockEntity ) ~= "function" or type( World.GetBlockState ) ~= "function" then
		return false
	end
	local rebuilt = {}
	local ok = World.ForEachBlockEntity( BLOCK_ENTITY_TYPE, function( bx, by, bz )
		if isEnchantingTableState( World.GetBlockState( bx, by, bz ) ) then
			addEntry( bx, by, bz, rebuilt )
		end
	end )
	if ok ~= true then return false end
	Entries = rebuilt
	return true
end

function MC.MarkEnchantingTableRenderEntriesDirty()
	RenderEntriesDirty = true
end

local function noteEnchantingTableStateChanged( bx, by, bz, oldStateId, newStateId )
	local wasTable = isEnchantingTableState( oldStateId )
	local isTable = isEnchantingTableState( newStateId )
	if not wasTable and not isTable then return end
	local key = cellKey( bx, by, bz )
	if isTable then addEntry( bx, by, bz ) else removeEntry( key ) end
end

hook.Add( "MC.ClientBlockStateChanged", "mcgame_enchanting_table_state", noteEnchantingTableStateChanged )
hook.Add( "MC.ClientWorldProjectionChanged", "mcgame_enchanting_table_projection", function( reason, context )
	if reason == "block_entity_changed" and type( context ) == "table"
	and context.bx ~= nil and context.by ~= nil and context.bz ~= nil
	and type( World.GetBlockState ) == "function" then
		local stateId = World.GetBlockState( context.bx, context.by, context.bz )
		noteEnchantingTableStateChanged( context.bx, context.by, context.bz, stateId, stateId )
		return
	end
	RenderEntriesDirty = true
end )

local function nearestPlayer( center )
	if type( Coords.EntityWorldPos ) ~= "function" then return nil end
	local nearest, distance = nil, PLAYER_RANGE_SQR
	for _, ply in ipairs( player.GetAll() ) do
		if IsValid( ply ) and ply:Alive() then
			local position = Coords.EntityWorldPos( ply )
			local current = position and center:DistToSqr( position ) or math.huge
			if current <= distance then nearest, distance = ply, current end
		end
	end
	return nearest
end

local function wrapAngle( value )
	while value >= math.pi do value = value - math.pi * 2 end
	while value < -math.pi do value = value + math.pi * 2 end
	return value
end

local function tickBook( entry )
	entry.oOpen = entry.open
	entry.oRot = entry.rot
	local center = type( Coords.CellCenter ) == "function" and Coords.CellCenter( entry.bx, entry.by, entry.bz ) or nil
	if not center then return end
	local ply = nearestPlayer( center )
	if IsValid( ply ) then
		local delta = Coords.EntityWorldPos( ply ) - center
		entry.tRot = math.atan2( delta.y, delta.x )
		entry.open = entry.open + 0.1
		if entry.open < 0.5 or math.random( 40 ) == 1 then
			local previous = entry.flipT
			repeat entry.flipT = entry.flipT + math.random( 0, 3 ) - math.random( 0, 3 ) until entry.flipT ~= previous
		end
	else
		entry.tRot = entry.tRot + 0.02
		entry.open = entry.open - 0.1
	end
	entry.rot = wrapAngle( entry.rot )
	entry.tRot = wrapAngle( entry.tRot )
	entry.rot = entry.rot + wrapAngle( entry.tRot - entry.rot ) * 0.4
	entry.open = math.Clamp( entry.open, 0, 1 )
	entry.time = entry.time + 1
	entry.oFlip = entry.flip
	local difference = math.Clamp( ( entry.flipT - entry.flip ) * 0.4, -0.2, 0.2 )
	entry.flipA = entry.flipA + ( difference - entry.flipA ) * 0.9
	entry.flip = entry.flip + entry.flipA
end

local function emitVertex( position, u, v, color, normal )
	mesh.Position( position )
	if mesh.Normal then mesh.Normal( normal ) end
	mesh.Color( color.r, color.g, color.b, color.a )
	mesh.TexCoord( 0, u, v )
	mesh.AdvanceVertex()
end

local function emitQuad( a, b, c, d, u0, v0, u1, v1, color )
	local normal = ( b - a ):Cross( d - a )
	if normal:LengthSqr() > 0 then normal:Normalize() else normal = UP end
	emitVertex( a, u1 / 64, v0 / 32, color, normal )
	emitVertex( b, u0 / 64, v0 / 32, color, normal )
	emitVertex( c, u0 / 64, v1 / 32, color, normal )
	emitVertex( d, u1 / 64, v1 / 32, color, normal )
end

local function partPoint( origin, axisX, axisY, axisZ, angle, tx, ty, tz, x, y, z )
	local cosine, sine = math.cos( angle ), math.sin( angle )
	local rotatedX = x * cosine + z * sine + tx
	local rotatedZ = -x * sine + z * cosine + tz
	return origin + axisX * ( rotatedX * MODEL_SCALE ) + axisY * ( ( y + ty ) * MODEL_SCALE )
		+ axisZ * ( rotatedZ * MODEL_SCALE )
end

local function drawBookBox( origin, axisX, axisY, axisZ, angle, tx, ty, tz,
	x, y, z, width, height, depth, texU, texV, color )
	local function point( px, py, pz )
		return partPoint( origin, axisX, axisY, axisZ, angle, tx, ty, tz, px, py, pz )
	end
	local x0, x1 = x, x + width
	local y0, y1 = y, y + height
	local z0, z1 = z, z + depth
	local t0, t1, t2, t3 = point( x0, y0, z0 ), point( x1, y0, z0 ), point( x1, y1, z0 ), point( x0, y1, z0 )
	local l0, l1, l2, l3 = point( x0, y0, z1 ), point( x1, y0, z1 ), point( x1, y1, z1 ), point( x0, y1, z1 )
	local u0, u1 = texU, texU + depth
	local u2, u22 = u1 + width, u1 + width * 2
	local u3, u4 = u2 + depth, u2 + depth + width
	local v0, v1, v2 = texV, texV + depth, texV + depth + height
	mesh.Begin( MATERIAL_QUADS, 6 )
		emitQuad( l1, l0, t0, t1, u1, v0, u2, v1, color )
		emitQuad( t2, t3, l3, l2, u2, v1, u22, v0, color )
		emitQuad( t0, l0, l3, t3, u0, v1, u1, v2, color )
		emitQuad( t1, t0, t3, t2, u1, v1, u2, v2, color )
		emitQuad( l1, t1, t2, l2, u2, v1, u3, v2, color )
		emitQuad( l0, l1, l2, l3, u3, v1, u4, v2, color )
	mesh.End()
end

local function entryColor( entry, center )
	local now = CurTime()
	if not entry.lightColor or now >= entry.nextLightAt then
		local r, g, b = 1, 1, 1
		if type( Light.SampleRGB ) == "function" then r, g, b = Light.SampleRGB( center, 1 ) end
		entry.lightColor = Color(
			math.Clamp( math.floor( r * 255 + 0.5 ), 0, 255 ),
			math.Clamp( math.floor( g * 255 + 0.5 ), 0, 255 ),
			math.Clamp( math.floor( b * 255 + 0.5 ), 0, 255 ), 255
		)
		entry.nextLightAt = now + 0.1
	end
	return entry.lightColor
end

local function lerpAngle( fraction, from, to )
	return from + wrapAngle( to - from ) * fraction
end

local function drawBook( entry, partialTick, renderCenter, worldCenter )
	local open = Lerp( partialTick, entry.oOpen, entry.open )
	local flip = Lerp( partialTick, entry.oFlip, entry.flip )
	local time = entry.time + partialTick
	local rotation = lerpAngle( partialTick, entry.oRot, entry.rot )
	local direction = Vector( math.cos( rotation ), math.sin( rotation ), 0 )
	local perpendicular = Vector( -direction.y, direction.x, 0 )
	local tilt = math.rad( 80 )
	local axisX = direction * math.cos( tilt ) + UP * math.sin( tilt )
	local axisY = -direction * math.sin( tilt ) + UP * math.cos( tilt )
	local axisZ = perpendicular
	local origin = renderCenter + UP * ( BS * ( 0.35 + math.sin( time * 0.1 ) * 0.01 ) )
	local page1 = math.Clamp( ( ( flip + 0.25 ) % 1 ) * 1.6 - 0.3, 0, 1 )
	local page2 = math.Clamp( ( ( flip + 0.75 ) % 1 ) * 1.6 - 0.3, 0, 1 )
	local openness = ( math.sin( time * 0.02 ) * 0.1 + 1.25 ) * open
	local shift = math.sin( openness )
	local color = entryColor( entry, worldCenter )
	render.SetMaterial( BOOK_MATERIAL )
	-- BookModel.createBodyLayer / setupAnim from Java 26.2.
	drawBookBox( origin, axisX, axisY, axisZ, math.pi + openness, 0, 0, -1,
		-6, -5, -0.005, 6, 10, 0.005, 0, 0, color )
	drawBookBox( origin, axisX, axisY, axisZ, -openness, 0, 0, 1,
		0, -5, -0.005, 6, 10, 0.005, 16, 0, color )
	drawBookBox( origin, axisX, axisY, axisZ, math.pi * 0.5, 0, 0, 0,
		-1, -5, 0, 2, 10, 0.005, 12, 0, color )
	drawBookBox( origin, axisX, axisY, axisZ, openness, shift, 0, 0,
		0, -4, -0.99, 5, 8, 1, 0, 10, color )
	drawBookBox( origin, axisX, axisY, axisZ, -openness, shift, 0, 0,
		0, -4, -0.01, 5, 8, 1, 12, 10, color )
	drawBookBox( origin, axisX, axisY, axisZ, openness - openness * 2 * page1, shift, 0, 0,
		0, -4, 0, 5, 8, 0.005, 24, 10, color )
	drawBookBox( origin, axisX, axisY, axisZ, openness - openness * 2 * page2, shift, 0, 0,
		0, -4, 0, 5, 8, 0.005, 24, 10, color )
end

hook.Add( "Think", "mc_enchanting_table_book_animation", function()
	local now = CurTime()
	if RenderEntriesDirty and now >= NextRebuildAttempt then
		RenderEntriesDirty = rebuildEntries() ~= true
		NextRebuildAttempt = now + ( RenderEntriesDirty and 1 or 0.25 )
	end
	local steps = 0
	while now - LastAnimationTick >= 0.05 and steps < 4 do
		LastAnimationTick = LastAnimationTick + 0.05
		for _, entry in pairs( Entries ) do tickBook( entry ) end
		steps = steps + 1
	end
	if now - LastAnimationTick > 0.25 then LastAnimationTick = now end
end )

hook.Add( "PostDrawTranslucentRenderables", "mc_enchanting_table_books", function( _, _, drawing3DSkybox )
	if drawing3DSkybox then return end
	local eye = EyePos()
	local partialTick = math.Clamp( ( CurTime() - LastAnimationTick ) / 0.05, 0, 1 )
	if render.PushFilterMin then render.PushFilterMin( TEXFILTER.POINT ) end
	if render.PushFilterMag then render.PushFilterMag( TEXFILTER.POINT ) end
	for key, entry in pairs( Entries ) do
		local renderCenter = type( Coords.CellRenderCenter ) == "function"
			and Coords.CellRenderCenter( entry.bx, entry.by, entry.bz ) or nil
		if renderCenter and eye:DistToSqr( renderCenter ) <= MAX_RENDER_DISTANCE_SQR then
			local stateId = type( World.GetBlockState ) == "function"
				and World.GetBlockState( entry.bx, entry.by, entry.bz ) or 0
			if not isEnchantingTableState( stateId ) then
				removeEntry( key )
			else
				local worldCenter = type( Coords.CellCenter ) == "function"
					and Coords.CellCenter( entry.bx, entry.by, entry.bz ) or nil
				if worldCenter then drawBook( entry, partialTick, renderCenter, worldCenter ) end
			end
		end
	end
	if render.PopFilterMag then render.PopFilterMag() end
	if render.PopFilterMin then render.PopFilterMin() end
end )
