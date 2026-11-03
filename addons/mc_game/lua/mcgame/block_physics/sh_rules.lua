-- Source-verified block movement rules for gameplay-parity checkpoint 3.
--
-- Values are kept in Minecraft block/tick units here.  Runtime adapters do
-- the Source-unit conversion at their boundary so the constants and formulas
-- remain directly comparable with out/net/minecraft.

MC = MC or {}
MC.BlockPhysics = MC.BlockPhysics or {}

local P = MC.BlockPhysics

P.Constants = P.Constants or {
	tickSeconds = 1 / 20,
	defaultFriction = 0.6,
	defaultSpeedFactor = 1.0,
	defaultJumpFactor = 1.0,
	defaultAirDrag = 0.91,
	defaultVerticalDrag = 0.98,
	defaultGravity = 0.08,
	defaultJumpStrength = 0.42,
	defaultSafeFallDistance = 3.0,
	fallDistanceEpsilon = 0.000001,
	insideBoundsDeflate = 0.00001,

	iceFriction = 0.98,
	blueIceFriction = 0.989,
	slimeFriction = 0.8,
	slimeBounceRestitution = 1.0,
	nonLivingBounceScale = 0.8,
	slimeStepVerticalThreshold = 0.1,
	slimeStepBaseScale = 0.4,
	slimeStepVerticalScale = 0.2,

	honeySpeedFactor = 0.4,
	honeyJumpFactor = 0.5,
	honeyFallDamageModifier = 0.2,
	honeyCollisionWidth = 14 / 16,
	honeyCollisionHeight = 15 / 16,
	honeySlideVerticalThreshold = 0.08,
	honeySlideFastThreshold = 0.13,
	honeySlideTargetSpeed = 0.05,
	honeySlideAchievementTicks = 20,
	honeySlideEffectsChance = 1 / 5,
	honeyHorizontalHalfExtent = 7 / 16,
	honeySlideEpsilon = 0.0000001,

	webHorizontalMultiplier = 0.25,
	webVerticalMultiplier = 0.05,
	weavingHorizontalMultiplier = 0.5,
	weavingVerticalMultiplier = 0.25,

	soulSandSpeedFactor = 0.4,
	soulSandCollisionHeight = 14 / 16,
	soulSpeedBaseBonus = 0.0405,
	soulSpeedPerExtraLevel = 0.0105,
	soulSpeedMovementEfficiency = 1.0,
	soulSpeedDurabilityChancePerLevel = 0.04,
	soulSpeedPeriodicTicks = 5,
	soulSpeedSoundChance = 0.35,

	frictionAccelerationNumerator = 0.21600002,
	pistonMoveLimit = 12,
}

local C = P.Constants

P.BlockProperties = P.BlockProperties or {
	["minecraft:ice"] = { friction = C.iceFriction },
	["minecraft:packed_ice"] = { friction = C.iceFriction },
	["minecraft:frosted_ice"] = { friction = C.iceFriction },
	["minecraft:blue_ice"] = { friction = C.blueIceFriction },
	["minecraft:honey_block"] = {
		speedFactor = C.honeySpeedFactor,
		jumpFactor = C.honeyJumpFactor,
		suppressesBounce = true,
	},
	["minecraft:slime_block"] = {
		friction = C.slimeFriction,
		bounceRestitution = C.slimeBounceRestitution,
	},
	["minecraft:soul_sand"] = { speedFactor = C.soulSandSpeedFactor },
	["minecraft:soul_soil"] = {},
	["minecraft:cobweb"] = { noCollision = true },
}

P.SoulSpeedBlocks = P.SoulSpeedBlocks or {
	["minecraft:soul_sand"] = true,
	["minecraft:soul_soil"] = true,
}

if CreateConVar then
	local flags = FCVAR_ARCHIVE or 0
	if SERVER and bit and bit.bor then
		flags = bit.bor( flags, FCVAR_REPLICATED or 0, FCVAR_NOTIFY or 0 )
	end
	P.EnableConVar = GetConVar and GetConVar( "mc_gameplay_parity_block_physics" )
		or CreateConVar( "mc_gameplay_parity_block_physics", "0", flags,
			"Enable source-verified ice/honey/cobweb/soul/slime block physics." )
end

function P.Enabled()
	local cv = P.EnableConVar
	if not cv and GetConVar then cv = GetConVar( "mc_gameplay_parity_block_physics" ) end
	return cv and cv.GetBool and cv:GetBool() == true or false
end

