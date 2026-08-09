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
SWEP.UseHands = true
SWEP.ViewModel = ""
SWEP.WorldModel = ""
SWEP.DrawViewModel = false
SWEP.DrawWorldModel = false
SWEP.Primary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" }
SWEP.Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" }

local ATTACK_INTERVAL = 0.12

local function aimedBlock( ply )
	return MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
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
end

function SWEP:Deploy()
	self:SetHoldType( "normal" )
	return true
end

function SWEP:Reload()
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
	local aim = aimedBlock( ply )
	if SERVER then
		local bx, by, bz = breakTarget( ply, aim, ply:GetEyeTrace() )
		if not bx then return end
		if MC.SV and MC.SV.Break then MC.SV.Break( ply, bx, by, bz ) end
	elseif CLIENT and IsFirstTimePredicted() and ply == LocalPlayer() then
		local bx, by, bz = breakTarget( ply, aim, ply:GetEyeTrace() )
		if bx and MC.CanPreviewBreak and MC.CanPreviewBreak( ply, bx, by, bz ) and MC.PredictBreakBlock then
			MC.PredictBreakBlock( bx, by, bz, ply )
		end
	end
end

function SWEP:SecondaryAttack()
	self:SetNextSecondaryFire( CurTime() + ATTACK_INTERVAL )
	local ply = self:GetOwner()
	if not IsValid( ply ) then return end
	local aim = aimedBlock( ply )
	local trace = aim or ply:GetEyeTrace()
	if not trace then return end
	if SERVER then
		local ux, uy, uz
		if aim then ux, uy, uz = aim.bx, aim.by, aim.bz
		elseif trace.Hit and MC.WorldToCell then ux, uy, uz = MC.WorldToCell( trace.HitPos - trace.HitNormal * 0.5 ) end
		local record, stack, definition = selectedRecord( ply )
		if aim and MC.SV and MC.SV.Use and MC.SV.Use( ply, ux, uy, uz, definition and definition.blockId or 0 ) then return end
		if MC.SV and MC.SV.UseSelectedItem and MC.SV.UseSelectedItem( ply, {
			reason = "right_click",
			target = aim and { bx = ux, by = uy, bz = uz } or nil,
		} ) then return end
		if not trace.Hit then return end
		if not definition or not definition.blockId or not MC.SV or not MC.SV.PlaceState then return end
		local bx, by, bz, stateId = placeTarget( ply, aim, trace, definition.blockId )
		if not bx then return end
		if not infiniteMaterials( ply ) and not stack then return end
		local consumedRecord, snapshot = consumeSelected( ply )
		if not infiniteMaterials( ply ) and not consumedRecord then return end
		if not MC.SV.PlaceState( ply, bx, by, bz, stateId ) then
			restoreConsumed( consumedRecord, snapshot )
			return
		end
		if not commitConsumed( consumedRecord, snapshot, ply ) then restoreConsumed( consumedRecord, snapshot ) end
	elseif IsFirstTimePredicted() and ply == LocalPlayer() then
		local state = MC.ClientInventory
		local stack = state and state.slots[( state.selected or 0 ) + 1] or nil
		local definition = stack and MC.GetItem( stack.item ) or nil
		if not definition or not definition.blockId then return end
		local bx, by, bz, stateId = placeTarget( ply, aim, trace, definition.blockId )
		local plan = bx and MC.BuildPlacementStatePlan and MC.BuildPlacementStatePlan( bx, by, bz, stateId )
		if plan and MC.CanPreviewPlacePlan and MC.CanPreviewPlacePlan( ply, plan ) and MC.PredictSetBlockState then
			MC.PredictSetBlockState( bx, by, bz, stateId )
		end
	end
end

if CLIENT then
	local function selectedStack( ply )
		if ply == LocalPlayer() and MC.ClientInventory then
			return MC.ClientInventory.slots[( MC.ClientInventory.selected or 0 ) + 1]
		end
		local runtime = IsValid( ply ) and ply:GetNWInt( "mc_selected_item_runtime", 0 ) or 0
		local definition = MC.GetItem( runtime )
		return definition and MC.NewItemStack( definition.name, 1 ) or nil
	end

	local function selectedState( ply, stack )
		local definition = stack and MC.GetItem( stack.item ) or nil
		if not definition or not definition.blockId or not MC.DefaultBlockState then return nil end
		return MC.DefaultBlockState( definition.blockId )
	end

	local function handPose( ply )
		local eyeAng = ply:EyeAngles()
		local pos = EyePos() + eyeAng:Forward() * 8 + eyeAng:Right() * 4 - eyeAng:Up() * 4
		local ang = Angle( eyeAng.p + 8, eyeAng.y + 28, eyeAng.r + 12 )
		return pos, ang, math.max( 0.35, ( MC.BS or 36.5 ) / 100 )
	end

	local function drawHeld( ply, firstPerson )
		if not IsValid( ply ) or not ply:Alive() then return end
		local weapon = ply:GetActiveWeapon()
		if not IsValid( weapon ) or weapon:GetClass() ~= "mc_item_hand" then return end
		local stack = selectedStack( ply )
		if MC.IsEmptyItemStack( stack ) then return end
		local definition = MC.GetItem( stack.item )
		if not definition then return end
		local pos, ang, scale
		if firstPerson then pos, ang, scale = handPose( ply )
		else
			local bone = ply:LookupBone( "ValveBiped.Bip01_R_Hand" )
			if bone then pos, ang = ply:GetBonePosition( bone ) end
			if not pos or not ang then pos, ang = ply:GetShootPos() + ply:EyeAngles():Forward() * 10, ply:EyeAngles() end
			pos = pos + ang:Forward() * 2 + ang:Right() * 2 + ang:Up() * 1
			scale = 0.45
		end
		local stateId = selectedState( ply, stack )
		if definition.blockId and stateId and MC.DrawCreativeHeldBlockState then
			render.OverrideDepthEnable( firstPerson, false )
			MC.DrawCreativeHeldBlockState( stateId, pos, ang, scale, 0.8 )
			render.OverrideDepthEnable( false, false )
		elseif MC.InventoryUI and MC.InventoryUI.ItemRenderer then
			local normal = firstPerson and EyeAngles():Forward() or ang:Forward()
			MC.InventoryUI.ItemRenderer.DrawHeldItem( stack, pos, normal, firstPerson and 2.4 or 1.1 )
		end
	end

	hook.Add( "PostDrawTranslucentRenderables", "mc_item_hand_first_person", function( _, sky3d )
		if sky3d then return end
		local ply = LocalPlayer()
		if not IsValid( ply ) or ply:ShouldDrawLocalPlayer() then return end
		drawHeld( ply, true )
	end )

	hook.Add( "PostPlayerDraw", "mc_item_hand_third_person", function( ply )
		if not IsValid( ply ) or ply == LocalPlayer() or not ply:Alive() then return end
		drawHeld( ply, false )
	end )

	function SWEP:DrawWorldModel() end
end
