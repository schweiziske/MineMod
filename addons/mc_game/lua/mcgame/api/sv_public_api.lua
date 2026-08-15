-- Public survival-game API surfaces. The voxel engine owns MC.API itself, but
-- item, inventory, mining, fire-tool and shears behavior is supplied only when
-- the separately shipped game addon is installed.

if not SERVER then return end

MC = MC or {}
MC.API = MC.API or {}

local API = MC.API
local World = API.World
local deepCopy = API.DeepCopy
local resolveStateInput = API.ResolveStateInput

local function SV()
	return MC.SV
end

local function cellCoords( bx, by, bz )
	local x, y, z = tonumber( bx ), tonumber( by ), tonumber( bz )
	if not x or not y or not z then return nil end
	if x ~= x or y ~= y or z ~= z then return nil end
	return math.floor( x ), math.floor( y ), math.floor( z )
end

--------------------------------------------------------------------- API.Fire
API.Fire = API.Fire or {}
local Fire = API.Fire

-- Returns ok, resultOrError.  result is a fresh table containing the committed
-- cell and selected fire type.  MCITEM deliberately cannot set arbitrary world
-- state through this surface.
function Fire.Ignite( ply, context )
	local sv = SV()
	if not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() or not ply:Alive() then
		return false, "invalid_player"
	end
	if not sv or not sv.IgnitePlayerAim then return false, "fire_api_unavailable" end
	local ok, resultOrError = sv.IgnitePlayerAim( ply, deepCopy( context or {} ) )
	if ok ~= true then return false, resultOrError or "ignite_failed" end
	return true, deepCopy( resultOrError )
end

-- Resolver-driven external flint-and-steel SWEPs use this entry point instead
-- of composing Fire.Ignite + Inventory.DamageSelected.  The game layer binds
-- the world write and selected-stack durability into one server transaction;
-- an inventory rejection leaves the world unchanged.
function Fire.UseFlintAndSteel( ply, context )
	local sv = SV()
	if not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() or not ply:Alive() then
		return false, "invalid_player"
	end
	if not sv or not sv.UseSelectedFlintAndSteel then return false, "fire_api_unavailable" end
	local ok, resultOrError = sv.UseSelectedFlintAndSteel( ply, deepCopy( context or {} ) )
	if ok ~= true then return false, resultOrError or "ignite_failed" end
	return true, deepCopy( resultOrError )
end

-- Place BaseFireBlock.getState at the adjacent cell of a real Minecraft block
-- impact.  The public surface cannot choose an arbitrary state or cell; the
-- game layer also enforces player-owner edit protection through
-- ProjectileMayInteract.  Returns a fresh result without the write transaction.
function Fire.PlaceProjectileImpact( projectile, hitPos, hitNormal, context )
	local sv = SV()
	if not IsValid( projectile ) then return false, "invalid_projectile" end
	if not isvector( hitPos ) or not isvector( hitNormal ) then return false, "invalid_impact" end
	if not sv or not sv.IgniteProjectileImpact then return false, "fire_api_unavailable" end
	local ok, resultOrError = sv.IgniteProjectileImpact(
		projectile,
		Vector( hitPos.x, hitPos.y, hitPos.z ),
		Vector( hitNormal.x, hitNormal.y, hitNormal.z ),
		deepCopy( context or {} )
	)
	if ok ~= true then return false, resultOrError or "ignite_failed" end
	return true, {
		bx = resultOrError.bx,
		by = resultOrError.by,
		bz = resultOrError.bz,
		stateId = resultOrError.stateId,
		source = resultOrError.source,
		reason = resultOrError.reason,
	}
end

------------------------------------------------------------------- API.Shears
API.Shears = API.Shears or {}
local Shears = API.Shears

