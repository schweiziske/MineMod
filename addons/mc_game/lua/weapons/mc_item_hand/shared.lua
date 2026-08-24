--[[----------------------------------------------------------------------------
    mc_item_hand

    The survival/creative Minecraft hand.  The selected item is read from the
    server-authoritative inventory record; the client only predicts the same
    block-state plan for responsiveness.  Inventory UI and hotbar are separate
    client modules, so this SWEP contains only world interaction and held-item
    presentation.
------------------------------------------------------------------------------]]

if SERVER then AddCSLuaFile() end

MC = MC or {}

SWEP.PrintName = "Minecraft Hand"
SWEP.Author = "schweiziske"
SWEP.Purpose = "Minecraft inventory item interaction"
SWEP.Instructions = "左键破坏  右键使用/放置  Reload 或 E 打开物品栏"
SWEP.Category = "Minecraft"
SWEP.Spawnable = true
SWEP.AdminOnly = false
SWEP.Slot = 1
SWEP.SlotPos = 5
SWEP.DrawAmmo = false
SWEP.DrawCrosshair = true
SWEP.Base = "weapon_base"
SWEP.UseHands = true
SWEP.ViewModel = "models/weapons/c_toolgun.mdl"
SWEP.WorldModel = "models/weapons/w_toolgun.mdl"
SWEP.DrawViewModel = false
SWEP.DrawWorldModel = false
SWEP.Primary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" }
SWEP.Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" }

local ATTACK_INTERVAL = 0.12
local USE_TICK_INTERVAL = 0.05
local CREATIVE_DESTROY_DELAY = 5 / 20
local PROXY_INTERACT_NET = "mc_inventory_proxy_world_interact"
if SERVER then util.AddNetworkString( PROXY_INTERACT_NET ) end
local COMBAT_INFRASTRUCTURE = {
	mc_block_cluster = true, mc_chunk = true, mc_chunk_phys = true,
	mc_collision_carrier = true, mc_item_drop = true, mc_projectile = true,
}

local function decorationCombatTarget( target )
	return IsValid( target ) and MC.Decoration and MC.Decoration.Enabled
		and MC.Decoration.Enabled() and MC.Decoration.EntityDecorationTarget
		and MC.Decoration.EntityDecorationTarget( target ) == true
end

local function aimedBlock( ply )
	return MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
end

local function traceCombatTarget( ply, trace )
	local target = trace and trace.Entity or nil
	local vehicle = MC.ResolveMinecraftVehicle and MC.ResolveMinecraftVehicle( target ) or nil
	if vehicle then target = vehicle end
	if not IsValid( target ) or target == ply or target.IsWorld and target:IsWorld() then return nil end
	if COMBAT_INFRASTRUCTURE[target.GetClass and target:GetClass() or ""] then return nil end
	local attackable = vehicle ~= nil
		or decorationCombatTarget( target )
		or target.IsPlayer and target:IsPlayer()
		or target.IsNPC and target:IsNPC()
		or target.IsNextBot and target:IsNextBot()
		or target.Health and tonumber( target:Health() ) and target:Health() > 0
	if not attackable then return nil end
	local start = ply.GetShootPos and ply:GetShootPos() or ply:EyePos()
	local hit = trace.HitPos or target.WorldSpaceCenter and target:WorldSpaceCenter() or target:GetPos()
	local reach = ( tonumber( MC.BS or MC.Config and MC.Config.BlockSize ) or 36.5 ) * 3
	if hit and ( hit - start ):LengthSqr() > reach * reach + 1 then return nil end
	return target
end

local function copiedInteractionStack( stack )
	if not istable( stack ) then return nil end
	if MC.CopyItemStack then return MC.CopyItemStack( stack ) end
	if MC.API and MC.API.DeepCopy then return MC.API.DeepCopy( stack ) end
	return table.Copy and table.Copy( stack ) or stack
end

local function hasCreativeEntityReach( ply )
	if SERVER then
		return MC.SV and MC.SV.PlayerIsCreative and MC.SV.PlayerIsCreative( ply ) == true
	end
	return MC.PlayerIsCreative and MC.PlayerIsCreative( ply ) == true
end

local function traceItemEntityTarget( ply )
	if not IsValid( ply ) or not ply.GetEyeTrace then return nil, nil end
	local trace = ply:GetEyeTrace()
	local target = trace and trace.Entity or nil
	if not IsValid( target ) or target == ply or target.IsWorld and target:IsWorld() then return nil, trace end
	if COMBAT_INFRASTRUCTURE[target.GetClass and target:GetClass() or ""] then return nil, trace end

	-- Player.DEFAULT_ENTITY_INTERACTION_RANGE is 3 blocks; creative adds the
	-- +2 attribute modifier in Player.java.  Use the traced surface point so a
	-- large entity is not rejected because its origin/centre is farther away.
	local reachBlocks = 3 + ( hasCreativeEntityReach( ply ) and 2 or 0 )
	local reach = ( tonumber( MC.BS or MC.Config and MC.Config.BlockSize ) or 36.5 ) * reachBlocks
	local start = ply.GetShootPos and ply:GetShootPos() or ply:EyePos()
	local hit = trace.HitPos or target.WorldSpaceCenter and target:WorldSpaceCenter() or target:GetPos()
	if hit and ( hit - start ):LengthSqr() > reach * reach + 1 then return nil, trace end
	return target, trace
end

local function runItemEntityInteraction( ply, target, stack, trace, preview, source, hand )
	if not IsValid( ply ) or not IsValid( target ) then return nil end
	local eventStack = copiedInteractionStack( stack )
	local eventContext = {
		preview = preview == true,
		hand = hand == "offhand" and "offhand" or "mainhand",
		source = source or "minecraft_hand",
		hitPos = trace and trace.HitPos and Vector( trace.HitPos ) or nil,
		hitNormal = trace and trace.HitNormal and Vector( trace.HitNormal ) or nil,
	}
	local ok, result = pcall( function()
		return hook.Run( "MC.UseItemOnEntity", ply, target, eventStack, eventContext )
	end )
	if ok then return result end
	if ErrorNoHalt then
		ErrorNoHalt( "[MC Game] event listener error in MC.UseItemOnEntity: " .. tostring( result ) .. "\n" )
	end
	return nil
end

local function offhandStackForRealm( ply )
	if SERVER then
		local record = MC.SV and MC.SV.GetPlayerInventoryRecord
			and MC.SV.GetPlayerInventoryRecord( ply, false ) or nil
		return record and record.equipment and record.equipment.offhand or nil
	end
	local state = MC.ClientInventory
	return state and state.equipment and state.equipment.offhand or nil
end

-- Minecraft's client attempts MAIN_HAND first and only sends OFF_HAND when the
-- first interaction returns PASS. nil is this bridge's PASS; false is FAIL and
-- therefore stops the second hand.
local function runItemEntityInteractionHands( ply, target, mainStack, trace, preview, source )
	local result = runItemEntityInteraction(
		ply, target, mainStack, trace, preview, source, "mainhand" )
	if result ~= nil then return result, "mainhand" end
	return runItemEntityInteraction(
		ply, target, offhandStackForRealm( ply ), trace, preview, source, "offhand" ), "offhand"
end

local function breakTarget( ply, aim, trace )
	if aim then return aim.bx, aim.by, aim.bz end
	if not trace or not trace.Hit or not MC.WorldToCell then return nil end
	return MC.WorldToCell( trace.HitPos - trace.HitNormal * 0.5 )
end

local function logisticsParityOrderEnabled()
	local L = MC.LogisticsParity
	return L and L.Enabled and L.Enabled() == true or false
end

local function applyLogisticsPlacementState( stateId, hit )
	if not stateId or not logisticsParityOrderEnabled() then return stateId end
	local L = MC.LogisticsParity
	local Blocks = MC.API and MC.API.Blocks
	if not Blocks or not Blocks.Name or not Blocks.WithProperty then return stateId end
	if Blocks.Name( stateId ) ~= "minecraft:hopper" then return stateId end
	local facing = L.HopperFacingForClickedNormal and L.HopperFacingForClickedNormal( hit and hit.HitNormal ) or nil
	if not facing then return stateId end
	return Blocks.WithProperty( stateId, "facing", facing ) or stateId
end