function P.NormalizeBlockName( name )
	name = tostring( name or "" )
	if name == "" then return "minecraft:air" end
	return string.find( name, ":", 1, true ) and name or "minecraft:" .. name
end

function P.PropertiesFor( blockName )
	return P.BlockProperties[P.NormalizeBlockName( blockName )]
end

function P.FrictionFor( blockName )
	local properties = P.PropertiesFor( blockName )
	return properties and properties.friction or C.defaultFriction
end

function P.SpeedFactorFor( blockName )
	local properties = P.PropertiesFor( blockName )
	return properties and properties.speedFactor or C.defaultSpeedFactor
end

function P.JumpFactorFor( blockName )
	local properties = P.PropertiesFor( blockName )
	return properties and properties.jumpFactor or C.defaultJumpFactor
end

function P.BounceRestitutionFor( blockName, living )
	local properties = P.PropertiesFor( blockName )
	local restitution = properties and properties.bounceRestitution or 0
	if living ~= true then restitution = restitution * C.nonLivingBounceScale end
	return restitution
end

function P.BlockSuppressesBounce( blockName )
	local properties = P.PropertiesFor( blockName )
	return properties and properties.suppressesBounce == true or false
end

function P.MovementSpeedFactor( blockName, movementEfficiency )
	local factor = P.SpeedFactorFor( blockName )
	local efficiency = math.max( 0, math.min( 1, tonumber( movementEfficiency ) or 0 ) )
	return factor + ( 1 - factor ) * efficiency
end

function P.EffectiveJumpFactor( blockHere, blockBelow )
	local here = P.JumpFactorFor( blockHere )
	return here == C.defaultJumpFactor and P.JumpFactorFor( blockBelow ) or here
end

function P.GroundDrag( friction, airDrag )
	return ( tonumber( friction ) or C.defaultFriction ) * ( tonumber( airDrag ) or C.defaultAirDrag )
end

function P.FrictionAccelerationScale( friction )
	friction = tonumber( friction ) or C.defaultFriction
	if friction <= C.defaultFriction then return 1 end
	return C.frictionAccelerationNumerator / ( friction * friction * friction )
end

function P.PerTickFactor( factor, seconds )
	factor = math.max( 0, tonumber( factor ) or 0 )
	seconds = math.max( 0, tonumber( seconds ) or C.tickSeconds )
	if seconds == 0 or factor == 1 then return 1 end
	if factor == 0 then return 0 end
	return factor ^ ( seconds / C.tickSeconds )
end

-- Source owns collision and wish-move integration.  Reconstruct the input
-- portion from the normal Java recurrence, then replay it with the target
-- friction.  At friction 0.6 this is exactly an identity operation.
function P.AdaptHorizontalVelocity( previousX, previousY, resolvedX, resolvedY, friction, seconds )
	previousX, previousY = tonumber( previousX ) or 0, tonumber( previousY ) or 0
	resolvedX, resolvedY = tonumber( resolvedX ) or 0, tonumber( resolvedY ) or 0
	friction = tonumber( friction ) or C.defaultFriction
	seconds = math.max( 0, tonumber( seconds ) or C.tickSeconds )
	if friction == C.defaultFriction or seconds == 0 then return resolvedX, resolvedY end
	local normalDrag = P.PerTickFactor( P.GroundDrag( C.defaultFriction ), seconds )
	local targetDrag = P.PerTickFactor( P.GroundDrag( friction ), seconds )
	local accelerationScale = P.FrictionAccelerationScale( friction )
	local inputX = resolvedX - previousX * normalDrag
	local inputY = resolvedY - previousY * normalDrag
	return previousX * targetDrag + inputX * accelerationScale,
		previousY * targetDrag + inputY * accelerationScale
end

function P.WebMultiplier( hasWeaving )
	if hasWeaving == true then
		return C.weavingHorizontalMultiplier, C.weavingHorizontalMultiplier, C.weavingVerticalMultiplier
	end
	return C.webHorizontalMultiplier, C.webHorizontalMultiplier, C.webVerticalMultiplier
end

function P.ScaleVelocityPerTick( x, y, z, multiplierX, multiplierY, multiplierZ, seconds )
	local sx = P.PerTickFactor( multiplierX, seconds )
	local sy = P.PerTickFactor( multiplierY, seconds )
	local sz = P.PerTickFactor( multiplierZ, seconds )
	return ( tonumber( x ) or 0 ) * sx, ( tonumber( y ) or 0 ) * sy, ( tonumber( z ) or 0 ) * sz
