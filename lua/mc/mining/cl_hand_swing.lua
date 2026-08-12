--[[----------------------------------------------------------------------------
	MC survival mining hand swing.

	Minecraft 26.2 calls player.swing(MAIN_HAND) on every successful
	continueDestroyBlock tick. LivingEntity.swing only restarts after the current
	swing reaches half of its duration, so a default six-tick item loops every
	three 20 TPS ticks while mining continues. This presentation module mirrors
	that cadence without touching the separate equip-height/place animation.
------------------------------------------------------------------------------]]

if not CLIENT then return end

MC = MC or {}
MC.HandMiningSwing = MC.HandMiningSwing or {}

local Swing = MC.HandMiningSwing
local TICK_SECONDS = 1 / 20
local DEFAULT_DURATION_TICKS = 6

Swing.TickSeconds = TICK_SECONDS
Swing.DefaultDurationTicks = DEFAULT_DURATION_TICKS

local function normalizedAmplifier( value )
	value = tonumber( value )
	if value == nil or value < 0 then return nil end
	return math.floor( value )
end

-- LivingEntity#getCurrentSwingDuration. Haste has priority over Mining Fatigue
-- because the Java method uses if (...) { ... } else if (...).
function Swing.DurationFromModifiers( modifiers )
	modifiers = istable( modifiers ) and modifiers or {}
	local duration = math.floor( tonumber( modifiers.baseDurationTicks ) or DEFAULT_DURATION_TICKS )
	local haste = normalizedAmplifier( modifiers.hasteAmplifier )
	local fatigue = normalizedAmplifier( modifiers.miningFatigueAmplifier )
	if haste ~= nil then
		duration = duration - ( 1 + haste )
	elseif fatigue ~= nil then
		duration = duration + ( 1 + fatigue ) * 2
	end
	return math.max( 1, duration )
end

function Swing.DurationTicks( ply, weapon )
	local defaults = {
		baseDurationTicks = DEFAULT_DURATION_TICKS,
		hasteAmplifier = nil,
		miningFatigueAmplifier = nil,
	}
	local supplied = hook.Run( "MC.HandSwingModifiers", ply, weapon, defaults )
	return Swing.DurationFromModifiers( istable( supplied ) and supplied or defaults )
end

local function stateFor( weapon )
	weapon.MCHandMiningSwingState = weapon.MCHandMiningSwingState or {}
	return weapon.MCHandMiningSwingState
end

-- Mirrors LivingEntity.swing: request every mining tick, restart only once the
-- current swingTime reaches duration / 2 (or the previous swing has ended).
function Swing.Request( weapon, bx, by, bz, now )
	if not IsValid( weapon ) then return false end
	local ply = weapon:GetOwner()
	if not IsValid( ply ) then return false end
	now = tonumber( now ) or CurTime()
	local state = stateFor( weapon )
	local durationTicks = Swing.DurationTicks( ply, weapon )
	local elapsedTicks = state.startedAt and ( now - state.startedAt ) / TICK_SECONDS or math.huge
	if not state.active or elapsedTicks < 0 or elapsedTicks >= durationTicks / 2 then
		state.startedAt = now
		state.active = true
	end
	state.durationTicks = durationTicks
	state.bx, state.by, state.bz = bx, by, bz
	state.lastRequestAt = now
	return true
end

function Swing.Begin( weapon, bx, by, bz )
	return Swing.Request( weapon, bx, by, bz, CurTime() )
end

function Swing.Progress( weapon, now )
	if not IsValid( weapon ) then return 0 end
	local state = weapon.MCHandMiningSwingState
	if not state or not state.active or not state.startedAt then return 0 end
	now = tonumber( now ) or CurTime()
	local duration = math.max( 1, tonumber( state.durationTicks ) or DEFAULT_DURATION_TICKS ) * TICK_SECONDS
	local progress = ( now - state.startedAt ) / duration
	if progress < 0 or progress >= 1 then
		state.active = false
		return 0
	end
	return progress
end

local function localMiningCrack( ply )
	local cracks = MC.ClientMiningCracks
	return cracks and cracks[ply:EntIndex()] or nil
end

local function stillAimingAt( ply, crack )
	if not crack or not MC.PlayerBlockAim then return false end
	local aim = MC.PlayerBlockAim( ply )
	return aim and aim.bx == crack.bx and aim.by == crack.by and aim.bz == crack.bz
end

local function continueLocalMiningSwing( tickTime )
	local ply = LocalPlayer()
	if not IsValid( ply ) or not ply:Alive() or not ply:KeyDown( IN_ATTACK ) then return end
	if ply:GetNWBool( "mc_item_using", false ) then return end
	local weapon = ply:GetActiveWeapon()
	if not IsValid( weapon ) or weapon:GetClass() ~= "mc_item_hand" then return end
	local crack = localMiningCrack( ply )
	if not stillAimingAt( ply, crack ) then return end
	Swing.Request( weapon, crack.bx, crack.by, crack.bz, tickTime )
end

local nextSwingTick = 0
hook.Add( "Think", "mc_survival_mining_hand_swing", function()
	local now = CurTime()
	if nextSwingTick <= 0 or now - nextSwingTick > 0.25 then nextSwingTick = now end
	local steps = 0
	while now >= nextSwingTick and steps < 5 do
		continueLocalMiningSwing( nextSwingTick )
		nextSwingTick = nextSwingTick + TICK_SECONDS
		steps = steps + 1
	end
end )

