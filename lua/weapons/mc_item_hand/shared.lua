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
local COMBAT_INFRASTRUCTURE = {
	mc_block_cluster = true, mc_chunk = true, mc_chunk_phys = true,
	mc_collision_carrier = true, mc_item_drop = true, mc_projectile = true,
}

local function aimedBlock( ply )
	return MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
end

local function traceCombatTarget( ply, trace )
	local target = trace and trace.Entity or nil
	if not IsValid( target ) or target == ply or target.IsWorld and target:IsWorld() then return nil end
	if COMBAT_INFRASTRUCTURE[target.GetClass and target:GetClass() or ""] then return nil end
	local attackable = target.IsPlayer and target:IsPlayer()
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

local function breakTarget( ply, aim, trace )
	if aim then return aim.bx, aim.by, aim.bz end
	if not trace or not trace.Hit or not MC.WorldToCell then return nil end
	return MC.WorldToCell( trace.HitPos - trace.HitNormal * 0.5 )
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

local function isUseCandidate( stack, definition )
	if not stack or not definition then return false end
	if MC.ItemBehavior and MC.ItemBehavior( stack ) then return true end
	if MC.ItemIsConsumable and MC.ItemIsConsumable( stack ) then return true end
	return isfunction and isfunction( definition.useHandler ) and definition.useHandler ~= nil
end

local function blockHasUse( id )
	local block = MC.Blocks and MC.Blocks[id]
	return block and block.handlers and block.handlers.OnUse ~= nil
end

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
	self.MCSecondaryHeld = false
	self.MCSecondaryMode = nil
	self.MCSecondaryStartedAt = 0
end

function SWEP:Deploy()
	self:SetHoldType( "normal" )
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
	if SERVER and MC.SV and MC.SV.CancelSelectedItemUse then
		MC.SV.CancelSelectedItemUse( ply, "primary_attack" )
	end
	local aim = aimedBlock( ply )
	local eyeTrace = ply:GetEyeTrace()
	if SERVER then
		local target = MC.SV and MC.SV.TraceSelectedItemAttack and select( 1, MC.SV.TraceSelectedItemAttack( ply ) ) or nil
		if target then
			if MC.SV and MC.SV.CancelMining then MC.SV.CancelMining( ply, "combat_target" ) end
			if MC.SV.AttackSelectedItem then MC.SV.AttackSelectedItem( ply, target, { reason = "primary_attack" } ) end
			return
		end
		local bx, by, bz = breakTarget( ply, aim, eyeTrace )
		if not bx then return end
		if not creativeMode( ply ) then
			if MC.SV and MC.SV.BeginMining then MC.SV.BeginMining( ply, bx, by, bz ) end
			return
		end
		if MC.SV and MC.SV.CancelMining then MC.SV.CancelMining( ply, "creative_break" ) end
		if MC.SV and MC.SV.Break and MC.SV.Break( ply, bx, by, bz ) then
			net.Start( "mc_creative_break_anim" )
				net.WriteInt( bx, MC.Net.COORD_BITS )
				net.WriteInt( by, MC.Net.COORD_BITS )
				net.WriteInt( bz, MC.Net.COORD_BITS )
			net.Send( ply )
		elseif MC.SV and MC.SV.SyncBreakPlan then
			MC.SV.SyncBreakPlan( ply, bx, by, bz )
		elseif MC.SV and MC.SV.SyncCell then
			MC.SV.SyncCell( ply, bx, by, bz )
		end
	elseif CLIENT and IsFirstTimePredicted() and ply == LocalPlayer() then
		if traceCombatTarget( ply, eyeTrace ) then return end
		local bx, by, bz = breakTarget( ply, aim, eyeTrace )
		if bx and not creativeMode( ply ) then
			if MC.HandMiningSwing and MC.HandMiningSwing.Begin then
				MC.HandMiningSwing.Begin( self, bx, by, bz )
			end
			return
		end
		if bx and MC.CanPreviewBreak and MC.CanPreviewBreak( ply, bx, by, bz ) and MC.PredictBreakBlock then
			if MC.PredictBreakBlock( bx, by, bz, ply ) then
				self:StartCreativePlaceAnimation( bx, by, bz )
			end
		end
	end
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
	local aim = aimedBlock( ply )
	local trace = aim or ply:GetEyeTrace()
	if not trace then self.MCSecondaryHeld = false return end
	if SERVER then
		local ux, uy, uz
		if aim then ux, uy, uz = aim.bx, aim.by, aim.bz
		elseif trace.Hit and MC.WorldToCell then ux, uy, uz = MC.WorldToCell( trace.HitPos - trace.HitNormal * 0.5 ) end
		local record, stack, definition = selectedRecord( ply )
		-- Functional blocks use the press edge, like the legacy creative placer.
		-- Automatic secondary attacks must not toggle a gate/door every tick while
		-- the player keeps the button held down.
		if aim and blockHasUse( aim.Block ) and not ply:KeyPressed( IN_ATTACK2 ) then
			self.MCSecondaryMode = "block"
			return
		end
		if aim and MC.SV and MC.SV.Use and MC.SV.Use( ply, ux, uy, uz, definition and definition.blockId or 0 ) then
			self.MCSecondaryMode = "block"
			return
		end
		local useCandidate = isUseCandidate( stack, definition )
		local used, useResult = MC.SV and MC.SV.BeginSelectedItemUse and MC.SV.BeginSelectedItemUse( ply, {
			reason = "right_click",
			target = aim and { bx = ux, by = uy, bz = uz } or nil,
		} ) or false, "item_use_unavailable"
		if used or useCandidate then
			self.MCSecondaryMode = used and "item" or "item_rejected"
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
		if not MC.SV.PlaceState( ply, bx, by, bz, stateId, { blockEntity = blockEntity } ) then
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
		-- Match the server's use-first order. Without this guard the client draws
		-- a predicted placement beside doors, gates, chests, and other usable
		-- blocks while the server correctly performs only their OnUse action.
		if aim and blockHasUse( aim.Block ) then
			self.MCSecondaryMode = "block"
			return
		end
		local state = MC.ClientInventory
		local stack = state and state.slots[( state.selected or 0 ) + 1] or nil
		local definition = stack and MC.GetItem( stack.item ) or nil
		if not definition or not definition.blockId then return end
		self.MCSecondaryMode = "place"
		if not trace.Hit then return end
		local bx, by, bz, stateId = placeTarget( ply, aim, trace, definition.blockId )
		local plan = bx and MC.BuildPlacementStatePlan and MC.BuildPlacementStatePlan( bx, by, bz, stateId )
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
		self.MCSecondaryHeld = false
		self.MCSecondaryMode = nil
		return
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
	self.MCSecondaryHeld = false
	self.MCSecondaryMode = nil
