AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

local SLOT_ORDER = { "mainhand", "offhand", "feet", "legs", "chest", "head" }

local function isCreative( ply ) return MC.Decoration.CreativePlayer( ply ) end

local function playerRecord( ply )
	return MC.SV and MC.SV.GetPlayerInventoryRecord and MC.SV.GetPlayerInventoryRecord( ply, false ) or nil
end

local function handStack( record, hand )
	if hand == "offhand" then return record and record.equipment and record.equipment.offhand or nil end
	local selected = math.Clamp( math.floor( tonumber( record and record.selected ) or 0 ), 0, 8 )
	return record and record.storage and record.storage[selected + 1] or nil
end

local function setPlayerHand( ply, record, hand, stack )
	if hand == "offhand" then
		if not MC.SV.EquipmentSnapshot or not MC.SV.CommitEquipmentMutation then return false, "equipment_api_unavailable" end
		local snapshot = MC.SV.EquipmentSnapshot( record )
		record.equipment.offhand = stack and MC.CopyItemStack( stack ) or nil
		local result, err = MC.SV.CommitEquipmentMutation( record, snapshot, { player = ply, reason = "armor_stand_swap" } )
		if not result then record.equipment.offhand = snapshot.offhand return false, err end
		return true
	end
	local index = math.Clamp( math.floor( tonumber( record.selected ) or 0 ), 0, 8 )
	local snapshot = MC.ContainerSnapshot( record.container )
	local ok, err = MC.ContainerSetStack( record.container, index, stack )
	if not ok then return false, err end
	local result, commitError = MC.SV.CommitPlayerInventoryMutation( record, snapshot, { player = ply, reason = "armor_stand_swap" } )
	if not result then MC.ContainerRestore( record.container, snapshot ) return false, commitError end
	return true
end

local function itemSlot( stack )
	if not stack then return "mainhand" end
	return MC.ItemEquipmentSlot and MC.ItemEquipmentSlot( stack ) or "mainhand"
end

function ENT:Initialize()
	self:SetModel( "models/hunter/blocks/cube025x025x025.mdl" )
	self:SetModelScale( 0.01, 0 )
	self:SetMoveType( MOVETYPE_NONE )
	self:SetSolid( SOLID_BBOX )
	self:SetCollisionGroup( COLLISION_GROUP_WEAPON or COLLISION_GROUP_DEBRIS or 1 )
	self:SetUseType( SIMPLE_USE )
	self:DrawShadow( false )
	self.IsMinecraftArmorStand = true
	self:SetupArmorStandData()
	self:RefreshArmorStandBounds()
	self.MCArmorStandLastThink = CurTime()
end

function ENT:PlayMinecraftPlacementSound()
	-- ArmorStandItem#useOn: SoundEvents.ARMOR_STAND_PLACE, BLOCKS,
	-- volume=0.75F, pitch=0.8F.
	MC.Decoration.PlayDecorationSound( "entity.armor_stand.place", self,
		MC.Decoration.Constants.armorStandPlaceVolume,
		MC.Decoration.Constants.armorStandPlacePitch )
end

function ENT:RefreshArmorStandBounds()
	local scale = self:GetArmorStandScale()
	local blockSize = MC.API and MC.API.Coords and MC.API.Coords.BlockSize and MC.API.Coords.BlockSize() or 36.5
	local width = 0.5 * scale * blockSize
	local height = 1.975 * scale * blockSize
	if self:IsArmorStandMarker() then
		self:SetCollisionBounds( Vector( 0, 0, 0 ), Vector( 0, 0, 0 ) )
		self:SetSolid( SOLID_NONE )
	else
		self:SetCollisionBounds( Vector( -width * 0.5, -width * 0.5, 0 ), Vector( width * 0.5, width * 0.5, height ) )
		self:SetSolid( SOLID_BBOX )
	end
end

function ENT:SurvivesMinecraft()
	if self:IsArmorStandMarker() then return true end
	local minimum, maximum = self:WorldSpaceAABB()
	return not MC.Decoration.WorldAABBHasCollision( minimum, maximum )
