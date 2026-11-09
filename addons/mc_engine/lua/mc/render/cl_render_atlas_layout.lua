-- Select once per client session; live meshes and materials retain this layout.
MC = MC or {}
local L = MC.RenderAtlasLayout or {}
MC.RenderAtlasLayout = L
local sizes = { ["16384"] = 16384, ["8192"] = 8192, ["4096"] = 4096 }

function L.Resolve( preference, maxWidth, maxHeight )
	if preference ~= "auto" and not sizes[preference] then
		return nil, "l2_atlas_size_invalid"
	end
	if type( maxWidth ) ~= "number" or type( maxHeight ) ~= "number"
		or maxWidth ~= math.floor( maxWidth ) or maxHeight ~= math.floor( maxHeight )
		or maxWidth < 1 or maxHeight < 1 or maxWidth == math.huge or maxHeight == math.huge then
		return nil, "l2_texture_device_limits_invalid"
	end
	local size = sizes[preference]
	if preference == "auto" then
		if maxWidth >= 16384 and maxHeight >= 16384 then size = 16384
		elseif maxWidth >= 8192 and maxHeight >= 8192 then size = 8192
		elseif maxWidth >= 4096 and maxHeight >= 4096 then size = 4096 end
	end
	if not size or size > maxWidth or size > maxHeight then
		return nil, "l2_texture_device_limit"
	end
	return size
end

function L.Query( preference )
	local maxWidth, maxHeight
	if mcmesh then
		if not mcmesh.GetL2PixelTextureLimits then
			return nil, "l2_texture_limits_api: update minemod_native and restart"
		end
		local limits, err = mcmesh.GetL2PixelTextureLimits()
		if not limits then return nil, err end
		maxWidth, maxHeight = limits.maxWidth, limits.maxHeight
	else
		if not render or not render.MaxTextureWidth or not render.MaxTextureHeight then
			return nil, "l2_texture_limits_api_unavailable"
		end
		maxWidth, maxHeight = render.MaxTextureWidth(), render.MaxTextureHeight()
	end
	local size, err = L.Resolve( preference, maxWidth, maxHeight )
	if not size then
		return nil, string.format( "%s: requested=%s maximum=%sx%s",
			err, tostring( preference ), tostring( maxWidth ), tostring( maxHeight ) )
	end
	return { size = size, preference = preference, maxWidth = maxWidth, maxHeight = maxHeight }
end

function L.SetPreference( preference )
	local layout, err = L.Query( preference )
	if not layout then return false, err end
	RunConsoleCommand( "mc_light_atlas_size", preference )
	return true
end

-- Preserve the resolved layout through Lua refresh, even if the saved choice changed.
if not L.active and not L.error then
	L.active, L.error = L.Query( MC.LightAtlasSize:GetString() )
end

cvars.AddChangeCallback( "mc_light_atlas_size", function( _, _, preference )
	local layout, err = L.Query( preference )
	if not layout then MC.Fault( "l2_atlas_size_setting", "%s", err ) return end
	if not L.active or layout.size ~= L.active.size then
		print( "[MC] " .. MC.T( "config.setting.mc_light_atlas_size.reconnect" ) )
	end
end, "mc_l2_atlas_layout" )
