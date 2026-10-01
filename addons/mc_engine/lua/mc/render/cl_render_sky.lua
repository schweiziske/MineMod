-- The engine owns the material contract; a sky addon supplies the captured RT.
MC = MC or {}
local S = MC.RenderSky or { VERSION = 1, materials = {}, count = 0, frame = -1, revision = 0 }
MC.RenderSky = S
local requireValue = MC.RenderL2Resources.Require

function S.Material( slot, program )
	local material = CreateMaterial( "mc_sky_quad1_" .. slot, "screenspace_general_8tex", {
		["$vertexshader"] = program.vertex, ["$pixshader"] = program.pixel,
		["$basetexture"] = "vgui/white", ["$vertexcolor"] = 1, ["$x360appchooser"] = 1,
		-- The opaque pass enables writes; $writedepth=1 would force ALWAYS.
		["$depthtest"] = 1, ["$writedepth"] = 0, ["$ignorez"] = 0,
		["$linearread_basetexture"] = 1, ["$linearwrite"] = 1, ["$c0_x"] = 0,
	} )
	requireValue( material and not material:IsError(), "render_sky_material", "sky material failed to load" )
	S.materials[material] = { revision = -1 }
	S.count = S.count + 1
	return material
end

function S.Bind( material )
	local state = S.materials[material]
	if not state then return end
	local frame = FrameNumber()
	local valid = S.texture ~= nil and S.frame >= frame - 1
	if valid and state.revision ~= S.revision then
		material:SetTexture( "$basetexture", S.texture )
		material:SetFloat( "$c0_y", 1 / S.width )
		material:SetFloat( "$c0_z", 1 / S.height )
		state.revision = S.revision
	end
	if state.valid ~= valid then
		material:SetFloat( "$c0_x", valid and 1 or 0 )
		state.valid = valid
	end
	if not valid and S.faultFrame ~= frame then
		S.faultFrame = frame
		MC.Fault( "render_sky_capture_missing", "sky block has no recent capture; check that mc_skybox_block is mounted" )
	end
end

function MC.API.Render.SkyTextureNeeded()
	return S.count > 0
end

function MC.API.Render.SetSkyTexture( texture )
	local kind = type( texture )
	if kind ~= "ITexture" then return false, "invalid_sky_texture" end
	if type( texture.IsError ) ~= "function" or type( texture.Width ) ~= "function"
		or type( texture.Height ) ~= "function" or type( texture.GetName ) ~= "function" then
		return false, "invalid_sky_texture"
	end
	if texture:IsError() or texture:Width() ~= ScrW() or texture:Height() ~= ScrH() then
		return false, "sky_texture_must_match_framebuffer"
	end
	local name = texture:GetName()
	if name ~= S.name or texture:Width() ~= S.width or texture:Height() ~= S.height then
		S.revision = S.revision + 1
		S.name, S.width, S.height = name, texture:Width(), texture:Height()
	end
	S.texture, S.frame = texture, FrameNumber()
	return true
end
