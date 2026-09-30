--[[----------------------------------------------------------------------------
	MC : public API, client layer (v2).

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

-------------------------------------------------------------------- API.Font
API.Font = API.Font or {}
local Font = API.Font

-- Minecraft bitmap-font metrics are returned in logical GUI pixels. Consumers
-- choose their own integer GUI scale when drawing.
function Font.Measure( text, fontName )
	if not MC.BitmapFont or not MC.BitmapFont.Measure then return 0 end
	return MC.BitmapFont.Measure( tostring( text or "" ), fontName )
end

-- Returns the longest UTF-8 prefix whose logical width does not exceed maxWidth.
function Font.TrimToWidth( text, maxWidth, fontName )
	if not MC.BitmapFont or not MC.BitmapFont.TrimToWidth then return "" end
	return MC.BitmapFont.TrimToWidth( tostring( text or "" ), math.max( 0, tonumber( maxWidth ) or 0 ), fontName )
end

-- options: font="default"|"alt", scale, color, align, verticalAlign,
-- shadow and maxWidth (the latter is in screen pixels, matching x/y).
function Font.Draw( text, x, y, options )
	if not MC.BitmapFont or not MC.BitmapFont.Draw then return 0 end
	return MC.BitmapFont.Draw( tostring( text or "" ), tonumber( x ) or 0, tonumber( y ) or 0,
		type( options ) == "table" and options or nil )
end

function Font.LineHeight()
	return MC.BitmapFont and MC.BitmapFont.LineHeight and MC.BitmapFont.LineHeight() or 9
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

-- Cached IMaterial showing one block's atlas tile, for addons drawing their own
-- particles. col/row pick a sub-cell of the tile (Minecraft's break particles
-- use a 2x2 split); omit them for the whole tile. Returns nil for air/unknown.
-- The material is shared and cached - never mutate it, and do not free it.
function Effects.BlockParticleMaterial( block, col, row )
	if not MC.GetBlockParticleMaterial then return nil, "effects_unavailable" end
	local stateId, id, _, stateErr = stateAndLegacy( block )
	if not stateId then return nil, stateErr or "invalid_state" end
	if not id or id == 0 then return nil, "air" end
	return MC.GetBlockParticleMaterial( id, col, row )
end

-- Play one local Java block-hit sound for a block state at a world position.
-- This deliberately exposes the hit event rather than aliasing the louder
-- break/place catalog; callers own cadence and replication. Optional
-- `{ volume, pitch }` supplies the exact Level.playLocalSound multipliers for
-- non-mining Java call sites. Omitting it preserves mining-progress semantics.
function Effects.PlayBlockHitSound( block, pos, options )
	if not MC.PlayBlockMiningHitSound then return false, "effects_unavailable" end
	if not isvector( pos ) then return false, "invalid_position" end
	if options ~= nil and not istable( options ) then return false, "invalid_options" end
	local volume = options and tonumber( options.volume ) or nil
	local pitch = options and tonumber( options.pitch ) or nil
	if options and options.volume ~= nil and volume == nil then return false, "invalid_volume" end
	if options and options.pitch ~= nil and pitch == nil then return false, "invalid_pitch" end
	if volume ~= nil and volume < 0 then return false, "invalid_volume" end
	if pitch ~= nil and pitch <= 0 then return false, "invalid_pitch" end
	local stateId, id, _, stateErr = stateAndLegacy( block )
	if not stateId then return false, stateErr or "invalid_state" end
	if not id or id == 0 then return false, id == 0 and "air" or "unmapped_block" end
	return MC.PlayBlockMiningHitSound( id, pos, volume, pitch ) == true
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

function Render.RegisterDynamicLightProvider( id, definition )
	return MC.RenderDynamicLights.RegisterProvider( id, definition )
end

function Render.UnregisterDynamicLightProvider( id )
	return MC.RenderDynamicLights.UnregisterProvider( id )
end

-- Custom opaque geometry that cannot participate in GMod's native SSAO pass.
-- The callback runs inside the SSR private depth scope with a captured camera.
function Render.RegisterSSRDepthRenderer( id, callback )
	return MC.RenderPBRSSR.RegisterDepthRenderer( id, callback )
end

function Render.UnregisterSSRDepthRenderer( id )
	return MC.RenderPBRSSR.UnregisterDepthRenderer( id )
end

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

-- Register client-only dynamic geometry for a block whose static chunk faces
-- must be suppressed (for example chests). The callback signature is the
-- engine mesh-emitter contract; the registry itself remains private.
function Render.RegisterSpecialBlockEmitter( blockName, emitter )
	if not MC.RegisterSpecialBlockVisualEmitter then return false, "render_api_unavailable" end
	if not isfunction( emitter ) then return false, "invalid_emitter" end
	local registered, err = MC.RegisterSpecialBlockVisualEmitter( blockName, emitter )
	if not registered then return false, err or "register_failed" end
	return true
end

-- Queue every loaded chunk for a geometry/light rebuild. This is intentionally
-- explicit and expensive; callers should use it only after changing a global
-- renderer registration or resource profile.
function Render.MarkAllDirty()
	if not MC.MarkAllMeshesDirty then return false, "render_api_unavailable" end
	return true, MC.MarkAllMeshesDirty()
end

-- Register or replace a client-side atlas pack. A definition may name a
-- registered atlas profile when its physical layout differs from the default.
-- Definitions and temporary activation leases are owner-scoped so multiple
-- addons can coexist and unload in any order.
-- path values are material paths without extension, for example
-- "mcbr/atlas_backrooms". The registry lives entirely on the client; callers
-- must ship matching PNG/VMT files.
function Render.RegisterTexturePack( name, definition, owner )
	if not MC.RegisterTexturePack then return false, "texture_pack_api_unavailable" end
	return MC.RegisterTexturePack( name, definition, owner )
end

function Render.UnregisterTexturePack( name, owner )
	if not MC.UnregisterTexturePack then return false, "texture_pack_api_unavailable" end
	return MC.UnregisterTexturePack( name, owner )
end

function Render.UnregisterTexturePackOwner( owner )
	if not MC.UnregisterTexturePackOwner then return 0 end
	return MC.UnregisterTexturePackOwner( owner )
end

function Render.AcquireTexturePack( owner, name, priority )
	if not MC.AcquireTexturePack then return false, "texture_pack_api_unavailable" end
	return MC.AcquireTexturePack( owner, name, priority )
end

function Render.ReleaseTexturePack( owner )
	if not MC.ReleaseTexturePack then return false, "texture_pack_api_unavailable" end
	return MC.ReleaseTexturePack( owner )
end

-- Low-level immediate switch. Gamemodes should prefer Acquire/Release so the
-- archived player preference and other addons are restored automatically.
function Render.SetTexturePack( name )
	if not MC.SetTexturePack then return false, "texture_pack_api_unavailable" end
	return MC.SetTexturePack( name )
end

function Render.GetTexturePack()
	if not MC.TexturePackName then return "default" end
	return MC.TexturePackName()
end

-- Save a player selection after a successful switch; mode leases take priority.
function Render.SetTexturePackPreference( name )
	if not MC.SetTexturePackPreference then return false, "texture_pack_api_unavailable" end
	return MC.SetTexturePackPreference( name )
end

function Render.GetTexturePackLeaseOwner()
	if not MC.TexturePackLeaseOwner then return nil end
	return MC.TexturePackLeaseOwner()
end

function Render.ListTexturePacks()
	if not MC.ListTexturePacks then return {} end
	return MC.ListTexturePacks()
end

function Render.ListTexturePackLeases()
	if not MC.ListTexturePackLeases then return {} end
	return MC.ListTexturePackLeases()
end

function Render.RegisterAtlasProfile( name, definition, owner )
	if not MC.RegisterAtlasProfile then return false, "atlas_profile_api_unavailable" end
	return MC.RegisterAtlasProfile( name, definition, owner )
end

function Render.UnregisterAtlasProfile( name, owner )
	if not MC.UnregisterAtlasProfile then return false, "atlas_profile_api_unavailable" end
	return MC.UnregisterAtlasProfile( name, owner )
end

function Render.UnregisterAtlasProfileOwner( owner )
	if not MC.UnregisterAtlasProfileOwner then return 0 end
	return MC.UnregisterAtlasProfileOwner( owner )
end

function Render.SetAtlasProfile( name )
	if not MC.SetAtlasProfile then return false, "atlas_profile_api_unavailable" end
	return MC.SetAtlasProfile( name )
end

function Render.GetAtlasProfile()
	if not MC.AtlasProfileName then return "default" end
	return MC.AtlasProfileName()
end

function Render.ResolveAtlasTile( tile )
	if not MC.ResolveAtlasTile then return math.floor( tonumber( tile ) or 0 ) end
	return MC.ResolveAtlasTile( tile )
end

function Render.ResolveAtlasSurface( tile )
	if not MC.ResolveAtlasSurface then
		return 0, math.floor( tonumber( tile ) or 0 ), MC.Atlas
	end
	return MC.ResolveAtlasSurface( tile )
end

function Render.GetAtlasPageCount()
	return MC.AtlasPageCount and MC.AtlasPageCount() or 1
end

function Render.GetAtlasPageLayout( page )
	return MC.AtlasPageLayout and MC.AtlasPageLayout( page ) or nil
end

function Render.ListAtlasProfiles()
	if not MC.ListAtlasProfiles then return {} end
	return MC.ListAtlasProfiles()
end
