--[[----------------------------------------------------------------------------
	MC : public API, client layer (v1).

	Drawing, UI windows, effects, voxel light sampling and render dirty
	marking. Same contract as the shared layer: validated inputs, no thrown
	errors, late binding.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.API = MC.API or {}

local API = MC.API
local resolveStateInput = API.ResolveStateInput

local function cellCoords( bx, by, bz )
	local x, y, z = tonumber( bx ), tonumber( by ), tonumber( bz )
	if not x or not y or not z then return nil end
	if x ~= x or y ~= y or z ~= z then return nil end -- NaN
	return math.floor( x ), math.floor( y ), math.floor( z )
end

local function stateAndLegacy( block )
	local stateId, err = resolveStateInput( block )
	if not stateId then return nil, nil, nil, err end
	if stateId == 0 then return nil, nil, nil, "air" end
	local id, orient = 0, 0
	if MC.LegacyFromState then
		id, orient = MC.LegacyFromState( stateId )
		id, orient = id or 0, orient or 0
	end
	return stateId, id, orient
end

------------------------------------------------------------------------ API.UI
API.UI = API.UI or {}
local UI = API.UI

-- 2D block icon (call inside HUDPaint / panel Paint). block as in the shared
-- contract (stateId or spec string).
function UI.DrawBlockIcon( block, x, y, w, h )
	local stateId, id, orient = stateAndLegacy( block )
	if not stateId then return false end
	if MC.DrawMinecraftBlockStateIcon and MC.DrawMinecraftBlockStateIcon( stateId, x, y, w, h ) then
		return true
	end
	if MC.DrawMinecraftBlockIcon then
		MC.DrawMinecraftBlockIcon( id, x, y, w, h, orient )
		return true
	end
	return false
end

-- 3D wireframe outline of a block shape at a cell (3D render context only).
function UI.DrawBlockOutline( block, bx, by, bz, color )
	local x, y, z = cellCoords( bx, by, bz )
	if not x or not MC.DrawBlockOutline then return false end
	local stateId, id, orient = stateAndLegacy( block )
	if not stateId then return false end
	MC.DrawBlockOutline( id, orient, x, y, z, color, stateId )
	return true
end

-- onSelect( id, stateIdOrNil ), optional. opts: { closeOnSelect = bool }.
function UI.OpenCreativeInventory( onSelect, opts )
	if not MC.OpenCreativeInventory then return false, "ui_unavailable" end
	if onSelect ~= nil and not isfunction( onSelect ) then return false, "invalid_callback" end
	MC.OpenCreativeInventory( onSelect, istable( opts ) and opts or nil )
	return true
end

-- onSelect( id ) is required: the palette window has no default handler.
function UI.OpenPalette( onSelect )
	if not MC.OpenPalette then return false, "ui_unavailable" end
	if not isfunction( onSelect ) then return false, "invalid_callback" end
	MC.OpenPalette( onSelect )
	return true
end

function UI.OpenSaveManager()
	if not MC.OpenSaveManager then return false, "ui_unavailable" end
	MC.OpenSaveManager()
	return true
end

function UI.OpenPresetManager()
	if not MC.OpenPresetManager then return false, "ui_unavailable" end
	MC.OpenPresetManager()
	return true
end

------------------------------------------------------------------- API.Hotbar
API.Hotbar = API.Hotbar or {}
local Hotbar = API.Hotbar

-- Fresh table { slot, id, stateId } of the local creative hotbar selection.
function Hotbar.GetSelection()
	if not MC.GetCreativeHotbarSelectedSlot then return nil, "hotbar_unavailable" end
	return {
		slot = MC.GetCreativeHotbarSelectedSlot(),
		id = MC.GetCreativeHotbarSelectedID and MC.GetCreativeHotbarSelectedID( LocalPlayer() ) or 0,
		stateId = MC.GetCreativeHotbarSelectedStateID and MC.GetCreativeHotbarSelectedStateID() or nil,
	}
end

-- Put a block into a hotbar slot (1..9). block as in the shared contract.
-- Side effect of the underlying UI code: the slot also becomes the SELECTED
-- slot and the selection is synced to the server.
function Hotbar.SetSlot( slot, block )
	if not MC.SetCreativeHotbarSlotStateID then return false, "hotbar_unavailable" end
	slot = math.floor( tonumber( slot ) or 0 )
	if slot < 1 or slot > 9 then return false, "invalid_slot" end
	local stateId, id = stateAndLegacy( block )
	if not stateId then return false, "invalid_state" end
	return MC.SetCreativeHotbarSlotStateID( slot, id, stateId ) == true
end

function Hotbar.SelectSlot( slot )
	if not MC.SelectCreativeHotbarSlot then return false, "hotbar_unavailable" end
	slot = math.floor( tonumber( slot ) or 0 )
	if slot < 1 or slot > 9 then return false, "invalid_slot" end
	return MC.SelectCreativeHotbarSlot( slot ) == true
end

------------------------------------------------------------------ API.Effects
API.Effects = API.Effects or {}
local Effects = API.Effects

-- Local block place/break sound + particles. kind: "place" | "break".
-- block nil samples the world cell. Purely client-side; to broadcast use
-- MC.API.World.PlayFx on the server.
function Effects.PlayBlockEffect( kind, bx, by, bz, block, opts )
	if not MC.PlayBlockEffect then return false, "effects_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	local stateId, id, orient, stateErr
	if block ~= nil then
		stateId, id, orient, stateErr = stateAndLegacy( block )
		if not stateId then return false, stateErr or "invalid_state" end
	else
		stateId = MC.GetBlockState and MC.GetBlockState( x, y, z ) or 0
		if stateId == 0 then return false, "air" end
		if MC.LegacyFromState then id, orient = MC.LegacyFromState( stateId ) end
	end
	-- copy: never mutate the caller's options table
	local options = { stateId = stateId }
	if istable( opts ) then
		for key, value in pairs( opts ) do
			if options[key] == nil then options[key] = value end
		end
	end
	return MC.PlayBlockEffect( kind, id or 0, orient or 0, x, y, z, options )
end

-------------------------------------------------------------------- API.Light
API.Light = API.Light or {}
local Light = API.Light

-- Voxel light (block + sky + day cycle + sun shadow) at a world position.
-- Returns r, g, b in 0..1. Costly: cache per entity per interval.
function Light.SampleRGB( pos, emission )
	if not isvector( pos ) or not MC.SampleDynamicLightingRGB then return 1, 1, 1 end
	local r, g, b = MC.SampleDynamicLightingRGB( pos, tonumber( emission ) or 0 )
	return r, g, b
end

-- Raw cell sample: brightness 0..1, level, blockLight, skyLight (0..15).
-- skyLight is time-independent; apply the day cycle yourself if needed.
-- (mc_light_enabled 0 makes the underlying sampler report full bright.)
function Light.SampleCell( bx, by, bz, selfEmission )
	if not MC.SampleLighting then return nil, "lighting_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil, "invalid_cell" end
	return MC.SampleLighting( x, y, z, tonumber( selfEmission ) or 0 )
end

function Light.SkyLightAt( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x or not MC.SkyVoxelLight then return 15 end
	return MC.SkyVoxelLight( x, y, z )
end

-- Clamp/scale a sampled RGB triple by a gain (the entity-lighting pipeline
-- uses this; a gain around 0.48 matches how Source models are exposed
-- versus chunk vertex lighting - see mc_light_entity_* convars).
function Light.ScaleRGB( r, g, b, gain )
	if not MC.ScaleDynamicLightingRGB then return r, g, b end
	return MC.ScaleDynamicLightingRGB( r, g, b, gain )
end

------------------------------------------------------------------- API.Render
API.Render = API.Render or {}
local Render = API.Render

-- Mark one cell dirty: geometry remesh + light SAMPLE refresh. Full light
-- re-propagation is not triggered - world edits that need it should go
-- through the server API, which syncs and relights properly.
function Render.MarkCellDirty( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	if MC.MarkDirty then MC.MarkDirty( x, y, z ) end
	if MC.MarkLightCellDirty then MC.MarkLightCellDirty( x, y, z ) end
	return true
end
