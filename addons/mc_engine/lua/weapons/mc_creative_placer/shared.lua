--[[----------------------------------------------------------------------------
	mc_creative_placer : SWEP front-end with a Minecraft-style creative inventory.
	Left = break, Right = place, R = categorized creative block picker.
------------------------------------------------------------------------------]]

if SERVER then AddCSLuaFile() end

local function L( key, fallback, vars )
	return MC and MC.T and MC.T( key, fallback, vars ) or fallback
end

local function blockDisplayText( blockOrID )
	local b = type( blockOrID ) == "table" and blockOrID or ( MC and MC.Blocks and MC.Blocks[blockOrID] )
	if not b then return "" end
	return MC.BlockDisplayName and MC.BlockDisplayName( b, b.dispZH or b.disp ) or b.disp
end

SWEP.PrintName     = L( "weapon.mc_creative_placer.name", "MC 创造方块放置器" )
SWEP.Author        = "schweiziske"
SWEP.Purpose       = L( "weapon.mc_creative_placer.purpose", "放置 / 破坏 Minecraft 方块，并从创造物品栏选择方块" )
SWEP.Instructions  = L( "weapon.mc_creative_placer.instructions", "左键破坏  右键放置  Reload 创造物品栏" )
SWEP.Category      = "Minecraft"

-- Right-click already tries MC.SV.Use before placing; see the fallback hook in
-- sv_world.lua for why double-handling must be opted out of explicitly.
SWEP.MCOwnsBlockInteraction = true

SWEP.Spawnable     = true
SWEP.AdminOnly     = false
SWEP.Slot          = 1
SWEP.SlotPos       = 6
SWEP.DrawAmmo      = false
SWEP.DrawCrosshair = true

SWEP.Base          = "weapon_base"
SWEP.ViewModel     = "models/weapons/c_toolgun.mdl"
SWEP.WorldModel    = "models/weapons/w_toolgun.mdl"
SWEP.UseHands      = true
SWEP.DrawViewModel = false
SWEP.DrawWorldModel = false

SWEP.Primary   = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" }
SWEP.Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" }

if CLIENT then
	-- The weapon selector uses the dedicated translucent icon; the spawn menu
	-- content panel uses materials/entities/mc_creative_placer.png.
	SWEP.WepSelectIcon = surface.GetTextureID( "vgui/entities/mc_creative_placer" )
	SWEP.BounceWeaponIcon = false
	SWEP.DrawWeaponInfoBox = false

	function SWEP:DrawWeaponSelection( x, y, width, height, alpha )
		local size = math.min( width, height ) * 0.70
		surface.SetDrawColor( 255, 255, 255, alpha or 255 )
		surface.SetTexture( self.WepSelectIcon )
		surface.DrawTexturedRect( x + ( width - size ) * 0.5, y + ( height - size ) * 0.5, size, size )
	end
end

local STEP = 0.13

local function defaultSelectedID()
	local resolved = MC.ResolveBlock and MC.ResolveBlock( "minecraft:stone" ) or nil
	local id = resolved and resolved.id or 1
	if not MC.IsValidBlock( id ) then id = 1 end
	return id
end

local function selectedID( ply )
	if CLIENT and ply == LocalPlayer() and MC.GetCreativeHotbarSelectedID then
		local hotbarID = MC.GetCreativeHotbarSelectedID( ply )
		if MC.IsValidBlock( hotbarID ) then return hotbarID end
	end
	local fallback = defaultSelectedID()
	local id = IsValid( ply ) and ply:GetNWInt( "mc_block", fallback ) or fallback
	if not MC.IsValidBlock( id ) then id = fallback end
	return id
end

local function selectedOrient( ply, id )
	local stateId
	if CLIENT and ply == LocalPlayer() and MC.GetCreativeHotbarSelectedStateID then
		stateId = MC.GetCreativeHotbarSelectedStateID()
	elseif IsValid( ply ) and ply:GetNWInt( "mc_block", -1 ) == id then
		local selected = ply:GetNWInt( "mc_block_state", -1 )
		stateId = selected >= 0 and selected or nil
	end
	if stateId and MC.LegacyFromState then
		local stateBlockId, orient = MC.LegacyFromState( stateId )
		if stateBlockId == id then return orient end
	end
	return nil
end

local function selectedStateId( ply, id )
	local stateId
	if CLIENT and ply == LocalPlayer() and MC.GetCreativeHotbarSelectedStateID then
		stateId = MC.GetCreativeHotbarSelectedStateID()
	elseif IsValid( ply ) and ply:GetNWInt( "mc_block", -1 ) == id then
		local selected = ply:GetNWInt( "mc_block_state", -1 )
		stateId = selected >= 0 and selected or nil
	end
	if not stateId or not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then return nil end
	if MC.BlockTypeForState( stateId ) ~= id then return nil end
	return stateId
end

local function placeCell( tr )
	return MC.WorldToCell( tr.HitPos + tr.HitNormal * 0.5 )
end

local function breakCell( tr )
	return MC.WorldToCell( tr.HitPos - tr.HitNormal * 0.5 )
end

local function aimedBlock( ply )
	return MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
end

local function blockHasUse( id )
	local b = MC.Blocks and MC.Blocks[id]
	return b and b.handlers and b.handlers.OnUse ~= nil
end

