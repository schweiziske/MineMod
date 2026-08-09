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

function ENT:DrawTranslucent()
	local renderer = MC.InventoryUI and MC.InventoryUI.ItemRenderer
	if not renderer then return end
	local stack = networkStack( self )
	if not stack or not renderer.CanDraw( stack ) then return end
	local base = self:GetPos() + Vector( 0, 0, 7 + math.sin( CurTime() * 3 + self:EntIndex() ) * 1.5 )
	local angles = Angle( 0, EyeAngles().y - 90, 90 )
	local count = math.max( 1, tonumber( stack.count ) or 1 )
	local copies = count >= 16 and 4 or count >= 8 and 3 or count >= 2 and 2 or 1
	for index = 1, copies do
		local offset = Vector( 0, 0, 0 )
		if index > 1 then
			local phase = ( self:EntIndex() * 17 + index * 31 ) * 0.17
			offset = Vector( math.sin( phase ) * 1.4, math.cos( phase * 1.3 ) * 1.4, ( index - 1 ) * 0.35 )
		end
		cam.Start3D2D( base + offset, angles, 0.75 )
			renderer.DrawStack( stack, -8, -8, 16, { drawCount = false, scale = 1, displayContext = "ground" } )
		cam.End3D2D()
	end
end

function ENT:Draw()
	self:DrawTranslucent()
end