local function placeTarget( ply, aim, trace, id )
	local hit = aim or trace
	if not hit or not hit.Hit then return nil end
	local bx, by, bz
	if aim then
		bx = aim.bx + math.Round( aim.HitNormal.x )
		by = aim.by + math.Round( aim.HitNormal.y )
		bz = aim.bz + math.Round( aim.HitNormal.z )
	else
		bx, by, bz = MC.WorldToCell( trace.HitPos + trace.HitNormal * 0.5 )
	end
	local stateId
	if MC.OrientForPlacement and MC.StateFromLegacy then
		local orient = MC.OrientForPlacement( ply, hit, id )
		stateId = MC.StateFromLegacy( id, orient )
	end
	if not stateId and MC.DefaultBlockState then stateId = MC.DefaultBlockState( id ) end
	if stateId and MC.ResolveTorchPlacementState then stateId = MC.ResolveTorchPlacementState( stateId, hit.HitNormal ) end
	if stateId and MC.ResolveFaceAttachedPlacementState then stateId = MC.ResolveFaceAttachedPlacementState( stateId, hit.HitNormal, ply ) end
	if stateId and MC.ResolveSignPlacementState then stateId = MC.ResolveSignPlacementState( stateId, hit.HitNormal, ply, bx, by, bz ) end
	if stateId and MC.ResolveBannerPlacementState then stateId = MC.ResolveBannerPlacementState( stateId, hit.HitNormal, ply, bx, by, bz ) end
	stateId = applyLogisticsPlacementState( stateId, hit )
	if not stateId then return nil end
	return bx, by, bz, stateId
end

local function selectedRecord( ply )
	if not MC.SV or not MC.SV.GetPlayerInventoryRecord then return nil end
	local record = MC.SV.GetPlayerInventoryRecord( ply, false )
	if not record or not record.container then return nil end
	local stack = MC.SV.GetSelectedPlayerStack and MC.SV.GetSelectedPlayerStack( ply ) or nil
	local definition = stack and MC.GetItem( stack.item ) or nil
	return record, stack, definition
end

local function infiniteMaterials( ply )
	return MC.SV and MC.SV.PlayerHasInfiniteMaterials and MC.SV.PlayerHasInfiniteMaterials( ply ) == true
end

local function creativeMode( ply )
	if SERVER then return MC.SV and MC.SV.PlayerIsCreative and MC.SV.PlayerIsCreative( ply ) == true end
	return MC.PlayerIsCreative and MC.PlayerIsCreative( ply ) == true
end

local function creativeBlockAttackAllowed( stack )
	return not MC.ItemCanDestroyBlocksInCreative or MC.ItemCanDestroyBlocksInCreative( stack ) == true
end

local function isUseCandidate( stack, definition )
	if not stack or not definition then return false end
	if MC.ItemBehavior and MC.ItemBehavior( stack ) then return true end
	if MC.ItemIsConsumable and MC.ItemIsConsumable( stack ) then return true end
	return isfunction and isfunction( definition.useHandler ) and definition.useHandler ~= nil
end

-- Items whose block interaction is "apply this item to the block" rather than
-- "operate the block". Minecraft swings the arm for the former; a fire charge
-- lighting TNT should look the same as a fire charge lighting the ground.
local IGNITER_ITEMS = {
	["minecraft:flint_and_steel"] = true,
	["minecraft:fire_charge"] = true,
}

local function igniterStack( stack )
	return stack ~= nil and IGNITER_ITEMS[stack.item] == true
end

local function blockHasUse( id, stack )
	local block = MC.Blocks and MC.Blocks[id]
	local handlers = block and block.handlers
	if not handlers or handlers.OnUse == nil then return false end
	if handlers.CanUse ~= nil then return handlers.CanUse( stack ) == true end
	return true
end

-- The two base SWEPs are never proxies: they implement SecondaryAttack
-- themselves. This matters because the client proxy preflight below strips
-- IN_ATTACK2 out of the usercmd once it claims a press.
local BASE_INTERACTION_WEAPONS = {
	mc_item_hand = true,
	mc_inventory = true,
}

local function inventoryProxyWeapon( weapon )
	if not IsValid( weapon ) then return false end
	if SERVER and weapon.MCHandWeaponBridgeProxy == true then return true end
	if weapon.GetNW2Bool and weapon:GetNW2Bool( "MCITEM_InventoryProxy", false ) == true then return true end
	if CLIENT and MC.IsInventoryHeldItemWeaponActive then
		-- IsSelectedActive() answers "is the inventory driving the held weapon",
		-- which is true for mc_item_hand itself. Treating the hand as a proxy
		-- made the client preflight claim the press and RemoveKey( IN_ATTACK2 ),
		-- so the key never reached the server: the hand's own SecondaryAttack
		-- never ran, and the PROXY_INTERACT_NET request it sent instead was
		-- rejected server-side, where the hand is correctly not a proxy. Result:
		-- right-click did nothing at all with an empty hand. The client branch
		-- exists only to catch predicted weapon_mcitem_* instances before the
		-- server stamps MCITEM_InventoryProxy, so exclude the base weapons.
		if BASE_INTERACTION_WEAPONS[weapon:GetClass()] then return false end
		local owner = weapon:GetOwner()
		return IsValid( owner ) and owner:GetActiveWeapon() == weapon
			and MC.IsInventoryHeldItemWeaponActive( owner ) == true
	end
	return false
end

local function activeInventoryProxy( ply )
	local weapon = IsValid( ply ) and ply:GetActiveWeapon() or nil
	return inventoryProxyWeapon( weapon )
end

local function selectedStackForRealm( ply )
	if SERVER then
		local _, stack = selectedRecord( ply )
		return stack
	end
	local state = MC.ClientInventory
	return state and state.slots and state.slots[( state.selected or 0 ) + 1] or nil
end

local function logisticsSecondaryUseSuppressesBlock( ply, stack )
	local L = MC.LogisticsParity
	if not logisticsParityOrderEnabled() or not L.SecondaryUseSuppressesBlock then return false end
	local secondaryUseActive = IsValid( ply ) and ply.KeyDown and ply:KeyDown( IN_SPEED ) == true
	return L.SecondaryUseSuppressesBlock( secondaryUseActive, stack, offhandStackForRealm( ply ) ) == true
end

local function proxyWorldInteractionCandidate( ply, stack )
	local vehicle = MC.TraceMinecraftVehicle and select( 1, MC.TraceMinecraftVehicle( ply, 3, MASK_SOLID ) ) or nil
	if IsValid( vehicle ) then return "vehicle", vehicle end
	local entity, trace = traceItemEntityTarget( ply )
	if IsValid( entity ) then
		local preview = runItemEntityInteractionHands( ply, entity, stack, trace, true, "inventory_proxy_preview" )
		if preview ~= nil then return "entity", { entity = entity, trace = trace } end
	end
	local aim = aimedBlock( ply )
	local hit = aim or trace
	local parityOrder = logisticsParityOrderEnabled()
	local suppressBlockUse = parityOrder and logisticsSecondaryUseSuppressesBlock( ply, stack )
	if parityOrder and not suppressBlockUse and aim and blockHasUse( aim.Block, stack ) then
		return "block", aim
	end
	if stack and hit and MC.Decoration and MC.Decoration.PreviewPlace then
		local preview = MC.Decoration.PreviewPlace( ply, stack, hit )
		if preview ~= nil then return "decoration", hit end
	end
	if not parityOrder and not suppressBlockUse and aim and blockHasUse( aim.Block, stack ) then
		return "block", aim
	end
	return nil, nil
end

local function performProxyWorldInteraction( ply, stack, kind, target )
	if not SERVER or not MC.SV or not kind or not target then return false end
	local now = CurTime()
	if now < ( ply.MCProxyWorldInteractNextAt or 0 ) then return true end
	ply.MCProxyWorldInteractNextAt = now + 0.05
	if MC.SV.CancelMining then MC.SV.CancelMining( ply, "secondary_attack" ) end
	if kind == "vehicle" and MC.SV.UseMinecraftVehicle then
		return MC.SV.UseMinecraftVehicle( ply, target ) == true
	end
	if kind == "entity" and IsValid( target.entity ) then
		local result = runItemEntityInteractionHands(
			ply, target.entity, stack, target.trace, false, "inventory_proxy" )
		return result ~= nil
	end
	if kind == "decoration" then
		return hook.Run( "MC.TryPlaceDecoration", ply, copiedInteractionStack( stack ),
			target, { source = "inventory_proxy" } ) ~= nil
	end
	if kind == "block" and MC.SV.Use then
		local definition = stack and MC.GetItem( stack.item ) or nil
		return MC.SV.Use( ply, target.bx, target.by, target.bz, definition and definition.blockId or 0 ) == true
	end
	return false
