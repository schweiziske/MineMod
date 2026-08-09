include( "shared.lua" )

ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

function ENT:Initialize()
	self:SetRenderBounds( Vector( -16, -16, -16 ), Vector( 16, 16, 24 ) )
end

local function networkStack( ent )
	local name = ent:GetItemName()
	if name == "" then return nil end
	return {
		item = name,
		count = math.max( 1, ent:GetItemCount() ),
		damage = ent:GetItemDamage() > 0 and ent:GetItemDamage() or nil,
	}
end

function ENT:DrawTranslucent()
	local renderer = MC.InventoryUI and MC.InventoryUI.ItemRenderer
	if not renderer then return end
	local stack = networkStack( self )
	if not stack or not renderer.CanDraw( stack ) then return end
	local position = self:GetPos() + Vector( 0, 0, 7 + math.sin( CurTime() * 3 + self:EntIndex() ) * 1.5 )
	local angles = Angle( 0, EyeAngles().y - 90, 90 )
	cam.Start3D2D( position, angles, 0.75 )
		renderer.DrawStack( stack, -8, -8, 16, { drawCount = false, scale = 1 } )
	cam.End3D2D()
end

function ENT:Draw()
	self:DrawTranslucent()
end
