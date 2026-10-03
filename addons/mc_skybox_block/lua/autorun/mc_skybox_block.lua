if SERVER then
	AddCSLuaFile()
	AddCSLuaFile( "mc_skybox/cl_capture.lua" )
end

local function requireResult( label, ok, value )
	if not ok then error( "[mc_skybox] " .. label .. ": " .. tostring( value ), 0 ) end
	return value
end

local manifest = {
	id = "mc_skybox", version = "1.0.0", environment = "*",
	depends = { mcswep = ">=1.0 <2.0" },
	entrypoints = { main = function( context )
		local api = context.api
		local block = requireResult( "block", api.Blocks.RegisterNamespaced( {
			id = "mc_skybox:sky", disp = "天空方块", solid = true, transparent = false,
			castsAmbientOcclusion = false,
			castsShadow = false,
			textures = { top = "light_blue_stained_glass", side = "light_blue_stained_glass", bottom = "light_blue_stained_glass" },
			boxes = { { 0, 0, 0, 1, 1, 1 } }, hardness = 1.5,
		} ) )
		requireResult( "item", api.Items.Register( { id = "mc_skybox:sky", block = "mc_skybox:sky", maxStack = 64 } ) )
		requireResult( "category", api.Creative.RegisterCategory( {
			id = "mc_skybox:blocks", title = "Skybox", titleZH = "天空方块", icon = "mc_skybox:sky",
		} ) )
		requireResult( "creative entry", api.Creative.RegisterBlock( "mc_skybox:blocks", "mc_skybox:sky" ) )
		if CLIENT then
			requireResult( "render binding", api.Render.BindBlock( block.blockId, {
				interface = "mc_skybox:sky", contract = 1, shader = "mc_skybox:captured",
			} ) )
			include( "mc_skybox/cl_capture.lua" )
		end
	end },
}

local function register()
	requireResult( "manifest", MC.API.RegisterManifest( manifest ) )
end
if MC and MC.API and MC.API.RegisterManifest then register()
else hook.Add( "MC.APIAvailable", "mc_skybox_manifest", register ) end