end

function ENT:ArmorStandClickedSlot( hitPos )
	local localY = MC.Decoration.LocalClickY( self, hitPos )
	local has = {}
	for _, slot in ipairs( { "feet", "chest", "legs", "head" } ) do has[slot] = self:HasItemInSlot( slot ) end
	return MC.Decoration.ArmorStandClickedSlot( localY, self:IsArmorStandSmall(), has,
		not self:HasItemInSlot( "mainhand" ), self:HasItemInSlot( "offhand" ) )
end

function ENT:IsArmorStandSlotDisabled( slot, taking )
	return MC.Decoration.ArmorStandDisabled( self:GetArmorStandDisabledSlots(), slot, taking, self:ShowArmorStandArms() )
end

function ENT:SwapArmorStandItem( ply, slot, playerStack, hand )
	if self:IsArmorStandSlotDisabled( slot, self:HasItemInSlot( slot ) ) then return false end
	local standStack = self:GetArmorStandSlot( slot )
	if standStack and self:IsArmorStandSlotDisabled( slot, true ) then return false end
	if not standStack and self:IsArmorStandSlotDisabled( slot, false ) then return false end
	if isCreative( ply ) and not standStack and playerStack then
		self:SetArmorStandSlot( slot, MC.CopyItemStack( playerStack, 1 ) )
		return true
	end
	if not playerStack or ( tonumber( playerStack.count ) or 0 ) <= 1 then
		local replacement = playerStack and MC.CopyItemStack( playerStack ) or nil
		local record = playerRecord( ply )
		if not record then return false end
		if not self:SetArmorStandSlot( slot, replacement, false ) then return false end
		local ok = setPlayerHand( ply, record, hand, standStack )
		if not ok then self:SetArmorStandSlot( slot, standStack, false ) return false end
		self:RefreshArmorStandBounds()
		return true
	end
	if standStack then return false end
	local record = playerRecord( ply )
	if not record then return false end
	local one = MC.CopyItemStack( playerStack, 1 )
	if not self:SetArmorStandSlot( slot, one, false ) then return false end
	local remaining = MC.CopyItemStack( playerStack, math.max( 1, playerStack.count - 1 ) )
	local ok = setPlayerHand( ply, record, hand, remaining )
	if not ok then self:SetArmorStandSlot( slot, nil, false ) return false end
	self:RefreshArmorStandBounds()
	return true
end

function ENT:MinecraftInteract( ply, stack, context )
	if ply and ply.IsSpectator and ply:IsSpectator() then return true end
	local hand = context and context.hand == "offhand" and "offhand" or "mainhand"
	local playerStack = stack
	if playerStack and MC.Decoration.ItemName( playerStack ) == "minecraft:name_tag" then
		-- ArmorStand#interact returns super for name tags, after which
		-- Player#interactOn invokes NameTagItem#interactLivingEntity. A present
		-- CUSTOM_NAME (including the empty component) claims the action; an
		-- unrenamed tag remains PASS and must not enter equipment swapping.
		local customName, present
		if MC.GetItemCustomName then customName, present = MC.GetItemCustomName( playerStack ) end
		if present ~= true then return nil end
		if context and context.preview then return true end
		if not MC.SV or not MC.SV.ConsumeHeldItem then return false end
		local result = MC.SV.ConsumeHeldItem( ply, 1, {
			hand = hand,
			expectedItem = "minecraft:name_tag",
			expectedHash = MC.ItemStackHash and MC.ItemStackHash( playerStack ) or nil,
			respectInfiniteMaterials = true,
			reason = "armor_stand_name_tag",
		} )
		if not result or result.ok ~= true then return false end
		self:SetArmorStandCustomName( tostring( customName or "" ) )
		self:SetArmorStandHasCustomName( true )
		return true
	end
	if self:IsArmorStandMarker() then return nil end
	if context and context.preview then return true end
	local record = playerRecord( ply )
	if not record then return false end
	-- The interaction event carries the exact hand snapshot.  Falling back to
	-- the authoritative record is only for older callers that did not provide a
	-- stack (notably an empty-hand click).
	playerStack = stack or handStack( record, hand )
	local slot = playerStack and itemSlot( playerStack ) or self:ArmorStandClickedSlot( context and context.hitPos )
	if not playerStack then
		local clicked = slot
		-- ArmorStand#interact uses MAINHAND as the item-in-hand slot when the
		-- hand is empty; a disabled clicked slot therefore falls back to it.
		if self:IsArmorStandSlotDisabled( clicked, nil ) then slot = "mainhand" end
		if not self:HasItemInSlot( slot ) then return nil end
	end
	if playerStack and ( slot == "mainhand" or slot == "offhand" ) and not self:ShowArmorStandArms() then return false end
	if playerStack and self:IsArmorStandSlotDisabled( slot, false ) then return false end
	return self:SwapArmorStandItem( ply, slot, playerStack, hand )
