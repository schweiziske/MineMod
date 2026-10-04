-- Render-safe bake. The coordinator may yield at safe boundaries after five
-- seconds to present progress; short bakes still finish in one callback.
MC = MC or {}
MC.ResourceGeneration = MC.ResourceGeneration or {}
local G = MC.ResourceGeneration
G.live = G.live or {}
G.textures = G.textures or {}
G.slots = G.slots or {}
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
	for handle in pairs(generation.handles) do
		local ok, err = backend.ReleaseAtlasSprite(handle)
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
local function upload(generation, animation, current, nextFrame, fraction, defer)
	if not defer and generation.updateTexture then
		local r,pad=animation.region,generation.layout.padding
		local ok,err=generation.updateTexture(animation.handle,animation.texture.id,r[1]-pad,r[2]-pad,current,nextFrame,fraction)
		if not ok then return nil,err end
		generation.dirtyChannels[animation.channel]=true
		animation.current,animation.nextFrame,animation.fraction=current,nextFrame,fraction
		return true
	end
	local levels, err = animation.levels
	if not levels then levels, err = generation.backend.SampleAtlasSprite(animation.handle, current, nextFrame, fraction) end
	if not levels then return nil, err end
	if generation.cache and not animation.sprite.animated then
		generation.cache:Put(animation.index,animation.channel,levels)
	end
	local r, pad = animation.region, generation.layout.padding
	local ok, uploadError = generation.backend.UploadAtlasTextureRect(animation.texture.id,
		r[1] - pad, r[2] - pad, r[3] + pad * 2, r[4] + pad * 2, levels, defer)
	if not ok then return nil, uploadError end
	animation.current, animation.nextFrame, animation.fraction = current, nextFrame, fraction
	return true
