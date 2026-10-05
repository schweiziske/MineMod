-- Moving light sources never enter the voxel propagation/mesh rebuild queue.
-- Providers own semantics; this module owns a bounded view list and GPU data.
MC = MC or {}
local D = MC.RenderDynamicLights or {
	providers = {}, classes = {}, records = {}, active = {}, selected = {},
	materials = {}, materialCount = 0, pixels = {}, previousPixels = {},
	stats = { uploads = 0, draws = 0, culled = 0, sourceUpdates = 0 }, revision = 0,
}
MC.RenderDynamicLights = D
D.VERSION, D.MAX_LIGHTS = 1, 8
local R, Coords = MC.RenderL2Resources, MC.API.Coords
local floor, min, max, sqrt, abs = math.floor, math.min, math.max, math.sqrt, math.abs
local enabled = CreateClientConVar( "mc_dynamic_lights", "1", true, false, "Moving lights in vanilla and shader packs", 0, 1 )
local limit = CreateClientConVar( "mc_dynamic_lights_max", "8", true, false, "Maximum visible moving lights", 0, 8 )
local flashlight = CreateClientConVar( "mc_dynamic_flashlight", "1", true, false, "Receive the F flashlight on Minecraft surfaces", 0, 1 )
local viewPoint = Vector()
D.count, D.ready, D.lastFrame = 0, false, nil
D.cpuSelected, D.cpuSelectionValid = {}, false

local function finite( x ) return type( x ) == "number" and x == x and abs( x ) < math.huge end