end

local function dropStack( ent, stack, causedBy )
	if not stack or not MC.SV or not MC.SV.SpawnItemDrop then return end
	MC.SV.SpawnItemDrop( ent:GetPos(), stack, causedBy, { pickupDelay = 0.5 } )
end

function ENT:DropArmorStandItem( causedBy )
	if not MC.NewItemStack then return end
	local components
	if self:GetArmorStandHasCustomName() then
		components = { ["minecraft:custom_name"] = self:GetArmorStandCustomName() }
	end
	dropStack( self, MC.NewItemStack( "minecraft:armor_stand", 1, components ), causedBy )
end

function ENT:DropArmorStandEquipment( causedBy )
	-- ArmorStand#brokenByAnything clears every EquipmentSlot. Its only item
	-- level veto is PREVENT_EQUIPMENT_DROP (Vanishing Curse); no early
	-- ENTITY_DROPS return is permitted here. The loop must run even when a
	-- host gamerule adapter suppresses ordinary mob loot.
	for _, slot in ipairs( SLOT_ORDER ) do
		local stack = self:GetArmorStandSlot( slot )
		if stack
		and MC.Decoration.ShouldDropEquipmentStack( causedBy, stack, {
			source = "armor_stand", slot = slot,
		} ) then
			dropStack( self, stack, causedBy )
		end
		self:SetArmorStandSlot( slot, nil, false )
	end
end

function ENT:DropArmorStandContents( causedBy, includeStand )
	-- Compatibility wrapper for the older decoration dispatcher. Keep the
	-- Java order when explicitly requested: stand item first, then equipment.
	if includeStand then
		self:DropArmorStandItem( causedBy )
	end
	self:DropArmorStandEquipment( causedBy )
end

function ENT:BrokenByAnything( causedBy, includeStand )
	MC.Decoration.PlayDecorationSound( "entity.armor_stand.break", self, 1, 1 )
	-- `includeStand` is false for Java brokenByAnything/causeDamage/explosion.
	-- The true path is retained only for legacy callers; the precise player
	-- path below emits the stand before this sound/cleanup method.
	if includeStand then
		self:DropArmorStandItem( causedBy )
	end
	self:DropArmorStandEquipment( causedBy )
end

function ENT:BrokenByPlayer( causedBy )
	-- ArmorStand#brokenByPlayer pops the stand item first, then delegates to
	-- brokenByAnything (which plays the break sound and drops equipment).
	self:DropArmorStandItem( causedBy )
	self:BrokenByAnything( causedBy, false )
end

function ENT:CauseArmorStandDamage( causedBy, amount )
	local health = ( tonumber( self:GetArmorStandHealth() ) or MC.Decoration.Constants.armorStandMaxHealth )
	health = health - ( tonumber( amount ) or 0 )
	if health <= 0.5 then
		self:BrokenByAnything( causedBy, false )
		self:KillMinecraft( causedBy )
	else
		self:SetArmorStandHealth( health )
		MC.Decoration.EmitDecorationGameEvent( self, "minecraft:entity_damage", causedBy )
	end
end

function ENT:ShowArmorStandBreakingParticles()
	return MC.Decoration.SendArmorStandBreakingParticles( self )