end

local function tryInventoryProxyWorldInteraction( weapon )
	if not inventoryProxyWeapon( weapon ) then return false end
	local ply = weapon:GetOwner()
	if not IsValid( ply ) or not ply:Alive() or ply:GetActiveWeapon() ~= weapon then return false end
	local stack = selectedStackForRealm( ply )
	local kind, target = proxyWorldInteractionCandidate( ply, stack )
	if not kind then return false end
	if weapon.SetNextSecondaryFire then weapon:SetNextSecondaryFire( CurTime() + ATTACK_INTERVAL ) end
	if SERVER then
		performProxyWorldInteraction( ply, stack, kind, target )
	elseif IsFirstTimePredicted() then
		net.Start( PROXY_INTERACT_NET )
		net.SendToServer()
	end
	return true
end

-- External weapon_mcitem classes remain responsible for their standalone
-- behavior. Inventory-owned proxy instances call this preflight first so
-- Minecraft entity/block use wins over eating, charging, or throwing.
MC.TryInventoryProxyWorldInteraction = tryInventoryProxyWorldInteraction

-- Resolver-driven weapon_mcitem_* instances own their own SecondaryAttack.
-- Minecraft still gives entity/block interaction precedence over item use, so
-- consume that user-command before the proxy can start eating/charging and
-- route the press through the same authoritative MCSWEP handlers as the hand.
hook.Add( "StartCommand", "mc_inventory_proxy_world_interaction", function( ply, command )
	if not activeInventoryProxy( ply ) then
		ply.MCInventoryProxySecondaryHeld = false
		ply.MCInventoryProxySecondaryConsumed = false
		return
	end
	if not command:KeyDown( IN_ATTACK2 ) then
		ply.MCInventoryProxySecondaryHeld = false
		ply.MCInventoryProxySecondaryConsumed = false
		return
	end

	if not ply.MCInventoryProxySecondaryHeld then
		ply.MCInventoryProxySecondaryHeld = true
		local stack = selectedStackForRealm( ply )
		local kind, target = proxyWorldInteractionCandidate( ply, stack )
		if kind then
			ply.MCInventoryProxySecondaryConsumed = true
			if SERVER then
				performProxyWorldInteraction( ply, stack, kind, target )
			elseif net then
				-- Removing IN_ATTACK2 client-side prevents the proxy's predicted food/
				-- charge action and also removes it from the outgoing usercmd. Send a
				-- payload-free request; the server recomputes and validates the target.
				net.Start( PROXY_INTERACT_NET )
				net.SendToServer()
			end
		end
	end

	if ply.MCInventoryProxySecondaryConsumed and command.RemoveKey then
		command:RemoveKey( IN_ATTACK2 )
	end
end )

if SERVER then
	net.Receive( PROXY_INTERACT_NET, function( _, ply )
		if not activeInventoryProxy( ply ) or not ply:Alive() then return end
		local stack = selectedStackForRealm( ply )
		local kind, target = proxyWorldInteractionCandidate( ply, stack )
		performProxyWorldInteraction( ply, stack, kind, target )
	end )
end

local FOOD_WORLD_USE_WRAPPER_VERSION = 1
local function installFoodWorldUsePreflight()
	if not weapons or not weapons.GetStored then return false end
	local stored = weapons.GetStored( "weapon_mcitem_food_base" )
	if not stored or not isfunction( stored.SecondaryAttack ) then return false end
	if stored.MCMCSWEPWorldUseWrapperVersion == FOOD_WORLD_USE_WRAPPER_VERSION
		and stored.SecondaryAttack == stored.MCMCSWEPWorldUseWrapper then return true end
	local original = stored.SecondaryAttack == stored.MCMCSWEPWorldUseWrapper
		and stored.MCMCSWEPWorldUseOriginalSecondary or stored.SecondaryAttack
	stored.MCMCSWEPWorldUseOriginalSecondary = original
	local wrapper = function( weapon, ... )
		if MC.TryInventoryProxyWorldInteraction
			and MC.TryInventoryProxyWorldInteraction( weapon ) == true then
			local food = MCITEM and MCITEM.Food
			if food and food.CancelUse and weapon.IsMCUsingItem and weapon:IsMCUsingItem() then
				food.CancelUse( weapon, "world_interaction" )
			end
			return
		end
		return original( weapon, ... )
	end
	stored.MCMCSWEPWorldUseWrapper = wrapper
	stored.SecondaryAttack = wrapper
	stored.MCMCSWEPWorldUseWrapperVersion = FOOD_WORLD_USE_WRAPPER_VERSION
	return true
end

local function scheduleFoodWorldUsePreflight()
	if not timer then return end
	timer.Simple( 0, installFoodWorldUsePreflight )
	timer.Create( "mc_inventory_food_world_use_preflight", 0.5, 20, function()
		if installFoodWorldUsePreflight() then timer.Remove( "mc_inventory_food_world_use_preflight" ) end
	end )
end

scheduleFoodWorldUsePreflight()
hook.Add( "OnReloaded", "mc_inventory_food_world_use_preflight", scheduleFoodWorldUsePreflight )

local function consumeSelected( ply )
	local record, stack, definition = selectedRecord( ply )
	if not record or not stack or not definition then return nil end
	if infiniteMaterials( ply ) then return record, nil end
	local snapshot = MC.ContainerSnapshot( record.container )
	local slot = MC.ContainerGetSlot( record.container, record.selected )
	local extracted = slot and MC.InventorySlotTake( slot, 1, { player = ply, reason = "place" } ) or nil
	if not extracted then return nil end
	return record, snapshot
end

local function commitConsumed( record, snapshot, ply )
	if not snapshot then return true end
	local result = MC.SV.CommitPlayerInventoryMutation( record, snapshot, { player = ply, reason = "place" } )
	return result ~= nil
end

local function restoreConsumed( record, snapshot )
	if record and snapshot then MC.ContainerRestore( record.container, snapshot ) end
end

function SWEP:Initialize()
	self:SetHoldType( "normal" )
	self.MCCreativeAttackHeld = false
	self.MCCreativeBreakReadyAt = 0
	self.MCSecondaryHeld = false
	self.MCSecondaryMode = nil
	self.MCSecondaryStartedAt = 0
end

function SWEP:Deploy()
	self:SetHoldType( "normal" )
	self.MCCreativeAttackHeld = false
	self.MCSecondaryHeld = false
	self.MCSecondaryMode = nil
	return true
end

function SWEP:MCReleaseSecondary( reason )
	local ply = self:GetOwner()
	local mode = self.MCSecondaryMode
	self.MCSecondaryHeld = false
	self.MCSecondaryMode = nil
	self.MCSecondaryStartedAt = 0
	if SERVER and mode == "item" and IsValid( ply ) and MC.SV and MC.SV.ReleaseSelectedItemUse then
		return MC.SV.ReleaseSelectedItemUse( ply, { reason = reason or "released" } )
	end
	return false, "not_using"
end

function SWEP:Reload()
	if SERVER then
		local ply = self:GetOwner()
		if IsValid( ply ) and MC.SV and MC.SV.CancelSelectedItemUse then
			MC.SV.CancelSelectedItemUse( ply, "inventory_open" )
		end
		if IsValid( ply ) and MC.SV and MC.SV.CancelMining then MC.SV.CancelMining( ply, "inventory_open" ) end
	end
	self.MCSecondaryHeld = false
	self.MCSecondaryMode = nil
	if SERVER then
		if game.SinglePlayer() then self:CallOnClient( "OpenInventoryClient" ) end
		return
	end
	if MC.InventoryUI and MC.InventoryUI.ToggleFromWeapon then
		MC.InventoryUI.ToggleFromWeapon( self )
	else
		self:OpenInventoryClient()
	end
end

function SWEP:OpenInventoryClient()
	if not CLIENT then return end
	if MC.InventoryUI and MC.InventoryUI.ToggleFromWeapon then
		MC.InventoryUI.ToggleFromWeapon( self )
		return
	end
	if MC.InventoryUI and IsValid( MC.InventoryUI.Screen ) then return end
	if MC.RequestInventoryOpen then MC.RequestInventoryOpen() end
end