local function forget( record )
	local index, records = record.index, D.records
	local last = records[#records]
	records[#records] = nil
	if last ~= record then records[index], last.index = last, index end
	record.provider.entities[record.entity] = nil
	record.active = false
	D.lastFrame, D.ready, D.cpuSelectionValid = nil, false, false
end

local function track( provider, ent )
	if provider.entities[ent] or not IsValid( ent ) then return end
	local record = { provider = provider, entity = ent, index = #D.records + 1,
		key = provider.id .. "/" .. ent:EntIndex(), strength = 1, x = 0, y = 0, z = 0, dx = 0, dy = 0, dz = 1 }
	provider.entities[ent] = record
	D.records[record.index] = record
	D.lastFrame, D.ready, D.cpuSelectionValid = nil, false, false
end

function D.UnregisterProvider( id )
	local provider = D.providers[id]
	if not provider then return false, "unknown_dynamic_light_provider" end
	for i = #D.records, 1, -1 do
		if D.records[i].provider == provider then forget( D.records[i] ) end
	end
	D.classes[provider.class][id], D.providers[id] = nil, nil
	return true
end

-- Public boundary: fixed radius/linear radiance/cone are validated once.
-- sample(ent, state, time) updates world-space x/y/z, and dx/dy/dz for spots;
-- returns true while emitting, false when dark. state is reused, not allocated.
function D.RegisterProvider( id, definition )
	if type( id ) ~= "string" or #id == 0 or #id > 128 or type( definition ) ~= "table" then
		return false, "invalid_dynamic_light_provider"
	end
	local class, sample, radius, color = definition.class, definition.sample, definition.radius, definition.color
	if type( class ) ~= "string" or #class == 0 or type( sample ) ~= "function" then return false, "invalid_dynamic_light_source" end
	if not finite( radius ) or radius < 1 / 64 or radius > 128 then return false, "invalid_dynamic_light_radius" end
	if type( color ) ~= "table" then return false, "invalid_dynamic_light_color" end
	for i = 1, 3 do
		if not finite( color[i] ) or color[i] < 0 or color[i] > 16 then return false, "invalid_dynamic_light_color" end
	end
	local spot = definition.kind == "spot"
	if definition.kind ~= nil and definition.kind ~= "point" and not spot then return false, "invalid_dynamic_light_kind" end
	local inner, outer = definition.innerCos or 1, definition.outerCos or 0
	if spot and ( not finite( inner ) or not finite( outer ) or outer < 0 or inner > 1 or inner - outer < 1 / 65535 ) then
		return false, "invalid_dynamic_light_cone"
	end
	if D.providers[id] then D.UnregisterProvider( id ) end
	local provider = { id = id, class = class, sample = sample, radius = radius,
		r = color[1], g = color[2], b = color[3], spot = spot, inner = inner, outer = outer,
		outerSin = spot and sqrt( 1 - outer * outer ) or 0, entities = {} }
	D.providers[id] = provider
	D.classes[class] = D.classes[class] or {}
	D.classes[class][id] = provider
	-- One inventory at registration; entity lifecycle hooks maintain it after that.
	for _, ent in ipairs( ents.FindByClass( class ) ) do track( provider, ent ) end
	return true
end

hook.Add( "NetworkEntityCreated", "mc_dynamic_lights", function( ent )
	local providers = D.classes[ent:GetClass()]
	if providers then for _, provider in pairs( providers ) do track( provider, ent ) end end
end )
hook.Add( "EntityRemoved", "mc_dynamic_lights", function( ent )
	for _, provider in pairs( D.providers ) do
		local record = provider.entities[ent]
		if record then forget( record ) end
	end
end )

function D.Invalidate()
	D.lastFrame, D.ready, D.count = nil, false, 0
	D.cpuSelectionValid = false
	D.revision = D.revision + 1
end
hook.Add( "MCWorldFrameInvalidated", "mc_dynamic_lights", D.Invalidate )
hook.Add( "MCWorldAdapterChanged", "mc_dynamic_lights", D.Invalidate )
hook.Add( "PostCleanupMap", "mc_dynamic_lights", D.Invalidate )
cvars.AddChangeCallback( "mc_dynamic_lights", D.Invalidate, "mc_dynamic_lights" )
cvars.AddChangeCallback( "mc_dynamic_lights_max", D.Invalidate, "mc_dynamic_lights" )
cvars.AddChangeCallback( "mc_dynamic_flashlight", D.Invalidate, "mc_dynamic_lights" )

function D.UpdateSources()
	local frame, on = FrameNumber(), enabled:GetBool()
	if D.lastFrame == frame and D.lastEnabled == on and D.world == MC.World and D.generation == MC.StateWorldGeneration then return end
	D.lastFrame, D.lastEnabled, D.world, D.generation = frame, on, MC.World, MC.StateWorldGeneration
	D.ready, D.cpuSelectionValid = false, false
	local active, count, now = D.active, 0, CurTime()
	for i = #D.records, 1, -1 do
		local record = D.records[i]
		local ent, provider = record.entity, record.provider
		record.active = false
		if not IsValid( ent ) then
			forget( record )
		elseif on and not ent:IsDormant() then
			record.strength = 1
			local ok, emitting = pcall( provider.sample, ent, record, now )
			if not ok then
				MC.Fault( "dynamic_light_provider", "%s: %s", provider.id, tostring( emitting ) )
			elseif emitting then
				local valid = finite( record.x ) and finite( record.y ) and finite( record.z )
					and finite( record.strength ) and record.strength >= 0 and record.strength <= 1
				if provider.spot then
					valid = valid and finite( record.dx ) and finite( record.dy ) and finite( record.dz )
					if valid then
						local length = sqrt( record.dx * record.dx + record.dy * record.dy + record.dz * record.dz )
						valid = length > 0.000001
						if valid then record.dx, record.dy, record.dz = record.dx / length, record.dy / length, record.dz / length end
					end
				end
				if valid then
					record.active = record.strength > 0
					if record.active then count = count + 1 active[count] = record end
				else
					MC.Fault( "dynamic_light_sample", "%s returned invalid world position, direction or strength", provider.id )
				end
			end
		end
	end
	for i = #active, count + 1, -1 do active[i] = nil end
	D.stats.sourceUpdates = D.stats.sourceUpdates + 1
end

local function word( value ) return min( 65535, max( 0, floor( value + 0.5 ) ) ) end
local function pixel( lo, hi ) return lo % 256 + floor( lo / 256 ) * 256 + hi % 256 * 65536 + floor( hi / 256 ) * 16777216 end
local function octahedron( x, y, z )
	local sum = abs( x ) + abs( y ) + abs( z )
	x, y, z = x / sum, y / sum, z / sum
	if z < 0 then
		local oldX = x
		x = ( 1 - abs( y ) ) * ( x < 0 and -1 or 1 )
		y = ( 1 - abs( oldX ) ) * ( y < 0 and -1 or 1 )
	end
	return word( ( x * 0.5 + 0.5 ) * 65535 ), word( ( y * 0.5 + 0.5 ) * 65535 )
end

local function selectLights( eye, blockSize, output )
	local selected, count, cap = output or D.selected, 0, limit:GetInt()
	for i = #selected, 1, -1 do selected[i] = nil end
	local localPlayer = LocalPlayer()
	for i = 1, #D.active do
		local light = D.active[i]
		light.rx, light.ry, light.rz = ( light.x - eye.x ) / blockSize, ( light.y - eye.y ) / blockSize, ( light.z - eye.z ) / blockSize
		-- Reserve the signed packing range; out-of-range lights cannot affect
		-- receivers inside the current nearby-light budget and are never clamped.
		if abs( light.rx ) < 480 and abs( light.ry ) < 480 and abs( light.rz ) < 480 then
			local distance = sqrt( light.rx * light.rx + light.ry * light.ry + light.rz * light.rz )
			light.rank = light.provider.radius / ( distance + 1 )
			if light.entity == localPlayer and light.provider.spot then light.rank = light.rank + 10000 end
			local at = count + 1
			while at > 1 do
				local previous = selected[at - 1]
				if previous.rank > light.rank or previous.rank == light.rank and previous.key < light.key then break end
				at = at - 1
			end
			if at <= cap then
				count = min( count + 1, cap )
				for j = count, at + 1, -1 do selected[j] = selected[j - 1] end
				selected[at] = light
			end
		end
	end
	return count
end

function D.Prepare( x, y, z )
	D.ready = false
	D.UpdateSources()
	local blockSize = Coords.BlockSize()
	viewPoint.x, viewPoint.y, viewPoint.z = x, y, z
	local eye, why = Coords.RenderToWorld( viewPoint )
	if not eye then D.Invalidate() return MC.Fault( "dynamic_light_view", "%s", tostring( why ) ) end
	local count = selectLights( eye, blockSize )
	-- Packs without an exposure setting (e.g. vanilla) keep unit exposure.
	local exposure = MC.RenderPackSettings.Get( "exposure" ) or 1
	if x ~= D.eyeX or y ~= D.eyeY or z ~= D.eyeZ or count ~= D.count or blockSize ~= D.blockSize or exposure ~= D.exposure then
		D.revision = D.revision + 1
	end
	D.eyeX, D.eyeY, D.eyeZ, D.count, D.blockSize, D.exposure = x, y, z, count, blockSize, exposure
	D.ready = false
	if count == 0 or D.materialCount == 0 then D.ready = true return true end
	local pixels = D.pixels
	for i = 1, 40 do pixels[i] = 0 end
	for i = 1, count do
		local light, offset = D.selected[i], ( i - 1 ) * 5
		local p = light.provider
		pixels[offset + 1] = pixel( word( light.rx * 64 + 32768 ), word( light.ry * 64 + 32768 ) )
		pixels[offset + 2] = pixel( word( light.rz * 64 + 32768 ), word( p.radius * 64 ) )
		local scale = light.strength * 255 / 16
		pixels[offset + 3] = floor( p.r * scale + 0.5 ) + floor( p.g * scale + 0.5 ) * 256
			+ floor( p.b * scale + 0.5 ) * 65536 + ( p.spot and 255 * 16777216 or 0 )
		if p.spot then
			local u, v = octahedron( light.dx, light.dy, light.dz )
			pixels[offset + 4] = pixel( u, v )
			pixels[offset + 5] = pixel( word( p.inner * 65535 ), word( p.outer * 65535 ) )
		end
	end
	local changed = not D.uploadValid
	for i = 1, 40 do if pixels[i] ~= D.previousPixels[i] then changed = true break end end
	if changed then
		D.uploadValid = false
		local ok, err = pcall( R.UploadDynamicLights, pixels )
		if not ok then return MC.Fault( "dynamic_light_upload", "%s", type( err ) == "table" and err.message or tostring( err ) ) end
		for i = 1, 40 do D.previousPixels[i] = pixels[i] end
		D.uploadValid = true
		D.stats.uploads = D.stats.uploads + 1
	end
	D.ready = true
	return true
end

-- Registration/build boundary; no textures or materials are created in Draw.
function D.RegisterMaterial( base, program, owner, source, stage, blockSize, maps, sprite )
	if maps and not sprite and not maps.water then
		R.Require( maps.dfg ~= nil, "dynamic_light_dfg", "PBR local lights require the base material DFG texture" )
	end
	if D.materials[base] then
		local material = D.materials[base].material
		material:SetTexture("$basetexture", source)
		if maps and not sprite then
			material:SetTexture("$texture3", maps.normal)
			material:SetTexture("$texture4", maps.orm)
			if not maps.water then material:SetTexture("$texture7", maps.dfg) end
		end
		if MC.ResourceGeneration then MC.ResourceGeneration.BindSampling(material,source) end
		return material
	end
	R.Require( D.materialCount < 4096, "dynamic_light_material_budget", "4096 local-light materials reached; restart the client" )
	R.Require( BLEND_ONE_MINUS_DST_COLOR ~= nil, "dynamic_light_blend_api", "destination-colour blend factor is unavailable" )
	local data = R.DynamicLightTexture()
	local pbr = maps ~= nil and not sprite
	local params = {
		["$vertexshader"] = program.vertex, ["$pixshader"] = program.pixel,
		["$basetexture"] = source:GetName(), ["$texture1"] = owner.atlas:GetName(), ["$texture2"] = data:GetName(),
		["$x360appchooser"] = 1, ["$vertexcolor"] = 1,
		["$nocull"] = ( sprite or maps and maps.water or not maps and stage == "world_translucent" ) and 1 or 0,
		["$depthtest"] = 1, ["$writedepth"] = 0, ["$ignorez"] = 0,
		["$linearread_basetexture"] = pbr and maps.colorSpace ~= "linear"
			and not MC.ResourceGeneration.textures[source:GetName()] and 0 or 1, ["$linearread_texture1"] = 1,
		["$linearread_texture2"] = 1, ["$linearwrite"] = pbr and 0 or 1,
		["$c0_x"] = tostring( 1 / blockSize ), ["$c0_y"] = "0", ["$c0_z"] = pbr and tostring( 1 / 2048 ) or "1", ["$c0_w"] = "0",
		["$c1_x"] = "0", ["$c1_y"] = "0", ["$c1_z"] = "0", ["$c1_w"] = "1",
	}
	if pbr then
		params["$texture3"], params["$texture4"] = maps.normal:GetName(), maps.orm:GetName()
		params["$linearread_texture3"], params["$linearread_texture4"] = 1, 1
		if not maps.water then
			params["$texture7"] = maps.dfg:GetName()
			params["$linearread_texture7"] = 1
		end
	end
	local material = CreateMaterial( "mc_dynamic_light2_" .. D.materialCount, "screenspace_general_8tex", params )
	R.Require( material and not material:IsError(), "dynamic_light_material", "could not create local-light material" )
	if pbr and not maps.water then material:SetTexture("$texture7", maps.dfg) end
	if MC.ResourceGeneration then MC.ResourceGeneration.BindSampling(material,source) end
	D.materials[base] = { material = material, revision = -1, sprite = sprite == true, pbr = pbr, stage = stage }
	if not pbr then MC.RenderVanillaWater.Register( material ) end
	D.materialCount = D.materialCount + 1
	return material
end

function D.Material( base )
	local state = D.materials[base]
	return state and state.material
end

function D.Bind( state, alpha )
	local material = state.material
	if not state.pbr then MC.RenderVanillaWater.Bind( material ) end
	if state.revision ~= D.revision then
		material:SetFloat( "$c0_x", 1 / D.blockSize )
		material:SetFloat( "$c0_w", D.count )
		material:SetFloat( "$c1_x", D.eyeX )
		material:SetFloat( "$c1_y", D.eyeY )
		material:SetFloat( "$c1_z", D.eyeZ )
		if state.pbr then material:SetFloat( "$c1_w", D.exposure ) end
		state.revision = D.revision
	end
	if state.sprite and state.alpha ~= alpha then material:SetFloat( "$c0_z", alpha ) state.alpha = alpha end
end

-- The caller supplies its known depth-write policy. Every draw restores the
-- original material, comparison/write state and blend, including Draw errors.
local function drawWithState( material, draw, ... )
	render.OverrideDepthEnable( true, false )
	-- Base materials already tone-map to LDR. Screen composition adds light
	-- within the remaining headroom instead of clipping lit wood/grass white.
	render.OverrideBlend( true, BLEND_ONE_MINUS_DST_COLOR, BLEND_ONE, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD )
	render.SetMaterial( material )
	return draw( ... )
end

function D.DrawFunction( base, draw, writeDepth, alpha, ... )
	local state = D.materials[base]
	if not D.ready or D.count == 0 or not state then return false end
	if writeDepth == nil then writeDepth = state.stage ~= "world_translucent" end
	D.Bind( state, alpha or 1 )
	local ok, err = pcall( drawWithState, state.material, draw, ... )
	local blendOK, blendErr = pcall( render.OverrideBlend, false )
	local depthOK, depthErr = pcall( render.OverrideDepthEnable, true, writeDepth == true )
	local materialOK, materialErr = pcall( render.SetMaterial, base )
	if not blendOK then MC.Fault( "dynamic_light_restore_blend", "%s", tostring( blendErr ) ) end
	if not depthOK then MC.Fault( "dynamic_light_restore_depth", "%s", tostring( depthErr ) ) end
	if not materialOK then MC.Fault( "dynamic_light_restore_material", "%s", tostring( materialErr ) ) end
	if not ok then return MC.Fault( "dynamic_light_draw", "%s", tostring( err ) ) end
	D.stats.draws = D.stats.draws + 1
	return true
end

function D.Draw( base, meshObject, writeDepth, alpha )
	return D.DrawFunction( base, meshObject.Draw, writeDepth, alpha, meshObject )
end

-- A mesh-bound sphere is conservative for protruding models and re-origining
-- worlds. Inputs are render-space origin minus this view's render-space eye.
function D.AffectsBounds( x, y, z, bounds )
	if not D.ready or D.count == 0 then return false end
	if not bounds then return true end
	x, y, z = ( x + bounds.x ) / D.blockSize, ( y + bounds.y ) / D.blockSize, ( z + bounds.z ) / D.blockSize
	local meshRadius = bounds.radius / D.blockSize + 0.02 -- conservative allowance for packed position precision
	for i = 1, D.count do
		local light = D.selected[i]
		local dx, dy, dz = x - light.rx, y - light.ry, z - light.rz
		local p = light.provider
		local radius, distance2 = p.radius + meshRadius, dx * dx + dy * dy + dz * dz
		if distance2 <= radius * radius then
			if not p.spot then return true end
			local along = dx * light.dx + dy * light.dy + dz * light.dz
			local sideways = sqrt( max( 0, distance2 - along * along ) )
			-- Sphere expanded against the cone's side plane. This over-includes
			-- the apex/cap rather than dropping a mesh touched by the beam edge.
			if along + meshRadius >= 0 and sideways * p.outer - along * p.outerSin <= meshRadius then return true end
		end
	end
	D.stats.culled = D.stats.culled + 1
	return false
end

-- Approximate RGB fill for legacy unlit entities/held items. World position is
-- explicit; this does not feed SampleDynamicLightLevels or baked vertex data.
function D.SampleRGB( position )
	D.UpdateSources()
	if limit:GetInt() == 0 then return 0, 0, 0 end
	local size = Coords.BlockSize()
	local sources, count = D.selected, D.count
	if not D.ready then
		-- Entity/held-item hooks may run before terrain prepares the GPU view.
		-- Select once at that boundary, with the same cap and flashlight priority;
		-- never upload a target from inside an entity's model matrix.
		if not D.cpuSelectionValid then
			local eye, err = position, nil
			local player = LocalPlayer()
			if IsValid( player ) then eye, err = Coords.EntityEyeWorldPos( player ) end
			if not eye then
				MC.Fault( "dynamic_light_cpu_view", "%s", tostring( err ) )
				return 0, 0, 0
			end
			D.cpuCount = selectLights( eye, size, D.cpuSelected )
			D.cpuSelectionValid = true
		end
		sources, count = D.cpuSelected, D.cpuCount
	end
	local r, g, b = 0, 0, 0
	for i = 1, count do
		local light, p = sources[i], sources[i].provider
		local dx, dy, dz = ( position.x - light.x ) / size, ( position.y - light.y ) / size, ( position.z - light.z ) / size
		local distance = sqrt( dx * dx + dy * dy + dz * dz )
		if distance < p.radius then
			local amount = ( 1 - distance / p.radius ) ^ 2 * light.strength / math.pi
			if p.spot then
				local cosine = ( dx * light.dx + dy * light.dy + dz * light.dz ) / max( distance, 0.000001 )
				local cone = min( 1, max( 0, ( cosine - p.outer ) / ( p.inner - p.outer ) ) )
				amount = amount * cone * cone * ( 3 - 2 * cone )
			end
			r, g, b = r + p.r * amount, g + p.g * amount, b + p.b * amount
		end
	end
	return r, g, b
end

local registered, registrationError = D.RegisterProvider( "mc:flashlight", {
	class = "player", kind = "spot", radius = 40, color = { 6, 5.85, 5.55 },
	innerCos = math.cos( math.rad( 13 ) ), outerCos = math.cos( math.rad( 24 ) ),
	sample = function( player, state )
		if not flashlight:GetBool() or not player:Alive() or not player:FlashlightIsOn() then return false end
		local position, err = Coords.EntityEyeWorldPos( player )
		if not position then error( err, 0 ) end
		local forward = player:EyeAngles():Forward()
		state.x, state.y, state.z = position.x, position.y, position.z
		state.dx, state.dy, state.dz = forward.x, forward.y, forward.z
		return true
	end,
} )
R.Require( registered, "dynamic_flashlight_registration", tostring( registrationError ) )

concommand.Add( "mc_dynamic_lights_stats", function()
	print( string.format( "[MC dynamic lights] tracked=%d active=%d selected=%d/%d materials=%d uploads=%d draws=%d culled=%d; GPU timing unmeasured",
		#D.records, #D.active, D.count, limit:GetInt(), D.materialCount, D.stats.uploads, D.stats.draws, D.stats.culled ) )
end )
