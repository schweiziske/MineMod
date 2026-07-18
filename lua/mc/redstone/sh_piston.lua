-- Transactional piston movement. Blocks are moved atomically without spawning
-- one entity per voxel; visual moving-piston interpolation can layer on later.

MC = MC or {}

local GetBlockState = MC.GetBlockState
local GetStateProperty = MC.GetStateProperty
local StateWith = MC.StateWith

local Offset = {
	north = { 0, -1, 0 }, south = { 0, 1, 0 },
	west = { -1, 0, 0 }, east = { 1, 0, 0 },
	up = { 0, 0, 1 }, down = { 0, 0, -1 },
}

local Immovable = {
	["minecraft:bedrock"] = true,
	["minecraft:barrier"] = true,
	["minecraft:end_portal"] = true,
	["minecraft:end_portal_frame"] = true,
	["minecraft:obsidian"] = true,
	["minecraft:crying_obsidian"] = true,
	["minecraft:respawn_anchor"] = true,
	["minecraft:reinforced_deepslate"] = true,
	["minecraft:moving_piston"] = true,
	["minecraft:piston_head"] = true,
}

local function stateName( stateId )
	local schema = MC.BlockStateSchemaForState( stateId )
	return schema and schema.name or nil
end

local function pistonOffset( stateId )
	return Offset[GetStateProperty( stateId, "facing" )] or Offset.north
end

local AdhesiveKind = {
	["minecraft:slime_block"] = "slime",
	["minecraft:honey_block"] = "honey",
}

local function movementKey( x, y, z )
	return x .. ":" .. y .. ":" .. z
end

local function adhesiveKind( stateId )
	return AdhesiveKind[stateName( stateId )]
end

local function adhesiveCanStick( adhesive, neighborState )
	local neighborName = stateName( neighborState )
	-- Glazed terracotta is movable but intentionally non-sticky in vanilla.
	if neighborName and string.match( neighborName, "_glazed_terracotta$" ) then return false end
	local neighborAdhesive = adhesiveKind( neighborState )
	-- Vanilla slime and honey deliberately do not adhere to each other.
	return not neighborAdhesive or neighborAdhesive == adhesive
end

local function movable( stateId, bx, by, bz )
	if not stateId or stateId == 0 then return true end
	local name = stateName( stateId )
	if Immovable[name] then return false end
	if ( name == "minecraft:piston" or name == "minecraft:sticky_piston" )
	and GetStateProperty( stateId, "extended" ) == true then return false end
	if MC.GetBlockEntity and MC.GetBlockEntity( bx, by, bz ) then return false end
	return true
end

local function airState()
	return MC.DefaultBlockState( "minecraft:air" ) or 0
end

local NeighborOffsets = {
	{ 1, 0, 0 }, { -1, 0, 0 },
	{ 0, 1, 0 }, { 0, -1, 0 },
	{ 0, 0, 1 }, { 0, 0, -1 },
}

