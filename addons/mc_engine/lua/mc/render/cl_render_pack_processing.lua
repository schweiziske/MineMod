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
	local key = name .. "/" .. w .. "x" .. h
	local entry = bank.targets[key]
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
	instance.screenKey, instance.screenDone, instance.screenOutputs = nil, nil, nil
end

function P.Release( instance )
	if not instance then return end
	P.Invalidate( instance )
	instance.contextIdentities, instance.contextScratch = nil, nil
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
	local context = { key = entry.key, world = identity.world, time = identity.time, block_size = identity.block_size,
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

local function scalar( value, context, target, shadow )
	if type( value ) == "number" then return value end
	local key = value:match( "^setting:(.+)$" )
	if key then
		local setting = context.settings[key]
		if type( setting ) == "boolean" then return setting and 1 or 0 end
		return setting
	end
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

local function draw( record, target, screenPass )
	local pushed, clipped, toned, overrides, oldClip, oldTone, oldBlend, r, g, b
	local ok, err = pcall( function()
		oldBlend = render.GetBlend()
		r, g, b = render.GetColorModulation()
		if target.texture then render.PushRenderTarget( target.texture ) pushed = true end
		if not screenPass then
			oldClip = render.EnableClipping( false ) clipped = true
			oldTone = render.GetToneMappingScaleLinear() toned = true
			render.SetToneMappingScaleLinear( unitTone )
		end
		overrides = true
		render.OverrideDepthEnable( false, false )
		render.OverrideBlend( true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD )
		render.OverrideAlphaWriteEnable( true, target.texture ~= nil )
		render.OverrideColorWriteEnable( true, true )
		render.SetBlend( 1 ) render.SetColorModulation( 1, 1, 1 )
		local clear = target.clear
		if clear then render.Clear( clear[1] * 255, clear[2] * 255, clear[3] * 255, clear[4] * 255, false, false ) end
		render.SetMaterial( record.material )
		target.quad:Draw()
	end )
	local cleanupError
	local function restore( fn, ... )
		local restored, why = pcall( fn, ... )
		if not restored and not cleanupError then cleanupError = tostring( why ) end
	end
	if overrides then
		restore( render.OverrideDepthEnable, false, false )
		restore( render.OverrideBlend, false )
		restore( render.OverrideAlphaWriteEnable, false, false )
		restore( render.OverrideColorWriteEnable, false, false )
		restore( render.SetBlend, oldBlend ) restore( render.SetColorModulation, r, g, b )
	end
	if toned then restore( render.SetToneMappingScaleLinear, oldTone ) end
	if pushed then restore( render.PopRenderTarget ) end
	if clipped then restore( render.EnableClipping, oldClip ) end
	if cleanupError then error( tostring( err ) .. "; cleanup: " .. cleanupError, 0 ) end
	if not ok then error( err, 0 ) end
end

local function execute( instance, stage, context, shadow )
	local outputs = {}
	if stage == "shadowcomp" then for name, texture in pairs( instance.beginOutputs ) do outputs[name] = texture end end
	for _, record in ipairs( instance.stages[stage] ) do
		local pass, inputs, enabled = record.spec, {}, true
		for _, key in ipairs( pass.enableSettings or {} ) do
			local value = context.settings[key]
			if value == false or value == 0 then enabled = false end
		end
		for slot, input in pairs( pass.inputs ) do
			local texture = record.textures[slot]
			if input.target then texture = outputs[input.target]
			elseif input.builtin then texture = shadow.target end
			requireValue( texture ~= nil, "render_processing_input", "unavailable input for " .. pass.id .. "/" .. slot )
			inputs[slot] = texture
		end
		if not enabled then outputs[pass.output] = inputs[pass.disabledInput]
		else
			local target = targetFor( instance, pass.output, context, shadow )
			for slot, texture in pairs( inputs ) do
				requireValue( texture ~= target.texture and texture:GetName() ~= target.texture:GetName(),
					"render_processing_alias", "physical read/write alias in " .. pass.id )
				record.material:SetTexture( textureSlots[slot], texture )
			end
			for register, vector in pairs( pass.constants ) do
				for index = 1, 4 do record.material:SetFloat( "$" .. register .. "_" .. components[index],
					scalar( vector[index], context, target, shadow ) ) end
			end
			for key, semantic in pairs( pass.matrices ) do
				local matrix = record.matrices[key]
				P.ShadowWorldMatrix( matrix, shadow, semantic == "shadow_near_world" and 1 or 2, context.block_size, pass.worldPeriod )
				record.material:SetMatrix( "$" .. key .. "mat", matrix )
			end
			draw( record, target )
			instance.stats.draws = instance.stats.draws + 1
			outputs[pass.output] = target.texture
		end
	end
	return outputs
end

function P.Run( instance, stage, context, shadow )
	if not instance then return true end
	requireValue( not instance.retired and instance.bank.owner == instance and instance.stages[stage],
		"render_processing_owner", "invalid processing instance or stage" )
	if instance.key ~= context.key or instance.world ~= context.world then
		P.Invalidate( instance ) instance.key, instance.world = context.key, context.world
	end
	if stage == "shadowcomp" and not instance.beginOutputs then
		local ok, err = P.Run( instance, "begin", context )
		if not ok then return false, err end
	end
	local key = stage == "shadowcomp" and shadow.revision or context.key
	if stage == "begin" and instance.beginOutputs or stage == "shadowcomp" and instance.shadowKey == key then
		instance.stats.reused = instance.stats.reused + 1
		return true
	end
	-- No consumer may keep a partially overwritten stage or previous-frame output.
	instance.outputs, instance.shadowKey = nil, nil
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
	else instance.shadowKey = key end
	instance.outputs = result
	return true
end

-- Only the generic executor consumes this private snapshot; adapters never see
-- it. Run still checks the currently resident outputs after an A-B-A view trip.
function P.RunView( instance, stage, active, x, y, z, view, shadow )
	local entry = contextIdentity( instance, active, x, y, z, view )
	if not entry.context then entry.context = copyContext( instance, entry ) end
	return P.Run( instance, stage, entry.context, shadow )
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

-- Trusted bindings supply data and availability, not drawing or ordering.
-- Camera-stage outputs never overwrite the light-space export cache.
function P.RunScreen( instance, stage, context, adapter )
	requireValue( instance and not instance.retired and instance.bank.owner == instance and instance.stages[stage],
		"render_processing_owner", "screen stage has no processing owner" )
	local key = context.key
	if instance.screenKey ~= key then
		instance.screenKey, instance.screenDone, instance.screenOutputs = key, {}, {}
	end
	if instance.screenDone[stage] then instance.stats.reused = instance.stats.reused + 1 return true end
	local outputs, start = {}, SysTime()
	for name, value in pairs( instance.screenOutputs ) do outputs[name] = value end
	local ok, err = pcall( function()
		for _, record in ipairs( instance.stages[stage] ) do
			local spec = record.spec
			if adapter.Enabled( spec.binding, context ) then
				local target
				if spec.output == "screen" then
					local cache = instance.bank.screenQuads or {}
					instance.bank.screenQuads = cache
					local size = context.view_width .. "x" .. context.view_height
					if not cache[size] then
						local count = instance.bank.screenQuadCount or 0
						requireValue( count < 32, "render_processing_quad_budget", "32 screen viewport sizes reached; restart the client" )
						cache[size] = P.CopyQuad( context.view_width, context.view_height )
						instance.bank.screenQuadCount = count + 1
					end
					target = { width = context.view_width, height = context.view_height, quad = cache[size] }
				else target = targetFor( instance, spec.output, context ) end
				local inputs = {}
				for slot, input in pairs( spec.inputs ) do
					local texture = record.textures[slot]
					if input.target then texture = outputs[input.target] and outputs[input.target].texture
					elseif input.builtin then texture = adapter.Input( input.builtin, context ) end
					requireValue( texture and not texture:IsError(), "render_processing_input", "unavailable screen input: " .. spec.id .. "/" .. slot )
					requireValue( not target.texture or texture:GetName() ~= target.texture:GetName(),
						"render_processing_alias", "screen pass reads its output: " .. spec.id )
					inputs[slot] = texture
					record.material:SetTexture( textureSlots[slot], texture )
				end
				adapter.Bind( spec.binding, record.material, context, target, outputs, inputs )
				for register, vector in pairs( spec.constants ) do
					for index = 1, 4 do record.material:SetFloat( "$" .. register .. "_" .. components[index],
						scalar( vector[index], context, target ) ) end
				end
				draw( record, target, true )
				if target.texture then outputs[spec.output] = target end
				instance.stats.draws = instance.stats.draws + 1
				instance.stats.lastPass = spec.id
			else
				outputs[spec.output] = nil
				instance.stats.skipped = instance.stats.skipped + 1
			end
		end
	end )
	instance.stats.cpuMS = ( SysTime() - start ) * 1000
	if not ok then
		instance.screenOutputs, instance.screenDone = {}, {}
		instance.stats.failures = instance.stats.failures + 1
		return false, err
	end
	instance.screenOutputs, instance.screenDone[stage] = outputs, true
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
