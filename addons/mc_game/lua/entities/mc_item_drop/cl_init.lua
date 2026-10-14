include( "shared.lua" )

ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

local FLAT_ITEM_GROUND_SCALE = 0.5
local BLOCK_ITEM_GROUND_SCALE = 0.25
local drawDistance = CreateClientConVar( "mc_item_drop_draw_distance", "96", true, false,
	"Maximum item drop draw distance in Minecraft blocks (0 disables distance culling).", 0, 1024 )
local visualVersion = 0
local sin, cos, min = math.sin, math.cos, math.min

local function invalidateVisuals()
	visualVersion = visualVersion + 1
end
hook.Add( "OnReloaded", "mc_item_drop_visual_cache", invalidateVisuals )
hook.Add( "MC.AtlasProfileChanged", "mc_item_drop_visual_cache", invalidateVisuals )

local function blockSize()
	return math.max( 0.001, MC.API.Coords.BlockSize() )
end

local function groundScale( plan )
	local ground = type( plan and plan.display ) == "table" and plan.display.ground or nil
	local scale = type( ground ) == "table" and ground.scale or nil
	local value = type( scale ) == "table" and math.abs( tonumber( scale[1] ) or 0 ) or 0
	if value > 0 then return value end
	return plan and ( plan.kind == "block" or plan.kind == "missing" )
		and BLOCK_ITEM_GROUND_SCALE or FLAT_ITEM_GROUND_SCALE
end

function ENT:Initialize()
	local size = blockSize()
	self:SetRenderBounds( Vector( -size, -size, -size ), Vector( size, size, size * 1.5 ) )
end

local function visualCache( ent )
	local cached = ent.MCDropVisual
	if cached then return cached end
	cached = {
		position = Vector( 0, 0, 0 ), angles = Angle( 0, 0, 0 ),
		offsetX = { 0 }, offsetY = { 0 }, offsetZ = { 0 },
		options = { displayContext = "ground", worldItem = true },
		nextPlanAt = 0, version = -1,
	}
	local id = ent:EntIndex()
	for i = 2, 4 do
		local phase = ( id * 17 + i * 31 ) * 0.17
		cached.offsetX[i], cached.offsetY[i], cached.offsetZ[i] =
			sin( phase ) * 1.4, cos( phase * 1.3 ) * 1.4, ( i - 1 ) * 0.35
	end
	ent.MCDropVisual = cached
	return cached
end

local function networkStack( ent, cached )
	local name = ent:GetItemName()
	if name == "" then return nil end
	local encoded, count, damage = ent:GetItemComponents(), math.max( 1, ent:GetItemCount() ), ent:GetItemDamage()
	if cached.name == name and cached.encoded == encoded and cached.count == count and cached.damage == damage then
		return cached.stack
	end
	local components = cached.stack and cached.stack.components
	if cached.encoded ~= encoded then
		components = nil
		if encoded ~= "" then
			local decoded = util.JSONToTable( encoded )
			if MC.Check( type( decoded ) == "table", "item_drop_visual_components", "Invalid item component JSON" ) then
				components = decoded
			end
		end
	end
	cached.name, cached.encoded, cached.count, cached.damage = name, encoded, count, damage
	cached.stack = { item = name, count = count, damage = damage > 0 and damage or nil, components = components }
	cached.prepared, cached.nextPlanAt = nil, 0
	return cached.stack
end

local function worldLightingColor( ent )
	local frame = FrameNumber()
	if ent.MCLightFrame ~= frame then
		local Light = MC.API and MC.API.Light or nil
		local sampleRGB = MC.Need( Light and Light.SamplePresentationRGB, "item_drop_light_api", "Missing MC.API.Light.SamplePresentationRGB" )
		if not sampleRGB then return nil end
		-- The physics origin is the box centre. Java probes ItemEntity's eye
		-- height above its feet, independently of the cosmetic bobbing model.
		local worldPosition = MC.API.Coords.EntityWorldPos( ent )
		if not MC.Check( isvector( worldPosition ), "item_drop_light_position", "Cannot sample item world lighting for %s", ent ) then return nil end
		local constants = MC.ItemEntityParity.Constants
		worldPosition.z = worldPosition.z + ( constants.eyeHeight - constants.height * 0.5 ) * blockSize()
		local r, g, b = sampleRGB( worldPosition, ent:IsOnFire() and 15 or 0 )
		if not MC.Check( r ~= nil, "item_drop_light_sample", "Cannot sample item lighting: %s", g ) then return nil end

		ent.MCWorldLightColor = ent.MCWorldLightColor or Color( 255, 255, 255, 255 )
		ent.MCWorldLightColor.r = math.floor( math.Clamp( r, 0, 1 ) * 255 + 0.5 )
		ent.MCWorldLightColor.g = math.floor( math.Clamp( g, 0, 1 ) * 255 + 0.5 )
		ent.MCWorldLightColor.b = math.floor( math.Clamp( b, 0, 1 ) * 255 + 0.5 )
		ent.MCLightFrame = frame
	end
	return ent.MCWorldLightColor or color_white