-- Collect a complete piston structure before writing anything. Destination
-- recursion resolves the normal push chain; adhesive recursion adds blocks on
-- every face of slime/honey. The same planner is used in reverse for sticky
-- piston retraction.
local function collectMovement( startX, startY, startZ, move, protected, vacated )
	local blocks, byKey = {}, {}
	local visiting, count = {}, 0

	local function stateAt( x, y, z )
		if vacated and vacated[movementKey( x, y, z )] then return 0 end
		return GetBlockState( x, y, z )
	end

	local function add( x, y, z )
		local key = movementKey( x, y, z )
		if byKey[key] then return true end
		if protected and protected[key] then return false end
		if visiting[key] then return true end
		local stateId = stateAt( x, y, z )
		if not stateId or stateId == 0 then return true end
		if not movable( stateId, x, y, z ) then return false end
		count = count + 1
		if count > 12 then return false end

		visiting[key] = true
		-- Make room at the destination before accepting this block.
		if not add( x + move[1], y + move[2], z + move[3] ) then
			visiting[key] = nil
			return false
		end

		local adhesive = adhesiveKind( stateId )
		if adhesive then
			-- PistonStructureResolver.addBlockLine first walks the sticky chain
			-- opposite the movement direction. A sticky block may bring one normal
			-- block behind it; propagation continues only while that block is sticky.
			local backX, backY, backZ = x - move[1], y - move[2], z - move[3]
			local backKey = movementKey( backX, backY, backZ )
			if not ( protected and protected[backKey] )
			and not ( vacated and vacated[backKey] ) then
				local backState = stateAt( backX, backY, backZ )
				if backState ~= 0 and movable( backState, backX, backY, backZ )
				and adhesiveCanStick( adhesive, backState )
				and not add( backX, backY, backZ ) then
					visiting[key] = nil
					return false
				end
			end

			-- addBranchingBlocks considers only directions perpendicular to the
			-- push axis. Unpushable side neighbours are ignored rather than making
			-- the complete structure fail (for example slime beside obsidian).
			for index = 1, 6 do
				local side = NeighborOffsets[index]
				if side[1] * move[1] + side[2] * move[2] + side[3] * move[3] == 0 then
					local nx, ny, nz = x + side[1], y + side[2], z + side[3]
					local neighborKey = movementKey( nx, ny, nz )
					if not ( protected and protected[neighborKey] )
					and not ( vacated and vacated[neighborKey] ) then
						local neighborState = stateAt( nx, ny, nz )
						if neighborState ~= 0 and movable( neighborState, nx, ny, nz )
						and adhesiveCanStick( adhesive, neighborState )
						and not add( nx, ny, nz ) then
							visiting[key] = nil
							return false
						end
					end
				end
			end
		end

		visiting[key] = nil
		if not byKey[key] then
			blocks[#blocks + 1] = { x = x, y = y, z = z, stateId = stateId }
			byKey[key] = blocks[#blocks]
		end
		return true
	end

	if not add( startX, startY, startZ ) then return nil end
	return blocks
end

local function appendMovementCells( cells, writes, blocks, move )
	local function write( x, y, z, stateId )
		local key = movementKey( x, y, z )
		local index = writes[key]
		if index then
			cells[index].stateId = stateId
		else
			cells[#cells + 1] = { bx = x, by = y, bz = z, stateId = stateId }
			writes[key] = #cells
		end
	end
	for index = 1, #blocks do
		local block = blocks[index]
		write( block.x, block.y, block.z, airState() )
	end
	for index = 1, #blocks do
		local block = blocks[index]
		write( block.x + move[1], block.y + move[2], block.z + move[3], block.stateId )
	end
	return write
end

local function pistonHeadState( baseState )
	local stateId = MC.DefaultBlockState( "minecraft:piston_head" )
	if not stateId then return nil end
	stateId = StateWith( stateId, "facing", GetStateProperty( baseState, "facing" ) ) or stateId
	stateId = StateWith( stateId, "type", stateName( baseState ) == "minecraft:sticky_piston" and "sticky" or "normal" ) or stateId
	stateId = StateWith( stateId, "short", false ) or stateId
	return stateId
end

local function matchingHead( baseState, headState )
	if stateName( headState ) ~= "minecraft:piston_head" then return false end
	if GetStateProperty( headState, "facing" ) ~= GetStateProperty( baseState, "facing" ) then return false end
	local wantType = stateName( baseState ) == "minecraft:sticky_piston" and "sticky" or "normal"
	return GetStateProperty( headState, "type" ) == wantType
end

local function matchingBase( headState, baseState )
	local name = stateName( baseState )
	if name ~= "minecraft:piston" and name ~= "minecraft:sticky_piston" then return false end
	return GetStateProperty( baseState, "extended" ) == true and matchingHead( baseState, headState )
end

function MC.PistonBreakPartner( bx, by, bz, stateId )
	stateId = stateId or GetBlockState( bx, by, bz )
	local name = stateName( stateId )
	local offset = pistonOffset( stateId )
	if name == "minecraft:piston" or name == "minecraft:sticky_piston" then
		if GetStateProperty( stateId, "extended" ) ~= true then return nil end
		local x, y, z = bx + offset[1], by + offset[2], bz + offset[3]
		return matchingHead( stateId, GetBlockState( x, y, z ) ) and x or nil, y, z
	end
	if name == "minecraft:piston_head" then
		local x, y, z = bx - offset[1], by - offset[2], bz - offset[3]
		return matchingBase( stateId, GetBlockState( x, y, z ) ) and x or nil, y, z
	end
	return nil
end

local ClosedPistonRegisteredModels = {}

local function transformClosedPistonModel( modelData, modelId )
	local quads = modelData and modelData.modelQuads
	if not quads then return modelData end

	local transformed = {
		compact = modelData.compact,
		generatedStateVisual = modelData.generatedStateVisual,
		geometryId = modelData.geometryId,
		surfaceId = modelData.surfaceId,
		modelSurfaces = modelData.modelSurfaces,
		modelQuads = {},
	}
	for index = 1, #quads do
		local source = quads[index]
		local quad = {}
		for key, value in pairs( source ) do quad[key] = value end
		quad.rot = ( ( quad.rot or 0 ) + 2 ) % 4
		transformed.modelQuads[index] = quad
	end
	return transformed
end

local function registerClosedPistonModel( stateId )
	if not MC.StateVisualPlanRangeFast or not MC.StateVisualPlanModelAtFast
	or not MC.RegisterStateVisualModelTransform then return false end
	local planId, groupOffset, groupCount = MC.StateVisualPlanRangeFast( stateId )
	if not planId or groupCount ~= 1 then return false end
	local modelId = MC.StateVisualPlanModelAtFast( planId, groupOffset, 0, 0, 0, 0 )
	if not modelId then return false end
	if not ClosedPistonRegisteredModels[modelId] then
		local registered = MC.RegisterStateVisualModelTransform( modelId, transformClosedPistonModel )
		if not registered then return false end
		ClosedPistonRegisteredModels[modelId] = true
	end
	return true
end

-- Register bases and heads before their first chunk mesh is built. Closed,
-- extended and head models must use the same texture-space correction.
local function registerAllClosedPistonModels()
	if not CLIENT then return 0 end
	local total = 0
	for _, name in ipairs( { "minecraft:piston", "minecraft:sticky_piston", "minecraft:piston_head" } ) do
		local schema = MC.BlockStateSchemaByName and MC.BlockStateSchemaByName[name]
		if schema and schema.firstStateId and schema.lastStateId then
			for stateId = schema.firstStateId, schema.lastStateId do
				if registerClosedPistonModel( stateId ) then
					total = total + 1
				end
			end
		end
	end
	return total
end

local function pistonVisual( stateId )
	registerClosedPistonModel( stateId )
	return {
		forceGeneratedVisual = true,
		cullGeneratedFaces = false,
		fullCube = false,
	}
end

MC.RegisterBlockStateVisual( "minecraft:piston", { Resolve = pistonVisual } )
MC.RegisterBlockStateVisual( "minecraft:sticky_piston", { Resolve = pistonVisual } )
MC.RegisterBlockStateVisual( "minecraft:piston_head", { Resolve = pistonVisual } )

if CLIENT and timer and timer.Simple then
	registerAllClosedPistonModels()
	timer.Simple( 0, function()
		registerAllClosedPistonModels()
		if MC.ClearDecodedStateVisualModels then MC.ClearDecodedStateVisualModels() end
		local renderMesh = MC.RenderMesh
		if renderMesh and renderMesh.resetShapeModelTemplateCache then
			renderMesh.resetShapeModelTemplateCache()
		end
		if MC.MarkAllMeshesDirty then MC.MarkAllMeshesDirty( "piston_visual_reload" ) end
	end )
end

local function extendCells( context )
	local offset = pistonOffset( context.stateId )
	local frontX, frontY, frontZ = context.bx + offset[1], context.by + offset[2], context.bz + offset[3]
	local protected = { [movementKey( context.bx, context.by, context.bz )] = true }
	local blocks = collectMovement( frontX, frontY, frontZ, offset, protected )
	if not blocks then return nil end
	local headState = pistonHeadState( context.stateId )
	if not headState then return nil end
	local cells, writes = {}, {}
	local write = appendMovementCells( cells, writes, blocks, offset )
	write( frontX, frontY, frontZ, headState )
	write( context.bx, context.by, context.bz, StateWith( context.stateId, "extended", true ) or context.stateId )
	return cells
end

local function retractCells( context )
	local offset = pistonOffset( context.stateId )
	local frontX, frontY, frontZ = context.bx + offset[1], context.by + offset[2], context.bz + offset[3]
	local cells = { {
		bx = context.bx, by = context.by, bz = context.bz,
		stateId = StateWith( context.stateId, "extended", false ) or context.stateId,
	} }
	local writes = { [movementKey( context.bx, context.by, context.bz )] = 1 }
	local frontState = airState()
	if stateName( context.stateId ) == "minecraft:sticky_piston" then
		local pullX, pullY, pullZ = context.bx + offset[1] * 2, context.by + offset[2] * 2, context.bz + offset[3] * 2
		local reverse = { -offset[1], -offset[2], -offset[3] }
		local protected = { [movementKey( context.bx, context.by, context.bz )] = true }
		local vacated = { [movementKey( frontX, frontY, frontZ )] = true }
		local blocks = collectMovement( pullX, pullY, pullZ, reverse, protected, vacated )
		if blocks and #blocks > 0 then
			appendMovementCells( cells, writes, blocks, reverse )
		end
	end
	local frontKey = movementKey( frontX, frontY, frontZ )
	if not writes[frontKey] then
		cells[#cells + 1] = { bx = frontX, by = frontY, bz = frontZ, stateId = frontState }
	end
	return cells
end

-- Vanilla pistons never listen to the face they push into: dust there would
-- both trigger the piston and be displaced by the head, retriggering forever.
local function pistonPowered( context )
	local offset = pistonOffset( context.stateId )
	return MC.RedstoneBestNeighborSignal(
		context.bx, context.by, context.bz,
		context.bx + offset[1], context.by + offset[2], context.bz + offset[3]
	) > 0
end

local function pistonSoundCommitted( data, transaction )
	if not data or not transaction or transaction.ok ~= true or ( transaction.changed or 0 ) <= 0 then return end
	MC.PlayRedstoneSound( data.sound, data.bx, data.by, data.bz, 0.5, data.pitch )
end

local function pistonSoundResult( context, extending )
	local spread = extending and 0.25 or 0.15
	local randomUnit = math.Rand and math.Rand( 0, 1 ) or math.random()
	return {
		sound = extending and "mc/tile/piston/out.wav" or "mc/tile/piston/in.wav",
		bx = context.bx, by = context.by, bz = context.bz,
		pitch = 0.6 + randomUnit * spread,
	}
end

local pistonHandler = {
	OnNeighborUpdate = function( context )
		local offset = pistonOffset( context.stateId )
		if GetStateProperty( context.stateId, "extended" ) == true then
			local headState = GetBlockState(
				context.bx + offset[1], context.by + offset[2], context.bz + offset[3]
			)
			if not matchingHead( context.stateId, headState ) then
				return { cells = { { bx = context.bx, by = context.by, bz = context.bz, stateId = airState() } }, compareCollision = true }
			end
		end
		local powered = pistonPowered( context )
		local extended = GetStateProperty( context.stateId, "extended" ) == true
		if powered == extended then return nil end
		return { schedule = { { delayTicks = 1, expectedStateId = context.stateId } } }
	end,
	OnScheduledTick = function( context )
		local powered = pistonPowered( context )
		local extended = GetStateProperty( context.stateId, "extended" ) == true
		if powered == extended then return nil end
		local cells = powered and extendCells( context ) or retractCells( context )
		return cells and {
			cells = cells,
			compareCollision = true,
			afterTransaction = pistonSoundCommitted,
			afterTransactionData = pistonSoundResult( context, powered ),
		} or nil
	end,
}

MC.RegisterBlockUpdateHandler( "minecraft:piston", pistonHandler )
MC.RegisterBlockUpdateHandler( "minecraft:sticky_piston", pistonHandler )
MC.RegisterBlockUpdateHandler( "minecraft:piston_head", {
	OnNeighborUpdate = function( context )
		local offset = pistonOffset( context.stateId )
		local baseState = GetBlockState(
			context.bx - offset[1], context.by - offset[2], context.bz - offset[3]
		)
		if matchingBase( context.stateId, baseState ) then return nil end
		return { cells = { { bx = context.bx, by = context.by, bz = context.bz, stateId = airState() } }, compareCollision = true }
	end,
} )

function MC.RedstonePistonDiagnostics()
	local registeredModels = 0
	for _ in pairs( ClosedPistonRegisteredModels ) do registeredModels = registeredModels + 1 end
	return {
		piston = MC.BlockUpdateHandlerForName( "minecraft:piston" ) ~= nil,
		sticky = MC.BlockUpdateHandlerForName( "minecraft:sticky_piston" ) ~= nil,
		pushLimit = 12,
		rotatedVisualModels = registeredModels,
	}
end