end
function G.Build(plan, checkpoint)
	if G.building then return nil,"resource_generation_build_running" end
	local backend=G.Backend()
	if not backend then return nil, "resource_generation_backend_unavailable" end
	if type(plan) ~= "table" or plan.state ~= "planned" or type(plan.layout) ~= "table"
		or type(plan.sprites) ~= "table" then return nil, "resource_generation_plan" end
	local started = SysTime()
	local sampling, samplingError
	if plan.layout.mip>0 then
		sampling, samplingError = MC.ResourceSampling.Get(backend)
		if not sampling then return nil, samplingError end
	else sampling={offset=0,pbrOffset=0} end
	local slot
	for i = 1, 3 do if not G.slots[i] then slot = i break end end
	if not slot then return nil, "resource_generation_slot_budget" end
	local generation = {state = "building", backend=backend, layout = plan.layout, key = plan.key,
		slot = slot, samplingOffset = sampling.offset, samplingPBROffset = sampling.pbrOffset, bindings = {}, handles = {}, channels = {}, animations = {}, metrics = {decodeMipMS = 0, copyMS = 0}, ticks = 0}
	-- Optional native fast path, selected once at the generation boundary.
	if type(backend.UpdateAtlasSpriteTexture)=="function" and type(backend.FlushAtlasTextureUpdates)=="function" then
		generation.updateTexture,generation.flushUpdates=backend.UpdateAtlasSpriteTexture,backend.FlushAtlasTextureUpdates
		generation.dirtyChannels={}
	end
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
			local frames = {}
			for i, frame in ipairs(sprite.frames) do frames[i] = frame.index end
			for _, channel in ipairs(channels) do
			local before = SysTime()
			local cached
			if generation.cache and not sprite.animated then cached=generation.cache:Get(index,channel) end
			local native, decodeError
			if not cached then
			local strategy, data, overlayData = strategies[sprite.strategy]
			if channel == "normal" then strategy, data, overlayData = 5, sprite.normalPNG, sprite.overlayNormalPNG
			elseif channel == "orm" then strategy, data, overlayData = 6, sprite.specularPNG, sprite.overlaySpecularPNG end
			native, decodeError = backend.CreateAtlasSprite(sprite.png, {width = sprite.width, height = sprite.height,
				mip = layout.mip, padding = layout.padding, strategy = strategy, dataPNG = data, overlayDataPNG = overlayData,
				alphaBias = sprite.alphaBias, item = sprite.item == true or sprite.id:find(":textures/item/", 1, true) ~= nil, frames = frames,
				tint = sprite.tint, overlayPNG = sprite.overlayPNG, baseWidth = sprite.baseWidth, baseHeight = sprite.baseHeight,
				overlayWidth = sprite.overlayWidth, overlayHeight = sprite.overlayHeight})
			if not native then return nil, sprite.id .. ":" .. tostring(decodeError) end
			generation.handles[native.id] = true
			if native.imageWidth ~= sprite.imageWidth or native.imageHeight ~= sprite.imageHeight then
				return nil, "resource_generation_decoded_size:" .. sprite.id
			end
			end
			generation.metrics.decodeMipMS = generation.metrics.decodeMipMS + (SysTime() - before) * 1000
			local animation = {handle = native and native.id, levels=cached, index=index, channel=channel,
				sprite = sprite, region = layout.regions[index], texture = generation.channels[channel]}
			local current, nextFrame, fraction = MC.ResourceSpriteRules.Sample(sprite, 0)
			before = SysTime()
			local ok, uploadError = upload(generation, animation, current, nextFrame, fraction, true)
			if not ok then return nil, sprite.id .. ":" .. tostring(uploadError) end
			generation.metrics.copyMS = generation.metrics.copyMS + (SysTime() - before) * 1000
			if sprite.animated and not (native and native.constant) then generation.animations[#generation.animations + 1] = animation
			elseif native then
				local freed, freeError = backend.ReleaseAtlasSprite(native.id)
				if not freed then return nil, freeError end
				generation.handles[native.id] = nil
			end
			end
			if checkpoint then checkpoint("bake",index,#plan.sprites) end
		end
		local before = SysTime()
		for _, channel in ipairs(channels) do
			local ok, err = backend.FlushAtlasTexture(generation.channels[channel].id)
			if not ok then return nil, err end
		end
		generation.metrics.uploadMS = (SysTime() - before) * 1000
		generation.metrics.totalMS = (SysTime() - started) * 1000
		if generation.cache then
			generation.metrics.cacheState,generation.metrics.cacheHits=generation.cache.state,generation.cache.hits
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

function G.BindSampling(material, texture, constants)
	local generation = G.textures[texture:GetName()]
	local matrix = constants or Matrix()
	local offset = generation and generation.samplingOffset or 0
	local scale = 2^offset
	local width,height=texture:Width(),texture:Height()
	if generation then width,height=generation.layout.width or width,generation.layout.height or height end
	matrix:SetField(3,1,width*scale)
	matrix:SetField(3,2,height*scale)
	matrix:SetField(3,3,scale*scale)
	matrix:SetField(3,4,(generation and generation.samplingPBROffset or 0)-offset)
	matrix:SetField(4,1,width)
	matrix:SetField(4,2,height)
	matrix:SetField(4,3,(generation and generation.layout.mip or 0)+offset)
	matrix:SetField(4,4,1/(width*height))
	material:SetMatrix("$invviewprojmat",matrix)
	G.TrackMaterial(material)
end

-- Called once per game tick by the active generation's renderer, never by
-- reflection/shadow passes. This updates already compiled frames, not baking.
function G.Update(generation, elapsedTicks)
	if not G.live[generation] or generation.state ~= "candidate" then return false, "resource_generation_not_ready" end
	if type(elapsedTicks) ~= "number" or elapsedTicks ~= elapsedTicks or math.abs(elapsedTicks) == math.huge then
		return false, "resource_generation_time"
	end
	local tick = math.max(0, math.floor(elapsedTicks))
	if generation.ticks == tick then return true end
	for _, animation in ipairs(generation.animations) do
		local a, b, fraction = MC.ResourceSpriteRules.Sample(animation.sprite, tick)
		if a ~= animation.current or b ~= animation.nextFrame or fraction ~= animation.fraction then
			local ok, err = upload(generation, animation, a, b, fraction, false)
			if not ok then return false, err end
		end
	end
	if generation.dirtyChannels then
		for channel in pairs(generation.dirtyChannels) do
			local ok,err=generation.flushUpdates(generation.channels[channel].id)
			if not ok then return false,err end
			generation.dirtyChannels[channel]=nil
		end
	end
	generation.ticks = tick
	return true
end
