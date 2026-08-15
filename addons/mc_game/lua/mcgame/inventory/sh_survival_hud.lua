-- Pure Java-HUD unit conversion shared by the renderer and runtime tests.

MC = MC or {}

local GMOD_HP_PER_MINECRAFT_HALF_HEART = 5
local MCITEM_ABSORPTION_NW_KEY = "MCITEMAbsorptionAmount"
local PLAYER = FindMetaTable and FindMetaTable( "Player" ) or nil

-- Cross-addon health-unit contract. Minecraft health, absorption and damage
-- are expressed in points where the vanilla player maximum is 20; this game
-- layer intentionally keeps Source players at 100 HP, hence the fixed 5:1
-- conversion. MCITEM/BMB consumers can query this instead of guessing from
-- current Health()/GetMaxHealth(), which breaks temporary max-health effects.
if PLAYER then
	function PLAYER:GetMCMinecraftHealthScale()
		return GMOD_HP_PER_MINECRAFT_HALF_HEART
	end
end

function MC.GModHealthToMinecraftHalves( health )
	health = math.max( 0, tonumber( health ) or 0 )
	return math.ceil( health / GMOD_HP_PER_MINECRAFT_HALF_HEART )
end

-- MCITEM stores absorption in native Minecraft health points: one point is one
-- half-heart. Prefer an explicit Player contract when another game addon
-- provides one, then consume MCITEM's established replicated fallback. This
-- keeps the HUD read-only and avoids creating a second absorption authority.
function MC.PlayerMinecraftAbsorptionAmount( ply )
	if ply == nil then return 0 end
	if type( ply.GetMCAbsorptionAmount ) == "function" then
		local called, amount = pcall( ply.GetMCAbsorptionAmount, ply )
		if called and tonumber( amount ) ~= nil then return math.max( 0, tonumber( amount ) ) end
	end
	if type( ply.GetNW2Float ) == "function" then
		return math.max( 0, tonumber( ply:GetNW2Float( MCITEM_ABSORPTION_NW_KEY, 0 ) ) or 0 )
	end
	return 0
end

function MC.BuildSurvivalHeartLayout( maxHealth, currentHealth, oldHealth, absorption )
	maxHealth = math.max( 0, tonumber( maxHealth ) or 0 )
	local currentHalves = MC.GModHealthToMinecraftHalves( currentHealth )
	local oldHalves = MC.GModHealthToMinecraftHalves( oldHealth )
	local absorptionHalves = math.ceil( math.max( 0, tonumber( absorption ) or 0 ) )
	local maxHealthHalves = math.max(
		maxHealth / GMOD_HP_PER_MINECRAFT_HALF_HEART,
		currentHalves,
		oldHalves
	)
	local healthContainerCount = math.ceil( maxHealthHalves / 2 )
	local absorptionContainerCount = math.ceil( absorptionHalves / 2 )
	local containerCount = healthContainerCount + absorptionContainerCount
	local rowCount = math.max( 1, math.ceil( containerCount / 10 ) )
	return {
		currentHalves = currentHalves,
		oldHalves = oldHalves,
		absorptionHalves = absorptionHalves,
		maxHealthHalves = maxHealthHalves,
		maxHealthUnits = maxHealthHalves,
		healthContainerCount = healthContainerCount,
		absorptionContainerCount = absorptionContainerCount,
		maxHealthContainerHalves = healthContainerCount * 2,
		containerCount = containerCount,
		rowCount = rowCount,
		rowHeight = math.max( 10 - ( rowCount - 2 ), 3 ),
		hpPerHalfHeart = GMOD_HP_PER_MINECRAFT_HALF_HEART,
	}
end