end

function P.HoneyOldVerticalVelocity( velocity )
	return ( tonumber( velocity ) or 0 ) / C.defaultVerticalDrag + C.defaultGravity
end

function P.HoneyNewVerticalVelocity( velocity )
	return ( ( tonumber( velocity ) or 0 ) - C.defaultGravity ) * C.defaultVerticalDrag
end

-- Coordinate convention matches MineMod cells: x/y horizontal, z vertical.
function P.IsHoneySliding( context )
	context = context or {}
	if context.onGround == true then return false end
	local blockZ = tonumber( context.blockZ ) or 0
	local entityZ = tonumber( context.entityZ ) or 0
	if entityZ > blockZ + C.honeyCollisionHeight - C.honeySlideEpsilon then return false end
	local oldVertical = P.HoneyOldVerticalVelocity( context.velocityZ )
	if oldVertical >= -C.honeySlideVerticalThreshold then return false end
	local entityX, entityY = tonumber( context.entityX ) or 0, tonumber( context.entityY ) or 0
	local blockX, blockY = tonumber( context.blockX ) or 0, tonumber( context.blockY ) or 0
	local halfWidth = math.max( 0, tonumber( context.width ) or 0 ) / 2
	local overlapDistance = C.honeyHorizontalHalfExtent + halfWidth
	local dx = math.abs( blockX + 0.5 - entityX )
	local dy = math.abs( blockY + 0.5 - entityY )
	return dx + C.honeySlideEpsilon > overlapDistance
		or dy + C.honeySlideEpsilon > overlapDistance
end

function P.HoneySlideVelocity( x, y, z )
	x, y, z = tonumber( x ) or 0, tonumber( y ) or 0, tonumber( z ) or 0
	local oldVertical = P.HoneyOldVerticalVelocity( z )
	local horizontalScale = 1
	if oldVertical < -C.honeySlideFastThreshold then
		horizontalScale = -C.honeySlideTargetSpeed / oldVertical
	end
	return x * horizontalScale, y * horizontalScale,
		P.HoneyNewVerticalVelocity( -C.honeySlideTargetSpeed )
end

function P.SlimeStepScale( verticalVelocity, steppingCarefully )
	local vertical = math.abs( tonumber( verticalVelocity ) or 0 )
	if steppingCarefully == true or vertical >= C.slimeStepVerticalThreshold then return 1 end
	return C.slimeStepBaseScale + vertical * C.slimeStepVerticalScale
end

function P.RestituteVerticalVelocity( currentVelocity, movedVelocity, gravity, airDrag, restitution )
	currentVelocity = tonumber( currentVelocity ) or 0
	movedVelocity = tonumber( movedVelocity ) or 0
	gravity = tonumber( gravity ) or C.defaultGravity
	airDrag = tonumber( airDrag ) or C.defaultVerticalDrag
	restitution = math.max( 0, tonumber( restitution ) or 0 )
	if currentVelocity == 0 or restitution == 0 then return 0 end
	local portion = movedVelocity / currentVelocity
	portion = math.max( 0, math.min( 1, portion ) )
	local gravityCompensation = portion * gravity
	local effectiveDrag = 1 + ( airDrag - 1 ) * portion
	return ( gravityCompensation - currentVelocity ) * effectiveDrag * restitution
end

function P.SimpleBounceVelocity( incomingVelocity, blockName, living, suppressingBounce )
	if suppressingBounce == true or P.BlockSuppressesBounce( blockName ) then return 0 end
	local restitution = P.BounceRestitutionFor( blockName, living )
	return math.abs( tonumber( incomingVelocity ) or 0 ) * restitution
end

function P.FallDamage( fallDistance, damageModifier, safeFallDistance, multiplier )
	fallDistance = tonumber( fallDistance ) or 0
	damageModifier = tonumber( damageModifier ) or 1
	safeFallDistance = tonumber( safeFallDistance ) or C.defaultSafeFallDistance
	multiplier = tonumber( multiplier ) or 1
	local base = fallDistance + C.fallDistanceEpsilon - safeFallDistance
	return math.max( 0, math.floor( base * damageModifier * multiplier ) )
end

function P.SoulSpeedBonus( level )
	level = math.max( 0, math.floor( tonumber( level ) or 0 ) )
	if level <= 0 then return 0 end
	return C.soulSpeedBaseBonus + C.soulSpeedPerExtraLevel * ( level - 1 )
end