end

function ENT:DrawTranslucent()
	local renderer = MC.InventoryUI and MC.InventoryUI.ItemRenderer
	if not renderer then return end
	local modelSize = blockSize()
	local origin = self:GetPos()
	local distanceSquared = origin:DistToSqr( EyePos() ) / ( modelSize * modelSize )
	local limit = drawDistance:GetFloat()
	if limit > 0 and distanceSquared > limit * limit then return end
	local cached = visualCache( self )
	local stack = networkStack( self, cached )
	if not stack or not renderer.CanDraw( stack ) then return end
	-- Java renders ItemDisplayContext.GROUND from a one-block model basis. Flat
	-- items normally scale to 0.5 while block.json scales to 0.25. Dropped block
	-- meshes bypass DrawHeldItem's JSON transform, so apply that model-specific
	-- ground scale explicitly on the direct mesh path.
	local current, id = CurTime(), self:EntIndex()
	if not cached.prepared or current >= cached.nextPlanAt or cached.renderer ~= renderer
	or cached.resolver ~= MC.ResolveItemModel or cached.version ~= visualVersion then
		cached.prepared = renderer.PrepareDroppedItem( stack, cached.options )
		cached.renderer, cached.resolver, cached.version = renderer, MC.ResolveItemModel, visualVersion
		-- Stack changes invalidate immediately. Periodic refresh also keeps
		-- local-time models (e.g. Christmas chests) and late model data current.
		cached.nextPlanAt = current + 1 + id % 10 * 0.01
	end
	local prepared = cached.prepared
	local plan = prepared.plan
	local droppedBlockSize = modelSize * groundScale( plan )
	local prefersBlock = plan.kind == "block" or plan.kind == "missing"
	local baseZ = origin.z + 7 + sin( current * 3 + id ) * 1.5
	local position, angles = cached.position, cached.angles
	position.x, position.y, position.z = origin.x, origin.y, baseZ
	angles.y = ( current * 90 + id * 37 ) % 360
	local worldColor = worldLightingColor( self )
	if not worldColor then return end
	local count = stack.count
	local copies = count >= 16 and 4 or count >= 8 and 3 or count >= 2 and 2 or 1
	if distanceSquared > 32 * 32 then copies = 1
	elseif distanceSquared > 16 * 16 then copies = min( copies, 2 ) end
	for index = 1, copies do
		position.x, position.y, position.z = origin.x + cached.offsetX[index],
			origin.y + cached.offsetY[index], baseZ + cached.offsetZ[index]
		-- Special entity models retain Minecraft's model-space Y-up axis in the
		-- ground context. Flat generated sprites keep the addon's established
		-- horizontal card pose, while chests/shields use the upright spin pose.
		local drawn = false
		if not prefersBlock and renderer.DrawHeldItem then
			drawn = renderer.DrawHeldItem( stack, position, angles, modelSize, worldColor, cached.options, prepared ) == true
		end
		if not drawn and renderer.DrawDroppedBlock then
			drawn = renderer.DrawDroppedBlock(
				stack, position, angles, droppedBlockSize, worldColor, cached.options, prepared ) == true
		end
		if not drawn and prefersBlock and renderer.DrawHeldItem then
			renderer.DrawHeldItem( stack, position, angles, modelSize, worldColor, cached.options, prepared )
		end
	end
end

function ENT:Draw()
	self:DrawTranslucent()
end