local function placeTarget( ply, aim, fallbackTrace, id, avoidUseBlocks )
	local tr = aim or fallbackTrace
	if not tr or not tr.Hit then return nil end
	if avoidUseBlocks and aim and blockHasUse( aim.Block ) then return nil end

	local bx, by, bz
	if aim then
		bx = aim.bx + math.Round( aim.HitNormal.x )
		by = aim.by + math.Round( aim.HitNormal.y )
		bz = aim.bz + math.Round( aim.HitNormal.z )
	else
		bx, by, bz = placeCell( tr )
	end

	tr.MCBlockX, tr.MCBlockY, tr.MCBlockZ = bx, by, bz
	local stateId = selectedStateId( ply, id )
	local orient
	if stateId then
		local _, projectedOrient = MC.LegacyFromState( stateId )
		orient = projectedOrient or MC.DefaultOrient( id )
	else
		orient = MC.OrientForPlacement( ply, tr, id )
		stateId = MC.StateFromLegacy( id, orient )
	end
	if stateId and MC.ResolveTorchPlacementState then
		stateId = MC.ResolveTorchPlacementState( stateId, tr.HitNormal )
		if not stateId then return nil end
	end
	if stateId and MC.ResolveFaceAttachedPlacementState then
		stateId = MC.ResolveFaceAttachedPlacementState( stateId, tr.HitNormal, ply )
		if not stateId then return nil end
	end
	if stateId and MC.ResolveSignPlacementState then
		stateId = MC.ResolveSignPlacementState( stateId, tr.HitNormal, ply, bx, by, bz )
		if not stateId then return nil end
	end
	if stateId and MC.ResolveBannerPlacementState then
		stateId = MC.ResolveBannerPlacementState( stateId, tr.HitNormal, ply, bx, by, bz )
		if not stateId then return nil end
	end
	if not stateId then return nil end
	return bx, by, bz, stateId
end

local function breakTarget( ply, aim, fallbackTrace )
	if aim then return aim.bx, aim.by, aim.bz end
	local tr = fallbackTrace
	if not tr or not tr.Hit then return nil end
	return breakCell( tr )
end

function SWEP:Initialize()
	self:SetHoldType( "pistol" )
end

function SWEP:Deploy()
	self:SetHoldType( "pistol" )
	if CLIENT and MC.EnsureCreativeHotbar then
		MC.EnsureCreativeHotbar()
		if MC.SyncCreativeHotbarSelection then MC.SyncCreativeHotbarSelection( true ) end
	end
	return true
end

function SWEP:PrimaryAttack()
	self:SetNextPrimaryFire( CurTime() + STEP )
	local owner = self:GetOwner()
	if not IsValid( owner ) then return end
	local aim = aimedBlock( owner )

	if SERVER then
		local bx, by, bz = breakTarget( owner, aim, owner:GetEyeTrace() )
		if not bx then return end
		if MC.SV.Break( owner, bx, by, bz ) then
			-- self:EmitSound( "buttons/button15.wav", 60, 120, 0.25 )
			net.Start( "mc_creative_break_anim" )
				net.WriteInt( bx, MC.Net.COORD_BITS )
				net.WriteInt( by, MC.Net.COORD_BITS )
				net.WriteInt( bz, MC.Net.COORD_BITS )
			net.Send( owner )
		elseif MC.SV.SyncBreakPlan then
			MC.SV.SyncBreakPlan( owner, bx, by, bz )
		elseif MC.SV.SyncCell then
			MC.SV.SyncCell( owner, bx, by, bz )
		end
	elseif CLIENT and not game.SinglePlayer() and IsFirstTimePredicted() and owner == LocalPlayer() then
		local bx, by, bz = breakTarget( owner, aim, owner:GetEyeTrace() )
		if bx and MC.CanPreviewBreak and MC.CanPreviewBreak( owner, bx, by, bz ) and MC.PredictBreakBlock then
			if MC.PredictBreakBlock( bx, by, bz, owner ) then
				self:StartCreativePlaceAnimation( bx, by, bz )
			end
		end
	end
end

function SWEP:SecondaryAttack()
	self:SetNextSecondaryFire( CurTime() + STEP )
	local owner = self:GetOwner()
	if not IsValid( owner ) then return end
	local aim = aimedBlock( owner )

	if SERVER then
		local tr = aim or owner:GetEyeTrace()
		if not tr.Hit then return end
		local ux, uy, uz
		if aim then
			ux, uy, uz = aim.bx, aim.by, aim.bz
		else
			ux, uy, uz = breakCell( tr )
		end
		local id = selectedID( owner )
		if MC.SV.Use( owner, ux, uy, uz, id ) then return end

		local bx, by, bz, stateId = placeTarget( owner, aim, tr, id )
		if not bx then return end
		if MC.SV.PlaceState( owner, bx, by, bz, stateId ) then
			-- self:EmitSound( "buttons/button14.wav", 60, 150, 0.25 )
			net.Start( "mc_creative_place_anim" )
				net.WriteInt( bx, MC.Net.COORD_BITS )
				net.WriteInt( by, MC.Net.COORD_BITS )
				net.WriteInt( bz, MC.Net.COORD_BITS )
			net.Send( owner )
		elseif MC.SV.SyncPlacementStatePlan then
			MC.SV.SyncPlacementStatePlan( owner, bx, by, bz, stateId )
		elseif MC.SV.SyncCell then
			MC.SV.SyncCell( owner, bx, by, bz )
		end
	elseif CLIENT and not game.SinglePlayer() and IsFirstTimePredicted() and owner == LocalPlayer() then
		local id = selectedID( owner )
		local selectedState = selectedStateId( owner, id )
		if MC.CreativeHotbarSelectionSynced and not MC.CreativeHotbarSelectionSynced( owner, id, selectedState ) then return end
		local bx, by, bz, stateId = placeTarget( owner, aim, owner:GetEyeTrace(), id, true )
		local plan = bx and MC.BuildPlacementStatePlan and MC.BuildPlacementStatePlan( bx, by, bz, stateId )
		if plan and MC.CanPreviewPlacePlan and MC.CanPreviewPlacePlan( owner, plan ) and MC.PredictSetBlockState then
			if MC.PredictSetBlockState( bx, by, bz, stateId ) then
				self:StartCreativePlaceAnimation( bx, by, bz )
			end
		end
	end
