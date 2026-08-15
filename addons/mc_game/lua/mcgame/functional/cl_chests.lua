-- Client renderer for vanilla single and double chests. Contents remain
-- server-only; clients only need block states and replicated opener counts.

MC = MC or {}

local API = MC.API or {}
local Coords = API.Coords or {}
local Light = API.Light or {}
local Network = API.Network or {}
local Render = API.Render or {}
local World = API.World or {}
local BS = Coords.BlockSize and Coords.BlockSize() or 36.5
local COORD_BITS = Network.CoordinateBits and Network.CoordinateBits() or 20
local SCALE = BS / 16
local UP = Vector( 0, 0, 1 )
local MAX_RENDER_DISTANCE_SQR = ( BS * 64 ) ^ 2
local MATERIAL_FLAGS = "alphatest vertexcolor vertexalpha nocull"
local CHEST_BLOCK_NAMES = {
	"chest", "trapped_chest", "copper_chest", "exposed_copper_chest",
	"weathered_copper_chest", "oxidized_copper_chest", "waxed_copper_chest",
	"waxed_exposed_copper_chest", "waxed_weathered_copper_chest",
	"waxed_oxidized_copper_chest",
}
local TEXTURE_BASES = {
	normal = true, trapped = true, copper = true, copper_exposed = true,
	copper_weathered = true, copper_oxidized = true,
}
local MATERIALS = {}

for baseName in pairs( TEXTURE_BASES ) do
	MATERIALS[baseName] = Material( "mc/entity/chest/" .. baseName .. ".png", MATERIAL_FLAGS )
	MATERIALS[baseName .. "_left"] = Material( "mc/entity/chest/" .. baseName .. "_left.png", MATERIAL_FLAGS )
	MATERIALS[baseName .. "_right"] = Material( "mc/entity/chest/" .. baseName .. "_right.png", MATERIAL_FLAGS )
end

local Entries = {}
local OpenStates = {}
local LastChunkRefresh = 0
local EntriesDirty = true

local function cellKey( bx, by, bz )
	return tostring( math.floor( tonumber( bx ) or 0 ) ) .. ":"
		.. tostring( math.floor( tonumber( by ) or 0 ) ) .. ":"
		.. tostring( math.floor( tonumber( bz ) or 0 ) )
end

local function removeEntry( key )
	Entries[key] = nil
end

local function addEntry( bx, by, bz )
	local key = cellKey( bx, by, bz )
	local entry = Entries[key]
	if entry then
		entry.bx, entry.by, entry.bz = bx, by, bz
		return entry
	end
	entry = { key = key, bx = bx, by = by, bz = bz, nextLightAt = 0 }
	Entries[key] = entry
	return entry
end

function MC.MarkChestRenderEntriesDirty()
	Entries = {}
	EntriesDirty = true
end

function MC.NoteChestStateChanged( bx, by, bz, oldStateId, newStateId )
	local wasChest = MC.IsChestState and MC.IsChestState( oldStateId ) or false
	local isChest = MC.IsChestState and MC.IsChestState( newStateId ) or false
	if not wasChest and not isChest then return end
	local key = cellKey( bx, by, bz )
	if isChest then addEntry( bx, by, bz ) else removeEntry( key ) end
end

local function refreshChunks()
	if not EntriesDirty or not World.ForEachLoadedBlock then return end
	Entries = {}
	World.ForEachLoadedBlock( function( bx, by, bz, stateId )
		if MC.IsChestState and MC.IsChestState( stateId ) then addEntry( bx, by, bz ) end
	end )
	EntriesDirty = false
end

hook.Add( "MC.ClientBlockStateChanged", "mcgame_chest_state_projection", function( bx, by, bz, oldStateId, newStateId )
	MC.NoteChestStateChanged( bx, by, bz, oldStateId, newStateId )
end )

hook.Add( "MC.ClientWorldProjectionChanged", "mcgame_chest_world_projection", function()
	MC.MarkChestRenderEntriesDirty()
	OpenStates = {}
end )

local function facingBasis( facing )
	local forward
	if facing == "north" then forward = Vector( 0, -1, 0 )
	elseif facing == "west" then forward = Vector( -1, 0, 0 )
	elseif facing == "east" then forward = Vector( 1, 0, 0 )
	else forward = Vector( 0, 1, 0 ) end
	return Vector( forward.y, -forward.x, 0 ), forward
