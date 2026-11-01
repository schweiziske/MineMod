-- Pack-owned, ordered full-screen processing. No effect-specific bindings.
MC = MC or {}
local P = MC.RenderPackProcessing or { banks = {}, targetBytes = 0, targetCount = 0, materialCount = 0 }
MC.RenderPackProcessing = P
P.VERSION = 2
local requireValue = MC.RenderL2Resources.Require
local canonical = MC.RenderPackSchema.Canonical
local maxTargetBytes = 512 * 1048576
local unitTone = Vector( 1, 1, 1 )
local components = { "x", "y", "z", "w" }
local textureSlots = { s0 = "$basetexture", s1 = "$texture1", s2 = "$texture2", s3 = "$texture3",
	s4 = "$texture4", s5 = "$texture5", s6 = "$texture6", s7 = "$texture7" }

function P.CopyQuad( width, height )
	local quad = Mesh()
	mesh.Begin( quad, MATERIAL_QUADS, 1 )
	-- D3D9 integer pixel centres; UVs still address source texel centres.
	local x0, x1, y0, y1 = -1 - 1 / width, 1 - 1 / width, 1 + 1 / height, -1 + 1 / height
	for _, vertex in ipairs( { { x0, y0, 0, 0 }, { x1, y0, 1, 0 }, { x1, y1, 1, 1 }, { x0, y1, 0, 1 } } ) do
		mesh.Position( Vector( vertex[1], vertex[2], 0 ) )
		mesh.TexCoord( 0, vertex[3], vertex[4] )
		mesh.AdvanceVertex()
	end
	mesh.End()
	return quad
end

local function validateAPI()
	requireValue( GetRenderTargetEx and CreateMaterial and Mesh and Matrix and mesh.Begin and mesh.End
		and render.PushRenderTarget and render.PopRenderTarget and render.Clear and render.SetMaterial
		and render.OverrideBlend and render.OverrideDepthEnable and render.OverrideAlphaWriteEnable
		and render.OverrideColorWriteEnable and render.EnableClipping and render.GetToneMappingScaleLinear
		and render.SetToneMappingScaleLinear and render.GetBlend and render.GetColorModulation
		and render.SetBlend and render.SetColorModulation and render.GetRenderTarget
		and RT_SIZE_LITERAL and MATERIAL_RT_DEPTH_NONE and IMAGE_FORMAT_RGBA8888 and IMAGE_FORMAT_RGBA16161616F,
		"render_processing_api", "processing v1 requires scoped render state and RGBA render targets" )
end

local function targetFor( instance, name, context, shadow )
	local spec = instance.definition.pipeline.targets[name]
	local size = spec.size
	local w, h = size.width, size.height
	if size.relative == "view" then
		local scale = size.scale
		if size.maxWidth then scale = math.min( scale, size.maxWidth / context.view_width, size.maxHeight / context.view_height ) end
		w, h = context.view_width * scale, context.view_height * scale
	elseif size.relative == "shadow" then
		requireValue( shadow and shadow.target, "render_processing_shadow", "shadow-relative target requires a completed atlas" )
		w, h = shadow.target:Width() * size.scale, shadow.target:Height() * size.scale
	end
	w, h = math.max( 1, math.ceil( w ) ), math.max( 1, math.ceil( h ) )
	-- A 2048-square cascade uses a 2x4 atlas with sky-boundary rows.
	-- Keep view and fixed-size targets within their existing limits.
	local maxHeight = size.relative == "shadow" and 8192 or 4096
	requireValue( w <= 4096 and h <= maxHeight, "render_processing_size", "processing target exceeds its layout limit" )
	local bank = instance.bank
	-- Fast path: the same named target at the same size as last time.
	local recent = bank.recentTargets
	if not recent then recent = {} bank.recentTargets = recent end
	local entry = recent[name]
	if entry and entry.width == w and entry.height == h and entry.quad then return entry end
	local key = name .. "/" .. w .. "x" .. h
	entry = bank.targets[key]
	if not entry then
		local bytes = w * h * ( spec.format == "rgba8" and 4 or 8 )
		requireValue( P.targetCount < 128 and P.targetBytes + bytes <= maxTargetBytes,
			"render_processing_target_budget", "processing reached 128 targets / 512 MiB; restart to release engine RTs" )
		-- Charge before allocation: Source RTs cannot be freed, even after failure.
		P.targetCount, P.targetBytes = P.targetCount + 1, P.targetBytes + bytes
		local texture = GetRenderTargetEx( "mc_processing1_" .. P.targetCount .. "_" .. name, w, h,
			RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor( spec.filter == "point" and 1 or 0, 4, 8, 256, 512 ),
			0, spec.format == "rgba8" and IMAGE_FORMAT_RGBA8888 or IMAGE_FORMAT_RGBA16161616F )
		requireValue( texture and not texture:IsError() and texture:Width() == w and texture:Height() == h,
			"render_processing_target", "processing target allocation failed: " .. name )
		entry = { texture = texture, width = w, height = h, clear = spec.clear }
		bank.targets[key] = entry
	end
	if not entry.quad then entry.quad = P.CopyQuad( w, h ) end
	if not entry.name then entry.name = entry.texture:GetName() end
	recent[name] = entry
	return entry