-- Standalone external SWEP path: validates the player's current block aim and
-- performs only the constrained age=25 GrowingPlantHeadBlock transition.
function Shears.MaxAgePlant( ply, context )
	local sv = SV()
	if not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() or not ply:Alive() then
		return false, "invalid_player"
	end
	if not sv or not sv.MaxAgePlayerPlantAim then return false, "shears_api_unavailable" end
	local ok, resultOrError = sv.MaxAgePlayerPlantAim( ply, deepCopy( context or {} ) )
	if ok ~= true then return false, resultOrError or "shears_use_failed" end
	return true, deepCopy( resultOrError )
end

-- Inventory-proxy path: binds the age transition and selected shears damage
-- into the same pre-publication world transaction. Creative/infinite-material
-- mode preserves the selected stack exactly, matching ItemStack.hurtAndBreak.
function Shears.UseSelectedOnBlock( ply, context )
	local sv = SV()
	if not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() or not ply:Alive() then
		return false, "invalid_player"
	end
	if not sv or not sv.UseSelectedShearsOnBlock then return false, "shears_api_unavailable" end
	local ok, resultOrError = sv.UseSelectedShearsOnBlock( ply, deepCopy( context or {} ) )
	if ok ~= true then return false, resultOrError or "shears_use_failed" end
	return true, deepCopy( resultOrError )
end

local BUCKET_OWN_COLLISION = {
	mc_chunk = true,
	mc_chunk_phys = true,
	mc_collision_carrier = true,
}

------------------------------------------------------------------- API.Mining
-- Public, tool-agnostic survival mining. External SWEPs provide only an item
-- id/stack and their active weapon entity; MCSWEP remains authoritative for
-- reach, block state, vanilla speed, crack stages, loot and the transaction.
API.Mining = API.Mining or {}
local Mining = API.Mining

local function validMiningPlayer( ply )
	return IsValid( ply ) and ply.IsPlayer and ply:IsPlayer()
end

local function normalizeMiningStack( input )
	if input == nil then return nil end
	if isstring( input ) then
		if input == "" then return nil, "invalid_item" end
		return { item = string.find( input, ":", 1, true ) and input or "minecraft:" .. input, count = 1 }
	end
	if not istable( input ) or not isstring( input.item ) or input.item == "" then return nil, "invalid_item" end
	return deepCopy( input )
end

function Mining.Start( ply, bx, by, bz, options )
	local sv = SV()
	if not validMiningPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.BeginMining then return false, "mining_api_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	options = istable( options ) and options or {}
	local stack, stackError = normalizeMiningStack( options.toolStack or options.item )
	if stackError then return false, stackError end
	local weapon = options.weapon
	if not IsValid( weapon ) then return false, "invalid_weapon" end
	return sv.BeginMining( ply, x, y, z, {
		external = true,
		toolStack = stack,
		weapon = weapon,
		sourceId = options.sourceId,
		sourceToken = options.sourceToken,
		requireAttackHeld = options.requireAttackHeld,
		requireAim = options.requireAim,
		modifiers = istable( options.modifiers ) and deepCopy( options.modifiers ) or nil,
		onCancel = isfunction( options.onCancel ) and options.onCancel or nil,
		onComplete = isfunction( options.onComplete ) and options.onComplete or nil,
		onDurabilityDamage = isfunction( options.onDurabilityDamage ) and options.onDurabilityDamage or nil,
		validate = isfunction( options.validate ) and options.validate or nil,
	} )
end

function Mining.Cancel( ply, reason )
	local sv = SV()
	if not validMiningPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.CancelMining then return false, "mining_api_unavailable" end
	return sv.CancelMining( ply, tostring( reason or "external_cancel" ) )
end

function Mining.Get( ply )
	local sv = SV()
	if not validMiningPlayer( ply ) then return nil, "invalid_player" end
	if not sv or not sv.GetMiningSession then return nil, "mining_api_unavailable" end
	return deepCopy( sv.GetMiningSession( ply ) )
end

