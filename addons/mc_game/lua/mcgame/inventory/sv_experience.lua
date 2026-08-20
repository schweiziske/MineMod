-- Server-authoritative Minecraft Java experience state and integration API.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local API = MC.API or {}
local Sound = API.Sound or {}
local SV = MC.SV
local PLAYER = FindMetaTable( "Player" )
local INT_MAX = 2147483647
local INT_MIN = -2147483648
local TICKS_PER_SECOND = 20
local LEVEL_SOUND_DELAY_TICKS = 100
local LEVEL_SOUND_EVENT = "entity.player.levelup"

if type( API.RegisterEvents ) == "function" then
	API.RegisterEvents( "mc.game.experience", {
		["MC.PlayerExperienceChanged"] = {
			realm = "server",
			args = "ply, previous, current, context",
			desc = "the game layer committed a player's Minecraft experience state",
		},
	} )
end

local function clampedInteger( value, minimum, maximum )
	value = math.floor( tonumber( value ) or 0 )
	return math.Clamp( value, minimum, maximum )
end

local function normalizedProgress( value )
	value = tonumber( value ) or 0
	if value ~= value or value == math.huge or value == -math.huge then return 0 end
	return math.Clamp( value, 0, 0.999999999 )
end

local function ensureExperienceState( record )
	if not record then return nil end
	record.experienceTotal = clampedInteger( record.experienceTotal, 0, INT_MAX )
	record.experienceLevel = clampedInteger( record.experienceLevel, 0, INT_MAX )
	record.experienceProgress = normalizedProgress( record.experienceProgress )
	record.experienceRevision = clampedInteger( record.experienceRevision, 0, INT_MAX )
	return record
end

local function experienceSnapshot( record )
	ensureExperienceState( record )
	return {
		total = record.experienceTotal,
		level = record.experienceLevel,
		progress = record.experienceProgress,
		revision = record.experienceRevision,
	}
end

local function experienceStatesEqual( left, right )
	return left and right
		and left.total == right.total
		and left.level == right.level
		and left.progress == right.progress
end

local function copyContext( context, reason )
	local result = {}
	if type( context ) == "table" then
		for key, value in pairs( context ) do result[key] = value end
	end
	if result.reason == nil then result.reason = reason end
	return result
end

function SV.ExperienceNeededForLevel( level )
	level = clampedInteger( level, 0, INT_MAX )
	if level >= 30 then return 112 + ( level - 30 ) * 9 end
	if level >= 15 then return 37 + ( level - 15 ) * 5 end
	return 7 + level * 2
end

function SV.UpdatePlayerExperienceNetwork( record, context )
	record = ensureExperienceState( record )
	local ply = record and record.owner
	if not IsValid( ply ) then return false, "invalid_player" end
	ply:SetNWInt( "mc_experience_total", record.experienceTotal )
	ply:SetNWInt( "mc_experience_level", record.experienceLevel )
	ply:SetNWFloat( "mc_experience_progress", record.experienceProgress )
	return true
end

local function publishExperienceChange( record, previous, context )
	ensureExperienceState( record )
	local current = experienceSnapshot( record )
	if experienceStatesEqual( previous, current ) then return current, false end
	record.experienceRevision = math.min( record.experienceRevision + 1, INT_MAX )
	current.revision = record.experienceRevision
	record.dirty = true
	SV.UpdatePlayerExperienceNetwork( record, context )
	local eventOK, eventError = pcall( hook.Run, "MC.PlayerExperienceChanged", record.owner,
		previous, current, context or {} )
	if not eventOK and ErrorNoHalt then
		ErrorNoHalt( "[MC Experience] change listener failed: " .. tostring( eventError ) .. "\n" )
	end
	return current, true
end

local function playerAgeTicks( record )
	local now = SysTime and SysTime() or 0
	return math.max( 0, math.floor( ( now - ( tonumber( record.loadedAt ) or now ) ) * TICKS_PER_SECOND ) )
end

