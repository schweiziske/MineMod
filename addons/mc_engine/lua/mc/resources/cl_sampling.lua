-- A synchronous, render-safe backend check. Source's AMD GET1 sampler state
-- can select one mip finer than tex2Dlod requests. Measure that behavior rather
-- than assuming an offset from the GPU vendor or modifying engine state.
MC.ResourceSampling = {}
local S = MC.ResourceSampling
local variables = {"mat_mipmaptextures", "mat_filtertextures", "mat_forceaniso", "mat_trilinear", "mat_picmip"}
local materials, quad, target, program
local function revision()
	local parts = {tostring(render.GetDXLevel())}
	for _, name in ipairs(variables) do parts[#parts+1] = GetConVar(name):GetString() end
	return table.concat(parts, ":")
end
local function prepare()
	if materials then return end
	local descriptor = util.JSONToTable(assert(file.Read("data_static/mc/shaderpacks/mc_vanilla.json", "GAME"), "sampling shader descriptor missing"))
	program = assert(descriptor.definition.programs.sampling, "sampling shader program missing")
	local created = {}
	for lod=0,5 do
		local material = CreateMaterial("mc_resource_sampling_"..program.pixel.."_"..lod, "screenspace_general_8tex", {
			["$vertexshader"]=program.vertex, ["$pixshader"]=program.pixel,
			["$basetexture"]="vgui/white", ["$texture3"]="vgui/white", ["$texture4"]="vgui/white",
			["$linearread_basetexture"]=1, ["$linearread_texture3"]=1, ["$linearread_texture4"]=1, ["$linearwrite"]=1,
			["$vertextransform"]=0, ["$tcsize0"]=2, ["$depthtest"]=0, ["$writedepth"]=0, ["$cull"]=0,
			["$c0_x"]=lod,
		})
		assert(material and not material:IsError(), "sampling material creation failed")
		created[lod+1]=material
	end
	target = GetRenderTargetEx("mc_resource_sampling",16,16,RT_SIZE_LITERAL,MATERIAL_RT_DEPTH_NONE,
		bit.bor(1,4,8,256,512),0,IMAGE_FORMAT_RGBA8888)
	assert(target and not target:IsError(), "sampling readback target missing")
	quad = Mesh(created[1])
	quad:BuildFromTriangles({
		{pos=Vector(-1,1,0),u=0,v=0},{pos=Vector(1,1,0),u=1,v=0},{pos=Vector(1,-1,0),u=1,v=1},
		{pos=Vector(-1,1,0),u=0,v=0},{pos=Vector(1,-1,0),u=1,v=1},{pos=Vector(-1,-1,0),u=0,v=1},
	})
	materials=created
end

function S.Get(backend)
	backend=backend or MC.ResourceGeneration.Backend()
	local key=revision()..":"..(backend.kind or "native")
	if S.cached and S.cached.revision==key then return S.cached end
	local texture, pushed, camera
	local clipping=DisableClipping(true)
	local result, reason
	local started=SysTime()
	local ok, err=xpcall(function()
		prepare()
		texture=assert(backend.CreateAtlasTexture(64,64,4))
		local levels={}
		for mip=0,4 do
			local value=16+mip*40
			levels[mip+1]=string.rep(string.char(value,value,value,255),(64/2^mip)^2)
		end
		assert(backend.UploadAtlasTextureRect(texture.id,0,0,64,64,levels))
		for _, material in ipairs(materials) do
			for _, parameter in ipairs({"$basetexture","$texture3","$texture4"}) do
				assert(backend.BindAtlasTexture(texture.id,"!"..material:GetName(),parameter))
			end
		end
		render.PushRenderTarget(target) pushed=true
		cam.Start2D() camera=true
		render.OverrideDepthEnable(true,false)
		render.OverrideBlend(true,BLEND_ONE,BLEND_ZERO,BLENDFUNC_ADD)
		render.OverrideColorWriteEnable(true,true)
		render.OverrideAlphaWriteEnable(true,true)
		local samples, offsets={},{}
		for lod=0,5 do
			render.Clear(0,0,0,255,false,false)
			render.SetMaterial(materials[lod+1])
			quad:Draw()
			render.CapturePixels()
			local r,g,b=render.ReadPixel(8,8)
			samples[lod+1]={r,g,b}
		end
		for channel=1,3 do
			for offset=0,1 do
				local valid=true
				for mip=0,4 do
					local value=samples[mip+offset+1][channel]
					if not value or math.abs(value-(16+mip*40))>2 then valid=false end
				end
				if valid then offsets[channel]=offset break end
			end
		end
		-- Normal and ORM share the same Source sampling contract and shader LOD.
		-- Refuse an unsupported mismatch rather than silently shifting one map.
		if offsets[1] and offsets[2] and offsets[2]==offsets[3] then
			result={revision=key,offset=offsets[1],pbrOffset=offsets[2],samples=samples,shader=program.pixel}
		else reason="resource_sampling_unsupported:"..util.TableToJSON(samples) end
	end,debug.traceback)
	if camera then cam.End2D() end
	if pushed then render.PopRenderTarget() end
	render.OverrideDepthEnable(false)
	render.OverrideBlend(false)
	render.OverrideColorWriteEnable(false)
	render.OverrideAlphaWriteEnable(false)
	DisableClipping(clipping)
	if texture then
		local released, releaseError=backend.ReleaseAtlasTexture(texture.id)
		if not released then ok,err=false,releaseError end
	end
	if not ok then return nil,"resource_sampling_probe:"..tostring(err) end
	if not result then return nil,reason end
	result.milliseconds=(SysTime()-started)*1000
	S.cached=result
	return result
end

hook.Add("OnScreenSizeChanged","mc_resource_sampling_reset",function() S.cached=nil end)