function Mining.ProgressPerTick( ply, bx, by, bz, item, modifiers )
	if not validMiningPlayer( ply ) then return nil, "invalid_player" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil, "invalid_cell" end
	local stack, stackError = normalizeMiningStack( item )
	if stackError then return nil, stackError end
	local stateId = World and World.GetBlockState and World.GetBlockState( x, y, z ) or 0
	if stateId == 0 then return nil, "air" end
	if not MC.BlockMiningProgressPerTick then return nil, "mining_rules_unavailable" end
	local progress, err, mining, resolvedModifiers = MC.BlockMiningProgressPerTick(
		stateId, stack, ply, istable( modifiers ) and deepCopy( modifiers ) or nil )
	if not progress then return nil, err end
	return progress, nil, deepCopy( mining ), deepCopy( resolvedModifiers )
end

-- Resolve the vanilla block loot for an arbitrary state/tool without changing
-- the world.  Unlike player mining this mirrors BlockState#getDrops directly:
-- the loot table's own match_tool predicates decide correctness, so the
-- survival mining precheck is deliberately bypassed.  Returned stacks and
-- metadata are fresh copies.
function Mining.ResolveDrops( block, toolStack, context )
	local sv = SV()
	if not sv or not sv.ResolveBlockDrops then return nil, "mining_api_unavailable" end
	local stateId, stateError = resolveStateInput( block )
	if stateId == nil then return nil, stateError or "invalid_state" end
	if stateId == 0 then return {}, nil end
	local stack, stackError = normalizeMiningStack( toolStack )
	if stackError then return nil, stackError end
	local copy = istable( context ) and deepCopy( context ) or {}
	copy.skipCorrectToolCheck = true
	local drops, err, mining = sv.ResolveBlockDrops( stateId, stack, copy )
	if not drops then return nil, err or "block_loot_failed" end
	return deepCopy( drops ), err, deepCopy( mining )
end

function Mining.IsCreative( ply )
	local sv = SV()
	if not validMiningPlayer( ply ) then return false, "invalid_player" end
	return sv and sv.PlayerIsCreative and sv.PlayerIsCreative( ply ) == true or false
end

function Mining.BreakCreative( ply, bx, by, bz, options )
	local sv = SV()
	if not validMiningPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.TryCreativeBreak then return false, "mining_api_unavailable" end
	if not ( sv.PlayerIsCreative and sv.PlayerIsCreative( ply ) ) then return false, "not_creative" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	return sv.TryCreativeBreak( ply, x, y, z, istable( options ) and deepCopy( options ) or nil )
end

----------------------------------------------------------------- API.Inventory
API.Inventory = API.Inventory or {}
local Inventory = API.Inventory

local function validInventoryPlayer( ply )
	return IsValid( ply ) and ply.IsPlayer and ply:IsPlayer()
end

function Inventory.Get( ply )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, "invalid_player" end
	if not sv or not sv.GetPlayerInventoryRecord then return nil, "inventory_api_unavailable" end
	local record = sv.GetPlayerInventoryRecord( ply )
	if not record then return nil, "inventory_not_loaded" end
	local result = { selected = record.selected, revision = record.container.revision, slots = {} }
	for slot = 0, 35 do result.slots[slot] = deepCopy( record.storage[slot + 1] ) end
	return result
end

function Inventory.GetSlot( ply, slot )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, "invalid_player" end
	slot = math.floor( tonumber( slot ) or -1 )
	if slot < 0 or slot > 35 then return nil, "invalid_slot" end
	if not sv or not sv.GetPlayerInventoryStack then return nil, "inventory_api_unavailable" end
	return deepCopy( sv.GetPlayerInventoryStack( ply, slot ) )
end

function Inventory.GetSelected( ply )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, nil, "invalid_player" end
	if not sv or not sv.GetPlayerInventoryRecord or not sv.GetSelectedPlayerStack then
		return nil, nil, "inventory_api_unavailable"
	end
	local record = sv.GetPlayerInventoryRecord( ply, false )
	if not record then return nil, nil, "inventory_not_loaded" end
	return deepCopy( sv.GetSelectedPlayerStack( ply ) ), record.selected
end

