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

local function stateAtDistance( bx, by, bz, offset, distance )
	return GetBlockState( bx + offset[1] * distance, by + offset[2] * distance, bz + offset[3] * distance )
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
	local length = 0
	for distance = 1, 13 do
		local x = context.bx + offset[1] * distance
		local y = context.by + offset[2] * distance
		local z = context.bz + offset[3] * distance
		local stateId = GetBlockState( x, y, z )
		if stateId == 0 then break end
		if distance > 12 or not movable( stateId, x, y, z ) then return nil end
		length = distance
	end
	local headState = pistonHeadState( context.stateId )
	if not headState then return nil end
	local cells = {}
	for distance = length, 1, -1 do
		cells[#cells + 1] = {
			bx = context.bx + offset[1] * ( distance + 1 ),
			by = context.by + offset[2] * ( distance + 1 ),
			bz = context.bz + offset[3] * ( distance + 1 ),
			stateId = stateAtDistance( context.bx, context.by, context.bz, offset, distance ),
		}
	end
	cells[#cells + 1] = {
		bx = context.bx + offset[1], by = context.by + offset[2], bz = context.bz + offset[3],
		stateId = headState,
	}
	cells[#cells + 1] = {
		bx = context.bx, by = context.by, bz = context.bz,
		stateId = StateWith( context.stateId, "extended", true ) or context.stateId,
	}
	return cells
end

local function retractCells( context )
	local offset = pistonOffset( context.stateId )
	local frontX, frontY, frontZ = context.bx + offset[1], context.by + offset[2], context.bz + offset[3]
	local cells = { {
		bx = context.bx, by = context.by, bz = context.bz,
		stateId = StateWith( context.stateId, "extended", false ) or context.stateId,
	} }
	local frontState = airState()
	if stateName( context.stateId ) == "minecraft:sticky_piston" then
		local pullX, pullY, pullZ = context.bx + offset[1] * 2, context.by + offset[2] * 2, context.bz + offset[3] * 2
		local pullState = GetBlockState( pullX, pullY, pullZ )
		if pullState ~= 0 and movable( pullState, pullX, pullY, pullZ ) then
			frontState = pullState
			cells[#cells + 1] = { bx = pullX, by = pullY, bz = pullZ, stateId = airState() }
		end
	end
	cells[#cells + 1] = { bx = frontX, by = frontY, bz = frontZ, stateId = frontState }
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
		sound = extending and "mc/tile/piston/out.ogg" or "mc/tile/piston/in.ogg",
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
