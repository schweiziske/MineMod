-- Built-in metadata is registered through the existing API-ready lifecycle.
MC = MC or {}
local B = {}
MC.RenderBuiltinPacks = B

function B.Register( update )
	local definition = include( "mc/render/generated/cl_render_pack_vanilla.lua" )
	local previous
	if update then
		previous = MC.RenderPackRegistry.Get( "pack", "mc:vanilla" )
	end
	local expectedBuild
	if previous then expectedBuild = previous.build end
	return MC.RenderPackRegistry.RegisterBuiltin( "pack", "mc:vanilla", definition, expectedBuild )
end

MC.API.OnRegister( function()
	local ok, err = B.Register( false )
	if not ok then
		MC.Fault( "render_builtin_register", "mc:vanilla registration failed: %s", tostring( err ) )
	end
end )