local function playLevelUpSound( record )
	local ply = record and record.owner
	local level = record and record.experienceLevel or 0
	if not IsValid( ply ) or level <= 0 or level % 5 ~= 0 then return end
	local tick = playerAgeTicks( record )
	local lastTick = math.max( 0, math.floor( tonumber( record.lastExperienceLevelSoundTick ) or 0 ) )
	if lastTick >= tick - LEVEL_SOUND_DELAY_TICKS then return end
	record.lastExperienceLevelSoundTick = tick
	if type( Sound.Play ) == "function" then
		local volume = math.min( level / 30, 1 ) * 0.75
		pcall( Sound.Play, LEVEL_SOUND_EVENT, ply:GetPos(), {
			volume = volume,
			pitch = 1,
			soundLevel = 75,
		} )
	end
end

local function giveExperienceLevelsOnRecord( record, amount, allowSound )
	amount = clampedInteger( amount, INT_MIN, INT_MAX )
	local level = record.experienceLevel + amount
	if level > INT_MAX then level = INT_MAX end
	record.experienceLevel = math.floor( level )
	if record.experienceLevel < 0 then
		record.experienceLevel = 0
		record.experienceProgress = 0
		record.experienceTotal = 0
	elseif allowSound and amount > 0 then
		playLevelUpSound( record )
	end
end

function SV.GetPlayerExperienceState( ply, create )
	if not IsValid( ply ) or not ply:IsPlayer() then return nil, "invalid_player" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, create ~= false ) or nil
	if not record then return nil, "inventory_not_loaded" end
	return experienceSnapshot( record )
end

function SV.AddPlayerExperience( ply, value, context )
	if not IsValid( ply ) or not ply:IsPlayer() then return false, "invalid_player" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply ) or nil
	if not ensureExperienceState( record ) then return false, "inventory_not_loaded" end
	local points = clampedInteger( value, INT_MIN, INT_MAX )
	if points == 0 then return true, experienceSnapshot( record ) end

	local previous = experienceSnapshot( record )
	local needed = SV.ExperienceNeededForLevel( record.experienceLevel )
	record.experienceProgress = record.experienceProgress + points / needed
	record.experienceTotal = math.Clamp( record.experienceTotal + points, 0, INT_MAX )

	while record.experienceProgress < 0 do
		local remaining = record.experienceProgress * SV.ExperienceNeededForLevel( record.experienceLevel )
		if record.experienceLevel > 0 then
			giveExperienceLevelsOnRecord( record, -1, false )
			record.experienceProgress = 1 + remaining / SV.ExperienceNeededForLevel( record.experienceLevel )
		else
			giveExperienceLevelsOnRecord( record, -1, false )
			record.experienceProgress = 0
		end
	end

	while record.experienceProgress >= 1 do
		local carried = ( record.experienceProgress - 1 ) * SV.ExperienceNeededForLevel( record.experienceLevel )
		giveExperienceLevelsOnRecord( record, 1, true )
		record.experienceProgress = carried / SV.ExperienceNeededForLevel( record.experienceLevel )
	end

	record.experienceProgress = normalizedProgress( record.experienceProgress )
	local current = publishExperienceChange( record, previous, copyContext( context, "add_experience" ) )
	return true, current
end

function SV.GivePlayerExperienceLevels( ply, amount, context )
	if not IsValid( ply ) or not ply:IsPlayer() then return false, "invalid_player" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply ) or nil
	if not ensureExperienceState( record ) then return false, "inventory_not_loaded" end
	amount = clampedInteger( amount, INT_MIN, INT_MAX )
	if amount == 0 then return true, experienceSnapshot( record ) end
	local previous = experienceSnapshot( record )
	giveExperienceLevelsOnRecord( record, amount, true )
	local current = publishExperienceChange( record, previous, copyContext( context, "give_experience_levels" ) )
	return true, current
end

function SV.PlayerHasExperienceLevels( ply, cost )
	cost = clampedInteger( cost, 0, INT_MAX )
	local state = SV.GetPlayerExperienceState( ply, false )
	return state ~= nil and state.level >= cost