end

-- In single-player weapon input is handled by the server realm. Keep the UI
-- opener client-only, but explicitly bridge Reload across realms there.
function SWEP:OpenCreativeInventoryClient()
	if not CLIENT then return end
	-- This weapon is the legacy standalone placer and always uses its own
	-- creative block picker. It used to hand the press to the game layer's
	-- inventory UI capability when mc_game was installed, which meant taking
	-- out the placer could put the survival inventory screen on screen instead
	-- of the block picker. The two UIs are separate by design; keep them so.
	if IsValid( MC.CreativeFrame ) and MC.CreativeFrame:IsVisible() then return end
	MC.OpenCreativeInventory( function( id, stateId )
		if stateId ~= nil and MC.SetCreativeHotbarSlotStateID then
			MC.SetCreativeHotbarSlotStateID( MC.GetCreativeHotbarSelectedSlot(), id, stateId )
		else
			MC.SetCreativeHotbarSlot( MC.GetCreativeHotbarSelectedSlot(), id )
		end
	end, { closeOnSelect = false } )
end

function SWEP:Reload()
	if SERVER then
		if game.SinglePlayer() then self:CallOnClient( "OpenCreativeInventoryClient" ) end
		return
	end
	if game.SinglePlayer() then return end
	self:OpenCreativeInventoryClient()
end

