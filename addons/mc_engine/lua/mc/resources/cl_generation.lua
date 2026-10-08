-- Render-safe bake. The coordinator may yield at safe boundaries after five
-- seconds to present progress; short bakes still finish in one callback.
MC = MC or {}
MC.ResourceGeneration = MC.ResourceGeneration or {}
local G = MC.ResourceGeneration
G.live = G.live or {}
G.textures = G.textures or {}
G.slots = G.slots or {}
-- Auto-refresh can retain a pre-residency generation. Freeze its last uploaded
-- frame until the pack is rebuilt; never resume the old CPU upload loop.
for generation in pairs(G.live) do
	if not generation.animationMaterials then
		generation.animationMaterials = {}
		generation.needsRebuild = true
		print("[mc_engine] GPU animation pipeline changed; reload the resource pack to rebuild resident frames.")
	end
end
local strategies = {auto = 0, mean = 1, cutout = 2, strict_cutout = 3, dark_cutout = 4}
local function nativeAvailable()
	if not mcmesh then return false end
	for _, name in ipairs({"CreateAtlasTexture", "UploadAtlasTextureRect", "FlushAtlasTexture", "ReleaseAtlasTexture",
		"CreateAtlasSprite", "SampleAtlasSprite", "ReleaseAtlasSprite", "BindAtlasTexture"}) do
		if type(mcmesh[name]) ~= "function" then return false end
	end
	return true
end
function G.Backend()
	if nativeAvailable() then return mcmesh end
	return MC.ResourceLuaBackend