end

function SV.TrySpendPlayerExperienceLevels( ply, cost, context )
	if not IsValid( ply ) or not ply:IsPlayer() then return nil, "invalid_player" end
	cost = clampedInteger( cost, 0, INT_MAX )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply ) or nil
	if not ensureExperienceState( record ) then return nil, "inventory_not_loaded" end
	if record.experienceLevel < cost then return nil, "insufficient_experience" end

	local previous = experienceSnapshot( record )
	if cost > 0 then
		giveExperienceLevelsOnRecord( record, -cost, false )
	end
	local current = publishExperienceChange( record, previous, copyContext( context, "spend_experience_levels" ) )
	return {
		player = ply,
		ownerId = record.ownerId,
		cost = cost,
		before = previous,
		after = current,
		revision = record.experienceRevision,
		noop = cost == 0,
	}
end

function SV.TakePlayerExperienceLevels( ply, cost, context )
	local token, err = SV.TrySpendPlayerExperienceLevels( ply, cost, context )
	if not token then return false, err end
	return true, token
end

function SV.RollbackPlayerExperienceSpend( token, context )
	if type( token ) ~= "table" or not IsValid( token.player ) then return false, "invalid_experience_token" end
	if token.noop then return true end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( token.player, false ) or nil
	if not ensureExperienceState( record ) or record.ownerId ~= token.ownerId then return false, "experience_owner_changed" end
	if record.experienceRevision ~= token.revision then return false, "experience_state_changed" end
	local current = experienceSnapshot( record )
	if not experienceStatesEqual( current, token.after ) then return false, "experience_state_changed" end

	record.experienceTotal = clampedInteger( token.before.total, 0, INT_MAX )
	record.experienceLevel = clampedInteger( token.before.level, 0, INT_MAX )
	record.experienceProgress = normalizedProgress( token.before.progress )
	publishExperienceChange( record, current, copyContext( context, "rollback_experience_levels" ) )
	return true
end

function PLAYER:GetMCExperienceLevel()
	local state = SV.GetPlayerExperienceState( self, false )
	return state and state.level or 0
end

function PLAYER:GetMCExperienceTotal()
	local state = SV.GetPlayerExperienceState( self, false )
	return state and state.total or 0
end

function PLAYER:GetMCExperienceProgress()
	local state = SV.GetPlayerExperienceState( self, false )
	return state and state.progress or 0
end

function PLAYER:AddMCExperience( value, context )
	return SV.AddPlayerExperience( self, value, context )
end

local MENDING_REPAIR_FACTOR = 2

local function stackMaxDamage( stack )
	if not stack then return 0 end
	if type( MC.ItemStackMaxDamage ) == "function" then
		return math.max( 0, math.floor( tonumber( MC.ItemStackMaxDamage( stack ) ) or 0 ) )
	end
	local definition = type( MC.GetItem ) == "function" and MC.GetItem( stack.item ) or nil
	return math.max( 0, math.floor( tonumber( definition and definition.maxDamage or stack.maxDamage ) or 0 ) )
end

local function ordinaryMendingLevel( stack )
	-- Mending is read from the ordinary `enchantments` component only.  In
	-- particular, an enchanted book's `stored_enchantments` must not make the
	-- book participate in runtime repair selection.
	if not stack or type( MC.GetItemEnchantments ) ~= "function" then return 0 end
	local levels = select( 1, MC.GetItemEnchantments( stack, false ) )
	if type( levels ) ~= "table" then return 0 end
	return math.max( 0,
		math.floor( tonumber( levels["minecraft:mending"] ) or tonumber( levels.mending ) or 0 ) )
end

local function isMendingCandidate( stack )
	if not stack or ( tonumber( stack.damage ) or 0 ) <= 0 then return false end
	if stackMaxDamage( stack ) <= 0 then return false end
	if type( MC.ItemIsUnbreakable ) == "function" and MC.ItemIsUnbreakable( stack ) then return false end
	return ordinaryMendingLevel( stack ) > 0