end

function P.Create( definition, pack )
	if not definition or not definition.pipeline then return nil end
	validateAPI()
	local signature = pack .. "/" .. canonical( definition )
	local bank
	for _, candidate in ipairs( P.banks ) do
		if candidate.signature == signature and not candidate.owner then bank = candidate break end
	end
	if not bank then
		requireValue( #P.banks < 128, "render_processing_bank_budget", "128 processing owner versions reached; restart the client" )
		bank = { id = #P.banks + 1, signature = signature, targets = {}, passes = {} }
		P.banks[#P.banks + 1] = bank
	end
	local instance = { definition = definition, bank = bank, stages = { begin = {}, shadowcomp = {}, opaque = {}, world = {}, final = {} },
		stats = { begin = 0, shadowcomp = 0, opaque = 0, world = 0, final = 0, skipped = 0, reused = 0, draws = 0, failures = 0, cpuMS = 0 } }
	for index, pass in ipairs( definition.pipeline.passes ) do
		local record = bank.passes[index]
		if not record then
			local program = definition.programs[pass.program]
			local params = { ["$vertexshader"] = program.vertex, ["$pixshader"] = program.pixel,
				["$x360appchooser"] = 1, ["$vertexcolor"] = 1, ["$nocull"] = 1, ["$nofog"] = 1,
				["$depthtest"] = 0, ["$writedepth"] = 0, ["$ignorez"] = 0, ["$linearwrite"] = pass.output == "screen" and 0 or 1 }
			local textures = {}
			for slot, input in pairs( pass.inputs ) do
				local parameter = textureSlots[slot]
				local resource = input.resource and definition.resources[input.resource]
				params["$linearread_" .. parameter:sub( 2 )] = ( resource and resource.colorSpace == "srgb" or input.builtin == "scene_color" ) and 0 or 1
				params[parameter] = "vgui/white"
				if resource then
					textures[slot] = MC.RenderPackResources.ProcessingTexture( resource, input )
					params[parameter] = textures[slot]:GetName()
				end
			end
			requireValue( P.materialCount < 2048, "render_processing_material_budget", "2048 processing material versions reached" )
			P.materialCount = P.materialCount + 1
			local material = CreateMaterial( "mc_processing1_pass_" .. P.materialCount, "screenspace_general_8tex", params )
			requireValue( material and not material:IsError(), "render_processing_material", "could not load pass " .. pass.id )
			record = { spec = pass, material = material, textures = textures, matrices = {} }
			for key in pairs( pass.matrices ) do record.matrices[key] = Matrix() end
			bank.passes[index] = record
		end
		local stage = instance.stages[pass.stage]
		stage[#stage + 1] = record
	end
	-- A candidate never borrows an active instance's writable targets/materials.
	bank.owner = instance
	return instance
end

function P.Invalidate( instance )
	if not instance then return end
	instance.key, instance.beginOutputs, instance.outputs, instance.shadowKey = nil, nil, nil, nil
	instance.shadowSource = nil
	instance.screenKey, instance.screenDone, instance.screenOutputs = nil, nil, nil
	if instance.stageInputs then
		for _, snapshot in pairs( instance.stageInputs ) do snapshot.valid = false end
	end
end

function P.Release( instance )
	if not instance then return end
	P.Invalidate( instance )
	instance.contextIdentities, instance.contextScratch, instance.viewContext = nil, nil, nil
	instance.bank.owner, instance.retired = nil, true
end

-- One clock for package processing and geometry sampled later in the frame.
function P.FrameTime()
	local frame = FrameNumber()
	if P.frame ~= frame then P.frame, P.time = frame, RealTime() % 8192 end
	return P.time
end

local function sameValues( a, b )
	if not b then return false end
	for key, value in pairs( a ) do if b[key] ~= value then return false end end
	for key, value in pairs( b ) do if a[key] ~= value then return false end end
	return true
end

local function contextIdentity( instance, active, x, y, z, view )
	view = view or render.GetViewSetup( true )
	local w, h = view.width or view.w, view.height or view.h
	requireValue( type( w ) == "number" and type( h ) == "number" and w > 0 and h > 0 and w <= 16384 and h <= 16384,
		"render_processing_view", "processing requires finite viewport dimensions" )
	local ox, oy, oz = MC.ChunkRenderFrameOffset()
	local frame = FrameNumber()
	local angle = view.angles
	local rt = render.GetRenderTarget()
	local identity = instance.contextScratch or {}
	identity.frame, identity.version, identity.generation = frame, active.version, MC.StateWorldGeneration
	identity.viewportX, identity.viewportY, identity.rt = view.x, view.y, rt and rt:GetName()
	identity.pitch, identity.yaw, identity.roll = angle and angle.p, angle and angle.y, angle and angle.r
	identity.fov, identity.aspect = view.fov, view.aspectratio or view.aspect
	identity.znear, identity.zfar = view.znear, view.zfar
	identity.ortho = view.ortho ~= nil and canonical( view.ortho ) or nil
	identity.offcenter = view.offcenter ~= nil and canonical( view.offcenter ) or nil
	identity.time, identity.block_size, identity.world = P.FrameTime(), MC.API.Coords.BlockSize(), MC.World
	identity.view_x, identity.view_y, identity.view_z = x, y, z
	identity.view_width, identity.view_height = w, h
	identity.origin_x, identity.origin_y, identity.origin_z = ox, oy, oz
	-- Validated spec objects are unique keys, separate from camera fields.
	-- Keep a private scalar snapshot: callers can extend/mutate their context.
	for _, spec in ipairs( instance.definition.settings ) do identity[spec] = MC.RenderPackSettings.Get( spec.key ) end
	if instance.contextFrame ~= frame or not instance.contextIdentities then
		instance.contextFrame, instance.contextIdentities = frame, {}
	end
	-- Screen and light-space consumers interleave. A round trip must recover
	-- the same key without retaining identities beyond this engine frame.
	local identities = instance.contextIdentities
	for _, entry in ipairs( identities ) do
		if sameValues( identity, entry.identity ) then
			instance.contextScratch = identity
			return entry
		end
	end
	instance.contextSerial = ( instance.contextSerial or 0 ) + 1
	local entry = { identity = identity, key = "context/" .. instance.contextSerial }
	identities[#identities + 1] = entry
	instance.contextScratch = nil
	return entry
end

local function copyContext( instance, entry )
	local identity = entry.identity
	local context = { key = entry.key, world = identity.world, generation = identity.generation, version = identity.version,
		time = identity.time, block_size = identity.block_size,
		view_x = identity.view_x, view_y = identity.view_y, view_z = identity.view_z,
		view_width = identity.view_width, view_height = identity.view_height,
		origin_x = identity.origin_x, origin_y = identity.origin_y, origin_z = identity.origin_z, settings = {} }
	for _, spec in ipairs( instance.definition.settings ) do context.settings[spec.key] = identity[spec] end
	return context
end

-- Public callers (including screen adapters) may extend or retain their copy.
function P.Context( instance, active, x, y, z, view )
	return copyContext( instance, contextIdentity( instance, active, x, y, z, view ) )
end

-- Maps tile UV + normalized linear depth to world blocks. Reducing only the
-- translation by whole periods preserves periodic shaders across re-origining.
function P.ShadowWorldMatrix( matrix, shadow, index, blockSize, period )
	local view = shadow.views[index]
	local axes = { { view.rx, view.ux, view.fx, view.x - shadow.frameX },
		{ view.ry, view.uy, view.fy, view.y - shadow.frameY },
		{ view.rz, view.uz, view.fz, view.z - shadow.frameZ } }
	for row = 1, 3 do
		local a = axes[row]
		local translation = ( a[4] - a[1] * view.radius + a[2] * view.radius ) / blockSize
		if period then translation = translation % period end
		matrix:SetField( row, 1, a[1] * 2 * view.radius / blockSize )
		matrix:SetField( row, 2, -a[2] * 2 * view.radius / blockSize )
		matrix:SetField( row, 3, a[3] * view.zfar / blockSize )
		matrix:SetField( row, 4, translation )
	end
	for col = 1, 4 do matrix:SetField( 4, col, col == 4 and 1 or 0 ) end
end

-- Per-pass descriptors are compiled once per bank record: parameter names,
-- constant sources and input slots never change for a validated spec.
local derivedScalars = { target_width = true, target_height = true, target_texel_x = true, target_texel_y = true,
	shadow_resolution = true, sun_x = true, sun_y = true, sun_z = true }

local function compileRecord( record )
	if record.compiled then return end
	local pass = record.spec
	local constants = {}
	for register, vector in pairs( pass.constants ) do
		for index = 1, 4 do
			local value = vector[index]
			local entry = { param = "$" .. register .. "_" .. components[index] }
			if type( value ) == "number" then entry.number = value
			else
				local key = value:match( "^setting:(.+)$" )
				if key then entry.setting = key else entry.field = value end
			end
			constants[#constants + 1] = entry
		end
	end
	local matrices = {}
	for key, semantic in pairs( pass.matrices or {} ) do
		matrices[#matrices + 1] = { key = key, param = "$" .. key .. "mat", index = semantic == "shadow_near_world" and 1 or 2 }
	end
	local inputs = {}
	for slot, input in pairs( pass.inputs ) do
		inputs[#inputs + 1] = { slot = slot, param = textureSlots[slot], input = input }
	end
	record.constantList, record.matrixList, record.inputList, record.inputScratch = constants, matrices, inputs, {}
	record.compiled = true
end

local function constantValue( entry, context, target, shadow )
	local number = entry.number
	if number then return number end
	local key = entry.setting
	if key then
		local setting = context.settings[key]
		if type( setting ) == "boolean" then return setting and 1 or 0 end
		return setting
	end
	local value = entry.field
	if value == "target_width" then return target.width end
	if value == "target_height" then return target.height end
	if value == "target_texel_x" then return 1 / target.width end
	if value == "target_texel_y" then return 1 / target.height end
	if value == "shadow_resolution" then return shadow.resolution end
	if value == "sun_x" then return shadow.sx end
	if value == "sun_y" then return shadow.sy end
	if value == "sun_z" then return shadow.sz end
	return context[value]
end

local function bindConstants( record, context, target, shadow )
	local material, list = record.material, record.constantList
	for i = 1, #list do
		local entry = list[i]
		material:SetFloat( entry.param, constantValue( entry, context, target, shadow ) )
	end
end

-- Render state owned by the pass currently being drawn. Restoration clears
-- each flag before its engine call, so a failing restore is not repeated and
-- the remaining steps still run on the next attempt.
local drawState = { overrides = 0 }
local function restoreDrawState()
	local ds = drawState
	while ds.overrides > 0 do
		local step = ds.overrides
		ds.overrides = step - 1
		if step == 6 then render.OverrideDepthEnable( false, false )
		elseif step == 5 then render.OverrideBlend( false )
		elseif step == 4 then render.OverrideAlphaWriteEnable( false, false )
		elseif step == 3 then render.OverrideColorWriteEnable( false, false )
		elseif step == 2 then render.SetBlend( ds.oldBlend )
		else render.SetColorModulation( ds.r, ds.g, ds.b ) end
	end
	if ds.toned then ds.toned = false render.SetToneMappingScaleLinear( ds.oldTone ) end
	if ds.pushed then ds.pushed = false render.PopRenderTarget() end
	if ds.clipped then ds.clipped = false render.EnableClipping( ds.oldClip ) end
end

local function drawBody( record, target, screenPass )
	local ds = drawState
	ds.oldBlend = render.GetBlend()
	ds.r, ds.g, ds.b = render.GetColorModulation()
	if target.texture then render.PushRenderTarget( target.texture ) ds.pushed = true end
	if not screenPass then
		ds.oldClip = render.EnableClipping( false ) ds.clipped = true
		ds.oldTone = render.GetToneMappingScaleLinear() ds.toned = true
		render.SetToneMappingScaleLinear( unitTone )
	end
	ds.overrides = 6
	render.OverrideDepthEnable( false, false )
	render.OverrideBlend( true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD )
	render.OverrideAlphaWriteEnable( true, target.texture ~= nil )
	render.OverrideColorWriteEnable( true, true )
	render.SetBlend( 1 ) render.SetColorModulation( 1, 1, 1 )
	local clear = target.clear
	if clear then render.Clear( clear[1] * 255, clear[2] * 255, clear[3] * 255, clear[4] * 255, false, false ) end
	render.SetMaterial( record.material )
	target.quad:Draw()
end

-- One protected call per pass. Every state it acquired is restored; a
-- restore failure is reported after all other restores were attempted.
local function draw( record, target, screenPass )
	local ds = drawState
	ds.overrides, ds.toned, ds.pushed, ds.clipped = 0, false, false, false
	local ok, err = pcall( drawBody, record, target, screenPass )
	local cleanupError
	repeat
		local done, why = pcall( restoreDrawState )
		if not done and not cleanupError then cleanupError = tostring( why ) end
	until done
	if cleanupError then error( tostring( err ) .. "; cleanup: " .. cleanupError, 0 ) end
	if not ok then error( err, 0 ) end
end

local function execute( instance, stage, context, shadow )
	-- Stage output tables are reused; Invalidate drops references on failure.
	local scratch = instance.stageScratch
	if not scratch then scratch = {} instance.stageScratch = scratch end
	local outputs = scratch[stage]
	if not outputs then outputs = {} scratch[stage] = outputs end
	for name in pairs( outputs ) do outputs[name] = nil end
	if stage == "shadowcomp" then for name, texture in pairs( instance.beginOutputs ) do outputs[name] = texture end end
	local records = instance.stages[stage]
	for r = 1, #records do
		local record = records[r]
		compileRecord( record )
		local pass, inputs, enabled = record.spec, record.inputScratch, true
		local enableSettings = pass.enableSettings
		if enableSettings then
			for i = 1, #enableSettings do
				local value = context.settings[enableSettings[i]]
				if value == false or value == 0 then enabled = false end
			end
		end
		for name in pairs( inputs ) do inputs[name] = nil end
		local inputList = record.inputList
		for i = 1, #inputList do
			local item = inputList[i]
			local input, texture = item.input, record.textures[item.slot]
			if input.target then texture = outputs[input.target]
			elseif input.builtin then texture = shadow.target end
			requireValue( texture ~= nil, "render_processing_input", "unavailable input for " .. pass.id .. "/" .. item.slot )
			inputs[item.slot] = texture
		end
		if not enabled then outputs[pass.output] = inputs[pass.disabledInput]
		else
			local target = targetFor( instance, pass.output, context, shadow )
			for i = 1, #inputList do
				local item = inputList[i]
				local texture = inputs[item.slot]
				requireValue( texture ~= target.texture and texture:GetName() ~= target.name,
					"render_processing_alias", "physical read/write alias in " .. pass.id )
				record.material:SetTexture( item.param, texture )
			end
			bindConstants( record, context, target, shadow )
			local matrixList = record.matrixList
			for i = 1, #matrixList do
				local item = matrixList[i]
				local matrix = record.matrices[item.key]
				P.ShadowWorldMatrix( matrix, shadow, item.index, context.block_size, pass.worldPeriod )
				record.material:SetMatrix( item.param, matrix )
			end
			draw( record, target )
			instance.stats.draws = instance.stats.draws + 1
			outputs[pass.output] = target.texture
		end
	end
	return outputs
end

-- begin/shadowcomp outputs depend only on what their passes read: declared
-- context scalars and settings, view-relative target sizes, block size (world
-- matrices) and the world identity. Anything else (frame number, camera
-- angles, render target, unreferenced view fields) never forces a rerun.
local function stageDependencies( instance, stage )
	local all = instance.stageDeps
	if not all then all = {} instance.stageDeps = all end
	local deps = all[stage]
	if deps then return deps end
	local fields, settings, seenFields, seenSettings = {}, {}, {}, {}
	local function field( name )
		if not seenFields[name] then seenFields[name] = true fields[#fields + 1] = name end
	end
	local function setting( key )
		if not seenSettings[key] then seenSettings[key] = true settings[#settings + 1] = key end
	end
	field( "block_size" )
	local pipeline = instance.definition.pipeline
	for _, pass in ipairs( pipeline.passes ) do
		if pass.stage == stage then
			for _, vector in pairs( pass.constants ) do
				for index = 1, 4 do
					local value = vector[index]
					if type( value ) == "string" then
						local key = value:match( "^setting:(.+)$" )
						if key then setting( key ) elseif not derivedScalars[value] then field( value ) end
					end
				end
			end
			for _, key in ipairs( pass.enableSettings or {} ) do setting( key ) end
			local spec = pipeline.targets[pass.output]
			if spec and spec.size.relative == "view" then field( "view_width" ) field( "view_height" ) end
		end
	end
	deps = { fields = fields, settings = settings }
	all[stage] = deps
	return deps
end

local function sameStageInputs( instance, stage, context, ignoreTime )
	local snapshot = instance.stageInputs and instance.stageInputs[stage]
	if not snapshot or not snapshot.valid or snapshot.world ~= context.world
		or snapshot.generation ~= context.generation or snapshot.version ~= context.version then return false end
	local deps = stageDependencies( instance, stage )
	local fields = deps.fields
	for i = 1, #fields do
		local name = fields[i]
		if snapshot[name] ~= context[name] and not ( ignoreTime and name == "time" ) then return false end
	end
	local settings, values = deps.settings, snapshot.settings
	for i = 1, #settings do
		local key = settings[i]
		if values[key] ~= context.settings[key] then return false end
	end
	return true
end

local function rememberStageInputs( instance, stage, context )
	local all = instance.stageInputs
	if not all then all = {} instance.stageInputs = all end
	local snapshot = all[stage]
	if not snapshot then snapshot = { settings = {} } all[stage] = snapshot end
	snapshot.valid, snapshot.world = true, context.world
	snapshot.generation, snapshot.version = context.generation, context.version
	local deps = stageDependencies( instance, stage )
	for _, name in ipairs( deps.fields ) do snapshot[name] = context[name] end
	for _, key in ipairs( deps.settings ) do snapshot.settings[key] = context.settings[key] end
end

-- shadow.timeInvariant: the shadow coordinator asserts that the raw atlas has
-- no time-varying input (no water interface pixels), so a shadowcomp stage
-- reading `time` produces the same output at any time.
function P.Run( instance, stage, context, shadow )
	if not instance then return true end
	requireValue( not instance.retired and instance.bank.owner == instance and instance.stages[stage],
		"render_processing_owner", "invalid processing instance or stage" )
	if instance.world ~= context.world then
		P.Invalidate( instance ) instance.world = context.world
	end
	if stage == "shadowcomp" then
		local ok, err = P.Run( instance, "begin", context )
		if not ok then return false, err end
	end
	local ignoreTime = stage == "shadowcomp" and shadow.timeInvariant == true
	if sameStageInputs( instance, stage, context, ignoreTime ) and ( stage == "begin" and instance.beginOutputs
		or stage == "shadowcomp" and instance.shadowKey == shadow.revision and instance.shadowSource == shadow.target ) then
		instance.stats.reused = instance.stats.reused + 1
		return true
	end
	-- No consumer may keep a partially overwritten stage or previous output.
	instance.outputs, instance.shadowKey, instance.shadowSource = nil, nil, nil
	if instance.stageInputs and instance.stageInputs[stage] then instance.stageInputs[stage].valid = false end
	local start = SysTime()
	P.rendering = true
	local ok, result = pcall( execute, instance, stage, context, shadow )
	P.rendering = false
	instance.stats.cpuMS = ( SysTime() - start ) * 1000
	if not ok then
		P.Invalidate( instance )
		instance.stats.failures = instance.stats.failures + 1
		return false, result
	end
	instance.stats[stage] = instance.stats[stage] + 1
	if stage == "begin" then instance.beginOutputs = result
	else instance.shadowKey, instance.shadowSource = shadow.revision, shadow.target end
	rememberStageInputs( instance, stage, context )
	instance.outputs = result
	return true
end

-- Only the generic executor consumes this private, reused context; adapters
-- never see it. Run decides reuse from the stage's declared dependencies.
function P.RunView( instance, stage, active, x, y, z, view, shadow )
	view = view or render.GetViewSetup( true )
	local w, h = view.width or view.w, view.height or view.h
	requireValue( type( w ) == "number" and type( h ) == "number" and w > 0 and h > 0 and w <= 16384 and h <= 16384,
		"render_processing_view", "processing requires finite viewport dimensions" )
	local context = instance.viewContext
	if not context then context = { settings = {} } instance.viewContext = context end
	context.world, context.generation, context.version = MC.World, MC.StateWorldGeneration, active.version
	context.time, context.block_size = P.FrameTime(), MC.API.Coords.BlockSize()
	context.view_x, context.view_y, context.view_z = x, y, z
	context.view_width, context.view_height = w, h
	context.origin_x, context.origin_y, context.origin_z = MC.ChunkRenderFrameOffset()
	local settings = context.settings
	for _, spec in ipairs( instance.definition.settings ) do settings[spec.key] = MC.RenderPackSettings.Get( spec.key ) end
	return P.Run( instance, stage, context, shadow )
end

-- Geometry adapters use the same owner bank and cumulative allocation budget.
function P.SceneTarget( instance, name, width, height, format, point, depth )
	requireValue( instance and not instance.retired and instance.bank.owner == instance,
		"render_processing_owner", "scene target requires an active processing owner" )
	local key = "scene/" .. name .. "/" .. width .. "x" .. height .. "/" .. format .. "/" .. tostring( point ) .. "/" .. tostring( depth )
	local entry = instance.bank.targets[key]
	if entry then return entry end
	local bytes = width * height * ( ( format == "rgba16f" and 8 or 4 ) + ( depth and 4 or 0 ) )
	requireValue( width > 0 and height > 0 and width <= 4096 and height <= 4096
		and P.targetCount < 128 and P.targetBytes + bytes <= maxTargetBytes,
		"render_processing_target_budget", "scene processing reached 128 targets / 512 MiB; restart the client" )
	P.targetCount, P.targetBytes = P.targetCount + 1, P.targetBytes + bytes
	local texture = GetRenderTargetEx( "mc_processing_scene_" .. P.targetCount .. "_" .. name, width, height, RT_SIZE_LITERAL,
		depth and MATERIAL_RT_DEPTH_SEPARATE or MATERIAL_RT_DEPTH_NONE, bit.bor( point and 1 or 0, 4, 8, 256, 512 ),
		0, format == "rgba16f" and IMAGE_FORMAT_RGBA16161616F or IMAGE_FORMAT_RGBA8888 )
	requireValue( texture and not texture:IsError() and texture:Width() == width and texture:Height() == height,
		"render_processing_target", "scene target allocation failed: " .. name )
	entry = { texture = texture, width = width, height = height, quad = P.CopyQuad( width, height ) }
	instance.bank.targets[key] = entry
	return entry
end

local function clearTable( t )
	for key in pairs( t ) do t[key] = nil end
	return t
end

local function screenTarget( instance, width, height )
	local bank = instance.bank
	local cache = bank.screenTargets
	if not cache then cache = {} bank.screenTargets = cache end
	local size = width * 32768 + height
	local target = cache[size]
	if not target then
		local count = bank.screenQuadCount or 0
		requireValue( count < 32, "render_processing_quad_budget", "32 screen viewport sizes reached; restart the client" )
		target = { width = width, height = height, quad = P.CopyQuad( width, height ) }
		cache[size] = target
		bank.screenQuadCount = count + 1
	end
	return target
end

local function executeScreen( instance, stage, context, adapter, outputs )
	local records = instance.stages[stage]
	for r = 1, #records do
		local record = records[r]
		compileRecord( record )
		local spec = record.spec
		if adapter.Enabled( spec.binding, context ) then
			local target
			if spec.output == "screen" then target = screenTarget( instance, context.view_width, context.view_height )
			else target = targetFor( instance, spec.output, context ) end
			local inputs, inputList = clearTable( record.inputScratch ), record.inputList
			for i = 1, #inputList do
				local item = inputList[i]
				local input, slot = item.input, item.slot
				local texture = record.textures[slot]
				if input.target then texture = outputs[input.target] and outputs[input.target].texture
				elseif input.builtin then texture = adapter.Input( input.builtin, context ) end
				requireValue( texture and not texture:IsError(), "render_processing_input", "unavailable screen input: " .. spec.id .. "/" .. slot )
				requireValue( not target.texture or texture:GetName() ~= target.name,
					"render_processing_alias", "screen pass reads its output: " .. spec.id )
				inputs[slot] = texture
				record.material:SetTexture( item.param, texture )
			end
			adapter.Bind( spec.binding, record.material, context, target, outputs, inputs )
			bindConstants( record, context, target )
			draw( record, target, true )
			if target.texture then outputs[spec.output] = target end
			instance.stats.draws = instance.stats.draws + 1
			instance.stats.lastPass = spec.id
		else
			outputs[spec.output] = nil
			instance.stats.skipped = instance.stats.skipped + 1
		end
	end
end

-- Trusted bindings supply data and availability, not drawing or ordering.
-- Camera-stage outputs never overwrite the light-space export cache.
-- screenOutputs is valid until the next RunScreen call; callers read it
-- immediately after a successful stage.
function P.RunScreen( instance, stage, context, adapter )
	requireValue( instance and not instance.retired and instance.bank.owner == instance and instance.stages[stage],
		"render_processing_owner", "screen stage has no processing owner" )
	local key = context.key
	if instance.screenKey ~= key or not instance.screenDone or not instance.screenOutputs then
		instance.screenKey = key
		instance.screenDone = clearTable( instance.screenDone or {} )
		instance.screenOutputs = clearTable( instance.screenOutputs or {} )
	end
	if instance.screenDone[stage] then instance.stats.reused = instance.stats.reused + 1 return true end
	local outputs = instance.screenSpare
	if not outputs or outputs == instance.screenOutputs then outputs = {} end
	clearTable( outputs )
	local start = SysTime()
	for name, value in pairs( instance.screenOutputs ) do outputs[name] = value end
	local ok, err = pcall( executeScreen, instance, stage, context, adapter, outputs )
	instance.stats.cpuMS = ( SysTime() - start ) * 1000
	if not ok then
		clearTable( instance.screenOutputs ) clearTable( instance.screenDone )
		instance.screenSpare = outputs
		instance.stats.failures = instance.stats.failures + 1
		return false, err
	end
	instance.screenSpare, instance.screenOutputs = instance.screenOutputs, outputs
	instance.screenDone[stage] = true
	instance.stats[stage] = instance.stats[stage] + 1
	instance.stats.lastStage = stage
	return true
end

function P.Export( instance, name )
	if not instance or not instance.outputs then return nil end
	return instance.outputs[instance.definition.pipeline.exports[name]]
end

concommand.Add( "mc_render_processing_stats", function()
	local active = MC.RenderPackRuntime.active
	local instance = active and active.processing
	local s = instance and instance.stats
	print( string.format( "[MC processing] active=%s targets=%d bytes=%d materials=%d GPU=unmeasured",
		tostring( instance ~= nil ), P.targetCount, P.targetBytes, P.materialCount ) )
	if s then print( string.format( "[MC processing] begin=%d shadowcomp=%d reused=%d draws=%d failures=%d lastCPU=%.3fms",
		s.begin, s.shadowcomp, s.reused, s.draws, s.failures, s.cpuMS ) ) end
	if s then print( string.format( "[MC processing screen] opaque=%d world=%d final=%d skipped=%d last=%s/%s",
		s.opaque, s.world, s.final, s.skipped, tostring( s.lastStage ), tostring( s.lastPass ) ) ) end
end )
