-- Empty inventory slots use the stock c_arms fist sequences and player hands.
-- No extra client models, timers or hooks: the SWEP owns presentation lifetime.

function SWEP:MCPlayFistSwing()
	if not self:MCIsEmptyHand() then return end
	MC.HandMiningSwing.Request( self, nil, nil, nil, CurTime() )
end

function SWEP:MCClearFistPresentation()
	local owner = self:GetOwner()
	if IsValid( owner ) and owner:GetActiveWeapon() == self then
		local vm = owner:GetViewModel()
		if IsValid( vm ) then vm:SetPlaybackRate( 1 ) end
	end
	self.MCFistPresentation = nil
end

function SWEP:MCPredictHandAttack()
	if not self:MCIsEmptyHand() then return end
	-- Render and prediction CurTime differ; use a monotonic local clock for HUD prediction.
	self.MCPredictedHandAttackAt = RealTime()
end

function SWEP:GetMCHandAttackCharge()
	local owner = self:GetOwner()
	local remaining = math.max( 0, owner:GetNWFloat( "mc_attack_ready_at", 0 ) - CurTime() )
	local spec = MC.ItemAttackSpec( nil )
	local duration = 1 / math.max( 0.1, spec.attackSpeed )
	if self.MCPredictedHandAttackAt then
		remaining = math.max( remaining, duration - ( RealTime() - self.MCPredictedHandAttackAt ) )
	end
	return math.Clamp( 1 - remaining / duration, 0, 1 )
end

-- Run from PreDrawViewModels, before the engine decides whether to draw the
-- native model and before gmod_hands copies its bones.
function SWEP:MCUpdateFistViewModel()
	if not self:MCIsEmptyHand() then
		self.MCFistPresentation = nil
		return false
	end
	local vm, state = self:MCPrepareFistViewModel()
	if not vm then return false end
	local progress = MC.HandMiningSwing.Progress( self )
	local swing = self.MCHandMiningSwingState
	local startedAt = swing and swing.active and swing.startedAt or nil
	-- Creative breaks use the existing placement clock instead of mining cracks.
	if self.MCCreativePlaceAnimStart
		and ( not startedAt or self.MCCreativePlaceAnimStart > startedAt ) then
		local elapsed = CurTime() - self.MCCreativePlaceAnimStart
		if elapsed >= 0 and elapsed < 0.3 then
			startedAt = self.MCCreativePlaceAnimStart
			progress = elapsed / 0.3
		end
	end
	if startedAt and startedAt ~= state.startedAt then
		state.rightHand = not state.rightHand
	end
	state.startedAt = startedAt
	local sequence = state.idle
	if startedAt then sequence = state.rightHand and state.right or state.left end
	if vm:GetSequence() ~= sequence then vm:SendViewModelMatchingSequence( sequence ) end
	vm:SetPlaybackRate( 0 )
	vm:SetCycle( startedAt and progress or 0 )
	vm:InvalidateBoneCache()
	return true
end

function SWEP:PreDrawViewModel()
	return not self:MCUpdateFistViewModel()
end

function SWEP:DoDrawCrosshair()
	if self:MCIsEmptyHand() and MCITEM and MCITEM.Crosshair then return true end
end

function SWEP:DrawHUD()
	local owner = self:GetOwner()
	if not IsValid( owner ) or not owner:Alive() or owner:ShouldDrawLocalPlayer()
		or not self:MCIsEmptyHand() then return end
	local ui = MC.InventoryUI
	if ui and IsValid( ui.Screen ) and ui.Screen:IsVisible() then return end
	local charge = self:GetMCHandAttackCharge()
	if MCITEM and MCITEM.Crosshair then
		MCITEM.Crosshair.Draw( charge, false )
	elseif charge < 1 then
		-- Standalone mc_game keeps the engine crosshair and a compact pixel bar.
		local x, y = math.floor( ScrW() / 2 ) - 16, math.floor( ScrH() / 2 ) + 18
		surface.SetDrawColor( 58, 59, 60, 255 )
		surface.DrawRect( x, y, 32, 4 )
		surface.SetDrawColor( 235, 235, 235, 255 )
		surface.DrawRect( x, y + 1, math.floor( charge * 32 ), 2 )
	end
end
