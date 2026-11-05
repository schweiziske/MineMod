-- Model geometry shared by inventory icons and first/third-person blocks.
-- Keep coordinates in block ratios and UVs in sprite space until drawing.
MC = MC or {}

local cache = {}
local visualRevision, modelRevision

function MC.BlockPresentationQuads( stateId )
	local catalog = MC.StateVisualCatalog
	if not stateId or not catalog or stateId < 0 or stateId >= catalog.stateCount then return nil end
	local visual = MC.ResolveBlockStateVisual( stateId )
	if not visual or visual.forceBaseRenderer or visual.block.connection then return nil end
	-- Connections retain their authored item shapes (a fence item has rails,
	-- for example, even though its isolated world state is only a post).
	if visualRevision ~= MC.BlockStateVisualRevision or modelRevision ~= MC.StateVisualModelRevision then
		cache = {}
		visualRevision, modelRevision = MC.BlockStateVisualRevision, MC.StateVisualModelRevision
	end
	if cache[stateId] ~= nil then return cache[stateId] or nil end
	local modelStateId = stateId
	local name = visual.block.name
	if ( name == "minecraft:piston" or name == "minecraft:sticky_piston" )
	and stateId == visual.schema.defaultStateId then
		-- Vanilla's piston_inventory model presents the retracted head on top.
		-- Its default world state faces north, hiding the sticky face in the GUI.
		modelStateId = MC.StateWith( stateId, "facing", "up" )
		if not MC.Check( modelStateId ~= nil, "block_presentation_state", "Missing piston item pose for state %s", stateId ) then return nil end
	end
	local result = {}
	local complete = true
	local needsBaseRenderer = false
	MC.VisitStateVisualModels( modelStateId, 0, 0, 0, function( modelId )
		local model, reason = MC.StateVisualModelData( modelId )
		if reason == "empty_model" then
			needsBaseRenderer = true
			return
		end
		if not MC.Check( model ~= nil, "block_presentation_model", "Missing presentation model %s for state %s", modelId, stateId ) then
			complete = false
			return
		end
		for _, quad in ipairs( model.modelQuads ) do
			local points = {}
			local rotation = ( quad.rot or 0 ) % 4
			for index = 1, 4 do
				local x, y, z, u, v = MC.ModelQuadVertex( quad, index )
				if rotation == 1 then u, v = v, 1 - u
				elseif rotation == 2 then u, v = 1 - u, 1 - v
				elseif rotation == 3 then u, v = 1 - v, u end
				points[index] = { pos = Vector( x - 0.5, y - 0.5, z - 0.5 ), u = u, v = v }
			end
			local normal = ( points[2].pos - points[1].pos ):Cross( points[3].pos - points[1].pos )
			normal:Normalize()
			result[#result + 1] = {
				tile = MC.BlockModelSurface( model, quad ), uv = quad.uv,
				face = quad.face, points = points, normal = normal,
				tintCode = MC.BlockStateTintCode( stateId, visual.id, quad.tintIndex or -1 ),
			}
		end
	end )
	if not complete then return nil end
	-- Empty entity-rendered models continue through their existing fallback.
	if needsBaseRenderer or #result == 0 then
		cache[stateId] = false
		return nil
	end
	cache[stateId] = result
	return result
end

hook.Add( "OnReloaded", "mc_block_presentation", function() cache = {} end )
