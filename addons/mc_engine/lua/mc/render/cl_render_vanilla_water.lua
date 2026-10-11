-- Vanilla water medium: Java WaterFogEnvironment and ScreenEffectRenderer.
MC = MC or {}
local V = MC.RenderVanillaWater or { materials = setmetatable( {}, { __mode = "k" } ), ticks = 0, serial = 0 }
MC.RenderVanillaWater = V
local requireValue = MC.RenderL2Resources.Require
local min, max = math.min, math.max
local overlay

function V.Vision( ticks )
	return min( ticks / 100, 1 ) * 0.6 + max( 0, min( ( ticks - 100 ) / 500, 1 ) ) * 0.4
end

function V.Prepare()
	local view = render.GetViewSetup( true )
	local active = MC.RenderPackRuntime.active
	local pack = active and active.pack
	local eye = view.origin
	if V.frame == FrameNumber() and V.x == eye.x and V.y == eye.y and V.z == eye.z and V.pack == pack then return V end
	V.frame, V.x, V.y, V.z, V.pack = FrameNumber(), eye.x, eye.y, eye.z, pack
	V.serial, V.underwater = V.serial + 1, false
	local now = CurTime()
	local elapsed = max( 0, now - ( V.time or now ) )
	V.time = now
	if pack == "mc:vanilla" then
		local world, err = MC.API.Coords.RenderToWorld( eye )
		requireValue( world ~= nil, "vanilla_water_coordinates", tostring( err ) )
		local liquid = MC.API.Liquid.AtPos( world )
		V.underwater = liquid ~= nil and liquid.kind == "water"
		if V.underwater then
			local bx, by, bz = MC.API.Coords.WorldToCell( world )
			local brightness = MC.API.Light.SampleCell( bx, by, bz, 0 )
			requireValue( type( brightness ) == "number", "vanilla_water_light", "camera light sample failed" )
			V.brightness = brightness
		end
	end
	-- Java gains one tick in water and loses ten ticks per tick out of water.
	V.ticks = min( 600, max( 0, V.ticks + elapsed * ( V.underwater and 20 or -200 ) ) )
	local size = MC.API.Coords.BlockSize()
	V.start, V.finish = -8 * size, 96 * max( 0.25, V.Vision( V.ticks ) ) * size
	V.inverse = V.underwater and 1 / ( V.finish - V.start ) or 0
	return V
end

function V.Register( material )
	V.materials[material] = -1
end

-- Draw entries prepare after any nested view has finished. Material loops
-- consume that view without allocating another GetViewSetup table per bind.
function V.BindPrepared( material )
	local serial = V.materials[material]
	if serial == nil then return end
	if serial == V.serial then return end
	material:SetFloat( "$c2_x", 5 / 255 )
	material:SetFloat( "$c2_y", 5 / 255 )
	material:SetFloat( "$c2_z", 51 / 255 )
	material:SetFloat( "$c2_w", V.inverse )
	material:SetFloat( "$c3_x", V.x )
	material:SetFloat( "$c3_y", V.y )
	material:SetFloat( "$c3_z", V.z )
	material:SetFloat( "$c3_w", V.start )
	V.materials[material] = V.serial
end

-- Standalone callers do not own a prepared terrain draw boundary.
function V.Bind( material )
	if V.materials[material] == nil then return end
	V.Prepare()
	V.BindPrepared( material )
end

local function fog( scale )
	V.Prepare()
	if not V.underwater then return end
	render.FogMode( MATERIAL_FOG_LINEAR )
	render.FogColor( 5, 5, 51 )
	render.FogStart( V.start * scale )
	render.FogEnd( V.finish * scale )
	render.FogMaxDensity( 1 )
	return true
end
hook.Add( "SetupWorldFog", "mc_vanilla_water", function() return fog( 1 ) end )
hook.Add( "SetupSkyboxFog", "mc_vanilla_water", fog )

hook.Add( "RenderScreenspaceEffects", "mc_vanilla_water", function()
	V.Prepare()
	if not V.underwater then return end
	local player = LocalPlayer()
	if not IsValid( player ) or player:ShouldDrawLocalPlayer() or GetViewEntity() ~= player
		or player:GetObserverMode() ~= OBS_MODE_NONE or render.GetRenderTarget() ~= nil then return end
	if not overlay then
		overlay = Material( "mc/effects/underwater.png", "smooth noclamp" )
		requireValue( not overlay:IsError(), "vanilla_water_overlay", "missing underwater texture" )
	end
	local angle = render.GetViewSetup( true ).angles
	local u, v = -angle.y / 64, angle.p / 64
	local brightness = math.Clamp( V.brightness, 0, 1 ) * 255
	cam.Start2D()
	surface.SetMaterial( overlay )
	surface.SetDrawColor( brightness, brightness, brightness, 25.5 )
	surface.DrawTexturedRectUV( 0, 0, ScrW(), ScrH(), u, v, u + 4, v + 4 )
	cam.End2D()
end )
