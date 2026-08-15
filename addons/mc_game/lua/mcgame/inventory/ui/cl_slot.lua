-- Reusable inventory slot view.  It owns presentation only; every mutation is
-- delegated to the ordered client action queue and remains server-authoritative.

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI

local PANEL = {}

function PANEL:Init()
	self:SetMouseInputEnabled( true )
	self:SetKeyboardInputEnabled( false )
	self:SetCursor( "hand" )
	self.Stack = nil
	self.InventoryIndex = nil
	self.MenuIndex = nil
	self.Kind = "empty"
	self.CreativeItem = nil
	self.Scale = 1
end

function PANEL:SetScreen( screen )
	self.Screen = screen
	return self
end

function PANEL:SetScale( scale )
	self.Scale = math.max( 1, math.floor( tonumber( scale ) or 1 ) )
	self:SetSize( 18 * self.Scale, 18 * self.Scale )
	return self
end

function PANEL:SetInventorySlot( index, menuIndex )
	self.Kind = "inventory"
	self.CreativeItem = nil
	self.InventoryIndex = math.floor( tonumber( index ) or -1 )
	self.MenuIndex = math.floor( tonumber( menuIndex ~= nil and menuIndex or index ) or -1 )
	self:RefreshInventoryStack()
	return self
end

function PANEL:SetMenuSlot( index, playerIndex, role )
	self.Kind = role == "result" and "result" or "menu"
	self.CreativeItem = nil
	self.MenuIndex = math.floor( tonumber( index ) or -1 )
	self.InventoryIndex = playerIndex ~= nil and math.floor( tonumber( playerIndex ) or -1 ) or nil
	self:RefreshInventoryStack()
	return self
end

function PANEL:SetCreativeItem( item )
	local stack = MC.NormalizeItemStack and MC.NormalizeItemStack( item ) or nil
	self.Kind = "creative"
	self.CreativeItem = MC.CopyItemStack( stack, 1 )
	self.InventoryIndex = nil
	self.MenuIndex = nil
	self.Stack = MC.CopyItemStack( stack, 1 )
	return self
end

function PANEL:SetDestroySlot()
	self.Kind = "destroy"
	self.CreativeItem = nil
	self.InventoryIndex = nil
	self.MenuIndex = nil
	self.Stack = nil
	return self
end

function PANEL:RefreshInventoryStack()
	if ( self.Kind ~= "inventory" and self.Kind ~= "menu" and self.Kind ~= "result" ) or self.MenuIndex == nil then return end
	local state = MC.ClientInventory
	if self.Kind == "inventory" and self.InventoryIndex ~= nil then
		-- Player slots are mirrored independently from an open menu.  Reading the
		-- authoritative 36-slot mirror prevents a late open snapshot from leaving
		-- the hotbar visually empty until another UI action causes a repaint.
		self.Stack = state and MC.CopyItemStack( state.slots and state.slots[self.InventoryIndex + 1] ) or nil
		return
	end
	self.Stack = state and state.menu and MC.CopyItemStack( state.menu.slots[self.MenuIndex + 1] ) or nil
end

function PANEL:Think()
	if self.Kind == "creative" then
		-- Creative slots can be laid out one frame before the generated item
		-- registry finalizes. Retry their saved item ID so a tab click is never
		-- needed to make the icon appear.
		if not self.Stack and self.CreativeItem and MC.GetItem then self:SetCreativeItem( self.CreativeItem ) end
		return
	end
	if self.Kind ~= "inventory" then return end
	local state = MC.ClientInventory
	local menu = state and state.menu or nil
	local revision = state and state.revision or 0
	if self.ObservedState ~= state or self.ObservedMenu ~= menu or self.ObservedRevision ~= revision then
		self.ObservedState, self.ObservedMenu, self.ObservedRevision = state, menu, revision
		self:RefreshInventoryStack()
	end
end

function PANEL:GetStack()
	return self.Stack
end

function PANEL:IsInventorySlot()
	return ( self.Kind == "inventory" or self.Kind == "menu" or self.Kind == "result" ) and self.MenuIndex ~= nil
end

function PANEL:GetActionIndex() return self.MenuIndex end

function PANEL:CanQuickCraft()
	return self:IsInventorySlot() and self.Kind ~= "result"
end

function PANEL:Paint( w, h )
	local hovered = self:IsHovered()
	if hovered then
		surface.SetDrawColor( UI.Colors.selectionDark )
		surface.DrawRect( self.Scale, self.Scale, w - self.Scale * 2, h - self.Scale * 2 )
	end
	if UI.Drag and UI.Drag.IsQueued and UI.Drag.IsQueued( self ) then
		surface.SetDrawColor( UI.Colors.valid )
		surface.DrawRect( self.Scale, self.Scale, w - self.Scale * 2, h - self.Scale * 2 )
	end
	if not MC.IsEmptyItemStack( self.Stack ) then
		UI.ItemRenderer.DrawStack( self.Stack, self.Scale, self.Scale, 16 * self.Scale, { scale = self.Scale } )
	end
	return true
end

function PANEL:OnCursorEntered()
	if IsValid( self.Screen ) and self.Screen.SetHoveredSlot then self.Screen:SetHoveredSlot( self ) end
	if UI.Drag and UI.Drag.HoverSlot then UI.Drag.HoverSlot( self ) end
end

function PANEL:OnCursorExited()
	if IsValid( self.Screen ) and self.Screen.ClearHoveredSlot then self.Screen:ClearHoveredSlot( self ) end
end

function PANEL:OnMousePressed( mouseCode )
	if UI.Drag and UI.Drag.BeginPointer then UI.Drag.BeginPointer( self, mouseCode ) end
	return true
end

function PANEL:OnMouseReleased( mouseCode )
	if UI.Drag and UI.Drag.ReleasePointer then UI.Drag.ReleasePointer( self, mouseCode ) end
	return true
end

function PANEL:OnMouseWheeled( delta )
	if IsValid( self.Screen ) and self.Screen.OnMouseWheeled then return self.Screen:OnMouseWheeled( delta ) end
end

function PANEL:OnRemove()
	if IsValid( self.Screen ) and self.Screen.ClearHoveredSlot then self.Screen:ClearHoveredSlot( self ) end
end

vgui.Register( "MCInventorySlot", PANEL, "DPanel" )