end
function G.Available() return G.Backend() ~= nil end
local function release(generation)
	local backend=generation.backend
	local errors = {}
	if generation.cache then generation.cache:Close() generation.cache=nil end
	for material, parameters in pairs(generation.bindings) do
		for parameter, name in pairs(parameters) do
			local current = material:GetTexture(parameter)
			if current and current:GetName() == name then
				material:SetTexture(parameter, Material("vgui/white"):GetTexture("$basetexture"))
			end
		end
	end
	generation.bindings = {}
	generation.animationMaterials = {}
	for handle in pairs(generation.handles) do
		local ok, err = handle.backend.ReleaseAtlasSprite(handle.id)
		if not ok then errors[#errors + 1] = tostring(err) end
		generation.handles[handle] = nil
	end
	for _, texture in pairs(generation.channels) do
		if texture.name then G.textures[texture.name] = nil end
		local ok, err = backend.ReleaseAtlasTexture(texture.id)
		if not ok then errors[#errors + 1] = tostring(err) end
	end
	generation.texture, generation.channels = nil, {}
	generation.state, generation.animations = "released", {}
	G.live[generation] = nil
	G.slots[generation.slot] = nil
	return #errors == 0, table.concat(errors, "; ")
end
function G.Release(generation)
	if not G.live[generation] then return false, "resource_generation_not_owned" end
	local ok, err = release(generation)
	if not ok then MC.Fault("resource_generation_release", "%s", err) end
	return ok, err
end
function G.Build(plan, checkpoint)
	if G.building then return nil,"resource_generation_build_running" end
	local backend=G.Backend()
	if not backend then return nil, "resource_generation_backend_unavailable" end
	if type(plan) ~= "table" or plan.state ~= "planned" or type(plan.layout) ~= "table"
		or type(plan.sprites) ~= "table" or not plan.layout.gpu
		or not plan.layout.gpu.records then return nil, "resource_generation_plan" end
	local started = SysTime()
	local sampling, samplingError
	if plan.layout.mip>0 then
		sampling, samplingError = MC.ResourceSampling.Get(backend)
		if not sampling then return nil, samplingError end
	else sampling={offset=0,pbrOffset=0} end
	local slot
	for i = 1, 3 do if not G.slots[i] then slot = i break end end
	if not slot then return nil, "resource_generation_slot_budget" end
	local residentLayout = {}
	for key,value in pairs(plan.layout) do residentLayout[key]=value end
	residentLayout.gpu={region=plan.layout.gpu.region,cell=plan.layout.gpu.cell}
	local generation = {state = "building", backend=backend, layout = residentLayout, key = plan.key,
		slot = slot, samplingOffset = sampling.offset, samplingPBROffset = sampling.pbrOffset, bindings = {},
		animationMaterials = {}, handles = {}, channels = {}, animations = {},
		metrics = {decodeMipMS = 0, copyMS = 0, residentFrames = 0}, ticks = 0}
	G.live[generation] = true
	G.slots[slot] = generation
	local function build()
		if backend.BeginBuild then backend.BeginBuild(checkpoint) end
		local layout = plan.layout
		if MC.ResourceCache then generation.cache=MC.ResourceCache.Open(plan,backend.kind) end
		local channels = plan.pbr and {"color", "normal", "orm"} or {"color"}
		for _, channel in ipairs(channels) do
			local texture, err = backend.CreateAtlasTexture(layout.width, layout.height, layout.mip)
			if not texture then return nil, err end
			generation.channels[channel] = texture
		end
		generation.texture = generation.channels.color
		for index, sprite in ipairs(plan.sprites) do
			for _, channel in ipairs(channels) do
			local info = layout.gpu.records[index][channel]
			local sampled, frames = info.sprite, info.frames
			local spriteBackend=backend
			if sampled~=sprite and (sampled.width~=sprite.width or sampled.height~=sprite.height) then
				-- Existing native DLLs require identical material sheet dimensions.
				-- Resample exceptional companions in Lua and upload through the
				-- selected texture backend; ordinary channels stay accelerated.
				spriteBackend=MC.ResourceLuaBackend
				if not spriteBackend then return nil,"resource_companion_resampler_unavailable" end
			end
			local cacheable=not (sprite.cacheAnimated or sprite.animated)
			local before = SysTime()
			local cached
			if generation.cache and cacheable then cached=generation.cache:Get(index,channel) end
			local native, decodeError
			if not cached then
			local strategy, data, overlayData = strategies[sprite.strategy]
			if channel == "normal" then strategy, data, overlayData = 5, sprite.normalPNG, sprite.overlayNormalPNG
			elseif channel == "orm" then strategy, data, overlayData = 6, sprite.specularPNG, sprite.overlaySpecularPNG end
			native, decodeError = spriteBackend.CreateAtlasSprite(sampled.png, {width = sprite.width, height = sprite.height,
				mip = layout.mip, padding = layout.padding, strategy = strategy, dataPNG = data, overlayDataPNG = overlayData,
				alphaBias = sprite.alphaBias, item = sprite.item == true or sprite.id:find(":textures/item/", 1, true) ~= nil, frames = frames,
				detectConstant = false,
				tint = sprite.tint, overlayPNG = sprite.overlayPNG, baseWidth = sprite.baseWidth or sampled.width, baseHeight = sprite.baseHeight or sampled.height,
				overlayWidth = sprite.overlayWidth, overlayHeight = sprite.overlayHeight})
			if not native then return nil, sprite.id .. ":" .. tostring(decodeError) end
			native.backend=spriteBackend
			generation.handles[native] = true
			if native.imageWidth ~= sampled.imageWidth or native.imageHeight ~= sampled.imageHeight then
				return nil, "resource_generation_decoded_size:" .. sprite.id
			end
			end
			generation.metrics.decodeMipMS = generation.metrics.decodeMipMS + (SysTime() - before) * 1000
			before = SysTime()
			for ordinal, frame in ipairs(frames) do
				local levels, sampleError = cached
				if not levels then levels,sampleError=spriteBackend.SampleAtlasSprite(native.id,frame,frame,0) end
				if not levels then return nil,sprite.id..":"..tostring(sampleError) end
				if generation.cache and cacheable then generation.cache:Put(index,channel,levels) end
				local r,pad = layout.gpu.records[index].regions[ordinal],layout.padding
				local ok,uploadError=backend.UploadAtlasTextureRect(generation.channels[channel].id,
					r[1]-pad,r[2]-pad,r[3]+pad*2,r[4]+pad*2,levels,true)
				if not ok then return nil,sprite.id..":"..tostring(uploadError) end
				generation.metrics.residentFrames=generation.metrics.residentFrames+1
			end
			generation.metrics.copyMS = generation.metrics.copyMS + (SysTime() - before) * 1000
			if sampled.animated then
				generation.animations[#generation.animations+1]={index=index,channel=channel,frames=#frames}
			end
			if native then
				local freed, freeError = spriteBackend.ReleaseAtlasSprite(native.id)
				if not freed then return nil, freeError end
				generation.handles[native] = nil
			end
			end
			if checkpoint then checkpoint("bake",index,#plan.sprites) end
		end
		local before = SysTime()
		for _, channel in ipairs(channels) do
			local r=layout.gpu.region
			local copied,copyError=backend.UploadAtlasTextureRect(generation.channels[channel].id,
				r[1],r[2],r[3],r[4],MC.ResourceGPUAnimation.Table(layout,channel),true)
			if not copied then return nil,copyError end
			local ok, err = backend.FlushAtlasTexture(generation.channels[channel].id)
			if not ok then return nil, err end
		end
		generation.metrics.uploadMS = (SysTime() - before) * 1000
		generation.metrics.totalMS = (SysTime() - started) * 1000
		if generation.cache then
			generation.metrics.cacheState,generation.metrics.cacheHits=generation.cache.state,generation.cache.hits
			generation.metrics.cacheLimited=generation.cache.limited == true
		end
		generation.state, generation.pixelsValidated = "candidate", true
		for _, texture in pairs(generation.channels) do
			if texture.name then G.textures[texture.name] = generation end
		end
		return generation
	end
	G.building=true
	local ok, result, err = pcall(build)
	G.building=nil
	if backend.EndBuild then backend.EndBuild() end
	if ok and result then return result end
	local cleaned, cleanupError = release(generation)
	if not cleaned then MC.Fault("resource_generation_cleanup", "%s", cleanupError) end
	if not ok then
		if result~="resource_apply_cancelled" then MC.Fault("resource_generation_internal", "%s", tostring(result)) end
		return nil,tostring(result)
	end
	return nil, err
end

function G.Identity(texture)
	local name = texture:GetName()
	local generation = G.textures[name]
	if generation then
		for channel, item in pairs(generation.channels) do
			if item.name == name then return "mc_resource_slot_" .. generation.slot .. "/" .. channel end
		end
	end
	return name
end

function G.Texture(generation, channel)
	local texture = generation.channels[channel or "color"]
	if not texture then return nil, "resource_generation_channel_missing" end
	local name = "mc_resource_texture_" .. generation.slot .. "_" .. (channel or "color")
	local material = CreateMaterial(name, "UnlitGeneric", {["$basetexture"]="vgui/white"})
	if not material or material:IsError() then return nil, "resource_generation_material" end
	local ok, err = generation.backend.BindAtlasTexture(texture.id, "!" .. material:GetName(), "$basetexture")
	if not ok then return nil, err end
	G.TrackMaterial(material)
	return material:GetTexture("$basetexture")
end

function G.TrackMaterial(material)
	for _, parameter in ipairs({"$basetexture", "$texture1", "$texture2", "$texture3", "$texture4", "$texture5", "$texture6", "$texture7"}) do
		local texture = material:GetTexture(parameter)
		local name = texture and texture:GetName()
		local generation = name and G.textures[name]
		if generation then
			local parameters = generation.bindings[material] or {}
			generation.bindings[material], parameters[parameter] = parameters, name
		end
	end
end

function G.BindSampling(material, texture, constants, interpolation)
	local generation = G.textures[texture:GetName()]
	local matrix = constants or Matrix()
	local offset = generation and generation.samplingOffset or 0
	local scale = 2^offset
	local width,height=texture:Width(),texture:Height()
	if generation then width,height=generation.layout.width or width,generation.layout.height or height end
	-- PBR uses the signs as independent spatial-filter flags. Squared gradient
	-- lengths (including legacy shaders) retain exactly the same LOD.
	matrix:SetField(3,1,width*scale*(interpolation and interpolation%2==1 and -1 or 1))
	matrix:SetField(3,2,height*scale*(interpolation and interpolation>=2 and -1 or 1))
	matrix:SetField(3,3,scale*scale)
	matrix:SetField(3,4,generation and not generation.channels.normal and -100
		or (generation and generation.samplingPBROffset or 0)-offset)
	matrix:SetField(4,1,width)
	matrix:SetField(4,2,height)
	matrix:SetField(4,3,(generation and generation.layout.mip or 0)+offset)
	matrix:SetField(4,4,1/(width*height))
	local gpu=generation and generation.layout.gpu
	matrix:SetField(2,1,gpu and gpu.region[1] or 0)
	matrix:SetField(2,2,gpu and gpu.region[2] or 0)
	matrix:SetField(2,3,gpu and gpu.region[3] or 0)
	matrix:SetField(2,4,generation and generation.ticks or 0)
	material:SetMatrix("$invviewprojmat",matrix)
	if generation then generation.animationMaterials[material]=matrix end
	G.TrackMaterial(material)
	return matrix
end

-- Only time constants change during playback. No sprite sampling, pixel copies,
-- texture Download, or native update/flush calls are allowed here.
function G.Update(generation, elapsedTicks)
	if not G.live[generation] or generation.state ~= "candidate" then return false, "resource_generation_not_ready" end
	if type(elapsedTicks) ~= "number" or elapsedTicks ~= elapsedTicks or math.abs(elapsedTicks) == math.huge then
		return false, "resource_generation_time"
	end
	local tick = math.max(0, math.floor(elapsedTicks))
	if generation.ticks == tick then return true end
	for material,matrix in pairs(generation.animationMaterials) do
		matrix:SetField(2,4,tick)
		material:SetMatrix("$invviewprojmat",matrix)
	end
	generation.ticks = tick
	return true
end
