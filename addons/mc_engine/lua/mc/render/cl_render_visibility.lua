-- Borrowed, synchronous section visibility input. Only queried cells enter the
-- numeric scratch arrays; neither the arrays nor resolved classes outlive a build.
MC = MC or {}
local Visibility = {}
MC.RenderVisibility = Visibility
Visibility.VERSION = 1

local C = MC.RenderMeshConstants
local floor = math.floor
local SIZE = MC.RENDER_SECTION_SIZE or 16
local WIDTH = SIZE + 2
local WIDTH2 = WIDTH * WIDTH
local STATE_CELLS = C.CS2 * 16
local FACE_BITS = { 1, 2, 4, 8, 16, 32 }

function Visibility.New( chunk, blockSections, perf )
	local view = {}
	local states, classes, touched = {}, {}, {}
	local staticClasses, classRevision = {}, MC.BlockStateVisualRevision
	local visibilityByType = {}
	local touchedCount = 0
	local minX, minY, minZ, snapshot
	-- Six neighbor queries run per emitted block. Count in upvalues and add
	-- them to the build's perf table once, in FlushStats.
	local queries, cacheHits, snapshotReads, stateReads, classResolves = 0, 0, 0, 0, 0
	local stateSections = chunk.stateSections
	local stateAPI = MC.StateSection
	local getState = stateAPI and ( stateAPI.GetFast or stateAPI.Get )
	local getBlockState = MC.GetBlockState
	local resolveClass = MC.ResolveBlockStateRenderClass
	local resolveVisual = MC.ResolveBlockStateVisual
	local blockTypeForState = MC.BlockTypeForState
	local visualFullCube = MC.BlockVisualIsFullCube
	local visualTranslucent = MC.BlockVisualIsTranslucent
	local blockFullCube = MC.BlockIsFullCube
	local blockTranslucent = MC.IsTranslucentBlock
	local specialEmitter = MC.BlockUsesSpecialVisualEmitter
	local sameLiquidKind = MC.RenderMesh.sameLiquidKind
	local blocks = MC.Blocks

	local function fail( code, bx, by, bz, detail )
		if not view.error then
			view.error = string.format( "%s at (%s,%s,%s): %s", code,
				tostring( bx ), tostring( by ), tostring( bz ), tostring( detail ) )
		end
		return nil
	end

	function view.BeginSection( index )
		if classRevision ~= MC.BlockStateVisualRevision then
			staticClasses = {}
			visibilityByType = {}
			classRevision = MC.BlockStateVisualRevision
		end
		for i = 1, touchedCount do
			local slot = touched[i]
			states[slot], classes[slot], touched[i] = nil, nil, nil
		end
		touchedCount = 0
		local zero = index - 1
		minX = ( zero % C.RENDER_SECTIONS_XY ) * SIZE
		minY = ( floor( zero / C.RENDER_SECTIONS_XY ) % C.RENDER_SECTIONS_XY ) * SIZE
		minZ = floor( zero / ( C.RENDER_SECTIONS_XY * C.RENDER_SECTIONS_XY ) ) * SIZE
		snapshot = blockSections and blockSections[index]
		perf.visibilitySections = ( perf.visibilitySections or 0 ) + 1
	end

	local function cacheSlot( lx, ly, lz )
		if minX == nil then return nil end
		local x, y, z = lx - minX + 1, ly - minY + 1, lz - minZ + 1
		-- Custom emitters may query beyond the one-cell halo. Never alias those
		-- coordinates into the compact section cache.
		if x < 0 or x >= WIDTH or y < 0 or y >= WIDTH or z < 0 or z >= WIDTH then return nil end
		return x + y * WIDTH + z * WIDTH2 + 1
	end

	local function readState( lx, ly, lz, bx, by, bz, slot )
		if view.error then return nil end
		if slot and states[slot] ~= nil then return states[slot] end
		local state, err
		if snapshot and not snapshot.partial and snapshot.slots and lx >= minX and lx < minX + SIZE
			and ly >= minY and ly < minY + SIZE and lz >= minZ and lz < minZ + SIZE then
			local key = lx - minX + ( ly - minY ) * SIZE + ( lz - minZ ) * SIZE * SIZE + 1
			local denseSlot = snapshot.slots[key]
			if denseSlot then state = snapshot.states[denseSlot] else state = 0 end
			snapshotReads = snapshotReads + 1
		elseif not chunk.nativeStateStorage and lx >= 0 and lx < C.CS and ly >= 0 and ly < C.CS and lz >= 0 and lz < C.CH then
			if not stateSections or not getState then
				return fail( "state_storage_unavailable", bx, by, bz )
			end
			local li = lx + ly * C.CS + lz * C.CS2
			local section = stateSections[floor( li / STATE_CELLS ) + 1]
			if section then
				stateReads = stateReads + 1
				state, err = getState( section, li % STATE_CELLS )
			else
				state = 0
			end
		else
			if not getBlockState then return fail( "world_state_reader_unavailable", bx, by, bz ) end
			stateReads = stateReads + 1
			state, err = getBlockState( bx, by, bz )
		end
		if type( state ) ~= "number" or state < 0 or state == math.huge or state ~= floor( state ) then
			return fail( "state_read_failed", bx, by, bz, err or state )
		end
		if slot then
			touchedCount = touchedCount + 1
			touched[touchedCount], states[slot] = slot, state
		end
		return state
	end

	function view.StateAt( lx, ly, lz, bx, by, bz )
		return readState( lx, ly, lz, bx, by, bz, cacheSlot( lx, ly, lz ) )
	end

	local function unpackClass( packed, state )
		local flags = packed % 8
		return floor( packed / 8 ), flags % 2 == 1, flags % 4 >= 2, flags >= 4, state
	end

	local function packedClassAt( lx, ly, lz, bx, by, bz )
		if view.error then return nil end
		queries = queries + 1
		local slot = cacheSlot( lx, ly, lz )
		local packed = slot and classes[slot]
		if packed ~= nil then
			cacheHits = cacheHits + 1
			return packed, states[slot]
		end
		local state = readState( lx, ly, lz, bx, by, bz, slot )
		if state == nil then return nil end
		if state == 0 then
			if slot then classes[slot] = 0 end
			return 0, 0
		end
		packed = staticClasses[state]
		if packed ~= nil then
			if slot then classes[slot] = packed end
			return packed, state
		end

		classResolves = classResolves + 1
		local id, fullCube, translucent, visual, positionIndependent
		if resolveClass then id, fullCube, translucent, visual, positionIndependent = resolveClass( state, bx, by, bz ) end
		if id == nil or id == 0 or fullCube == nil or translucent == nil then
			positionIndependent = false
			if not visual and resolveVisual then visual = resolveVisual( state, bx, by, bz ) end
			if id == nil then
				if visual then id = visual.id or visual.blockId end
				if id == nil and blockTypeForState then id = blockTypeForState( state ) end
			end
			if fullCube == nil then
				if visual and visualFullCube then
					fullCube = visualFullCube( visual, bx, by, bz )
				elseif id and blockFullCube then
					fullCube = blockFullCube( id, visual and visual.renderOrient or 0 )
				end
			end
			if translucent == nil then
				if visual and visualTranslucent then
					translucent = visualTranslucent( visual, bx, by, bz )
				elseif id and blockTranslucent then
					translucent = blockTranslucent( id )
				end
			end
		end
		if type( id ) ~= "number" or id < 0 or id == math.huge or id ~= floor( id )
			or ( id == 0 and not visual ) or fullCube == nil or translucent == nil then
			return fail( "render_class_unavailable", bx, by, bz, state )
		end
		local block = blocks and blocks[id]
		local transparent = translucent or block and block.transparent
		local special = specialEmitter and specialEmitter( id )
		packed = id * 8 + ( fullCube and 1 or 0 ) + ( transparent and 2 or 0 ) + ( special and 4 or 0 )
		if positionIndependent == true then staticClasses[state] = packed end
		if slot then classes[slot] = packed end
		return packed, state
	end

	function view.ClassAt( lx, ly, lz, bx, by, bz )
		local packed, state = packedClassAt( lx, ly, lz, bx, by, bz )
		if packed == nil then return nil end
		return unpackClass( packed, state )
	end

	local function rulesFor( curId )
		local rules = visibilityByType[curId]
		if not rules then
			rules = { [0] = true }
			visibilityByType[curId] = rules
		end
		return rules
	end

	local function visibleWithRules( curId, rules, lx, ly, lz, bx, by, bz )
		local packed = packedClassAt( lx, ly, lz, bx, by, bz )
		if packed == nil then return false end -- The caller must discard the failed build.
		local visible = rules[packed]
		if visible ~= nil then return visible end
		-- Classification remains coordinate-dependent. Only the pure relation
		-- between the current type and an already resolved class is shared.
		local id, fullCube, transparent, special = unpackClass( packed )
		if id == 0 or special then visible = true
		elseif sameLiquidKind( curId, id ) then visible = false
		elseif transparent then
			-- Unlike glass, leaves keep the faces between them (MC cutout leaves).
			local block = blocks[id]
			visible = id ~= curId or block ~= nil and string.match( block.name, "_leaves$" ) ~= nil
		else visible = not fullCube end
		rules[packed] = visible
		return visible
	end

	function view.VisibleAt( curId, lx, ly, lz, bx, by, bz )
		return visibleWithRules( curId, rulesFor( curId ), lx, ly, lz, bx, by, bz )
	end

	function view.FaceMask( curId, lx, ly, lz, bx, by, bz )
		local mask, count = 0, 0
		local rules = rulesFor( curId )
		for f = 1, 6 do
			local off = C.FACES[f].off
			if visibleWithRules( curId, rules, lx + off[1], ly + off[2], lz + off[3],
				bx + off[1], by + off[2], bz + off[3] ) then
				mask, count = mask + FACE_BITS[f], count + 1
			end
			if view.error then return nil end
		end
		return mask, count
	end

	function view.FlushStats()
		perf.visibilityQueries = ( perf.visibilityQueries or 0 ) + queries
		perf.visibilityCacheHits = ( perf.visibilityCacheHits or 0 ) + cacheHits
		perf.visibilitySnapshotReads = ( perf.visibilitySnapshotReads or 0 ) + snapshotReads
		perf.visibilityStateReads = ( perf.visibilityStateReads or 0 ) + stateReads
		perf.visibilityClassResolves = ( perf.visibilityClassResolves or 0 ) + classResolves
		queries, cacheHits, snapshotReads, stateReads, classResolves = 0, 0, 0, 0, 0
	end

	-- Called after Native submission has frozen all geometry and neighbor reads.
	-- Pending upload/publication keeps the view object, but no input arrays.
	function view.ReleaseInput()
		view.FlushStats()
		blockSections, snapshot, stateSections = nil, nil, nil
		states, classes, touched = {}, {}, {}
		staticClasses, visibilityByType = {}, {}
		touchedCount, minX, minY, minZ = 0, nil, nil, nil
	end

	return view
end
