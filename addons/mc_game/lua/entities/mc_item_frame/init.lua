AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

function ENT:Initialize()
	self:SetModel( "models/hunter/blocks/cube025x025x025.mdl" )
	self:SetFrameItemName( "" )
	self:SetFrameItemComponents( "" )
	self:SetFrameItemCount( 0 )
	self:SetFrameItemDamage( 0 )
	self:SetFrameRotation( 0 )
	self:SetFrameFixed( false )
	self:SetFrameDropChance( 1 )
	MC.Decoration.HangingInitialize( self,
		self:IsGlowMinecraftFrame() and "glow_item_frame" or "item_frame" )
	self.MCDecorationCheckInterval = 0
end

function ENT:SurvivesMinecraft()
	return MC.Decoration.HangingSurvives(
		self, true, self:GetDecorationSupportCells(), self:GetFrameFixed() )
end

function ENT:DropMinecraftContents( causedBy, withFrame )
	if self:GetFrameFixed() then return end
	local item = self:GetMinecraftFrameItem()
	self:SetMinecraftFrameItem( nil )
	if not MC.Decoration.EntityDropsEnabled() then
		-- ItemFrame#dropItem only clears map tracking in this branch when the
		-- break has no causing entity (survival tick / movement).
		if causedBy == nil then MC.Decoration.NotifyFramedMapRemoved( self, item ) end
		return
	end
	if MC.Decoration.CreativePlayer( causedBy ) then
		MC.Decoration.NotifyFramedMapRemoved( self, item )
		return
	end
	if withFrame then
		local frame = MC.NewItemStack and MC.NewItemStack( self:GetFrameItemNameForDrop(), 1 ) or nil
		if frame then MC.Decoration.SpawnDecorationDrop( self, frame, nil, causedBy ) end
	end
	if item then
		MC.Decoration.NotifyFramedMapRemoved( self, item )
		if math.Rand( 0, 1 ) < math.Clamp( self:GetFrameDropChance(), 0, 1 ) then
			MC.Decoration.SpawnDecorationDrop( self, item, nil, causedBy )
		end
	end
end

function ENT:BeforeMinecraftKill()
	-- ItemFrame#kill always removes framed-map tracking, including fixed
	-- frames. The subsequent dropItem path can issue the same idempotent
	-- removal again, exactly like Java's kill-then-drop sequence.
	MC.Decoration.NotifyFramedMapRemoved( self, self:GetMinecraftFrameItem() )
end

function ENT:DropMinecraftItem( causedBy )
	MC.Decoration.PlayDecorationSound( self:FrameSoundEvent( "break" ), self, 1, 1 )
	self:DropMinecraftContents( causedBy, true )
	MC.Decoration.EmitDecorationGameEvent( self, "minecraft:block_change", causedBy )
end

function ENT:PlayMinecraftPlacementSound()
	MC.Decoration.PlayDecorationSound( self:FrameSoundEvent( "place" ), self, 1, 1 )
end

function ENT:MinecraftInteract( ply, stack, context )
	if self:GetFrameFixed() then return nil end
	local current = self:GetMinecraftFrameItem()
	if current then
		if context and context.preview then return true end
		MC.Decoration.PlayDecorationSound( self:FrameSoundEvent( "rotate_item" ), self, 1, 1 )
		self:SetMinecraftRotation( self:GetFrameRotation() + 1 )
		MC.Decoration.EmitDecorationGameEvent( self, "minecraft:block_change", ply )
		return true
	end
	if not stack then return nil end
	if context and context.preview then return true end
	if MC.Decoration.MapTrackedCountOverLimit and MC.Decoration.MapTrackedCountOverLimit( stack, 256 ) then
		return false
	end
	if not MC.SV or not MC.SV.ConsumeHeldItem then return false end
	local hand = context and context.hand == "offhand" and "offhand" or "mainhand"
	local set, setError = self:SetMinecraftFrameItem( stack )
	if set ~= true then return false, setError end
	MC.Decoration.EmitDecorationGameEvent( self, "minecraft:block_change", ply )
	local result = MC.SV.ConsumeHeldItem( ply, 1, {
		hand = hand,
		expectedItem = stack.item,
		expectedHash = MC.ItemStackHash and MC.ItemStackHash( stack ) or nil,
		respectInfiniteMaterials = true,
		reason = "item_frame_add_item",
	} )
	if not result or result.ok ~= true then
		-- Java's synchronous ItemStack#consume cannot fail after setItem. A stale
		-- network mutation can; restore the frame rather than duplicate the item.
		self:SetMinecraftFrameItem( nil )
		return false
	end
	return true
end

function ENT:HandleMinecraftDecorationAttack( ply, _, context )
	context = context or {}
	context.removed = self:IsRemoved()
	context.fixed = self:GetFrameFixed()
	context.hasItem = self:GetMinecraftFrameItem() ~= nil
	if context.creative == nil then context.creative = MC.Decoration.CreativePlayer( ply ) end
	local decision = MC.Decoration.ItemFrameDamageDecision( context )
	if decision.action == "reject" then
		return { handled = true, accepted = false, damageTool = false }
	end
	if decision.action == "remove_item" then
		self:DropMinecraftContents( ply, false )
		MC.Decoration.EmitDecorationGameEvent( self, "minecraft:block_change", ply )
		MC.Decoration.PlayDecorationSound( self:FrameSoundEvent( "remove_item" ), self, 1, 1 )
		return { handled = true, accepted = true, damageTool = false, removedItem = true }
	end
	-- Both the fixed accepted branch and the ordinary BlockAttachedEntity path
	-- kill first, then run the normal frame drop routine. Keep kill's map
	-- tracking side effect before drops even though Source removal itself must
	-- wait until the drop helper has read the entity position.
	self:BeforeMinecraftKill()
	self:DropMinecraftItem( ply )
	self:Remove()
	return { handled = true, accepted = true, damageTool = false, destroyed = true }
end

function ENT:OnTakeDamage( damageInfo )
	local attacker = damageInfo and damageInfo.GetAttacker and damageInfo:GetAttacker() or nil
	local context = MC.Decoration.DecorationDamageContext( self, damageInfo )
	if MC.Decoration.BlockAttachedIgnoresExplosion( damageInfo, context ) then return 0 end
	context.creative = MC.Decoration.CreativePlayer( attacker )
	context.invulnerable = self.GetNW2Bool and self:GetNW2Bool( "mc_invulnerable", false ) or false
	context.mob = IsValid( attacker ) and (
		( attacker.IsNPC and attacker:IsNPC() ) or ( attacker.IsNextBot and attacker:IsNextBot() )
		or attacker.IsMinecraftMob == true ) or false
	context.mobGriefing = MC.Decoration.MobGriefingEnabled and MC.Decoration.MobGriefingEnabled() or true
	self:HandleMinecraftDecorationAttack( attacker, nil, context )
	return 0
end

function ENT:Think()
	MC.Decoration.HangingTick( self )
	self:NextThink( CurTime() + 0.05 )
	return true
end

function ENT:PhysicsUpdate( physics )
	if self:GetFrameFixed() or not IsValid( physics ) or physics:GetVelocity():LengthSqr() <= 0 then return end
	MC.Decoration.HangingMoveBreak( self )
end