function SWEP:PrimaryAttack()
	self:SetNextPrimaryFire( CurTime() + ATTACK_INTERVAL )
	local ply = self:GetOwner()
	if not IsValid( ply ) then return end
	local initialPress = self.MCCreativeAttackHeld ~= true
		or ply.KeyPressed and ply:KeyPressed( IN_ATTACK ) == true
	self.MCCreativeAttackHeld = true
	if SERVER and MC.SV and MC.SV.CancelSelectedItemUse then
		MC.SV.CancelSelectedItemUse( ply, "primary_attack" )
	end
	local aim = aimedBlock( ply )
	local eyeTrace = ply:GetEyeTrace()
	local creative = creativeMode( ply )
	local selectedStack = selectedStackForRealm( ply )
	local canDestroyInCreative = not creative or creativeBlockAttackAllowed( selectedStack )
	if SERVER then
		local target = MC.SV and MC.SV.TraceSelectedItemAttack and select( 1, MC.SV.TraceSelectedItemAttack( ply ) ) or nil
		if target then
			if MC.SV and MC.SV.CancelMining then MC.SV.CancelMining( ply, "combat_target" ) end
			if MC.SV.AttackSelectedItem then MC.SV.AttackSelectedItem( ply, target, { reason = "primary_attack" } ) end
			return
		end
		if aim and MC.EntityOccludesBlockAim and MC.EntityOccludesBlockAim( ply, aim ) then
			if MC.SV and MC.SV.CancelMining then MC.SV.CancelMining( ply, "entity_occluded" ) end
			return
		end
		local bx, by, bz = breakTarget( ply, aim, eyeTrace )
		if not bx then return end
		if not creative then
			if MC.SV and MC.SV.BeginMining then MC.SV.BeginMining( ply, bx, by, bz ) end
			return
		end
		if not canDestroyInCreative then
			if MC.SV and MC.SV.CancelMining then MC.SV.CancelMining( ply, "creative_item_cannot_destroy" ) end
			return
		end
		local now = CurTime()
		if not initialPress and now < ( self.MCCreativeBreakReadyAt or 0 ) then
			self:SetNextPrimaryFire( self.MCCreativeBreakReadyAt )
			return
		end
		local broke, breakResult, nextContinueAt = false, "mining_api_unavailable", nil
		if MC.SV and MC.SV.TryCreativeBreak then
			broke, breakResult, nextContinueAt = MC.SV.TryCreativeBreak(
				ply, bx, by, bz, { initialPress = initialPress }
			)
		end
		if broke then
			self.MCCreativeBreakReadyAt = now + CREATIVE_DESTROY_DELAY
			net.Start( "mc_creative_break_anim" )
				net.WriteInt( bx, MC.Net.COORD_BITS )
				net.WriteInt( by, MC.Net.COORD_BITS )
				net.WriteInt( bz, MC.Net.COORD_BITS )
			net.Send( ply )
		elseif breakResult == "creative_destroy_delay" and tonumber( nextContinueAt ) then
			self.MCCreativeBreakReadyAt = math.max( self.MCCreativeBreakReadyAt or 0, nextContinueAt )
			self:SetNextPrimaryFire( self.MCCreativeBreakReadyAt )
		elseif MC.SV and MC.SV.SyncBreakPlan then
			MC.SV.SyncBreakPlan( ply, bx, by, bz )
		elseif MC.SV and MC.SV.SyncCell then
			MC.SV.SyncCell( ply, bx, by, bz )
		end
	elseif CLIENT and IsFirstTimePredicted() and ply == LocalPlayer() then
		if traceCombatTarget( ply, eyeTrace ) then return end
		if aim and MC.EntityOccludesBlockAim and MC.EntityOccludesBlockAim( ply, aim ) then return end
		local bx, by, bz = breakTarget( ply, aim, eyeTrace )
		if bx and ( not creative or not canDestroyInCreative ) then
			if MC.HandMiningSwing and MC.HandMiningSwing.Begin then
				MC.HandMiningSwing.Begin( self, bx, by, bz )
			end
			return
		end
		local now = CurTime()
		if bx and not initialPress and now < ( self.MCCreativeBreakReadyAt or 0 ) then
			self:SetNextPrimaryFire( self.MCCreativeBreakReadyAt )
			return
		end
		if bx
		and MC.CanPreviewBreak and MC.CanPreviewBreak( ply, bx, by, bz ) and MC.PredictBreakBlock then
			if MC.PredictBreakBlock( bx, by, bz, ply ) then
				self.MCCreativeBreakReadyAt = now + CREATIVE_DESTROY_DELAY
				self:StartCreativePlaceAnimation( bx, by, bz )
			end
		end
	end
end

-- Lighting a block through its OnUse handler (TNT) has to look like lighting
-- the ground does: MC.SV.Use itself is silent, so the swing is requested here.
-- Only igniters swing; operating a chest or a door must not.
function SWEP:SendIgniterSwing( ply, stack, bx, by, bz )
	if not SERVER or not igniterStack( stack ) or bx == nil then return end
	net.Start( "mc_creative_place_anim" )
		net.WriteInt( bx, MC.Net.COORD_BITS )
		net.WriteInt( by, MC.Net.COORD_BITS )
		net.WriteInt( bz, MC.Net.COORD_BITS )
	net.Send( ply )
end

