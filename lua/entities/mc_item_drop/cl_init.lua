include( "shared.lua" )

ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

function ENT:Initialize()
	self:SetRenderBounds( Vector( -16, -16, -16 ), Vector( 16, 16, 24 ) )
end

local function networkStack( ent )
	local name = ent:GetItemName()
	if name == "" then return nil end
	local components
	local encoded = ent.GetItemComponents and ent:GetItemComponents() or ""
	if encoded ~= "" and util and util.JSONToTable then
		local decoded = util.JSONToTable( encoded )
		if type( decoded ) == "table" then components = decoded end
	end
	return {
		item = name,
		count = math.max( 1, ent:GetItemCount() ),
		damage = ent:GetItemDamage() > 0 and ent:GetItemDamage() or nil,
		components = components,
	}
end

local function worldLightingColor( ent, position )
	local now = CurTime()
	if not ent.MCNextLightSample or now >= ent.MCNextLightSample then
		ent.MCNextLightSample = now + 0.1 + ent:EntIndex() % 5 * 0.01
		local r, g, b = 1, 1, 1
		if MC.SampleDynamicLightingRGB then r, g, b = MC.SampleDynamicLightingRGB( position, 0 ) end
		if MC.ScaleDynamicLightingRGB then
			r, g, b = MC.ScaleDynamicLightingRGB( r, g, b, 0.48 )
		else
			r, g, b = r * 0.48, g * 0.48, b * 0.48
		end
		ent.MCWorldLightColor = ent.MCWorldLightColor or Color( 255, 255, 255, 255 )
		ent.MCWorldLightColor.r = math.floor( math.Clamp( r, 0, 1 ) * 255 + 0.5 )
		ent.MCWorldLightColor.g = math.floor( math.Clamp( g, 0, 1 ) * 255 + 0.5 )
		ent.MCWorldLightColor.b = math.floor( math.Clamp( b, 0, 1 ) * 255 + 0.5 )
	end
	return ent.MCWorldLightColor or color_white
end

function ENT:DrawTranslucent()
	local renderer = MC.InventoryUI and MC.InventoryUI.ItemRenderer
	if not renderer then return end
	local stack = networkStack( self )
	if not stack or not renderer.CanDraw( stack ) then return end
	local base = self:GetPos() + Vector( 0, 0, 7 + math.sin( CurTime() * 3 + self:EntIndex() ) * 1.5 )
	local seed = self:EntIndex() * 37
	local yaw = ( CurTime() * 90 + seed ) % 360
	local flatAngles = Angle( 0, yaw, 90 )
	local blockAngles = Angle( 0, yaw, 0 )
	local worldColor = worldLightingColor( self, base )
	local count = math.max( 1, tonumber( stack.count ) or 1 )
	local copies = count >= 16 and 4 or count >= 8 and 3 or count >= 2 and 2 or 1
	for index = 1, copies do
		local offset = Vector( 0, 0, 0 )
		if index > 1 then
			local phase = ( self:EntIndex() * 17 + index * 31 ) * 0.17
			offset = Vector( math.sin( phase ) * 1.4, math.cos( phase * 1.3 ) * 1.4, ( index - 1 ) * 0.35 )
		end
		local position = base + offset
		local drewBlock = renderer.DrawDroppedBlock
			and renderer.DrawDroppedBlock( stack, position, blockAngles, 12, worldColor,
				{ displayContext = "ground" } )
		if not drewBlock then
			cam.Start3D2D( position, flatAngles, 0.75 )
				renderer.DrawStack( stack, -8, -8, 16,
					{ drawCount = false, scale = 1, displayContext = "ground", worldColor = worldColor } )
			cam.End3D2D()
		end
	end
end

function ENT:Draw()
	self:DrawTranslucent()
end