end

local function textureBase( name )
	name = string.gsub( tostring( name or "" ), "^minecraft:", "" )
	if name == "trapped_chest" then return "trapped" end
	if string.find( name, "oxidized", 1, true ) then return "copper_oxidized" end
	if string.find( name, "weathered", 1, true ) then return "copper_weathered" end
	if string.find( name, "exposed", 1, true ) then return "copper_exposed" end
	if string.find( name, "copper_chest", 1, true ) then return "copper" end
	return "normal"
end

local function materialFor( info )
	local suffix = info.type == "left" and "_left" or info.type == "right" and "_right" or ""
	return MATERIALS[textureBase( info.name ) .. suffix] or MATERIALS.normal
end

local function emitVertex( position, u, v, color, normal )
	mesh.Position( position )
	if mesh.Normal then mesh.Normal( normal ) end
	mesh.Color( color.r, color.g, color.b, color.a )
	mesh.TexCoord( 0, u, v )
	mesh.AdvanceVertex()
end

local function emitQuad( a, b, c, d, u0, v0, u1, v1, color, normal )
	-- ModelPart.Polygon maps its first vertex to the upper-right UV corner.
	emitVertex( a, u1 / 64, v0 / 64, color, normal )
	emitVertex( b, u0 / 64, v0 / 64, color, normal )
	emitVertex( c, u0 / 64, v1 / 64, color, normal )
	emitVertex( d, u1 / 64, v1 / 64, color, normal )
end

local function drawBox( origin, right, forward, up, x, y, z, width, height, depth, texU, texV, color, hidden )
	local function point( px, py, pz )
		return origin + right * ( px * SCALE ) + forward * ( pz * SCALE ) + up * ( py * SCALE )
	end
	local x0, x1 = x, x + width
	local y0, y1 = y, y + height
	local z0, z1 = z, z + depth
	local t0, t1, t2, t3 = point( x0, y0, z0 ), point( x1, y0, z0 ), point( x1, y1, z0 ), point( x0, y1, z0 )
	local l0, l1, l2, l3 = point( x0, y0, z1 ), point( x1, y0, z1 ), point( x1, y1, z1 ), point( x0, y1, z1 )
	local u0, u1 = texU, texU + depth
	local u2 = u1 + width
	local u22 = u2 + width
	local u3 = u2 + depth
	local u4 = u3 + width
	local v0, v1, v2 = texV, texV + depth, texV + depth + height
	local faces = 6 - ( hidden and ( ( hidden.west and 1 or 0 ) + ( hidden.east and 1 or 0 ) ) or 0 )
	mesh.Begin( MATERIAL_QUADS, faces )
	emitQuad( l1, l0, t0, t1, u1, v0, u2, v1, color, -up )
	emitQuad( t2, t3, l3, l2, u2, v1, u22, v0, color, up )
	if not ( hidden and hidden.west ) then emitQuad( t0, l0, l3, t3, u0, v1, u1, v2, color, -right ) end
	emitQuad( t1, t0, t3, t2, u1, v1, u2, v2, color, -forward )
	if not ( hidden and hidden.east ) then emitQuad( l1, t1, t2, l2, u2, v1, u3, v2, color, right ) end
	emitQuad( l0, l1, l2, l3, u3, v1, u4, v2, color, forward )
	mesh.End()
end

local function entryColor( entry, worldCenter )
	local now = CurTime()
	if not entry.lightColor or now >= entry.nextLightAt then
		local r, g, b = 1, 1, 1
		if Light.SampleRGB and worldCenter then r, g, b = Light.SampleRGB( worldCenter, 0 ) end
		entry.lightColor = Color(
			math.Clamp( math.floor( r * 255 + 0.5 ), 0, 255 ),
			math.Clamp( math.floor( g * 255 + 0.5 ), 0, 255 ),
			math.Clamp( math.floor( b * 255 + 0.5 ), 0, 255 ), 255
		)
		local stagger = math.abs( entry.bx * 31 + entry.by * 17 + entry.bz * 13 ) % 17
		entry.nextLightAt = now + 0.1 + stagger * 0.003
	end
	return entry.lightColor
end