function SWEP:SecondaryAttack()
	local repeatingPlacement = self.MCSecondaryHeld and self.MCSecondaryMode == "place"
	self:SetNextSecondaryFire( CurTime() + ATTACK_INTERVAL )
	local ply = self:GetOwner()
	if not IsValid( ply ) then return end
	if SERVER and MC.SV and MC.SV.CancelMining then MC.SV.CancelMining( ply, "secondary_attack" ) end
	if self.MCSecondaryHeld and not repeatingPlacement then return end
	if not repeatingPlacement then
		self.MCSecondaryHeld = true
		self.MCSecondaryStartedAt = CurTime()
		self.MCSecondaryMode = nil
	end
	local vehicle = MC.TraceMinecraftVehicle and select( 1, MC.TraceMinecraftVehicle( ply, 3, MASK_SOLID ) ) or nil
	if IsValid( vehicle ) then
		self.MCSecondaryMode = "vehicle"
		if SERVER and MC.SV and MC.SV.UseMinecraftVehicle then MC.SV.UseMinecraftVehicle( ply, vehicle ) end
		return
	end
	local aim = aimedBlock( ply )
	local eyeTrace = ply:GetEyeTrace()
	local trace = aim or eyeTrace
	if not trace then self.MCSecondaryHeld = false return end
	if SERVER then
		local record, stack, definition = selectedRecord( ply )
		local entity = traceItemEntityTarget( ply )
		if IsValid( entity ) then
			local entityResult = runItemEntityInteractionHands(
				ply, entity, stack, eyeTrace, false, "hand_secondary" )
			if entityResult ~= nil then
				self.MCSecondaryMode = entityResult == true and "entity" or "entity_rejected"
				return
			end
		end
		local parityOrder = logisticsParityOrderEnabled()
		local suppressBlockUse = parityOrder and logisticsSecondaryUseSuppressesBlock( ply, stack )
		local ux, uy, uz
		if aim then ux, uy, uz = aim.bx, aim.by, aim.bz
		elseif trace.Hit and MC.WorldToCell then ux, uy, uz = MC.WorldToCell( trace.HitPos - trace.HitNormal * 0.5 ) end
		if parityOrder and not suppressBlockUse and aim and MC.SV and MC.SV.Use
		and MC.SV.Use( ply, ux, uy, uz, definition and definition.blockId or 0 ) then
			self.MCSecondaryMode = "block"
			self:SendIgniterSwing( ply, stack, ux, uy, uz )
			return
		end
		if stack and MC.Decoration and MC.Decoration.IsDecorationItem
		and MC.Decoration.IsDecorationItem( stack ) and MC.Decoration.Enabled
		and MC.Decoration.Enabled() then
			local decorationResult = hook.Run( "MC.TryPlaceDecoration", ply,
				copiedInteractionStack( stack ), trace, { source = "hand_secondary" } )
			if decorationResult ~= nil then
				self.MCSecondaryMode = decorationResult == true and "decoration" or "decoration_rejected"
				return
			end
		end
		-- Functional blocks use the press edge, like the legacy creative placer.
		-- Automatic secondary attacks must not toggle a gate/door every tick while
		-- the player keeps the button held down.
		if not parityOrder and not suppressBlockUse and aim and MC.SV and MC.SV.Use
		and MC.SV.Use( ply, ux, uy, uz, definition and definition.blockId or 0 ) then
			self.MCSecondaryMode = "block"
			self:SendIgniterSwing( ply, stack, ux, uy, uz )
			return
		end
		local useCandidate = isUseCandidate( stack, definition )
		-- Written as one `a and b and f() or false, "..."` expression this only
		-- ever bound useResult to the literal: a call's extra return values are
		-- dropped unless the call is last in the list. The result is needed
		-- below to tell an instant use from one that starts a held animation.
		local used, useResult = false, "item_use_unavailable"
		if MC.SV and MC.SV.BeginSelectedItemUse then
			used, useResult = MC.SV.BeginSelectedItemUse( ply, {
				reason = "right_click",
				target = aim and { bx = ux, by = uy, bz = uz } or nil,
			} )
		end
		if used or useCandidate then
			self.MCSecondaryMode = used and "item" or "item_rejected"
			-- Minecraft swings the arm when useOn/use resolves immediately
			-- (fire charge, flint and steel). A held use -- food, bow, spyglass --
			-- runs its own animation and must not also swing.
			if used and aim and useResult ~= "started" and useResult ~= "already_using" then
				net.Start( "mc_creative_place_anim" )
					net.WriteInt( ux, MC.Net.COORD_BITS )
					net.WriteInt( uy, MC.Net.COORD_BITS )
					net.WriteInt( uz, MC.Net.COORD_BITS )
				net.Send( ply )
			end
			return
		end
		if not definition or not definition.blockId or not MC.SV or not MC.SV.PlaceState then
			self:MCReleaseSecondary( "not_placeable" )
			return
		end
		-- Block placement is the automatic right-click mode. Keeping this mode
		-- armed lets weapon_base invoke SecondaryAttack again while the key stays down.
		self.MCSecondaryMode = "place"
		if not trace.Hit then return end
		local bx, by, bz, stateId = placeTarget( ply, aim, trace, definition.blockId )
		if not bx then return end
		if not infiniteMaterials( ply ) and not stack then return end
		local blockEntity
		if MC.IsBannerState and MC.IsBannerState( stateId ) and MC.BannerRecordFromItemStack then
			blockEntity = MC.BannerRecordFromItemStack( stack )
			if not blockEntity then return end
		end
		local consumedRecord, snapshot = consumeSelected( ply )
		if not infiniteMaterials( ply ) and not consumedRecord then return end
		-- isSecondaryUseActive(): sneaking suppresses the automatic double-chest
		-- merge, so a shift-placed chest stays a separate single chest.
		local secondaryUse = ply.KeyDown and ply:KeyDown( IN_SPEED ) == true
		if not MC.SV.PlaceState( ply, bx, by, bz, stateId,
			{ blockEntity = blockEntity, secondaryUse = secondaryUse } ) then
			restoreConsumed( consumedRecord, snapshot )
			if MC.SV.SyncPlacementStatePlan then
				MC.SV.SyncPlacementStatePlan( ply, bx, by, bz, stateId )
			elseif MC.SV.SyncCell then
				MC.SV.SyncCell( ply, bx, by, bz )
			end
			return
		end
		if not commitConsumed( consumedRecord, snapshot, ply ) then restoreConsumed( consumedRecord, snapshot ) end
		net.Start( "mc_creative_place_anim" )
			net.WriteInt( bx, MC.Net.COORD_BITS )
			net.WriteInt( by, MC.Net.COORD_BITS )
			net.WriteInt( bz, MC.Net.COORD_BITS )
		net.Send( ply )
	elseif IsFirstTimePredicted() and ply == LocalPlayer() then
		local state = MC.ClientInventory
		local stack = state and state.slots[( state.selected or 0 ) + 1] or nil
		local entity = traceItemEntityTarget( ply )
		if IsValid( entity ) then
			local entityResult = runItemEntityInteractionHands(
				ply, entity, stack, eyeTrace, true, "hand_preview" )
			if entityResult ~= nil then
				self.MCSecondaryMode = entityResult == true and "entity" or "entity_rejected"
				return
			end
		end
		local parityOrder = logisticsParityOrderEnabled()
		local suppressBlockUse = parityOrder and logisticsSecondaryUseSuppressesBlock( ply, stack )
		if parityOrder and not suppressBlockUse and aim and blockHasUse( aim.Block, stack ) then
			self.MCSecondaryMode = "block"
			return
		end
		if stack and MC.Decoration and MC.Decoration.PreviewPlace then
			local decorationResult = MC.Decoration.PreviewPlace( ply, stack, trace )
			if decorationResult ~= nil then
				self.MCSecondaryMode = decorationResult == true and "decoration" or "decoration_rejected"
				return
			end
		end
		-- Match the server's use-first order. Without this guard the client draws
		-- a predicted placement beside doors, gates, chests, and other usable
		-- blocks while the server correctly performs only their OnUse action.
		if not parityOrder and not suppressBlockUse and aim and blockHasUse( aim.Block, stack ) then
			self.MCSecondaryMode = "block"
			return
		end
		local definition = stack and MC.GetItem( stack.item ) or nil
		if not definition or not definition.blockId then return end
		self.MCSecondaryMode = "place"
		if not trace.Hit then return end
		local bx, by, bz, stateId = placeTarget( ply, aim, trace, definition.blockId )
		-- Same sneak context as the server write, so the predicted plan does not
		-- briefly show a merged double chest that the server then rejects.
		local plan = bx and MC.BuildPlacementStatePlan and MC.BuildPlacementStatePlan(
			bx, by, bz, stateId, { secondaryUse = ply.KeyDown and ply:KeyDown( IN_SPEED ) == true } )
		if plan and MC.CanPreviewPlacePlan and MC.CanPreviewPlacePlan( ply, plan ) and MC.PredictSetBlockState then
			if MC.PredictSetBlockState( bx, by, bz, stateId ) then
				self:StartCreativePlaceAnimation( bx, by, bz )
			end
		end
	end
end

function SWEP:KeyRelease( ply, key )
	if key ~= IN_ATTACK2 then return end
	if ply ~= self:GetOwner() then return end
	self:MCReleaseSecondary( "released" )
end

function SWEP:Think()
	local ply = self:GetOwner()
	if not IsValid( ply ) or not ply:Alive() then
		if SERVER and IsValid( ply ) and MC.SV and MC.SV.CancelSelectedItemUse then
			MC.SV.CancelSelectedItemUse( ply, "owner_invalid" )
		end
		if SERVER and IsValid( ply ) and MC.SV and MC.SV.CancelMining then MC.SV.CancelMining( ply, "owner_invalid" ) end
		self.MCCreativeAttackHeld = false
		self.MCSecondaryHeld = false
		self.MCSecondaryMode = nil
		return
	end

	local active = ply:GetActiveWeapon()
	if active ~= self then
		if SERVER and MC.SV and MC.SV.CancelSelectedItemUse then
			MC.SV.CancelSelectedItemUse( ply, "weapon_switched" )
		end
		if SERVER and MC.SV and MC.SV.CancelMining then MC.SV.CancelMining( ply, "weapon_switched" ) end
		self.MCCreativeAttackHeld = false
		self.MCSecondaryHeld = false
		self.MCSecondaryMode = nil
		return
	end
	if self.MCCreativeAttackHeld and not ply:KeyDown( IN_ATTACK ) then
		self.MCCreativeAttackHeld = false
	end
	if self.MCSecondaryHeld and not ply:KeyDown( IN_ATTACK2 )
		and CurTime() - ( self.MCSecondaryStartedAt or 0 ) >= 0.02 then
		self:MCReleaseSecondary( "released" )
	end
	if SERVER then
		if self.MCSecondaryHeld and self.MCSecondaryMode == "item"
			and ply:KeyDown( IN_ATTACK2 ) and MC.SV and MC.SV.TickSelectedItemUse then
			MC.SV.TickSelectedItemUse( ply, { reason = "right_click_tick" } )
		end
	end

	self:NextThink( CurTime() + USE_TICK_INTERVAL )
	return true
end

function SWEP:Holster()
	if SERVER then
		local ply = self:GetOwner()
		if IsValid( ply ) and MC.SV and MC.SV.CancelSelectedItemUse then
			MC.SV.CancelSelectedItemUse( ply, "holster" )
		end
		if IsValid( ply ) and MC.SV and MC.SV.CancelMining then MC.SV.CancelMining( ply, "holster" ) end
	end
	self.MCCreativeAttackHeld = false
	self.MCSecondaryHeld = false
	self.MCSecondaryMode = nil
	return true