if CLIENT then
	local HELD_FACE_SHADE = {
		[1] = Color( 255, 255, 255, 255 ),
		[2] = Color( 130, 130, 130, 255 ),
		[3] = Color( 170, 170, 170, 255 ),
		[4] = Color( 170, 170, 170, 255 ),
		[5] = Color( 215, 215, 215, 255 ),
		[6] = Color( 215, 215, 215, 255 ),
	}
	-- Unlit atlas geometry at RGB 255 reads substantially hotter than the chunk
	-- shader under GMod's HDR/bloom pass. Keep the sampled hue and contrast, but
	-- leave headroom so the held block does not clip to glowing white outdoors.
	local HELD_LIGHT_GAIN = 0.48

	local HELD_FACE_NORMALS = {
		[1] = Vector( 0, 0, 1 ),
		[2] = Vector( 0, 0, -1 ),
		[3] = Vector( 1, 0, 0 ),
		[4] = Vector( -1, 0, 0 ),
		[5] = Vector( 0, 1, 0 ),
		[6] = Vector( 0, -1, 0 ),
	}

	local HELD_FACE_CORNERS = {
		[1] = function( b ) return { { b[1], b[2], b[6] }, { b[4], b[2], b[6] }, { b[4], b[5], b[6] }, { b[1], b[5], b[6] } } end,
		[2] = function( b ) return { { b[1], b[5], b[3] }, { b[4], b[5], b[3] }, { b[4], b[2], b[3] }, { b[1], b[2], b[3] } } end,
		[3] = function( b ) return { { b[4], b[2], b[3] }, { b[4], b[5], b[3] }, { b[4], b[5], b[6] }, { b[4], b[2], b[6] } } end,
		[4] = function( b ) return { { b[1], b[5], b[3] }, { b[1], b[2], b[3] }, { b[1], b[2], b[6] }, { b[1], b[5], b[6] } } end,
		[5] = function( b ) return { { b[4], b[5], b[3] }, { b[1], b[5], b[3] }, { b[1], b[5], b[6] }, { b[4], b[5], b[6] } } end,
		[6] = function( b ) return { { b[1], b[2], b[3] }, { b[4], b[2], b[3] }, { b[4], b[2], b[6] }, { b[1], b[2], b[6] } } end,
	}

	local HELD_TRI = { 1, 3, 2, 1, 4, 3 }
	local HELD_FULL_BLOCK = { { 0, 0, 0, 1, 1, 1 } }
	local HELD_ITEM_BOXES = {
		fence = { { 0.375, 0.375, 0, 0.625, 0.625, 1 }, { 0.1875, 0.4375, 0.35, 0.8125, 0.5625, 0.5 }, { 0.1875, 0.4375, 0.65, 0.8125, 0.5625, 0.8 } },
		pane = { { 0.4375, 0, 0, 0.5625, 1, 1 } },
		pipe6 = { { 0.25, 0.25, 0.25, 0.75, 0.75, 0.75 } },
		wall = { { 0.25, 0.25, 0, 0.75, 0.75, 1 } },
	}
	-- Minecraft source reference:
	-- ItemInHandRenderer: ITEM_POS_X=0.56, ITEM_POS_Y=-0.52, ITEM_POS_Z=-0.72.
	-- ItemInHandRenderer swingArm: x=-0.4*sin(sqrt(attack)*pi), y=0.2*sin(sqrt(attack)*2pi), z=-0.2*sin(attack*pi).
	-- ItemInHandRenderer applyItemArmAttackTransform: Y=+45+sin(attack^2*pi)*-20, Z=sin(sqrt(attack)*pi)*-20, X=sin(sqrt(attack)*pi)*-80, Y=-45.
	-- ItemInHandRenderer itemUsed(MAIN_HAND): mainHandHeight=0.
	-- ItemInHandRenderer tick: mainHandHeight approaches target by clamp(delta, -0.4, 0.4) per 20 TPS tick.
	-- ItemInHandRenderer applyItemArmTransform: y=-0.52+inverseArmHeight*-0.6.
	-- block/block.json: firstperson_righthand rotation=[0,45,0], scale=0.40;
	-- block/block.json: thirdperson_righthand rotation=[75,45,0], scale=0.375.
	local HELD_FP_DEFAULTS = { forward = 11.5, right = 12, up = -8.3, scale = 6.4, yaw = 45, pitch = 0, roll = 0, bob = 0 }
	local HELD_TP_DEFAULTS = { forward = 2.5, right = 2.2, up = -1.8, scale = 6, yaw = 45, pitch = 75, roll = 0 }
	local HELD_PLACE_ANIM = { duration = 0.30, rightScale = 21.4, upScale = 16, forwardScale = 16, yaw = -20, pitch = -80, roll = -20 }
	local HELD_HAND_HEIGHT = { recoverPerSecond = 8, upScale = 9.6 }
	local HELD_MODEL_CVAR = CreateClientConVar( "mc_creative_held_model", "1", true, false, "Draw the MC creative held block model" )
	local HELD_ANIM_CVAR = CreateClientConVar( "mc_creative_held_anim", "1", true, false, "Play MC creative held block swing animations" )
	local HELD_FP_CVARS = {
		forward = CreateClientConVar( "mc_creative_held_fp_forward", tostring( HELD_FP_DEFAULTS.forward ), true, false, "MC creative held block first-person forward offset" ),
		right = CreateClientConVar( "mc_creative_held_fp_right", tostring( HELD_FP_DEFAULTS.right ), true, false, "MC creative held block first-person right offset" ),
		up = CreateClientConVar( "mc_creative_held_fp_up", tostring( HELD_FP_DEFAULTS.up ), true, false, "MC creative held block first-person up offset" ),
		scale = CreateClientConVar( "mc_creative_held_fp_scale", tostring( HELD_FP_DEFAULTS.scale ), true, false, "MC creative held block first-person scale" ),
		yaw = CreateClientConVar( "mc_creative_held_fp_yaw", tostring( HELD_FP_DEFAULTS.yaw ), true, false, "MC creative held block first-person yaw" ),
		pitch = CreateClientConVar( "mc_creative_held_fp_pitch", tostring( HELD_FP_DEFAULTS.pitch ), true, false, "MC creative held block first-person pitch" ),
		roll = CreateClientConVar( "mc_creative_held_fp_roll", tostring( HELD_FP_DEFAULTS.roll ), true, false, "MC creative held block first-person roll" ),
	}
	local HELD_TP_CVARS = {
		forward = CreateClientConVar( "mc_creative_held_tp_forward", tostring( HELD_TP_DEFAULTS.forward ), true, false, "MC creative held block third-person forward offset" ),
		right = CreateClientConVar( "mc_creative_held_tp_right", tostring( HELD_TP_DEFAULTS.right ), true, false, "MC creative held block third-person right offset" ),
		up = CreateClientConVar( "mc_creative_held_tp_up", tostring( HELD_TP_DEFAULTS.up ), true, false, "MC creative held block third-person up offset" ),
		scale = CreateClientConVar( "mc_creative_held_tp_scale", tostring( HELD_TP_DEFAULTS.scale ), true, false, "MC creative held block third-person scale" ),
		yaw = CreateClientConVar( "mc_creative_held_tp_yaw", tostring( HELD_TP_DEFAULTS.yaw ), true, false, "MC creative held block third-person yaw" ),
		pitch = CreateClientConVar( "mc_creative_held_tp_pitch", tostring( HELD_TP_DEFAULTS.pitch ), true, false, "MC creative held block third-person pitch" ),
		roll = CreateClientConVar( "mc_creative_held_tp_roll", tostring( HELD_TP_DEFAULTS.roll ), true, false, "MC creative held block third-person roll" ),
	}
	if math.abs( HELD_FP_CVARS.right:GetFloat() - 9 ) < 0.001 or math.abs( HELD_FP_CVARS.right:GetFloat() - 10.5 ) < 0.001 then
		RunConsoleCommand( "mc_creative_held_fp_right", tostring( HELD_FP_DEFAULTS.right ) )
	end

	local function cvarFloat( cvar, fallback )
		return cvar and cvar.GetFloat and cvar:GetFloat() or fallback
	end

	local function cvarBool( cvar, fallback )
		if cvar and cvar.GetBool then return cvar:GetBool() end
		return fallback
	end

	local function creativeHeldModelEnabled()
		return cvarBool( HELD_MODEL_CVAR, true )
	end

	local function creativeHeldAnimEnabled()
		return cvarBool( HELD_ANIM_CVAR, true )
	end

	local function heldBlockLightingAt( pos, state )
		local r, g, b = 1, 1, 1
		if MC.SampleDynamicLightingRGB then
			r, g, b = MC.SampleDynamicLightingRGB( pos, 0 )
		elseif MC.WorldToCell and MC.SampleLighting then
			local bx, by, bz = MC.WorldToCell( pos )
			if bx ~= nil then
				local brightness = MC.SampleLighting( bx, by, bz, 0 )
				r = math.Clamp( tonumber( brightness ) or 1, 0, 1 )
				g, b = r, r
			end
		end

		state = state or {}
		local dt = RealFrameTime and RealFrameTime() or FrameTime and FrameTime() or 0.016
		local blend = 1 - math.exp( -math.Clamp( dt, 0, 0.1 ) * 12 )
		state.r = state.r and Lerp( blend, state.r, r ) or r
		state.g = state.g and Lerp( blend, state.g, g ) or g
		state.b = state.b and Lerp( blend, state.b, b ) or b
		return state
	end

	local function rotatedUV( uf, vf, rot, flipU, flipV )
		rot = ( rot or 0 ) % 4
		if rot == 1 then uf, vf = vf, 1 - uf
		elseif rot == 2 then uf, vf = 1 - uf, 1 - vf
		elseif rot == 3 then uf, vf = 1 - vf, uf end
		if flipU then uf = 1 - uf end
		if flipV then vf = 1 - vf end
		return uf, vf
	end

	local function faceUV( face, c )
		if face == 1 then return c[1], c[2] end
		if face == 2 then return c[1], 1 - c[2] end
		if face == 3 then return c[2], 1 - c[3] end
		if face == 4 then return 1 - c[2], 1 - c[3] end
		if face == 5 then return 1 - c[1], 1 - c[3] end
		return c[1], 1 - c[3]
	end

	local function atlasUV( tile, face, c, rot, flipU, flipV )
		local u0, v0, u1, v1 = MC.TileUV( tile )
		local uf, vf = faceUV( face, c )
		uf, vf = rotatedUV( uf, vf, rot, flipU, flipV )
		return u0 + uf * ( u1 - u0 ), v0 + vf * ( v1 - v0 )
	end

	local function heldBlockBoxes( id, orient, stateId )
		local b = MC.Blocks and MC.Blocks[id]
		if b and b.connection and HELD_ITEM_BOXES[b.connection] then
			return HELD_ITEM_BOXES[b.connection]
		end
		if stateId and MC.BlockBoxesForState then
			local boxes = MC.BlockBoxesForState( stateId )
			if boxes and #boxes > 0 then return boxes end
		end
		local boxes = MC.BlockBoxes and MC.BlockBoxes( id, orient ) or nil
		if boxes and #boxes > 0 then return boxes end
		return HELD_FULL_BLOCK
	end

	function MC.DrawCreativeHeldBlock( id, orient, pos, ang, scale, brightness, stateId )
		if not ( MC.Blocks and MC.Blocks[id] and MC.Material and MC.BlockFace and MC.TileUV ) then return false end
		if not stateId and MC.StateFromLegacy then stateId = MC.StateFromLegacy( id, orient or 0 ) end
		local boxes = heldBlockBoxes( id, orient, stateId )
		if not boxes or #boxes == 0 then return false end

		local translucent = stateId and MC.IsTranslucentBlockState and MC.IsTranslucentBlockState( stateId )
			or MC.IsTranslucentBlock and MC.IsTranslucentBlock( id )
		local material = translucent and MC.MaterialHeldBlockTranslucent or MC.MaterialHeldBlock
		if not MC.Need( material, "held_block_material", "Missing held block atlas material" ) then return false end

		scale = scale or 8
		local lightR, lightG, lightB
		if type( brightness ) == "table" then
			local rawR = math.Clamp( tonumber( brightness.r ) or 1, 0, 1 )
			local rawG = math.Clamp( tonumber( brightness.g ) or rawR, 0, 1 )
			local rawB = math.Clamp( tonumber( brightness.b ) or rawR, 0, 1 )
			if MC.ScaleDynamicLightingRGB then
				lightR, lightG, lightB = MC.ScaleDynamicLightingRGB( rawR, rawG, rawB, HELD_LIGHT_GAIN )
			else
				lightR, lightG, lightB = rawR * HELD_LIGHT_GAIN, rawG * HELD_LIGHT_GAIN, rawB * HELD_LIGHT_GAIN
			end
		else
			local raw = math.Clamp( tonumber( brightness ) or 1, 0, 1 )
			if MC.ScaleDynamicLightingRGB then
				lightR, lightG, lightB = MC.ScaleDynamicLightingRGB( raw, raw, raw, HELD_LIGHT_GAIN )
			else
				lightR = raw * HELD_LIGHT_GAIN
				lightG, lightB = lightR, lightR
			end
		end
		local tintR, tintG, tintB = 255, 255, 255
		if stateId and MC.BlockStateTintCode and MC.BlockTintRGB then
			local tintCode = MC.BlockStateTintCode( stateId, id, 0 )
			if tintCode and tintCode ~= 0 then tintR, tintG, tintB = MC.BlockTintRGB( tintCode ) end
		end
		local mat = Matrix()
		mat:Translate( pos )
		mat:Rotate( ang )
		mat:Scale( Vector( scale, scale, scale ) )

		cam.PushModelMatrix( mat )
		-- Keep the source texels crisp in both hands, independent of the world's
		-- trilinear/aniso settings. Restore the sampler even if mesh emission fails.
		render.PushFilterMin( TEXFILTER.POINT )
		render.PushFilterMag( TEXFILTER.POINT )
		local building = false
		local ok, err = pcall( function()
			render.SetMaterial( material )
			mesh.Begin( MATERIAL_TRIANGLES, #boxes * 12 )
			building = true
			for _, box in ipairs( boxes ) do
				for face = 1, 6 do
					local tile, rot, flipU, flipV
					if stateId and MC.BlockFaceForState then
						tile, rot, flipU, flipV = MC.BlockFaceForState( stateId, face )
					else
						tile, rot, flipU, flipV = MC.BlockFace( id, face, orient )
					end
					local corners = HELD_FACE_CORNERS[face]( box )
					local normal = HELD_FACE_NORMALS[face]
					local shade = HELD_FACE_SHADE[face]
					for _, ci in ipairs( HELD_TRI ) do
						local c = corners[ci]
						local u, v = atlasUV( tile, face, c, rot, flipU, flipV )
						mesh.Position( Vector( c[1] - 0.5, c[2] - 0.5, c[3] - 0.5 ) )
						mesh.Normal( normal )
						mesh.TexCoord( 0, u, v )
						mesh.Color(
							math.Clamp( math.floor( shade.r * lightR * tintR / 255 + 0.5 ), 0, 255 ),
							math.Clamp( math.floor( shade.g * lightG * tintG / 255 + 0.5 ), 0, 255 ),
							math.Clamp( math.floor( shade.b * lightB * tintB / 255 + 0.5 ), 0, 255 ),
							shade.a
						)
						mesh.AdvanceVertex()
					end
				end
			end
			building = false
			mesh.End()
		end )
		if building then
			-- Finish the abandoned immediate mesh before restoring render state.
			-- Preserve the original emission error if ending it also fails.
			local ended, endError = pcall( mesh.End )
			if not ended then err = tostring( err ) .. "; mesh.End: " .. tostring( endError ) end
		end
		render.PopFilterMag()
		render.PopFilterMin()
		cam.PopModelMatrix()
		if not ok then error( err, 0 ) end

		return true
	end

	function MC.DrawCreativeHeldBlockState( stateId, pos, ang, scale, brightness )
		local visual = MC.ResolveBlockStateVisual and MC.ResolveBlockStateVisual( stateId ) or nil
		if not visual then return false end
		return MC.DrawCreativeHeldBlock( visual.id, visual.renderOrient, pos, ang, scale, brightness, stateId )
	end

	local function creativeHeldOrient( id )
		local orient = MC.GetCreativeHotbarSelectedOrient and MC.GetCreativeHotbarSelectedOrient() or nil
		if orient ~= nil then return orient end
		return MC.DefaultOrient and MC.DefaultOrient( id ) or 0
	end

	local function placeAnimKey( bx, by, bz )
		if bx == nil then return nil end
		return MC.CellKey( bx, by, bz )
	end

	function SWEP:StartCreativePlaceAnimation( bx, by, bz )
		if not creativeHeldAnimEnabled() then return end
		local now = CurTime()
		local key = placeAnimKey( bx, by, bz )
		if key and self.MCCreativePlaceAnimKey == key and now - ( self.MCCreativePlaceAnimStart or 0 ) < 0.75 then return end
		self.MCCreativePlaceAnimKey = key
		self.MCCreativePlaceAnimStart = now
		self.MCCreativeOldMainHandHeight = 0
		self.MCCreativeMainHandHeight = 0
		self.MCCreativeHandHeightLast = now
	end

	function SWEP:CreativePlaceAnim()
		if not creativeHeldAnimEnabled() then return 0 end
		local start = self.MCCreativePlaceAnimStart
		if not start then return 0 end
		local t = ( CurTime() - start ) / HELD_PLACE_ANIM.duration
		if t <= 0 then return 0 end
		if t >= 1 then return 0 end
		return t
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
		local step = math.min( HELD_HAND_HEIGHT.recoverPerSecond * dt, HELD_HAND_HEIGHT.recoverPerSecond / 20 )
		self.MCCreativeMainHandHeight = math.Clamp( self.MCCreativeMainHandHeight + step, 0, 1 )
		self.MCCreativeHandHeightLast = now
	end

	function SWEP:CreativeMainHandInverseHeight()
		if not creativeHeldAnimEnabled() then return 0 end
		self:UpdateCreativeMainHandHeight()
		return 1 - math.Clamp( self.MCCreativeMainHandHeight or 1, 0, 1 )
	end

	local function applyMinecraftDisplayRotation( baseAng, pitch, yaw, roll )
		local ang = Angle( baseAng.p, baseAng.y, baseAng.r )
		ang:RotateAroundAxis( ang:Right(), pitch )
		ang:RotateAroundAxis( ang:Up(), yaw )
		ang:RotateAroundAxis( ang:Forward(), roll )
		return ang
	end

	local function firstPersonHeldMotion( wep, leftHand )
		local eyeAng = EyeAngles()
		local side = leftHand and -1 or 1
		local bob = math.sin( CurTime() * 1.8 ) * HELD_FP_DEFAULTS.bob
		local placeAnim = IsValid( wep ) and wep:CreativePlaceAnim() or 0
		local inverseArmHeight = IsValid( wep ) and wep:CreativeMainHandInverseHeight() or 0
		local swingRoot = placeAnim > 0 and math.sin( math.sqrt( placeAnim ) * math.pi ) or 0
		local swingLinear = placeAnim > 0 and math.sin( placeAnim * math.pi ) or 0
		local swingDouble = placeAnim > 0 and math.sin( math.sqrt( placeAnim ) * math.pi * 2 ) or 0
		local swingSquared = placeAnim > 0 and math.sin( placeAnim * placeAnim * math.pi ) or 0
		local xSwingPosition = -0.4 * swingRoot
		local ySwingPosition = 0.2 * swingDouble
		local zSwingPosition = -0.2 * swingLinear
		local pos = EyePos()
			+ eyeAng:Forward() * ( cvarFloat( HELD_FP_CVARS.forward, HELD_FP_DEFAULTS.forward ) - zSwingPosition * HELD_PLACE_ANIM.forwardScale )
			+ eyeAng:Right() * side * ( cvarFloat( HELD_FP_CVARS.right, HELD_FP_DEFAULTS.right ) + xSwingPosition * HELD_PLACE_ANIM.rightScale )
			+ eyeAng:Up() * ( cvarFloat( HELD_FP_CVARS.up, HELD_FP_DEFAULTS.up ) + bob + ySwingPosition * HELD_PLACE_ANIM.upScale - inverseArmHeight * HELD_HAND_HEIGHT.upScale )
		return pos, eyeAng,
			swingRoot * HELD_PLACE_ANIM.pitch,
			side * swingSquared * HELD_PLACE_ANIM.yaw,
			side * swingRoot * HELD_PLACE_ANIM.roll
	end

	local function firstPersonHeldPose( wep, leftHand )
		local side = leftHand and -1 or 1
		local pos, eyeAng, swingPitch, swingYaw, swingRoll = firstPersonHeldMotion( wep, leftHand )
		local ang = applyMinecraftDisplayRotation(
			eyeAng,
			cvarFloat( HELD_FP_CVARS.pitch, HELD_FP_DEFAULTS.pitch ) + swingPitch,
			side * cvarFloat( HELD_FP_CVARS.yaw, HELD_FP_DEFAULTS.yaw ) + swingYaw,
			side * cvarFloat( HELD_FP_CVARS.roll, HELD_FP_DEFAULTS.roll ) + swingRoll
		)
		return pos, ang, cvarFloat( HELD_FP_CVARS.scale, HELD_FP_DEFAULTS.scale )
	end

	-- Inventory-held blocks and flat items share the same vanilla-derived hand
	-- motion. Flat items use the unrotated anchor, then apply their model display.
	function MC.CreativeHeldFirstPersonPose( weapon, leftHand )
		return firstPersonHeldPose( weapon, leftHand == true )
	end

	function MC.CreativeHeldFirstPersonAnchor( weapon, leftHand )
		local pos, eyeAng, swingPitch, swingYaw, swingRoll = firstPersonHeldMotion( weapon, leftHand == true )
		return pos, applyMinecraftDisplayRotation( eyeAng, swingPitch, swingYaw, swingRoll )
	end

	function MC.CreativeHeldLightingAt( pos, state )
		return heldBlockLightingAt( pos, state )
	end

	local function drawFirstPersonHeldBlock( ply, wep )
		local id = selectedID( ply )
		if not MC.IsValidBlock( id ) then return end

		local pos, ang, scale = firstPersonHeldPose( wep )
		-- Eye-space sampling is more stable than the animated hand position and
		-- matches the light environment the first-person camera actually sees.
		wep.MCHeldLight = heldBlockLightingAt( EyePos(), wep.MCHeldLight )
		local brightness = wep.MCHeldLight

		render.OverrideDepthEnable( true, false )
			local stateId = selectedStateId( ply, id )
			if not stateId or not MC.DrawCreativeHeldBlockState( stateId, pos, ang, scale, brightness ) then
				MC.DrawCreativeHeldBlock( id, selectedOrient( ply, id ) or creativeHeldOrient( id ), pos, ang, scale, brightness )
			end
		render.OverrideDepthEnable( false, false )
	end

	local function playerHandTransform( ply, leftHand )
		local bone = ply:LookupBone( leftHand and "ValveBiped.Bip01_L_Hand" or "ValveBiped.Bip01_R_Hand" )
		if bone then
			local pos, ang = ply:GetBonePosition( bone )
			if pos and ang then return pos, ang end
		end
		local ang = ply:EyeAngles()
		local side = leftHand and -1 or 1
		return ply:GetShootPos() + ang:Forward() * 12 + ang:Right() * ( 7 * side ) - ang:Up() * 5, ang
	end

	local function thirdPersonHeldPose( ply, leftHand )
		local side = leftHand and -1 or 1
		local pos, ang = playerHandTransform( ply, leftHand )
		pos = pos
			+ ang:Forward() * cvarFloat( HELD_TP_CVARS.forward, HELD_TP_DEFAULTS.forward )
			+ ang:Right() * side * cvarFloat( HELD_TP_CVARS.right, HELD_TP_DEFAULTS.right )
			+ ang:Up() * cvarFloat( HELD_TP_CVARS.up, HELD_TP_DEFAULTS.up )
		local blockAng = applyMinecraftDisplayRotation(
			ang,
			cvarFloat( HELD_TP_CVARS.pitch, HELD_TP_DEFAULTS.pitch ),
			side * cvarFloat( HELD_TP_CVARS.yaw, HELD_TP_DEFAULTS.yaw ),
			side * cvarFloat( HELD_TP_CVARS.roll, HELD_TP_DEFAULTS.roll )
		)
		return pos, blockAng, cvarFloat( HELD_TP_CVARS.scale, HELD_TP_DEFAULTS.scale )
	end

	function MC.CreativeHeldThirdPersonPose( ply, leftHand )
		return thirdPersonHeldPose( ply, leftHand == true )
	end

	function MC.CreativeHeldThirdPersonAnchor( ply, leftHand )
		local side = leftHand and -1 or 1
		local pos, ang = playerHandTransform( ply, leftHand == true )
		pos = pos
			+ ang:Forward() * cvarFloat( HELD_TP_CVARS.forward, HELD_TP_DEFAULTS.forward )
			+ ang:Right() * side * cvarFloat( HELD_TP_CVARS.right, HELD_TP_DEFAULTS.right )
			+ ang:Up() * cvarFloat( HELD_TP_CVARS.up, HELD_TP_DEFAULTS.up )
		return pos, ang
	end

	local function drawThirdPersonHeldBlock( ply )
		local id = selectedID( ply )
		if not MC.IsValidBlock( id ) then return end

		local pos, ang, scale = thirdPersonHeldPose( ply )
		ply.MCHeldLight = heldBlockLightingAt( pos, ply.MCHeldLight )
		local brightness = ply.MCHeldLight
		local stateId = selectedStateId( ply, id )
		if not stateId or not MC.DrawCreativeHeldBlockState( stateId, pos, ang, scale, brightness ) then
			MC.DrawCreativeHeldBlock( id, selectedOrient( ply, id ) or creativeHeldOrient( id ), pos, ang, scale, brightness )
		end
	end

	function SWEP:PreDrawViewModel()
		return true
	end

	function SWEP:DrawWorldModel()
		local owner = self:GetOwner()
		if IsValid( owner ) and creativeHeldModelEnabled() then
			drawThirdPersonHeldBlock( owner )
		end
	end

	function SWEP:DrawWorldModelTranslucent() end

	function SWEP:GetPrintName()
		return L( "weapon.mc_creative_placer.name", self.PrintName or "MC 创造方块放置器" )
	end

	local function receiveCreativeHeldBlockAnim()
		local bx = net.ReadInt( MC.Net.COORD_BITS )
		local by = net.ReadInt( MC.Net.COORD_BITS )
		local bz = net.ReadInt( MC.Net.COORD_BITS )
		local ply = LocalPlayer()
		if not IsValid( ply ) then return end
		local wep = ply:GetActiveWeapon()
		if not IsValid( wep ) then return end
		local class = wep:GetClass()
		if class ~= "mc_creative_placer" and class ~= "mc_item_hand" then
			-- A weapon proxying for the hand (MCITEM's SWEPs) is the active one
			-- while the swing request is in flight, so it has to be able to play
			-- it too; it carries its own swing rather than this animation.
			if isfunction( wep.MCSwing ) then wep:MCSwing( CurTime() ) end
			return
		end
		wep:StartCreativePlaceAnimation( bx, by, bz )
	end

	net.Receive( "mc_creative_place_anim", receiveCreativeHeldBlockAnim )
	net.Receive( "mc_creative_break_anim", receiveCreativeHeldBlockAnim )

	function SWEP:DrawHUD()
		local ply = LocalPlayer()
		local id = selectedID( ply )
		local b = MC.Blocks[id]

		local sw, sh = ScrW(), ScrH()
		local slotSize = 54
		local hotbarY = sh - slotSize - 30

		if b then
			local tr = aimedBlock( ply ) or ply:GetEyeTrace()
			local stateId = selectedStateId( ply, id )
			if not stateId then
				local orient = tr.Hit and MC.OrientForPlacement( ply, tr, id ) or MC.DefaultOrient( id )
				stateId = MC.StateFromLegacy( id, orient )
			end
			local stateSpec = stateId and MC.FormatBlockState( stateId ) or ""
			local state = string.match( stateSpec, "%[(.*)%]$" ) or ""
			local w, h = 64, 64
			local panelW = 380
			local panelH = state ~= "" and 118 or 96
			local px = sw * 0.5 - panelW * 0.5
			local py = hotbarY - panelH - 14
			local x, y = px + 18, py + ( panelH - h ) * 0.5
			local tx = x + w + 18
			local maxTextW = panelW - ( tx - px ) - 18

			draw.RoundedBox( 6, px, py, panelW, panelH, Color( 0, 0, 0, 175 ) )
			if not stateId or not MC.DrawMinecraftBlockStateIcon or not MC.DrawMinecraftBlockStateIcon( stateId, x, y, w, h ) then
				MC.DrawMinecraftBlockIcon( id, x, y, w, h )
			end
			MC.DrawFittedText( blockDisplayText( b ), "mc_hud_big", { "mc_hud_fit_24", "mc_hud_fit_20", "mc_hud_fit_16" }, tx, py + 22, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, maxTextW )
			if state ~= "" then
				draw.SimpleText( state, "mc_hud_small", tx, py + 58, Color( 210, 230, 255 ), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
			end
		end
		if MC.DrawCreativeHotbar then
			MC.DrawCreativeHotbar( sw * 0.5, hotbarY, { slotSize = slotSize } )
		end
		draw.SimpleText( L( "weapon.mc_creative_placer.hud", "左键破坏    右键放置    中键取块(自动)    Shift+中键取数据    Reload 创造栏    Tab 切出" ), "mc_hud_small", sw * 0.5, sh - 10, Color( 255, 255, 255, 190 ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )

		surface.SetDrawColor( 255, 255, 255, 220 )
		surface.DrawRect( sw * 0.5 - 1, sh * 0.5 - 1, 2, 2 )
	end

	hook.Remove( "PostDrawTranslucentRenderables", "mc_creative_held_block" )
	hook.Add( "PreDrawViewModels", "mc_creative_held_block", function()
		local ply = LocalPlayer()
		if not IsValid( ply ) or not ply:Alive() or ply:ShouldDrawLocalPlayer() then return end
		local wep = ply:GetActiveWeapon()
		if not IsValid( wep ) or wep:GetClass() ~= "mc_creative_placer" then return end
		if not creativeHeldModelEnabled() then return end
		if not MC.DrawCreativeHeldBlock then return end
		drawFirstPersonHeldBlock( ply, wep )
	end )

	hook.Add( "PostDrawTranslucentRenderables", "mc_creative_ghost", function( _, bSky, bSky3D )
		-- bSky (DF_DRAWSKYBOX) is also true on the main pass on 2D-sky maps; skip only the 3D skybox pass
		if bSky3D then return end
		local ply = LocalPlayer()
		if not IsValid( ply ) or not ply:Alive() then return end
		local wep = ply:GetActiveWeapon()
		if not IsValid( wep ) or wep:GetClass() ~= "mc_creative_placer" then return end

		local aim = aimedBlock( ply )
		if not aim then return end
		MC.DrawBlockOutline( aim.Block, aim.Orient, aim.bx, aim.by, aim.bz, Color( 0, 0, 0, 235 ), aim.StateId )
	end )
end