local function drawChest( entry, stateId, openness, renderCenter )
	local info = MC.ChestStateInfo and MC.ChestStateInfo( stateId ) or nil
	if not info then return false end
	local right, forward = facingBasis( info.facing )
	renderCenter = renderCenter or ( Coords.CellRenderCenter
		and Coords.CellRenderCenter( entry.bx, entry.by, entry.bz ) or nil )
	if not renderCenter then return false end
	local base = Vector( renderCenter.x, renderCenter.y, renderCenter.z - BS * 0.5 )
	local origin = base - right * ( BS * 0.5 ) - forward * ( BS * 0.5 )
	local x, width, lockX, lockWidth, hidden = 1, 14, 7, 2, nil
	if info.type == "right" then x, width, lockX, lockWidth, hidden = 1, 15, 15, 1, { east = true }
	elseif info.type == "left" then x, width, lockX, lockWidth, hidden = 0, 15, 0, 1, { west = true } end
	local worldCenter = Coords.CellCenter and Coords.CellCenter( entry.bx, entry.by, entry.bz ) or nil
	local color = entryColor( entry, worldCenter )
	render.SetMaterial( materialFor( info ) )
	drawBox( origin, right, forward, UP, x, 0, 1, width, 10, 14, 0, 19, color, hidden )

	local closed = 1 - math.Clamp( openness or 0, 0, 1 )
	local eased = 1 - closed * closed * closed
	local angle = eased * math.pi * 0.5
	local cosine, sine = math.cos( angle ), math.sin( angle )
	local lidForward = forward * cosine + UP * sine
	local lidUp = UP * cosine - forward * sine
	local hinge = origin + forward * SCALE + UP * ( SCALE * 9 )
	drawBox( hinge, right, lidForward, lidUp, x, 0, 0, width, 5, 14, 0, 0, color, hidden )
	drawBox( hinge, right, lidForward, lidUp, lockX, -2, 14, lockWidth, 4, 1, 0, 0, color, hidden )
	return true
end

local function opennessFor( key )
	local state = OpenStates[key]
	return state and state.openness or 0
end

net.Receive( "mc_chest_open_state", function()
	local bx = net.ReadInt( COORD_BITS )
	local by = net.ReadInt( COORD_BITS )
	local bz = net.ReadInt( COORD_BITS )
	local count = net.ReadUInt( 8 )
	local key = cellKey( bx, by, bz )
	local state = OpenStates[key] or { openness = 0 }
	state.count = count
	state.target = count > 0 and 1 or 0
	OpenStates[key] = state
end )

hook.Add( "Think", "mc_chest_lid_animation", function()
	local step = math.max( FrameTime(), 0 ) * 2 -- ChestLidController: 0.1 per 20 Hz tick.
	for key, state in pairs( OpenStates ) do
		state.openness = math.Approach( state.openness or 0, state.target or 0, step )
		if state.count == 0 and state.openness <= 0 then OpenStates[key] = nil end
	end
	if CurTime() >= LastChunkRefresh then
		LastChunkRefresh = CurTime() + 0.25
		refreshChunks()
	end
end )

if Render.RegisterSpecialBlockEmitter then
	local function chestEmitter( _, _, _, _, bx, by, bz )
		addEntry( bx, by, bz )
		return "chest", false, 0
	end
	for _, blockName in ipairs( CHEST_BLOCK_NAMES ) do
		Render.RegisterSpecialBlockEmitter( "minecraft:" .. blockName, chestEmitter )
	end
	if Render.MarkAllDirty then Render.MarkAllDirty() end
end

hook.Add( "PostDrawTranslucentRenderables", "mc_chest_block_entities", function( _, _, bSky3D )
	if bSky3D then return end
	local eye = EyePos()
	if render.PushFilterMin then render.PushFilterMin( TEXFILTER.POINT ) end
	if render.PushFilterMag then render.PushFilterMag( TEXFILTER.POINT ) end
	for key, entry in pairs( Entries ) do
		local center = Coords.CellRenderCenter and Coords.CellRenderCenter( entry.bx, entry.by, entry.bz ) or nil
		if center and eye:DistToSqr( center ) <= MAX_RENDER_DISTANCE_SQR then
			local stateId = World.GetBlockState and World.GetBlockState( entry.bx, entry.by, entry.bz ) or 0
			if not MC.IsChestState( stateId ) then removeEntry( key )
			else drawChest( entry, stateId, opennessFor( key ), center ) end
		end
	end
	if render.PopFilterMag then render.PopFilterMag() end
	if render.PopFilterMin then render.PopFilterMin() end
end )