end

function SWEP:OnRemove()
	if SERVER then
		local ply = self:GetOwner()
		if IsValid( ply ) and MC.SV and MC.SV.CancelSelectedItemUse then
			MC.SV.CancelSelectedItemUse( ply, "weapon_removed" )
		end
		if IsValid( ply ) and MC.SV and MC.SV.CancelMining then MC.SV.CancelMining( ply, "weapon_removed" ) end
	end
	self.MCCreativeAttackHeld = false
	self.MCSecondaryHeld = false
	self.MCSecondaryMode = nil
end

if CLIENT then
	local ITEM_PLACE_ANIM_DURATION = 0.30
	local ITEM_HAND_HEIGHT_RECOVERY = 8
	local HELD_ITEM_LIGHT_GAIN = 0.48
	-- ItemInHandRenderer.applyItemArmTransform from Java 26.2. The dimensionless
	-- parent translation is (side * 0.56, -0.52, -0.72); size only converts the
	-- vanilla camera-space pose into Source world units. Minecraft's hand HUD uses
	-- a fixed 70-degree vertical FOV, converted to GMod's horizontal Start3D FOV
	-- only while an item model is drawn.
	local MC_WEAPONS_FP = {
		armX = 0.56, armY = -0.52, armZ = -0.72,
		size = 36.5 * 0.5, fov = 70,
	}

	local function itemHeldAnimationEnabled()
		local cvar = GetConVar and GetConVar( "mc_creative_held_anim" ) or nil
		return not cvar or cvar:GetBool()
	end

	local function placeAnimKey( bx, by, bz )
		if bx == nil then return nil end
		return MC.CellKey( bx, by, bz )
	end

	-- Kept on the hand SWEP so the legacy creative pose can drive exactly the
	-- same swing and equip-height animation for inventory-selected blocks.
	function SWEP:StartCreativePlaceAnimation( bx, by, bz )
		if not itemHeldAnimationEnabled() then return end
		local now = CurTime()
		local key = placeAnimKey( bx, by, bz )
		if key and self.MCCreativePlaceAnimKey == key
		and now - ( self.MCCreativePlaceAnimStart or 0 ) < 0.75 then return end
		self.MCCreativePlaceAnimKey = key
		self.MCCreativePlaceAnimStart = now
		self.MCCreativeOldMainHandHeight = 0
		self.MCCreativeMainHandHeight = 0
		self.MCCreativeHandHeightLast = now
	end

	function SWEP:CreativePlaceAnim()
		if not itemHeldAnimationEnabled() then return 0 end
		local mining = MC.HandMiningSwing and MC.HandMiningSwing.Progress
			and MC.HandMiningSwing.Progress( self ) or 0
		if mining > 0 then return mining end
		local start = self.MCCreativePlaceAnimStart
		if not start then return 0 end
		local progress = ( CurTime() - start ) / ITEM_PLACE_ANIM_DURATION
		if progress <= 0 or progress >= 1 then return 0 end
		return progress
	end

	function SWEP:UpdateCreativeMainHandHeight()
		local now = CurTime()
		if self.MCCreativeMainHandHeight == nil then
			self.MCCreativeOldMainHandHeight = 1
			self.MCCreativeMainHandHeight = 1
			self.MCCreativeHandHeightLast = now
			return
		end
		local last = self.MCCreativeHandHeightLast or now
		local dt = math.Clamp( now - last, 0, 0.25 )
		if dt <= 0 then return end
		self.MCCreativeOldMainHandHeight = self.MCCreativeMainHandHeight
		local step = math.min( ITEM_HAND_HEIGHT_RECOVERY * dt, ITEM_HAND_HEIGHT_RECOVERY / 20 )
		self.MCCreativeMainHandHeight = math.Clamp( self.MCCreativeMainHandHeight + step, 0, 1 )
		self.MCCreativeHandHeightLast = now
	end

	function SWEP:CreativeMainHandInverseHeight()
		if not itemHeldAnimationEnabled() then return 0 end
		self:UpdateCreativeMainHandHeight()
		return 1 - math.Clamp( self.MCCreativeMainHandHeight or 1, 0, 1 )
	end

	local function selectedStack( ply )
		if ply == LocalPlayer() and MC.ClientInventory then
			return MC.ClientInventory.slots[( MC.ClientInventory.selected or 0 ) + 1]
		end
		local runtime = IsValid( ply ) and ply:GetNWInt( "mc_selected_item_runtime", 0 ) or 0
		local definition = MC.GetItem( runtime )
		-- Remote inventory proxies must preserve an authoritative false.  Omitting
		-- the component would let vanilla-default foil items become shiny again.
		local components = {
			["minecraft:enchantment_glint_override"] = IsValid( ply )
				and ply:GetNWBool( "mc_selected_item_foil", false ) or false,
		}
		return definition and MC.NewItemStack( definition.name,
			math.max( 1, ply:GetNWInt( "mc_selected_item_count", 1 ) ), components,
			math.max( 0, ply:GetNWInt( "mc_selected_item_damage", 0 ) ) ) or nil
	end

	local function equipmentStack( ply, slot )
		if ply == LocalPlayer() and MC.ClientInventory then
			return MC.CopyItemStack( MC.ClientInventory.equipment and MC.ClientInventory.equipment[slot] )
		end
		local prefix = "mc_equipment_" .. slot .. "_"
		local runtime = IsValid( ply ) and ply:GetNWInt( prefix .. "runtime", 0 ) or 0
		local definition = MC.GetItem( runtime )
		if not definition then return nil end
		local components = {
			["minecraft:enchantment_glint_override"] = ply:GetNWBool( prefix .. "foil", false ),
		}
		return MC.NewItemStack( definition.name, math.max( 1, ply:GetNWInt( prefix .. "count", 1 ) ), components,
			math.max( 0, ply:GetNWInt( prefix .. "damage", 0 ) ) )
	end

	local function selectedState( ply, stack )
		local definition = stack and MC.GetItem( stack.item ) or nil
		local Blocks = MC.API and MC.API.Blocks or nil
		if not definition or not definition.blockId or not Blocks or not Blocks.DefaultState then return nil end
		return Blocks.DefaultState( definition.blockId )
	end

	-- Minecraft applies the attack/equip animation to the hand that actually
	-- performed the interaction.  The offhand still renders its item, but it
	-- must not borrow the active weapon's main-hand animation state.
	local function animationWeaponFor( ply, leftHand )
		if leftHand or not IsValid( ply ) then return nil end
		local weapon = ply:GetActiveWeapon()
		if not IsValid( weapon ) then return nil end
		-- The engine presentation bridge calls both callbacks as part of its
		-- vanilla first-person hand pose.  They are optional capabilities, not
		-- part of the SWEP base contract: MCITEM resolver weapons (for example
		-- weapon_mcitem_cod) deliberately do not implement them.  Returning nil
		-- here makes the bridge take its neutral IsValid(nil) path; checking only
		-- the class would make every newly registered proxy a new hard-coded case.
		if type( weapon.CreativePlaceAnim ) ~= "function"
		or type( weapon.CreativeMainHandInverseHeight ) ~= "function" then
			return nil
		end
		return weapon
	end

	-- Inventory-proxy SWEPs are allowed to drive held-item presentation, but
	-- CreativePlaceAnim/CreativeMainHandInverseHeight are optional helpers owned
	-- by mc_item_hand and mc_creative_placer.  Unknown weapons keep rendering
	-- with the neutral vanilla pose instead of receiving an unconditional call.
	local function optionalWeaponAnimation( weapon, methodName )
		if not IsValid( weapon ) then return 0 end
		local callback = weapon[methodName]
		if type( callback ) ~= "function" then return 0 end
		return tonumber( callback( weapon ) ) or 0
	end

	local function heldPose( ply, firstPerson, hand )
		local leftHand = hand == "offhand"
		local HandWeapon = MC.API and MC.API.HandWeapon or nil
		if firstPerson and HandWeapon and HandWeapon.GetBlockFirstPersonPose then
			local pos, ang, scale = HandWeapon.GetBlockFirstPersonPose(
				animationWeaponFor( ply, leftHand ), leftHand )
			if pos then return pos, ang, scale end
		end
		if not firstPerson and HandWeapon and HandWeapon.GetBlockThirdPersonPose then
			local pos, ang, scale = HandWeapon.GetBlockThirdPersonPose( ply, leftHand )
			if pos then return pos, ang, scale end
		end
		if firstPerson then
			local eyeAng = ply:EyeAngles()
			local side = leftHand and -1 or 1
			return EyePos() + eyeAng:Forward() * 11.5 + eyeAng:Right() * ( 12 * side ) - eyeAng:Up() * 8.3,
				eyeAng, 6.4
		end
		local bone = ply:LookupBone( leftHand and "ValveBiped.Bip01_L_Hand" or "ValveBiped.Bip01_R_Hand" )
		local pos, ang
		if bone then pos, ang = ply:GetBonePosition( bone ) end
		if not pos or not ang then pos, ang = ply:GetShootPos() + ply:EyeAngles():Forward() * 10, ply:EyeAngles() end
		local side = leftHand and -1 or 1
		pos = pos + ang:Forward() * 2 + ang:Right() * ( 2 * side ) + ang:Up()
		return pos, ang, 0.45
	end

	local ITEM_TP_SCALE = 7.5
	-- Minecraft's thirdperson_righthand display scale for block models, which is
	-- what the block-shaped entity models (chest) carry in their display table.
	local BLOCK_DISPLAY_TP_SCALE = 0.375

	local function heldItemPose( ply, firstPerson, hand, blockShaped )
		local leftHand = hand == "offhand"
		if firstPerson then
			local eyeAng = ply:EyeAngles()
			local side = leftHand and -1 or 1
			local weapon = animationWeaponFor( ply, leftHand )
			local swing = optionalWeaponAnimation( weapon, "CreativePlaceAnim" )
			local equip = optionalWeaponAnimation( weapon, "CreativeMainHandInverseHeight" )
			local swingRoot = math.sqrt( math.max( swing, 0 ) )
			local swingSin = math.sin( swingRoot * math.pi )
			local swingSin2 = math.sin( swingRoot * math.pi * 2 )
			local swingSinFull = math.sin( swing * math.pi )

			local pos = EyePos()
				+ eyeAng:Forward() * ( -MC_WEAPONS_FP.armZ * MC_WEAPONS_FP.size )
				+ eyeAng:Right() * ( side * MC_WEAPONS_FP.armX * MC_WEAPONS_FP.size )
				+ eyeAng:Up() * ( MC_WEAPONS_FP.armY * MC_WEAPONS_FP.size )
			pos = pos
				+ eyeAng:Right() * ( side * -0.4 * swingSin * MC_WEAPONS_FP.size )
				+ eyeAng:Up() * ( ( -0.6 * equip + 0.2 * swingSin2 ) * MC_WEAPONS_FP.size )
				+ eyeAng:Forward() * ( 0.2 * swingSinFull * MC_WEAPONS_FP.size )
			local ang = Angle( eyeAng.p, eyeAng.y, eyeAng.r )
			ang:RotateAroundAxis( ang:Up(), side * ( 45 - 20 * math.sin( swing * swing * math.pi ) ) )
			ang:RotateAroundAxis( ang:Forward(), side * swingSin * 20 )
			ang:RotateAroundAxis( ang:Right(), swingSin * -80 )
			ang:RotateAroundAxis( ang:Up(), side * -45 )
			return pos, ang, MC_WEAPONS_FP.size
		end
		local HandWeapon = MC.API and MC.API.HandWeapon or nil
		-- The two renderers use DIFFERENT scale conventions, so their numbers are
		-- not directly comparable. The block path applies its scale straight to
		-- the mesh. The item path treats the scale as a base size and multiplies
		-- it by the model's Minecraft display transform, so the drawn size is
		-- baseSize * display.scale (chest thirdperson_righthand = 0.375).
		--
		-- A block-shaped special model must therefore be handed the base size
		-- that CANCELS its display scale and lands on the block scale:
		--     baseSize * 0.375 == blockScale   ->   baseSize = blockScale / 0.375
		-- Passing the block scale directly made a held chest roughly a third of
		-- a normal held block. Flat items keep their own base size: their larger
		-- display scale is vanilla behaviour, not a bug.
		local scale = ITEM_TP_SCALE
		if blockShaped and HandWeapon and HandWeapon.GetBlockThirdPersonPose then
			local _, _, blockScale = HandWeapon.GetBlockThirdPersonPose( ply, leftHand )
			blockScale = tonumber( blockScale )
			if blockScale then scale = blockScale / BLOCK_DISPLAY_TP_SCALE end
		end
		if not firstPerson and HandWeapon and HandWeapon.GetItemThirdPersonAnchor then
			local pos, ang = HandWeapon.GetItemThirdPersonAnchor( ply, leftHand )
			if pos then return pos, ang, scale end
		end
		local bone = ply:LookupBone( leftHand and "ValveBiped.Bip01_L_Hand" or "ValveBiped.Bip01_R_Hand" )
		local pos, ang
		if bone then pos, ang = ply:GetBonePosition( bone ) end
		if not pos or not ang then pos, ang = ply:GetShootPos(), ply:EyeAngles() end
		local side = leftHand and -1 or 1
		return pos + ang:Forward() * 2.5 + ang:Right() * ( 2.2 * side ) - ang:Up() * 1.8, ang, scale
	end

	local function setFirstPersonItemDepthState( enabled )
		enabled = enabled == true
		if enabled then
			-- GameRenderer clears the main target's depth texture immediately before
			-- renderItemInHand. Clearing Source's shared depth buffer here would break
			-- later GMod hooks, so use the documented local equivalent instead: map
			-- the hand pass to the near depth range while keeping depth writes disabled.
			if render and render.OverrideDepthEnable then
				render.OverrideDepthEnable( true, false )
			end
			if cam and cam.IgnoreZ then
				cam.IgnoreZ( true )
			elseif render and render.DepthRange then
				render.DepthRange( 0, 0.01 )
			end
			return
		end
		if cam and cam.IgnoreZ then
			cam.IgnoreZ( false )
		elseif render and render.DepthRange then
			render.DepthRange( 0, 1 )
		end
		if render and render.OverrideDepthEnable then
			render.OverrideDepthEnable( false, false )
		end
	end

	local function drawFirstPersonItemPass( renderer, stack, pos, ang, scale, color, modelOptions )
		setFirstPersonItemDepthState( true )
		local ok, drawn = pcall( renderer.DrawHeldItem,
			stack, pos, ang, scale, color, modelOptions )
		setFirstPersonItemDepthState( false )
		return ok, drawn
	end

	local function drawFirstPersonItemModel( ply, renderer, stack, pos, ang, scale, color, modelOptions )
		if not cam or not cam.Start3D or not cam.End3D then
			local ok, drawn = drawFirstPersonItemPass(
				renderer, stack, pos, ang, scale, color, modelOptions )
			if not ok then error( drawn, 0 ) end
			return drawn
		end
		local width, height = ScrW(), math.max( ScrH(), 1 )
		-- cam.Start3D accepts horizontal FOV. Projection.setupPerspective in Java
		-- accepts vertical FOV, so convert the fixed 70-degree hand projection by
		-- the live viewport aspect instead of deriving it from the player's world
		-- FOV. This keeps the item pose stable at every GMod FOV setting.
		local horizontalFov = math.deg( 2 * math.atan(
			math.tan( math.rad( MC_WEAPONS_FP.fov ) * 0.5 ) * width / height ) )
		cam.Start3D( EyePos(), ply:EyeAngles(), horizontalFov,
			0, 0, width, height, 0.05, 100 )
		local ok, drawn = drawFirstPersonItemPass(
			renderer, stack, pos, ang, scale, color, modelOptions )
		cam.End3D()
		if not ok then error( drawn, 0 ) end
		return drawn
	end

	local function heldItemLightingColor( ply, pos, firstPerson, hand )
		local owner = firstPerson and ply:GetActiveWeapon() or ply
		local lightField = hand == "offhand" and "MCItemHandOffhandLight" or "MCItemHandMainhandLight"
		local colorField = hand == "offhand" and "MCItemHandOffhandColor" or "MCItemHandMainhandColor"
		local lighting
		local HandWeapon = MC.API and MC.API.HandWeapon or nil
		if HandWeapon and HandWeapon.SamplePresentationLighting and IsValid( owner ) then
			local sampled = HandWeapon.SamplePresentationLighting(
				firstPerson and EyePos() or pos, owner[lightField] )
			if type( sampled ) == "table" then owner[lightField] = sampled end
			lighting = owner[lightField]
		end

		local r, g, b = 1, 1, 1
		if type( lighting ) == "table" then
			r = math.Clamp( tonumber( lighting.r ) or 1, 0, 1 )
			g = math.Clamp( tonumber( lighting.g ) or r, 0, 1 )
			b = math.Clamp( tonumber( lighting.b ) or r, 0, 1 )
		end
		local Light = MC.API and MC.API.Light
		if Light and Light.ScaleRGB then
			r, g, b = Light.ScaleRGB( r, g, b, HELD_ITEM_LIGHT_GAIN )
		else
			r = math.Clamp( r * HELD_ITEM_LIGHT_GAIN, 0, HELD_ITEM_LIGHT_GAIN )
			g = math.Clamp( g * HELD_ITEM_LIGHT_GAIN, 0, HELD_ITEM_LIGHT_GAIN )
			b = math.Clamp( b * HELD_ITEM_LIGHT_GAIN, 0, HELD_ITEM_LIGHT_GAIN )
		end

		local color = IsValid( owner ) and owner[colorField] or nil
		if not color then
			color = Color( 255, 255, 255, 255 )
			if IsValid( owner ) then owner[colorField] = color end
		end
		color.r = math.floor( math.min( r, HELD_ITEM_LIGHT_GAIN ) * 255 + 0.5 )
		color.g = math.floor( math.min( g, HELD_ITEM_LIGHT_GAIN ) * 255 + 0.5 )
		color.b = math.floor( math.min( b, HELD_ITEM_LIGHT_GAIN ) * 255 + 0.5 )
		color.a = 255
		return color
	end

	local function drawHeldStack( ply, stack, firstPerson, hand, useState )
		if MC.IsEmptyItemStack( stack ) then return end
		local definition = MC.GetItem( stack.item )
		if not definition then return end
		local renderer = MC.InventoryUI and MC.InventoryUI.ItemRenderer or nil
		local displayContext = firstPerson
			and ( hand == "offhand" and "firstperson_lefthand" or "firstperson_righthand" )
			or ( hand == "offhand" and "thirdperson_lefthand" or "thirdperson_righthand" )
		local using = useState.using and useState.hand == hand
		local useProgress = using and useState.progress or 0
		local useStart = using and useState.startedAt or 0
		local useDuration = using and useState.duration or 0
		if using and useDuration > 0 and MC.ItemUseProgress then
			useProgress = MC.ItemUseProgress( useStart, useDuration, CurTime() )
		end
		local modelOptions = {
			displayContext = displayContext,
			using = using,
			useProgress = math.Clamp( tonumber( useProgress ) or 0, 0, 1 ),
			useDuration = useDuration,
			crossbowPull = useProgress,
			chargeType = MC.ItemCrossbowChargeType and MC.ItemCrossbowChargeType( stack ) or "none",
			mcWeaponsView = firstPerson and MC_WEAPONS_FP or nil,
		}
		local plan = renderer and renderer.ModelPlan and renderer.ModelPlan( stack, modelOptions ) or nil
		local preferItemModel = plan and plan.kind ~= "block" and plan.kind ~= "missing"

		local function tryDrawItemModel()
			if not renderer or not renderer.DrawHeldItem then return false end
			local pos, ang, scale = heldItemPose( ply, firstPerson, hand, plan.kind == "special" )
			local color = heldItemLightingColor( ply, pos, firstPerson, hand )
			local drawn
			if firstPerson then
				drawn = drawFirstPersonItemModel(
					ply, renderer, stack, pos, ang, scale, color, modelOptions )
			else
				drawn = renderer.DrawHeldItem( stack, pos, ang, scale, color, modelOptions )
			end
			return drawn == true
		end

		-- Vanilla chooses the item-model definition before consulting the block
		-- carried by a BlockItem. Barrier is a flat generated item and chests are
		-- special entity models; only ordinary block-model plans belong on the
		-- creative held-block renderer.
		if preferItemModel and tryDrawItemModel() then return end

		local pos, ang, scale = heldPose( ply, firstPerson, hand )
		local stateId = selectedState( ply, stack )
		local HandWeapon = MC.API and MC.API.HandWeapon or nil
		if definition.blockId and stateId and HandWeapon and HandWeapon.DrawBlockState then
			local brightness = 0.8
			if HandWeapon.SamplePresentationLighting then
				local owner = firstPerson and ply:GetActiveWeapon() or ply
				local field = hand == "offhand" and "MCItemHandOffhandLight" or "MCItemHandMainhandLight"
				if IsValid( owner ) then
					local sampled = HandWeapon.SamplePresentationLighting(
						firstPerson and EyePos() or pos, owner[field] )
					if type( sampled ) == "table" then owner[field] = sampled end
					brightness = owner[field] or brightness
				end
			end
			render.OverrideDepthEnable( firstPerson, false )
			HandWeapon.DrawBlockState( stateId, pos, ang, scale, brightness )
			render.OverrideDepthEnable( false, false )
		elseif not preferItemModel then
			tryDrawItemModel()
		end
	end

	local function drawHeld( ply, firstPerson )
		if not IsValid( ply ) or not ply:Alive() then return end
		local weapon = ply:GetActiveWeapon()
		if not IsValid( weapon ) then return end
		-- MCITEM and other registered resolvers may promote the selected stack to
		-- an inventory-proxy SWEP. The public bridge owns that lifecycle decision;
		-- checking only the base mc_item_hand class makes every proxy-held item
		-- disappear even though it resolves to the same selected inventory stack.
		if weapon:GetClass() ~= "mc_item_hand" then
			if not MC.IsInventoryHeldItemWeaponActive
			or not MC.IsInventoryHeldItemWeaponActive( ply ) then return end
		end
		local using = ply:GetNWBool( "mc_item_using", false )
		local useHand = ply:GetNWString( "mc_item_using_hand", "" )
		if useHand ~= "offhand" then useHand = "mainhand" end
		local useState = {
			using = using,
			hand = useHand,
			progress = ply:GetNWFloat( "mc_item_using_progress", 0 ),
			startedAt = ply:GetNWFloat( "mc_item_using_start", 0 ),
			duration = ply:GetNWFloat( "mc_item_using_duration", 0 ),
		}
		local HandWeapon = MC.API and MC.API.HandWeapon or nil
		local ownsFirstPerson = firstPerson and HandWeapon
			and HandWeapon.OwnsFirstPersonPresentation
			and HandWeapon.OwnsFirstPersonPresentation( weapon ) == true
		if not ownsFirstPerson then
			drawHeldStack( ply, selectedStack( ply ), firstPerson, "mainhand", useState )
		end
		drawHeldStack( ply, equipmentStack( ply, "offhand" ), firstPerson, "offhand", useState )
	end

	hook.Add( "PostDrawTranslucentRenderables", "mc_item_hand_first_person", function( _, sky3d )
		if sky3d then return end
		local ply = LocalPlayer()
		if not IsValid( ply ) or ply:ShouldDrawLocalPlayer() then return end
		drawHeld( ply, true )
	end )

	hook.Add( "PostDrawTranslucentRenderables", "mc_item_hand_block_outline", function( _, _, sky3d )
		if sky3d then return end
		local ply = LocalPlayer()
		if not IsValid( ply ) or not ply:Alive() then return end
		local weapon = ply:GetActiveWeapon()
		if not IsValid( weapon ) then return end
		if MC.IsInventoryHeldItemWeaponActive then
			if not MC.IsInventoryHeldItemWeaponActive( ply ) then return end
		elseif weapon:GetClass() ~= "mc_item_hand" then return end

		local aim = aimedBlock( ply )
		if not aim or not MC.DrawBlockOutline then return end
		MC.DrawBlockOutline( aim.Block, aim.Orient, aim.bx, aim.by, aim.bz,
			Color( 0, 0, 0, 235 ), aim.StateId )
	end )

	hook.Remove( "PostPlayerDraw", "mc_item_hand_third_person" )

	function SWEP:PreDrawViewModel()
		return true
	end

	function SWEP:DrawWorldModel()
		local owner = self:GetOwner()
		if IsValid( owner ) then drawHeld( owner, false ) end
	end

	function SWEP:DrawWorldModelTranslucent() end
end
