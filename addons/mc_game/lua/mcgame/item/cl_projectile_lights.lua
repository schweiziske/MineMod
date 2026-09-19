-- Game semantics stay in the game addon. The engine only sees a provider of
-- world-space light positions and never depends on projectile entity classes.
local Coords = MC.API.Coords
local ok, err = MC.API.Render.RegisterDynamicLightProvider( "mc_game:burning_projectile", {
	class = "mc_projectile", radius = 7.75, color = { 5, 1.9, 0.45 },
	sample = function( entity, light )
		if not entity:GetProjectileOnFire() then return false end
		local position, why = Coords.EntityWorldPos( entity )
		if not position then error( why, 0 ) end
		light.x, light.y, light.z = position.x, position.y, position.z
		return true
	end,
} )
if not ok then MC.Fault( "projectile_light_registration", "%s", tostring( err ) ) end
