-- Vanilla barrier presentation semantics.
--
-- BarrierBlock keeps a full collision shape, but getRenderShape() returns
-- INVISIBLE and Blocks.BARRIER is registered with noOcclusion().  The generated
-- block model therefore contains only a particle texture and no renderable
-- elements.  Keep collision untouched while making the block non-occluding and
-- forcing the generated empty visual plan instead of the legacy full-cube
-- fallback.  The creative-only marker particle is owned by mc_game through the
-- public Blocks/World/GameMode APIs; the engine never calls back into mc_game.

MC = MC or {}

local resolved = MC.ResolveBlock and MC.ResolveBlock( "minecraft:barrier" ) or nil
local barrier = resolved and resolved.block or nil
if barrier then
	-- In the engine block descriptor, transparent means neighbouring faces and
	-- skylight are not occluded.  It does not alter the separate collision data.
	barrier.transparent = true
end

if MC.RegisterBlockStateVisual then
	MC.RegisterBlockStateVisual( "minecraft:barrier", {
		-- assets/minecraft/models/block/barrier.json has no elements.  Selecting
		-- its generated state plan emits zero terrain vertices in both Lua and
		-- native mesh backends instead of falling back to a textured cube.
		forceGeneratedVisual = true,
	} )
end