end

local function candidateStack( record, candidate )
	if not record or not candidate then return nil end
	if candidate.hand == "mainhand" then
		return record.storage and record.storage[candidate.selected + 1] or nil
	end
	return record.equipment and record.equipment[candidate.slot] or nil
end

local function appendMendingCandidate( candidates, record, candidate )
	local stack = candidateStack( record, candidate )
	if not isMendingCandidate( stack ) then return end
	candidate.mendingLevel = ordinaryMendingLevel( stack )
	candidates[#candidates + 1] = candidate
end

local function mendingCandidates( record )
	local candidates = {}
	local selected = math.Clamp( math.floor( tonumber( record and record.selected ) or 0 ), 0, 8 )

	-- EquipmentSlot.VALUES in Java 26.2 is mainhand, offhand, feet, legs,
	-- chest, head (the remaining animal slots are empty for players).  Keep
	-- this order so a deterministic test/random source observes the same
	-- candidate sequence.
	appendMendingCandidate( candidates, record, { hand = "mainhand", selected = selected } )
	appendMendingCandidate( candidates, record, { hand = "offhand", slot = "offhand" } )
	for _, slot in ipairs( { "feet", "legs", "chest", "head" } ) do
		appendMendingCandidate( candidates, record, { hand = "equipment", slot = slot } )
	end
	return candidates
end

local function restoreEquipmentSlot( record, slot, stack )
	if not record then return end
	record.equipment = record.equipment or {}
	record.equipment[slot] = MC.CopyItemStack( stack )
end

local function stackMatchesUseState( state, stack )
	if not state or not stack then return false end
	if state.stackHash and type( MC.ItemStackHash ) == "function" then
		return state.stackHash == MC.ItemStackHash( stack )
	end
	return state.itemName == stack.item
		and ( tonumber( state.damage ) or 0 ) == ( tonumber( stack.damage ) or 0 )
end

local function refreshItemUseAfterMending( record, candidate, before, after )
	local state = record and record.itemUse
	if not state or not after or state.hand ~= candidate.hand then return end
	if candidate.hand == "mainhand" and state.selected ~= candidate.selected then return end
	if not stackMatchesUseState( state, before ) then return end
	state.itemName = after.item
	state.damage = after.damage
	state.stackHash = type( MC.ItemStackHash ) == "function" and MC.ItemStackHash( after ) or nil
end

local function repairMendingCandidate( ply, record, candidate, xp, context )
	local before = candidateStack( record, candidate )
	if not isMendingCandidate( before ) then return false, "candidate_changed" end
	local damage = math.max( 0, math.floor( tonumber( before.damage ) or 0 ) )
	local capacity = math.max( 0, math.floor( xp * MENDING_REPAIR_FACTOR ) )
	if capacity <= 0 then return false, "no_repair_capacity" end
	local repaired = math.min( capacity, damage )
	if repaired <= 0 then return false, "no_repair" end
	local after = MC.CopyItemStack( before )
	if not after then return false, "invalid_candidate" end
	after.damage = damage - repaired
	if after.damage <= 0 then after.damage = nil end

	local commitContext = copyContext( context, "mending" )
	commitContext.player = commitContext.player or ply
	commitContext.hand = candidate.hand
	commitContext.slot = candidate.slot
	commitContext.repaired = repaired
	commitContext.experience = xp
	commitContext.mendingLevel = candidate.mendingLevel or ordinaryMendingLevel( before )

	if candidate.hand == "mainhand" then
		if type( MC.ContainerSnapshot ) ~= "function"
		or type( MC.ContainerSetStack ) ~= "function"
		or type( MC.ContainerRestore ) ~= "function"
		or type( SV.CommitPlayerInventoryMutation ) ~= "function"
		or not record.container then
			return false, "inventory_mutation_unavailable"
		end
		local snapshot = MC.ContainerSnapshot( record.container )
		local ok, setError = MC.ContainerSetStack( record.container, candidate.selected, after )
		if not ok then
			MC.ContainerRestore( record.container, snapshot )
			return false, setError or "mending_set_failed"
		end
		local result, commitError = SV.CommitPlayerInventoryMutation( record, snapshot, commitContext )
		if not result then
			MC.ContainerRestore( record.container, snapshot )
			return false, commitError or "mending_commit_failed"
		end
		refreshItemUseAfterMending( record, candidate, before, after )
		return repaired
	end

	if type( SV.EquipmentSnapshot ) ~= "function" or type( SV.CommitEquipmentMutation ) ~= "function" then
		return false, "equipment_mutation_unavailable"
	end
	local snapshot = SV.EquipmentSnapshot( record )
	if type( snapshot ) ~= "table" then return false, "equipment_snapshot_failed" end
	record.equipment = record.equipment or {}
	record.equipment[candidate.slot] = MC.CopyItemStack( after )
	local result, commitError = SV.CommitEquipmentMutation( record, snapshot, commitContext )
	if not result then
		restoreEquipmentSlot( record, candidate.slot, snapshot[candidate.slot] )
		return false, commitError or "mending_equipment_commit_failed"
	end
	refreshItemUseAfterMending( record, candidate, before, after )
	return repaired
end

function SV.RepairPlayerItemsWithExperience( ply, value, context )
	local remaining = clampedInteger( value, 0, INT_MAX )
	if remaining <= 0 or not IsValid( ply ) or not ply:IsPlayer() then return remaining end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if not record or type( record.storage ) ~= "table" or type( record.equipment ) ~= "table" then return remaining end

	-- Java's ExperienceOrb.repairPlayerItems recursively selects a fresh random
	-- candidate after every successful repair.  Rebuild the list each round so
	-- a stack that was fully repaired disappears immediately.
	while remaining > 0 do
		local candidates = mendingCandidates( record )
		if #candidates == 0 then return remaining end
		local pick = math.random( 1, #candidates )
		local candidate = candidates[pick]
		local repaired, repairError = repairMendingCandidate( ply, record, candidate, remaining, context )
		if not repaired then
			-- A failed authoritative mutation must not consume the orb.  A zero
			-- capacity/progress is only reachable through a malformed integration;
			-- Java's recursive implementation returns zero in that case.
			if repairError == "no_repair_capacity" or repairError == "no_repair" then return 0 end
			return remaining
		end
		-- Java computes `xp - repaired * xp / (xp * factor)` using integer
		-- division.  With mending's factor 2 this is exactly floor(repaired/2),
		-- including the intentional zero-cost one-point repair.
		local spent = math.floor( repaired / MENDING_REPAIR_FACTOR )
		remaining = math.max( 0, remaining - spent )
	end
	return remaining
end

function PLAYER:RepairMCItemsWithExperience( value, context )
	value = clampedInteger( value, 0, INT_MAX )
	if type( SV.RepairPlayerItemsWithExperience ) ~= "function" then return value end
	local remaining = SV.RepairPlayerItemsWithExperience( self, value, context )
	if not isnumber( remaining ) then return value end
	return math.Clamp( math.floor( remaining ), 0, value )
end

-- Player methods are the canonical path. Hooks remain as a load-order-safe
-- fallback for integrations which call the MCITEM contract directly.
hook.Add( "MCITEM.GiveExperience", "mc_inventory_give_experience", function( ply, value, context )
	return SV.AddPlayerExperience( ply, value, context )
end )

hook.Add( "MCITEM.RepairWithExperience", "mc_inventory_repair_with_experience", function( ply, value, context )
	if not IsValid( ply ) or not ply:IsPlayer() then return value end
	return ply:RepairMCItemsWithExperience( value, context )
end )

timer.Simple( 0, function()
	for _, ply in ipairs( player.GetAll() ) do
		local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
		if record then SV.UpdatePlayerExperienceNetwork( record, { reason = "experience_reload" } ) end
	end
end )
