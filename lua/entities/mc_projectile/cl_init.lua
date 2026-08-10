include( "shared.lua" )

local function networkStack( ent )
	local item = ent:GetProjectileItemName()
	if item == "" or not MC or not MC.NewItemStack then return nil end
	return MC.NewItemStack( item, 1, nil, ent:GetProjectileDamage() )
end

function ENT:Initialize()
	self:SetRenderBounds( Vector( -16, -16, -16 ), Vector( 16, 16, 16 ) )
end

function ENT:DrawTranslucent()
	local renderer = MC.InventoryUI and MC.InventoryUI.ItemRenderer
	if not renderer then return end
	local stack = networkStack( self )
	if not stack or not renderer.CanDraw( stack ) then return end
	local toViewer = EyePos() - self:GetPos()
	local normal = toViewer:LengthSqr() > 1 and toViewer:GetNormalized() or self:GetForward()
	renderer.DrawHeldItem( stack, self:GetPos(), normal, 1.25, nil, {
		displayContext = "ground",
		using = false,
		useProgress = 0,
	} )
end

function ENT:Draw()
	self:DrawTranslucent()
end