end

function ENT:KillMinecraft( causedBy )
	local context = { worldPosition = MC.Decoration.WorldFromEntity( self ) }
	self:Remove()
	MC.Decoration.EmitDecorationGameEvent( self, "minecraft:entity_die", causedBy, context )
end

function ENT:HandleMinecraftDecorationAttack( ply, context )
	context = context or {}
	context.removed = self:IsRemoved()
	context.invisible = self:IsArmorStandInvisible()
	context.marker = self:IsArmorStandMarker()
	context.health = self:GetArmorStandHealth()
	context.lastHit = self:GetArmorStandLastHit()
	context.onFire = self:IsOnFire()
	local decision = MC.Decoration.ArmorStandDamageDecision( context )
	if decision.action == "ignite" then
		self:Ignite( decision.seconds )
	elseif decision.action == "cause_damage" then
		self:CauseArmorStandDamage( ply, decision.amount )
	elseif decision.action == "wobble" then
		local tick = tonumber( context.gameTick ) or math.floor( ( CurTime() or 0 ) * 20 )
		MC.Decoration.PlayDecorationSound( "entity.armor_stand.hit", self, 0.3, 1 )
		MC.Decoration.EmitDecorationGameEvent( self, "minecraft:entity_damage", ply )
		self:SetArmorStandLastHit( tick )
	elseif decision.action == "break_player" then
		self:BrokenByPlayer( ply )
		self:ShowArmorStandBreakingParticles()
		self:KillMinecraft( ply )
	elseif decision.action == "break_anything" then
		self:BrokenByAnything( ply, false )
		self:KillMinecraft( ply )
	elseif decision.action == "creative_break" then
		MC.Decoration.PlayDecorationSound( "entity.armor_stand.break", self, 1, 1 )
		self:ShowArmorStandBreakingParticles()
		self:KillMinecraft( ply )
	elseif decision.action == "kill" then
		-- BYPASSES_INVULNERABILITY calls kill() directly: no sound, particles or
		-- equipment mutation in the Java method.
		self:KillMinecraft( ply )
	end
	decision.handled = true
	decision.destroyed = decision.action == "kill" or decision.action == "creative_break"
		or decision.action == "break_player"
		or decision.action == "break_anything" or self:IsRemoved()
	return decision
end

function ENT:OnTakeDamage( damageInfo )
	local attacker = damageInfo and damageInfo.GetAttacker and damageInfo:GetAttacker() or nil
	local context = MC.Decoration.DecorationDamageContext( self, damageInfo )
	context.removed = self:IsRemoved()
	context.invisible = self:IsArmorStandInvisible()
	context.marker = self:IsArmorStandMarker()
	-- The SENT has no Java Level/ damage-source invulnerability hook. Keep an
	-- explicit network override if a host supplies one; never call a guessed
	-- Source method with the wrong signature.
	context.invulnerable = self.GetNW2Bool and self:GetNW2Bool( "mc_invulnerable", false ) or false
	context.health = self:GetArmorStandHealth()
	context.lastHit = self:GetArmorStandLastHit()
	context.onFire = self:IsOnFire()
	context.mob = IsValid( attacker ) and (
		( attacker.IsNPC and attacker:IsNPC() ) or ( attacker.IsNextBot and attacker:IsNextBot() )
		or attacker.IsMinecraftMob == true ) or false
	if MC.Decoration.MobGriefingEnabled then
		context.mobGriefing = MC.Decoration.MobGriefingEnabled()
	else
		context.mobGriefing = true
	end
	if MC.Decoration.PlayerMayBuild then
		context.playerMayBuild = MC.Decoration.PlayerMayBuild( attacker )
	else
		context.playerMayBuild = true
	end
	context.creative = MC.Decoration.CreativePlayer( attacker )
	context.gameTick = math.floor( ( CurTime() or 0 ) * 20 )
	self:HandleMinecraftDecorationAttack( attacker, context )
	return 0
end

function ENT:Think()
	self:NextThink( CurTime() + 0.05 )
	return true
end