function Inventory.Give( ply, item, count, components, damage )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return 0, nil, "invalid_player" end
	if not sv or not sv.InsertPlayerItem then return 0, nil, "inventory_api_unavailable" end
	local stack, err = MC.NewItemStack( item, count or 1, components, damage )
	if not stack then return 0, nil, err or "invalid_stack" end
	local remainder, result = sv.InsertPlayerItem( ply, stack, { reason = "api_give" } )
	if result == nil then return 0, stack, "inventory_insert_failed" end
	local remainingCount = remainder and remainder.count or 0
	return stack.count - remainingCount, deepCopy( remainder )
end

function Inventory.Remove( ply, item, count )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return 0, "invalid_player" end
	if not sv or not sv.RemovePlayerItem then return 0, "inventory_api_unavailable" end
	return sv.RemovePlayerItem( ply, item, count or 1, { reason = "api_remove" } )
end

function Inventory.Select( ply, slot )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.SetPlayerSelectedSlot then return false, "inventory_api_unavailable" end
	return sv.SetPlayerSelectedSlot( ply, slot, { reason = "api_select" } )
end

function Inventory.DamageSelected( ply, amount, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, false, "invalid_player" end
	if not sv or not sv.DamageSelectedItem then return nil, false, "inventory_api_unavailable" end
	local result, broken, err = sv.DamageSelectedItem( ply, amount, deepCopy( context or {} ) )
	return deepCopy( result ), broken == true, err
end

-- Atomically applies a non-breaking durability use and extracts one complete
-- copy of the selected ItemStack.  Used by external trident implementations so
-- damage/components travel with the projectile and return unchanged on pickup.
-- Returns stack, infinite, mutationResult, err.  In infinite-material mode the
-- selected slot is unchanged and the returned projectile stack is still a copy.
function Inventory.TakeSelectedWithDurability( ply, amount, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, false, nil, "invalid_player" end
	if not sv or not sv.TakeSelectedItemWithDurability then
		return nil, false, nil, "inventory_api_unavailable"
	end
	local stack, infinite, result, err = sv.TakeSelectedItemWithDurability(
		ply,
		amount,
		deepCopy( context or {} )
	)
	return deepCopy( stack ), infinite == true, deepCopy( result ), err
end

function Inventory.CanTakeSelectedWithDurability( ply, amount, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, false, nil, "invalid_player" end
	if not sv or not sv.CanTakeSelectedItemWithDurability then
		return false, false, nil, "inventory_api_unavailable"
	end
	local allowed, infinite, stack, err = sv.CanTakeSelectedItemWithDurability(
		ply,
		amount,
		deepCopy( context or {} )
	)
	return allowed == true, infinite == true, deepCopy( stack ), err
end

-- context.consumeInInfiniteMaterials=true mirrors Java ItemUtils.createFilledResult
-- with limitCreativeStackSize=false: the selected item is genuinely consumed
-- even when the player otherwise has infinite materials.
function Inventory.ConsumeSelected( ply, amount, replacement, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, 0, nil, false, "invalid_player" end
	if not sv or not sv.ConsumeSelectedItem then return nil, 0, nil, false, "inventory_api_unavailable" end
	local result, consumed, overflow, infinite, err = sv.ConsumeSelectedItem(
		ply,
		amount,
		deepCopy( replacement ),
		deepCopy( context or {} )
	)
	return deepCopy( result ), consumed, deepCopy( overflow ), infinite == true, err
end

-- Atomically consumes a real item from mainhand/offhand, including in creative
-- mode. Intended for Java mechanics such as death protection whose source code
-- directly shrinks the held stack. Returns result, consumed, oldStack, err.
function Inventory.ConsumeHeld( ply, hand, amount, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, 0, nil, "invalid_player" end
	if not sv or not sv.ConsumeHeldItem then return nil, 0, nil, "inventory_api_unavailable" end
	local copy = deepCopy( context or {} )
	copy.hand = hand
	local result, consumed, oldStack, err = sv.ConsumeHeldItem(
		ply,
		amount,
		copy
	)
	return deepCopy( result ), consumed, deepCopy( oldStack ), err
end

function Inventory.ReplaceSelected( ply, replacement, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, nil, "invalid_player" end
	if not sv or not sv.ReplaceSelectedItem then return nil, nil, "inventory_api_unavailable" end
	local result, stack, err = sv.ReplaceSelectedItem(
		ply, deepCopy( replacement ), deepCopy( context or {} ) )
	return deepCopy( result ), deepCopy( stack ), err
end

function Inventory.HasInfiniteMaterials( ply )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.PlayerHasInfiniteMaterials then
		return false, "inventory_api_unavailable"
	end
	return sv.PlayerHasInfiniteMaterials( ply ) == true
end

function Inventory.Open( ply )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.OpenPlayerInventory then return false, "inventory_api_unavailable" end
	return sv.OpenPlayerInventory( ply, "api" )
end

-- Projectile ammo for external bow/crossbow SWEPs. kind is "bow" (arrow /
-- spectral arrow) or "crossbow" (also firework rockets). Creative players
-- report ammo without owning any and never consume it.
function Inventory.HasAmmo( ply, kind )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.FindProjectileAmmo then return false, "inventory_api_unavailable" end
	if sv.PlayerHasInfiniteMaterials and sv.PlayerHasInfiniteMaterials( ply ) then return true end
	local _, stack, err = sv.FindProjectileAmmo( ply, kind )
	if not stack then return false, err end
	return true, nil, deepCopy( stack )
end

-- Selects the same complete ammo ItemStack the built-in projectile path would
-- use. Infinite-material players still prefer an owned arrow type; only an
-- actually empty inventory falls back to a generated normal arrow.
-- Returns stack, slot, infinite, generated, err.
function Inventory.SelectAmmo( ply, kind )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, nil, false, false, "invalid_player" end
	if not sv or not sv.SelectProjectileAmmo then return nil, nil, false, false, "inventory_api_unavailable" end
	local stack, slot, infinite, generated, err = sv.SelectProjectileAmmo( ply, kind )
	return deepCopy( stack ), slot, infinite == true, generated == true, err
end

-- Compatibility wrapper. Returns consumed, itemName, err, infinite, stack.
function Inventory.ConsumeAmmo( ply, kind, amount, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return 0, nil, "invalid_player" end
	if not sv or not sv.ConsumeProjectileAmmo then return 0, nil, "inventory_api_unavailable" end
	local consumed, itemName, err, infinite, stack = sv.ConsumeProjectileAmmo(
		ply, kind, amount, deepCopy( context or {} )
	)
	return consumed, itemName, err, infinite, deepCopy( stack )
end

-- Atomically selects and (outside infinite-material mode) consumes projectile
-- ammunition. Returns stack, consumed, infinite, generated, err.
function Inventory.TakeAmmo( ply, kind, amount, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, 0, false, false, "invalid_player" end
	if not sv or not sv.TakeProjectileAmmo then return nil, 0, false, false, "inventory_api_unavailable" end
	local stack, consumed, infinite, generated, err = sv.TakeProjectileAmmo(
		ply, kind, amount, deepCopy( context or {} )
	)
	return deepCopy( stack ), consumed, infinite == true, generated == true, err
end

-- Atomically selects one projectile and stores it in the selected crossbow's
-- charged_projectiles component. Returns stack, infinite, generated, result,
-- err. `kind="bow"` intentionally excludes firework rockets.
function Inventory.LoadCrossbowProjectile( ply, kind, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, false, false, nil, "invalid_player" end
	if not sv or not sv.LoadSelectedCrossbowProjectile then
		return nil, false, false, nil, "inventory_api_unavailable"
	end
	local stack, infinite, generated, result, err = sv.LoadSelectedCrossbowProjectile(
		ply,
		kind,
		deepCopy( context or {} )
	)
	return deepCopy( stack ), infinite == true, generated == true, deepCopy( result ), err
end

-- Atomically clears charged_projectiles and damages the selected crossbow.
-- The external projectile must be removed when this call fails.
function Inventory.CommitCrossbowShot( ply, durabilityAmount, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, false, nil, false, "invalid_player" end
	if not sv or not sv.CommitSelectedCrossbowShot then
		return nil, false, nil, false, "inventory_api_unavailable"
	end
	local result, broken, projectile, infinite, err = sv.CommitSelectedCrossbowShot(
		ply,
		durabilityAmount,
		deepCopy( context or {} )
	)
	return deepCopy( result ), broken == true, deepCopy( projectile ), infinite == true, err
end

-- Public selected-item use bridge for resolver-driven external SWEPs. These
-- are the same state-machine functions used by mc_item_hand, but every call is
-- pinned to the caller-supplied active SWEP class. The private allowAnyWeapon
-- flag is never accepted without that exact-class assertion.
local function externalUseContext( ply, context )
	local copy = deepCopy( context or {} )
	local expectedClass = tostring( copy.expectedClass or "" )
	if expectedClass == "" then return nil, "expected_weapon_class_missing" end
	local weapon = IsValid( ply ) and ply.GetActiveWeapon and ply:GetActiveWeapon() or nil
	if not IsValid( weapon ) or not weapon.GetClass or weapon:GetClass() ~= expectedClass then
		return nil, "active_weapon_mismatch"
	end
	copy.expectedClass = expectedClass
	copy.allowAnyWeapon = true
	return copy
end

function Inventory.BeginSelectedUse( ply, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.BeginSelectedItemUse then return false, "inventory_api_unavailable" end
	local useContext, contextError = externalUseContext( ply, context )
	if not useContext then return false, contextError end
	return sv.BeginSelectedItemUse( ply, useContext )
end

function Inventory.TickSelectedUse( ply, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.TickSelectedItemUse then return false, "inventory_api_unavailable" end
	local useContext, contextError = externalUseContext( ply, context )
	if not useContext then return false, contextError end
	return sv.TickSelectedItemUse( ply, useContext )
end

function Inventory.ReleaseSelectedUse( ply, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.ReleaseSelectedItemUse then return false, "inventory_api_unavailable" end
	local useContext, contextError = externalUseContext( ply, context )
	if not useContext then return false, contextError end
	return sv.ReleaseSelectedItemUse( ply, useContext )
end

function Inventory.CancelSelectedUse( ply, reason )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.CancelSelectedItemUse then return false, "inventory_api_unavailable" end
	return sv.CancelSelectedItemUse( ply, tostring( reason or "external_cancelled" ) )
end

function Inventory.IsShieldDisabled( ply )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.IsPlayerShieldDisabled then return false, "inventory_api_unavailable" end
	return sv.IsPlayerShieldDisabled( ply ) == true, nil,
		math.max( 0, ( tonumber( ply:GetNWFloat( "mc_shield_disabled_until", 0 ) ) or 0 ) - CurTime() )
end

-- Spawn a world item drop (the same mc_item_drop entity block loot and player
-- drops use), so external addons never have to invent their own pickup entity.
-- options: { velocity = Vector, pickupDelay = seconds, lifetime = seconds
--            (<=0 means never expire), target = ply (owner-only pickup) }.
function Inventory.SpawnDrop( position, item, count, actor, options )
	local sv = SV()
	if not sv or not sv.SpawnItemDrop then return nil, "inventory_api_unavailable" end
	if not isvector( position ) then return nil, "invalid_position" end
	local stack, stackError = MC.NewItemStack( item, count or 1 )
	if not stack then return nil, stackError or "invalid_stack" end
	local ent, err = sv.SpawnItemDrop( position, stack, actor, deepCopy( options or {} ) )
	if not IsValid( ent ) then return nil, err or "item_drop_failed" end
	return ent
end

-- Full-ItemStack twin of SpawnDrop.  This is the path for damaged or component-
-- bearing items (thrown tridents, potion stacks, enchanted equipment, etc.).
function Inventory.SpawnDropStack( position, input, actor, options )
	local sv = SV()
	if not sv or not sv.SpawnItemDrop then return nil, "inventory_api_unavailable" end
	if not isvector( position ) then return nil, "invalid_position" end
	local stack, stackError = MC.NormalizeItemStack( deepCopy( input ) )
	if not stack then return nil, stackError or "invalid_stack" end
	local ent, err = sv.SpawnItemDrop( position, stack, actor, deepCopy( options or {} ) )
	if not IsValid( ent ) then return nil, err or "item_drop_failed" end
	return ent
end


API.RegisterCapability( "mc.game.fire", 1, Fire, "mc.game" )
API.RegisterCapability( "mc.game.shears", 1, Shears, "mc.game" )
API.RegisterCapability( "mc.game.mining", 1, Mining, "mc.game" )
API.RegisterCapability( "mc.game.inventory", 1, Inventory, "mc.game" )

if API.HandWeapon then
	API.HandWeapon.RegisterSelectionProvider( "mc.game.server_inventory", {
		GetSelected = function( ply )
			local sv = SV()
			return sv and sv.GetSelectedPlayerStack and sv.GetSelectedPlayerStack( ply ) or nil
		end,
		IsSessionOpen = function( ply )
			local sv = SV()
			local record = sv and sv.GetPlayerInventoryRecord and sv.GetPlayerInventoryRecord( ply, false ) or nil
			return record and record.session ~= nil or false
		end,
	}, 100 )
end

hook.Add( "MC.PlayerHeldItemChanged", "mcgame_hand_weapon_reconcile", function( ply, _, stack, context )
	if not API.HandWeapon or not API.HandWeapon.QueueRefresh then return end
	local copy = deepCopy( context or {} )
	copy.allowMissingWeapon = true
	API.HandWeapon.QueueRefresh( ply, stack, copy )
end )

hook.Add( "MC.PlayerGameModeChanged", "mcgame_game_mode_cleanup", function( ply )
	local sv = SV()
	if not sv then return end
	if sv.CancelMining then sv.CancelMining( ply, "game_mode_changed" ) end
	if sv.CancelSelectedItemUse then sv.CancelSelectedItemUse( ply, "game_mode_changed" ) end
	local record = sv.GetPlayerInventoryRecord and sv.GetPlayerInventoryRecord( ply, false ) or nil
	if sv.ClosePlayerInventory and record and record.session then
		sv.ClosePlayerInventory( ply, "game_mode_changed" )
	end
end )

hook.Add( "PlayerDisconnected", "mcgame_public_api_cleanup", function( ply )
	local sv = SV()
	if sv and sv.MiningSessions then sv.MiningSessions[ply] = nil end
end )

hook.Add( "MC.PlayerBrokeBlock", "mcgame_engine_break_durability", function( ply, _, _, _, _, context )
	if not context or context.damageTool ~= true then return end
	local sv = SV()
	if sv and sv.DamageSelectedItem then
		sv.DamageSelectedItem( ply, 1, {
			reason = tostring( context.reason or "mine" ),
			useToolScale = true,
		} )
	end
end )

hook.Add( "MC.MinecraftVehicleDestroyed", "mcgame_vehicle_item_drop", function( _, snapshot )
	if type( snapshot ) ~= "table" or snapshot.suppressDrop == true then return end
	if type( snapshot.dropItem ) ~= "string" or snapshot.dropItem == "" then return end
	if not isvector( snapshot.position ) then return end
	Inventory.SpawnDrop( snapshot.position, snapshot.dropItem, 1, snapshot.attacker, {
		pickupDelay = 0.5,
		velocity = isvector( snapshot.velocity ) and snapshot.velocity or nil,
		reason = "vehicle_destroyed",
	} )
end )

net.Receive( "mc_block_use_request", function( _, ply )
	if API.Player and API.Player.UseAimedBlock then API.Player.UseAimedBlock( ply ) end
end )