end

if CLIENT then
	local ITEM_PLACE_ANIM_DURATION = 0.30
	local ITEM_HAND_HEIGHT_RECOVERY = 8
	local HELD_ITEM_LIGHT_GAIN = 0.48
	-- Calibrated Source-space view from MC_weapons' item view renderer.
	local MC_WEAPONS_FP = {
		forward = 19.5, right = 10.3, up = -7,
		pitch = -3, yaw = 110, roll = 20,
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
		if not definition or not definition.blockId or not MC.DefaultBlockState then return nil end
		return MC.DefaultBlockState( definition.blockId )
	end

	-- Minecraft applies the attack/equip animation to the hand that actually
	-- performed the interaction.  The offhand still renders its item, but it
	-- must not borrow the active weapon's main-hand animation state.
	local function animationWeaponFor( ply, leftHand )
		if leftHand then return nil end
		return ply:GetActiveWeapon()
	end

	local function heldPose( ply, firstPerson, hand )
		local leftHand = hand == "offhand"
		if firstPerson and MC.CreativeHeldFirstPersonPose then
			return MC.CreativeHeldFirstPersonPose( animationWeaponFor( ply, leftHand ), leftHand )
		end
		if not firstPerson and MC.CreativeHeldThirdPersonPose then
			return MC.CreativeHeldThirdPersonPose( ply, leftHand )
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

	local function heldItemPose( ply, firstPerson, hand )
		local leftHand = hand == "offhand"
		if firstPerson then
			local eyeAng = ply:EyeAngles()
			local side = leftHand and -1 or 1
			local weapon = animationWeaponFor( ply, leftHand )
			local swing = IsValid( weapon ) and weapon:CreativePlaceAnim() or 0
			local equip = IsValid( weapon ) and weapon:CreativeMainHandInverseHeight() or 0
			local swingRoot = math.sqrt( math.max( swing, 0 ) )
			local swingSin = math.sin( swingRoot * math.pi )
			local swingSin2 = math.sin( swingRoot * math.pi * 2 )
			local swingSinFull = math.sin( swing * math.pi )

			local pos = EyePos()
				+ eyeAng:Forward() * MC_WEAPONS_FP.forward
				+ eyeAng:Right() * ( side * MC_WEAPONS_FP.right )
				+ eyeAng:Up() * MC_WEAPONS_FP.up
			pos = pos
				+ eyeAng:Right() * ( side * -0.4 * swingSin * MC_WEAPONS_FP.size )
				+ eyeAng:Up() * ( ( -0.6 * equip + 0.2 * swingSin2 ) * MC_WEAPONS_FP.size )
				+ eyeAng:Forward() * ( 0.2 * swingSinFull * MC_WEAPONS_FP.size )
			local worldFov = math.Clamp( tonumber( ply:GetFOV() ) or 90, 20, 120 )
			local fovScale = math.tan( math.rad( worldFov ) * 0.5 )
				/ math.tan( math.rad( MC_WEAPONS_FP.fov ) * 0.5 )
			local eyePos = EyePos()
			local offset = pos - eyePos
			local depth = offset:Dot( eyeAng:Forward() )
			pos = eyePos
				+ eyeAng:Forward() * depth
				+ eyeAng:Right() * ( offset:Dot( eyeAng:Right() ) * fovScale )
				+ eyeAng:Up() * ( offset:Dot( eyeAng:Up() ) * fovScale )

			local ang = Angle( eyeAng.p, eyeAng.y, eyeAng.r )
			ang:RotateAroundAxis( ang:Up(), side * ( 45 - 20 * math.sin( swing * swing * math.pi ) ) )
			ang:RotateAroundAxis( ang:Forward(), side * swingSin * 20 )
			ang:RotateAroundAxis( ang:Right(), swingSin * -80 )
			ang:RotateAroundAxis( ang:Up(), side * -45 )
			return pos, ang, MC_WEAPONS_FP.size * fovScale
		end
		if not firstPerson and MC.CreativeHeldThirdPersonAnchor then
			local pos, ang = MC.CreativeHeldThirdPersonAnchor( ply, leftHand )
			return pos, ang, 7.5
		end
		local bone = ply:LookupBone( leftHand and "ValveBiped.Bip01_L_Hand" or "ValveBiped.Bip01_R_Hand" )
		local pos, ang
		if bone then pos, ang = ply:GetBonePosition( bone ) end
		if not pos or not ang then pos, ang = ply:GetShootPos(), ply:EyeAngles() end
		local side = leftHand and -1 or 1
		return pos + ang:Forward() * 2.5 + ang:Right() * ( 2.2 * side ) - ang:Up() * 1.8, ang, 7.5
	end

	local function heldItemLightingColor( ply, pos, firstPerson, hand )
		local owner = firstPerson and ply:GetActiveWeapon() or ply
		local lightField = hand == "offhand" and "MCItemHandOffhandLight" or "MCItemHandMainhandLight"
		local colorField = hand == "offhand" and "MCItemHandOffhandColor" or "MCItemHandMainhandColor"
		local lighting
		if MC.CreativeHeldLightingAt and IsValid( owner ) then
			owner[lightField] = MC.CreativeHeldLightingAt( firstPerson and EyePos() or pos, owner[lightField] )
			lighting = owner[lightField]
		end

		local r, g, b = 1, 1, 1
		if type( lighting ) == "table" then
			r = math.Clamp( tonumber( lighting.r ) or 1, 0, 1 )
			g = math.Clamp( tonumber( lighting.g ) or r, 0, 1 )
			b = math.Clamp( tonumber( lighting.b ) or r, 0, 1 )
		end
		if MC.ScaleDynamicLightingRGB then
			r, g, b = MC.ScaleDynamicLightingRGB( r, g, b, HELD_ITEM_LIGHT_GAIN )
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
		local pos, ang, scale = heldPose( ply, firstPerson, hand )
		local stateId = selectedState( ply, stack )
		if definition.blockId and stateId and MC.DrawCreativeHeldBlockState then
			local brightness = 0.8
			if MC.CreativeHeldLightingAt then
				local owner = firstPerson and ply:GetActiveWeapon() or ply
				local field = hand == "offhand" and "MCItemHandOffhandLight" or "MCItemHandMainhandLight"
				if IsValid( owner ) then
					owner[field] = MC.CreativeHeldLightingAt( firstPerson and EyePos() or pos, owner[field] )
					brightness = owner[field]
				end
			end
			render.OverrideDepthEnable( firstPerson, false )
			MC.DrawCreativeHeldBlockState( stateId, pos, ang, scale, brightness )
			render.OverrideDepthEnable( false, false )
		elseif MC.InventoryUI and MC.InventoryUI.ItemRenderer then
			pos, ang, scale = heldItemPose( ply, firstPerson, hand )
			local color = heldItemLightingColor( ply, pos, firstPerson, hand )
			local using = useState.using and useState.hand == hand
			local useProgress = using and useState.progress or 0
			local useStart = using and useState.startedAt or 0
			local useDuration = using and useState.duration or 0
			if using and useDuration > 0 and MC.ItemUseProgress then
				useProgress = MC.ItemUseProgress( useStart, useDuration, CurTime() )
			end
			render.OverrideDepthEnable( firstPerson, false )
			MC.InventoryUI.ItemRenderer.DrawHeldItem( stack, pos, ang, scale,
				color, {
					displayContext = firstPerson and ( hand == "offhand" and "firstperson_lefthand" or "firstperson_righthand" )
						or ( hand == "offhand" and "thirdperson_lefthand" or "thirdperson_righthand" ),
					using = using,
					useProgress = math.Clamp( tonumber( useProgress ) or 0, 0, 1 ),
					useDuration = useDuration,
					crossbowPull = useProgress,
					chargeType = MC.ItemCrossbowChargeType and MC.ItemCrossbowChargeType( stack ) or "none",
					mcWeaponsView = firstPerson and MC_WEAPONS_FP or nil,
				} )
			render.OverrideDepthEnable( false, false )
		end
	end

	local function drawHeld( ply, firstPerson )
		if not IsValid( ply ) or not ply:Alive() then return end
		local weapon = ply:GetActiveWeapon()
		if not IsValid( weapon ) or weapon:GetClass() ~= "mc_item_hand" then return end
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
		drawHeldStack( ply, selectedStack( ply ), firstPerson, "mainhand", useState )
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
