# Developer API (v2)

English | [简体中文](zh/api.md)

Third-party addons access MineMod through `MC.API`. `MC.API.VERSION == 2`, content registration `ModRegistryVersion == "1.0"`, and manifest `ManifestVersion == "1"` are independent versions. Internal `MC.World`, `MC.SV`, registries, `mcmesh`, and underscore-prefixed fields are outside the public extension API.

Implementations: [shared](../addons/mc_engine/lua/mc/api/sh_api.lua), [server](../addons/mc_engine/lua/mc/api/sv_api.lua), [client](../addons/mc_engine/lua/mc/api/cl_api.lua), [manifest](../addons/mc_engine/lua/mc/api/sh_manifest.lua). The `MC.API.` prefix is omitted below. SH means both realms, SV server, CL client. SH does not imply automatic networking.

## Getting started

[mod_api_example.lua](../examples/mod_api_example.lua) is a complete standalone addon example. Rename it into your addon's `lua/autorun/` and copy the localization catalogs in [examples/data_static](../examples/data_static). Distribute shared files with GMod's `AddCSLuaFile()`.

Loading has two phases:

1. **register**: `MC.APIAvailable(version)`; registries remain open. Register manifests, blocks, items, and categories here.
2. **ready**: `MC.APIReady(version)`; registries are frozen. Start runtime logic, networking, UI, and timers.

After autorun, engine bootstrap schedules manifests, then freezes registries. Do not delay content registration with timers or put registration in `OnReady`. Both sides need identical content. Do not persist runtime numeric IDs.

```lua
if SERVER then AddCSLuaFile() end

local function registerContent()
	local api = MC.API
	local ok, result = api.Blocks.RegisterNamespaced( {
		id = "example:stone",
		textures = { top = "stone", side = "stone", bottom = "stone" },
		boxes = { { 0, 0, 0, 1, 1, 1 } },
		hardness = 1.5,
		explosionResistance = 6,
	} )
	if not ok then ErrorNoHalt( "[example] " .. tostring( result ) .. "\n" ) end
end

if MC and MC.API and MC.API.OnRegister then
	MC.API.OnRegister( registerContent )
else
	hook.Add( "MC.APIAvailable", "example.register", registerContent )
end
```

This registers an engine block only; the linked complete example includes items, drops, and creative tabs. Its name comes from `block.example.stone` in the addon's `data_static/mc/i18n/`. See the [localization contract](localization.md) for catalog format and the full I18n interface.

### Lifecycle, manifests, and optional capabilities (SH)

| Call | Returns and semantics |
| --- | --- |
| `IsAvailable()`, `IsReady()` | Whether the corresponding phase has been reached. |
| `OnRegister(callback)`, `OnReady(callback)` | Invoke immediately if the phase occurred, otherwise queue. Invalid callbacks return `false`. Late subscriptions do not reopen frozen registries. |
| `Require(2, addonName)` | Check the minimum facade version; return `ok, err`. |
| `Require("mcswep", ">=1.0 <2.0", addonName)` | Check manifest dependency versions; return `ok, err`. The compatible engine dependency ID remains `mcswep`. |
| `RegisterManifest(definition)` | Return `ok, manifestOrErr`; registration phase only. |
| `GetManifest(id)`, `ListManifests()` | One public record or error; array of records sorted by ID. |
| `GetCapability(name, minimumVersion)` | Success: `surface, nil, version, owner`; failure: `nil, err, actualVersionOrNil`. |
| `HasCapability(name, minimumVersion)` | Whether a capability satisfying the version exists. |
| `RequireCapability(name, minimumVersion, addonName)` | Success: `surface, version`; failure prints the reason and returns `nil, err`. |
| `OnCapability(name, minimumVersion, callback)` | Invoke `callback(surface, version, owner)` immediately when satisfied, otherwise wait. |
| `RegisterCapability(name, version, surface, owner)` | Publish a capability; `ok, surfaceOrErr`. The same owner can replace it; another cannot. |
| `UnregisterCapability(name, owner)` | Only the owner can remove it; `ok, err`. |
| `RegisterEvents(owner, definitions)` | Register event descriptions, returning `ok, err`; does not emit events. |
| `DeepCopy(value)` | Deep-copy tables; return other values unchanged. |
| `ResolveStateInput(block)` | State-input parsing equivalent to Blocks.ParseState. |

A manifest is a Lua table, not automatically scanned JSON, and does not load addon files:

```lua
local manifest = {
	id = "example", version = "1.0.0", environment = "*",
	depends = { mcswep = ">=1.0 <2.0" },
	entrypoints = { main = function( context )
		-- context.api, context.manifest, context.realm
		return true
	end },
}
```

`environment` is `*`, `client`, or `server`. Entrypoints `main`, `shared`, `client`, and `server` are functions or arrays of functions. Manifests run in dependency order; each realm runs main/shared/its realm entrypoint. An exception or explicit `false, reason` fails bootstrap; do not signal failure using only `return nil`.

## Units, identities, and return values

- `bx/by/bz` are integer cell coordinates. Continuous MC-world coordinates use Source units. Read size from `Coords.BlockSize()`; model boxes are block ratios and are multiplied exactly once.
- Entity `GetPos()`/`EyePos()` are engine-space positions. Re-origining worlds require conversion with entity context. Draw positions use current-frame render space. Do not pass MC-world positions directly to engine traces or `SetPos`.
- A `block` argument generally accepts **stateId**, `"minecraft:stone"`, a property-bearing specification, or `0/nil/"air"`. blockId, runtimeId, and stateId are distinct. `Blocks.Resolve` queries block types; `ParseState` queries states.
- Persist namespaced names or `FormatState` specifications. Runtime numbers are valid only in the current process.
- Not every function returns `ok, err`: counts may be 0, queries may return nil. Receive multiple results directly, without wrapping calls in `and`, `or`, or parentheses.

```lua
local x, y, z = MC.API.Coords.EntityCell( ply )
if x == nil then return end
local ok, err = MC.API.Player.Place( ply, x, y, z + 1, "minecraft:stone" )
if not ok then print( err ) end
```

## Coords (SH, except entries marked CL)

| Call | Returns and semantics |
| --- | --- |
| `BlockSize()` | Current block edge length. |
| `WorldToCell(pos)`, `EngineToCell(pos, context)` | `bx, by, bz`; three nil values for invalid inputs. |
| `EngineToWorld(pos, context)`, `WorldToEngine(pos, context)` | Converted Vector, or `nil, err`. |
| `EntityCell(ent)`, `EntityEyeCell(ent)` | Foot/eye `bx, by, bz`. |
| `EntityWorldPos(ent)`, `EntityEyeWorldPos(ent)` | Copied world-space Vector, or `nil, err`. |
| `MoveOriginWorldPos(ply, pos)` | World Vector converted using the predicted movement origin, or `nil, err`. |
| `EntityWorldAABB(ent)` | Two world Vectors, `minimum, maximum`; failure: `nil, nil, err`. |
| `EntityCellBounds(ent, inset)` | `minX, minY, minZ, maxX, maxY, maxZ`; inset is in Source units. |
| `CellMin(bx, by, bz)`, `CellCenter(bx, by, bz)` | World-space cell corner/center Vector; nil for invalid cells. |
| `CellToChunk(bx, by, bz)` | `cx, cy, cz, localIndex`. |
| `RenderToWorld(pos)`, `WorldToRender(pos)` | CL: converted Vector or `nil, err`; server returns `client_only`. |
| `CellRenderMin(bx, by, bz)`, `CellRenderCenter(bx, by, bz)` | Current-frame draw coordinates for client render hooks. |

## Blocks (SH)

| Call | Returns and semantics |
| --- | --- |
| `Resolve(input)` | Block-type record `{id, blockId, runtimeId, name, mcid, defaultStateId}`, or `nil, err`. |
| `ParseState(spec)`, `FormatState(stateId)` | `stateId, err` / `spec, err`. |
| `Name(stateId)`, `StateName(stateId)` | Canonical block name / complete state specification. |
| `IsValidState(stateId)`, `StateBlockId(stateId)` | Validity / compatible blockId. |
| `StateFromLegacy(blockId, orient)`, `DefaultState(input)` | `stateId, err`. |
| `GetProperty(stateId, propertyName)`, `WithProperty(stateId, propertyName, value)` | Read a property / return another valid state without modifying the original. |
| `DisplayName(idOrStateId, locale)`, `DisplayNameForState(stateId, locale)` | Localized name. For numeric collisions, the first function prefers blockId; use the second for states. |
| `TranslationKey(idOrStateId)` | `key, varsCopy`, or `nil, err`. |
| `Hardness(id)`, `ExplosionResistance(id)`, `LightEmission(id)`, `RequiresCorrectTool(id)` | Block-type properties; id here is blockId. |
| `LightOpacity(stateId, bx, by, bz)` | State opacity 0..15; position resolves connected shapes. |
| `StateShapeAt(stateId, bx, by, bz)` | Copied exact state shape: boxes, collisionBoxes, collisionConvexes, extentLo/Hi, hasCollision, fullCube, etc. |
| `Kind(stateId)` | `air/liquid/narrow/door/trapdoor/bed/stairs/slab/slope/none/full/partial` or `nil, err`. Coarse classification does not replace exact collision. |
| `IsFlammable(block)` | Flammability, with err on resolution failure. |
| `List()`, `ListNames()` | blockId array / sorted canonical-name array. |
| `RuntimeId(input)`, `NameForRuntimeId(runtimeId)` | Current-process mapping. |
| `RegistrySnapshot()`, `ResolveRegistrySnapshot(snapshot)` | Registry mapping snapshot / resolved copy, or `nil, err`. |
| `RegistryHash()`, `NetworkHash()` | Persistent schema hash / network runtime-mapping hash; not interchangeable. |
| `RegisterNamespaced(definition)` | `true, result` or `nil, err`; recommended registration entry point. |
| `Register(definition)` | Legacy-compatible registration: old definitions return `true, blockId`; new definitions with string-only IDs forward to RegisterNamespaced. |

### Definitions and behavior registration

New definitions use an owned `namespace:path`, without choosing numeric IDs.

| Field | Meaning |
| --- | --- |
| `id` | Canonical content name, such as `example:stone`. |
| `textures` | `top/side/bottom/front/particle/icon`, referring to registered atlas textures. The minimal example reuses stone. |
| `boxes` | Array of ratio boxes `{minX,minY,minZ,maxX,maxY,maxZ}`. |
| `collisionConvexes` (or `convexes`) | Convex collision geometry; do not supply both aliases. |
| `hardness`, `explosionResistance`, `lightEmission` | Finite numbers; emission is an integer 0..15. |
| `castsAmbientOcclusion`, `castsShadow` | Booleans. |
| `translationKey`, `translationVars` | Optional name key and interpolation parameters; otherwise derive from the block name. |
| `handlers` | Lifecycle callbacks listed below. |

Complex shapes also validate `boxFaces/modelQuads/baked/modelVariants`; see the [registration validator](../addons/mc_engine/lua/mc/registry/sh_mod_registry.lua). New registration rejects `collisionBoxes`, `drops/lootTable/loot_table`, internal aliases/generated-geometry fields, and inline `disp/dispZH`. Register drops separately through `BlockLoot`.

| Call | Returns and semantics |
| --- | --- |
| `SetHandlers(nameOrId, handlers)` | Replace specified callbacks; false removes one. Supports CanUse, OnUse, OnPlace, OnBreak, OnTick, OnPlaced, OnRemoved, OnReplaced, OnStateChanged, OnMoved. |
| `RegisterUpdateHandler(blockName, definition)`, `UnregisterUpdateHandler(blockName)` | Functional-block update callbacks. |
| `RegisterStateUpdateHandler(key, matcher, definition)`, `UnregisterStateUpdateHandler(key)` | Pure matcher(stateId, schema), cached results; first match in registration order wins. |
| `RegisterBlockEntityType(definition)`, `IsBlockEntityTypeRegistered(typeName)` | Register/query block-entity data types. |
| `BindBlockEntityType(blockNames, typeName)`, `CreateDefaultBlockEntity(stateId)` | Bind types / return copied default records. Block entities are not GMod Entities. |
| `RegisterPlacementStateProvider(id, provider, priority)`, `UnregisterPlacementStateProvider(id)` | Placement-state extensions. |

Update definitions use `OnScheduledTick/OnNeighborUpdate/OnRandomTick/OnBlockEvent`. The [update registry](../addons/mc_engine/lua/mc/block_update/sh_registry.lua) defines context and `{cells, schedule, updates}` results. Lifecycle and update callbacks are different protocols; do not mix their arguments.

## World queries (SH)

| Call | Returns and semantics |
| --- | --- |
| `GetBlockState(bx, by, bz)`, `IsAir(bx, by, bz)` | stateId (air is 0) / boolean. Invalid or unavailable data may also appear as air. |
| `IsCellLoaded(bx, by, bz)`, `IsChunkLoaded(cx, cy, cz)` | Resident or known-empty cells/chunks. Check before making assertions about world contents. |
| `GetBlockInfo(bx, by, bz)` | `{stateId,id,orient,name,mcid,spec}`; nil for air. |
| `ForEachBlock(x1,y1,z1,x2,y2,z2, callback)` | Non-air cells in an inclusive box. callback(bx,by,bz,stateId); false stops early. Return `ok, skippedChunks`, or err as the second value on failure. |
| `ForEachLoadedBlock(callback, stateFilter)` | Loaded non-air cells. filter(stateId) filters section palettes. Success: `true, visited`; callback failure: `false, "callback_failed", visited`. |
| `GetCellShape(bx, by, bz)` | Copied cell shape, or nil. |
| `TraceRay(startPos, dir, maxDist)` | World-space voxel ray, blocks only, excluding map/props. Result includes bx/by/bz, StateId, HitPos, HitNormal. Distance uses Source units. |
| `PlayerAim(ply, reach)` | Player block-aim result, or `nil, err`. |
| `CanSeeSky(bx, by, bz)` | Height-column sky test: any positive opacity blocks on SV; only full opacity blocks on CL. Not lateral flood propagation. |
| `GetBlockEntity(bx, by, bz)` | Copied record, or nil. |
| `ListBlockEntities(typeName)` | Loaded `{bx,by,bz,record}` array, optionally type-filtered. |
| `ForEachBlockEntity(typeName, callback)` | callback(bx,by,bz,record); false stops. Success: `true, entriesCount`, where count is the snapshot total. |

`skippedChunks > 0` means incomplete query coverage. An empty result does not establish absence. Client streaming and server lazy loading affect residency. Do not scan the whole world every frame.

## Authoritative changes (SV)

`World` writes are trusted server operations that bypass player reach, cooldown, and administrator validation. Player/network-triggered edits should call `Player`; never pass untrusted requests directly to World.

| Call | Returns and semantics |
| --- | --- |
| `World.SetBlock(bx,by,bz,block,opts)`, `RemoveBlock(bx,by,bz,opts)` | `ok, err`; no change is `false, "unchanged"`. |
| `World.SetBlocks(cells,opts)`, `RemoveBlocks(cells,opts)` | Changed count and underlying result; validation failure is `0, err`. Cells use named bx/by/bz and block/stateId/spec. |
| `World.Fill(x1,y1,z1,x2,y2,z2,block,opts)` | Fill result `{changed,chunks,added,removed,revision,...}`, or `nil, err`; opts: actor, ignoreVolumeLimit, quiet. |
| `World.Clear()` | Clear the voxel world and resynchronize every player. |
| `World.SetBlockEntity(bx,by,bz,record,opts)` | Validate/replace a record; nil clears the record without changing state. |
| `World.UpdateBlockEntity(bx,by,bz,callback,opts)` | Callback edits a private copy, returns a replacement, or false to abort. Success: `true, recordCopy`. |
| `World.Damage(bx,by,bz,amount,opts)` | `broken, status, damage, health`. |
| `World.Explode(center,damage,opts)` | `ok, brokenCount, radiusOrStatus`. |
| `World.TriggerExplosion(center,radius,opts)` | Non-destructive TRIGGER_BLOCK interaction; `ok, triggeredCount, selectedCountOrStatus`. |
| `World.MinecraftExplosion(center,radius,opts)` | Full Minecraft explosion. Success: `true, summary`; failure: `false, err, summaryOrNil`. Radius is in Minecraft blocks. |
| `World.PlayFx(kind,bx,by,bz,block)` | Broadcast place/break effects without world changes. |
| `World.CountBlocks()`, `World.GetRevision()` | Current block count / committed transaction revision. |
| `World.RegisterBlockGuard(id,callback)`, `UnregisterBlockGuard(id)` | Guard non-player damage/explosions. callback(bx,by,bz,stateId,cause,context) returns false to reject; must be inexpensive. |
| `Player.Place(ply,bx,by,bz,block)`, `Break(ply,bx,by,bz)`, `Use(ply,bx,by,bz)` | Full player validation and veto hooks; return underlying operation results. |
| `Player.UseAimedBlock(ply)` | Whether the aimed block was successfully used. |
| `Player.CanEdit(ply)`, `CanReachCell(ply,bx,by,bz)` | Editing eligibility / reach only; the latter neither runs edit vetoes nor writes the world. |
| `Player.TransformBlock(ply,bx,by,bz,block,expectedState)` | In-place change with permissions, reach, and optional expected stateId; no mining drops. |
| `Player.Resync(ply)` | Restart synchronization; nil means all players. |

General write opts accept only actor, fx, fxIndex, fxLimit, handlers, blockUpdates, preventPlayerOverlap, priorityPhys, deferPhys, netPaced, stateStream, cellsPerMessage, compareCollision, and blockEntity. Unknown options are discarded.

MinecraftExplosion has separate opts: source, actor, interaction, dropDecay, dropResources, interactsWithBlocks, createFire, affectsEntities, and entityDamageScale. The last accepts a nonnegative multiplier or callback(entity, vanillaDamage, center, radius). Summaries expose counts/results without internal transactions.

`Explosion.RegisterBlockInteractionHandler(identifier,{Prepare,Commit})` and `UnregisterBlockInteractionHandler(identifier)` extend explosion-block interactions. Prepare(snapshots,radius,options) and Commit(plan,transaction,snapshots,radius,options) receive public snapshots. `RegisterKnockbackResistanceProvider(identifier,callback)` / `UnregisterKnockbackResistanceProvider(identifier)` extend knockback resistance through callback(entity,center,radius,options).

## Items, BlockLoot, and Creative (SH)

The engine retains neutral item/drop registration queues. `mc_game` supplies full item queries and ItemStack semantics. Engine-only Items queries return `item_registry_unavailable`.

| Call | Returns and semantics |
| --- | --- |
| `Items.Register(definition)` | `true, {name,runtimeId?,pending}` or `nil, err`; register id, block, maxStack, texture, kind, etc. during registration. |
| `Items.Resolve(value)` | mc_game: `{name,runtimeId,blockName,maxStack,maxDamage}`, or `nil, err`. |
| `Items.RuntimeId(value)`, `NameForRuntimeId(runtimeId)`, `ListNames()`, `RegistrySnapshot()` | Current mc_game mappings/snapshots. |
| `Items.TranslationKey(value)`, `DisplayName(value,locale)` | mc_game: `key,varsCopy` / localized name. |
| `BlockLoot.RegisterDefaultBlockItem(blockName,itemName)` | Register ordinary dropSelf; `ok, recordOrErr`. If itemName is omitted, resolve the bound BlockItem at freeze time. |
| `Creative.RegisterCategory(definition)` | `ok, categoryOrErr`; id, icon, showTitle, canScroll, optional titleKey. Registry allocates slots. |
| `Creative.RegisterBlock(categoryId,blockName)`, `RegisterItem(categoryId,itemName)`, `RegisterStack(categoryId,stack)` | Register category entries; `ok, resultOrErr`. Stack count must be 1. |
| `Creative.ListCategories()`, `GetCategory(id)`, `IsFrozen()` | Category copies / one category / frozen status. |

Names derive from `item.<namespace>.<path>` or the BlockItem's block key; `displayName/displayNameZH` are rejected. Category titles derive from `itemGroup.<namespace>.<path>`; inline title/titleZH are rejected. Self-selected row/column/page fields are ignored with a notice. Do not add the same ItemStack to one category through both RegisterBlock and RegisterItem.

mc_game ItemStack helpers: `ItemStack.GetCustomName(stack)` returns `name,present,err` (empty strings can be present); `Hash(stack)` returns a concurrency-validation hash; `GetEnchantmentLevel(stack,enchantment)` returns a nonnegative level and optional err. See the [game item facade](../addons/mc_game/lua/mcgame/item/sh_public_api.lua).

## Other shared systems

| Namespace | Calls and semantics |
| --- | --- |
| `Identifiers` | Normalize(value) returns a canonical identifier or nil,err; Parts(value) splits it. Supply valid lowercase namespaces rather than relying on runtime spelling repair. |
| `Network` | Register(owner,names) records ownership and also AddNetworkString on SV; returns ok,namesCopyOrErr. Owner(name); CoordinateBits() is the signed protocol coordinate width. Implement net.Send/Receive yourself. |
| `Sound` | Candidates(eventName) returns copies; Play(eventName,position,options) returns ok,candidateCopy,err. Options: volume/pitch multipliers and soundLevel. |
| `Banners` | MaxStoredPatterns(), IsState(stateId), IsWallState(stateId), NormalizeData(data,maxLayers); the last returns a normalized record copy and err. |
| `Redstone` | GetPower(bx,by,bz), GetPowerToward(bx,by,bz,dx,dy,dz) return 0..15; the latter reads the specified neighbor's signal into the target cell. RegisterEmitter(blockName,emitter), RegisterDirectEmitter(blockName,emitter). |
| `Liquid` | GetAt(bx,by,bz): kind,height,level,falling,waterlogged, with height 0..1. GetBucketSource also includes stateId/source. AtPos(pos), PlayerEye(ply) query contact; FlowAt(bx,by,bz,requiredKind) returns x,y,z. |
| `DayCycle` | GetTicks(), IsEnabled(), IsPaused(), SkyLevel(), SunVector(), NightAmount(), NightBlend(), IsNight(), SkyBrightness(), CelestialAngle(). SunVector returns Vector,elevation; SkyLevel is 0..15, SkyBrightness 0..1. |
| `GameMode` | Get(ply) returns creative/survival and optional err; IsCreative(ply) returns bool,err. |
| `Config` | HasGroup(scope,id), HasCategory(scope,id), RegisterGroup(scope,group), RegisterCategory(scope,category); scope: client/server. Entries use catalog keys such as labelKey, rejecting inline bilingual text. |

See [localization.md](localization.md) for I18n queries, count variants, notifications, language changes, and diagnostics.

### Other server operations

| Namespace | Calls and semantics |
| --- | --- |
| `Saves` | Save(name): ok,pathOrErr, with nil for the map default; Load(name,resync), Delete(name), Exists(name), List(). List scans disk; do not poll. |
| `Presets` | List(), Get(name), Place(ply,name,origin,opts), SaveFromWorld(name,cornerA,cornerB,anchor,ply), Delete(name). Cells: bx/by/bz or three-element arrays; rotation 0..3, opts.overwrite boolean. Nil ply bypasses player gates and is trusted-code-only. |
| `Cluster` | Capture(x1,y1,z1,x2,y2,z2) returns a non-air record. Spawn(record,pos,opts): entity or nil,err,convexCount; pos is engine space; opts: angles/frozen/owner. PlaceBack(ply,ent,targetMin,rotation), Break(ent,attacker). |
| `Schedule` | BlockTick(bx,by,bz,delayTicks,expectedStateId,options) at 20 TPS; BlockUpdate(bx,by,bz); CancelBlockTick(bx,by,bz) cancels all pending types at that cell, regardless of owner. |
| `Schedule` | Observe(key,match,definition), Unobserve(key) add filtered observers after the original handler. Match is a block name or pure state matcher. CancelBlockTick does not remove observers. |
| `Farming` | CanSurvive(bx,by,bz,state); Plant(ply,bx,by,bz,state,opts), ApplyBonemeal(ply,bx,by,bz,opts), TryTrample(entity,bx,by,bz,fallDistance,opts). Successful writes return true,resultCopy. |
| `Redstone` | Pulse(bx,by,bz,power,durationTicks), for targets or lightning rods. |
| `DayCycle`, `GameMode` | SetTicks(ticks), modulo 24000; Set(ply,mode,actor). |
| `Liquid` | PickupSource(ply), PlaceSource(ply,kind), water/lava. Success returns a result record. On inventory transaction failure call RollbackPickup/Placement(ply,result); after completion call CommitPickup/Placement(ply,result) to emit events. |

## Client presentation and lighting (CL)

| Namespace | Calls and semantics |
| --- | --- |
| `UI` | DrawBlockIcon(block,x,y,w,h) in 2D Paint; DrawBlockOutline(block,bx,by,bz,color) in a 3D context. |
| `UI` | OpenCreativeInventory(onSelect,opts): callback id,stateIdOrNil, opts.closeOnSelect. OpenPalette(onSelect) requires callback(id). OpenSaveManager(), OpenPresetManager(). |
| `Font` | Measure(text,fontName), TrimToWidth(text,maxWidth,fontName), Draw(text,x,y,options), LineHeight(). Measurements use logical GUI pixels. Draw options: font/scale/color/align/verticalAlign/shadow/maxWidth. |
| `Hotbar` | GetSelection(): slot/id/stateId. SetSlot(slot,block) also selects/synchronizes; SelectSlot(slot). Slots are 1..9. |
| `Effects` | PlayBlockEffect(kind,bx,by,bz,block,opts) is local only. BlockParticleMaterial(block,col,row) returns shared cached material: do not modify/release it. PlayBlockHitSound(block,pos,options) supports volume/pitch. |
| `Light` | SampleCell(bx,by,bz,selfEmission) exists on both realms and returns brightness,level,blockLight,skyLight; sky excludes day/night. SV height-column and CL render samples differ. |
| `Light` | SampleRGB(pos,emission), SamplePresentationRGB(pos,emission) return r,g,b. Both take persistent MC-world positions; the latter samples item/particle-cell lightmap plus moving lights, not hand poses or render-relative positions. |
| `Light` | SkyLightAt(bx,by,bz), ScaleRGB(r,g,b,gain). |
| `Render` | MarkCellDirty(bx,by,bz) rebuilds geometry/samples without world-light propagation. MarkAllDirty() is expensive; reserve for global registration changes. |
| `Render` | RegisterDynamicLightProvider(id,definition) / UnregisterDynamicLightProvider(id); RegisterSSRDepthRenderer(id,callback) / UnregisterSSRDepthRenderer(id); RegisterSpecialBlockEmitter(blockName,emitter). Advanced render extensions; follow provider definitions linked by the facade. |

Optional Minecraft player lighting (`mc_light_entity`) leaves ARC9 players on Source's normal lighting/draw path to avoid running their third-person animation solver twice.

### Resource packs and atlases (CL)

`Resources.VERSION == "1.2"`. Preparing a resource stack and switching published atlases are separate operations. PrepareSelection synchronously prepares CPU data; it does not publish a GPU atlas.

| Call | Returns and semantics |
| --- | --- |
| `Resources.GetCatalog()`, `Refresh()` | Resource catalog snapshot / refresh. |
| `Resources.RegisterResourcePack(id,definition,owner)`, `UnregisterResourcePack(id,owner)` | Owned source-pack registration. |
| `Resources.ValidateSelection(ids,revision,confirmed)` | Validate catalog revision and selection. |
| `Resources.PrepareSelection(ids,revision,resources,options)` | Synchronous CPU resource-stack preparation. |
| `Resources.GetResourceSource(ids,revision,resource,confirmed)` | Open a selection snapshot, resolve sources, then close; return result,err. |
| `Resources.ResolveTexturePath(pack,resource)` | Resolve a texture source path. |
| `Resources.RegisterAtlasPack(name,definition,owner)`, `UnregisterAtlasPack(name,owner)` | Baked atlases; forwards to Render texture-pack registration. |
| `Resources.RegisterSourcePack(name,definition,owner)`, `UnregisterSourcePack(name,owner)` | Source packs baked at runtime. |
| `Resources.ListPacks()`, `GetSelection()` | Available packs / current selection. |
| `Resources.ApplyPack(name,options)`, `ReloadPack(name,options)` | Apply one atlas pack / reload. |
| `Resources.GetApplyStatus(id)`, `CancelApply(id)` | Query/cancel an application job. |
| `Render.RegisterTexturePack(name,definition,owner)`, `UnregisterTexturePack(name,owner)`, `UnregisterTexturePackOwner(owner)` | Client texture-pack registration and owner cleanup. Material paths omit extensions. |
| `Render.AcquireTexturePack(owner,name,priority)`, `ReleaseTexturePack(owner)` | Temporary mode ownership; release restores player preferences and other leases. |
| `Render.SetTexturePack(name)`, `SetTexturePackPreference(name)`, `GetTexturePack()` | Immediate switch / saved preference / current name. Modes should prefer leases. |
| `Render.GetTexturePackLeaseOwner()`, `ListTexturePacks()`, `ListTexturePackLeases()` | Current owner / packs / leases. |
| `Render.RegisterAtlasProfile(name,definition,owner)`, `UnregisterAtlasProfile(name,owner)`, `UnregisterAtlasProfileOwner(owner)` | Register/clean up physical atlas layouts. |
| `Render.SetAtlasProfile(name)`, `GetAtlasProfile()`, `ListAtlasProfiles()` | Current atlas layout. |
| `Render.ResolveAtlasTile(tile)`, `ResolveAtlasSurface(tile)` | Tile mapping / page,tile,layout. |
| `Render.GetAtlasPageCount()`, `GetAtlasPageLayout(page)` | Atlas page queries. |

New packs are usually discovered through addon `data_static/mc/resourcepacks/` manifests without runtime Lua registration. See the [resource-pack guide](../docs-user/05-resource-packs.md) for player workflows. Follow implementations forwarded by the [Resources facade](../addons/mc_engine/lua/mc/api/cl_api.lua) for complex definitions rather than calling internal tables.

Render also has an independent cold-path definition catalog: `RegisterPack(id,definition)`, `RegisterShader(id,definition)`, `UpdatePack(id,definition,expectedBuild)`, `UpdateShader(id,definition,expectedBuild)`, `GetPack(id)`, `GetShader(id)`, `ListPacks()`, `ListShaders()`, `PlanPack(id,requests)`, and `GetPackStatus()`. Updates require an expectedBuild string for version comparison. This catalog is separate from production shader-variant registration; PlanPack does not indicate GPU readiness. See the [render-pack registry](../addons/mc_engine/lua/mc/render/cl_render_pack_registry.lua) for schemas and results.

## HandWeapon: selected items and SWEP bridging

This engine layer obtains upper-layer selected items through providers, without an engine dependency on mc_game. See the [shared bridge](../addons/mc_engine/lua/mc/integration/sh_hand_weapon_bridge.lua).

| Call | Returns and semantics |
| --- | --- |
| `RegisterResolver(id,resolver,priority)`, `UnregisterResolver(id)` | SH: resolver(stackCopy,ply) returns a SWEP class or nil for bridge selection. |
| `RegisterSelectionProvider(id,provider,priority)`, `UnregisterSelectionProvider(id)` | SH: provider.GetSelected(ply), optional IsSessionOpen(ply). |
| `RegisterPresentationProvider(id,provider,priority)`, `UnregisterPresentationProvider(id)` | SH: provider(weapon,stackCopy,ply) synchronizes presentation. |
| `RegisterWeaponAdapter(className,adapter)` | SH: adapter requires acquire/matches, with optional retain/ownsFirstPerson. |
| `ConfigureBaseClasses(owner,handClass,inventoryClass)` | SH: configure default classes under one owner. |
| `RegisterManagedClass(className)`, `UnregisterManagedClass(className)` | SH: add/remove managed classes. |
| `IsManagedClass(value)`, `IsInventoryControlledClass(value)`, `OwnsFirstPersonPresentation(value)` | SH: ownership and first-person presentation capability for a class/entity. |
| `Resolve(stack,ply)` | SH: className,resolverId; failure nil,err. |
| `Refresh(ply)`, `Reconcile(ply,stack,context)`, `QueueRefresh(ply,stack,context)` | SV: realign selected item and active weapon; CL returns server_only. |
| `SelectOwnedWeapon(ply,weapon)` | SV: request a predicted switch to an already owned weapon and cancel queued inventory reconciliation; returns true,className or false,err. Completion is asynchronous. |
| `IsManagedActive(ply)` | Realm-local active weapon check; compatibility name IsInventoryActive. |
| `IsSelectedActive(ply)`, `IsManagedSwitchPending(ply)` | CL: selected-item weapon / pending switch. IsHeldItemActive is an alias of the first. |
| `GetBlockFirstPersonPose(weapon,leftHand)`, `GetBlockThirdPersonPose(ply,leftHand)`, `GetItemThirdPersonAnchor(ply,leftHand)` | CL: poses/anchors may return multiple values; receive them directly. See client bridge contract. |
| `SamplePresentationLighting(pos,state)`, `DrawBlockState(stateId,pos,ang,scale,lighting)` | CL: sample position uses MC-world coordinates; draw position follows the active render context. |

See the [client bridge](../addons/mc_engine/lua/mc/integration/cl_hand_weapon_bridge.lua) for exact returns and draw parameters. These APIs preserve public Lua names; do not infer switching state from internal network fields.

Weapon switches use the owning client's usercmd so SWEP Deploy/Holster run with normal prediction; bots select through server StartCommand. A temporarily vetoed selection is retried. During delayed Holster, newer requests replace the queued destination; the current stage completes before the latest destination is selected. The bridge retains proxies until the final activation is confirmed and cancels the chain when the player selects a different weapon. A stage that does not complete within ten seconds reports `hand_weapon_switch_timeout`. Integrations must not call Deploy/Holster manually to compensate for server-forced selection.

## Optional mc_game runtime interfaces

These require more than mc_engine. Shared capabilities: `mc.game.items/creative/block_loot/config` (v1). Server: `mc.game.fire/shears/mining` (v1), `mc.game.inventory` (v2). Client: `mc.game.item_renderer/inventory_ui` (v1). Negotiate with GetCapability/OnCapability before calling.

```lua
local inventory, err = MC.API.GetCapability( "mc.game.inventory", 2 )
if not inventory then return false, err end
local stack, slot, selectedError = inventory.GetSelected( ply )
```

Inventory slots are **0..35**, unlike the client creative Hotbar's **1..9**.

| Call | Returns and semantics |
| --- | --- |
| `Inventory.Get(ply)` | Snapshot of selected, revision, slots[0..35]. |
| `GetSlot(ply,slot)`, `GetEquipmentSlot(ply,slot)` | Copied ItemStack; equipment aliases include head/chest/legs/feet/offhand. |
| `GetSelected(ply)` | stackCopy,slot; errors: nil,nil,err. |
| `Give(ply,item,count,components,damage)` | inserted,remainderCopy,err; handle uninserted remainder. |
| `Remove(ply,item,count)`, `Select(ply,slot)` | Remove items / select a slot. |
| `DamageSelected(ply,amount,context)`, `DamageEquipment(ply,slot,amount,context)` | resultCopy,broken,err. |
| `ConsumeSelected(ply,amount,replacement,context)` | result,consumed,overflow,infinite,err. |
| `ConsumeHeld(ply,hand,amount,context)` | result,consumed,oldStack,err; hand: mainhand/offhand. |
| `ReplaceSelected(ply,replacement,context)` | result,stack,err. |
| `TakeSelectedWithDurability(ply,amount,context)` | stack,infinite,mutationResult,err; atomic extraction for projectiles. |
| `CanTakeSelectedWithDurability(ply,amount,context)` | allowed,infinite,stack,err. |
| `HasInfiniteMaterials(ply)`, `Open(ply)` | Infinite-material check / open inventory. |

Exact bow/crossbow ammunition, use-state, drop-entity, equipment-write, and menu signatures are in the [game server facade](../addons/mc_game/lua/mcgame/api/sv_public_api.lua), which also exposes `Farming.UseHeld(ply,bx,by,bz,context)`, `Tools.UseHeld(ply,action,context)`, Fire, Shears, and Mining. Do not replace inventory-transaction operations with World.SetBlock plus manual item removal. Client capability fields are in the [client bridge](../addons/mc_game/lua/mcgame/api/cl_engine_bridge.lua).

Shared mc_game `CreativeStacks` extends existing categories rather than creating categories after freeze. `RegisterEntries(tab,id,operations,priority)` / `UnregisterEntries(id)` use actions append/prepend/before/after, visibility both/tab/search, and count=1 stacks. before/after also require anchor. Advanced `RegisterProvider(id,provider,priority)` / `UnregisterProvider(id)`, `Invalidate()`, and `Contains(stack)` are in the [creative-entry implementation](../addons/mc_game/lua/mcgame/inventory/sh_creative_stacks.lua). Explicitly Invalidate after external state changes. Wait for `MC.CreativeStacksAPIReady`, not just engine APIReady.

## Events and permissions

`MC.API.Events` is a description catalog with realm, args, and desc. Listen with GMod `hook.Add(name, uniqueId, callback)`. Observers return nothing. Veto listeners return `false` only to reject, and nothing to allow, so other listeners can run.

| Event | Usage |
| --- | --- |
| `MC.APIAvailable`, `MC.APIReady` | Registration/runtime phases; argument version. |
| `MC.APICapabilityAvailable`, `MC.APICapabilityRemoved` | Optional capability availability/removal; arguments follow capability API above. |
| `MC.CanPlayerEdit(ply)`, `MC.CanPlayerEditCell(ply,bx,by,bz,placing,context)` | SV veto of player actions. context.action: place/break/use/modify. Does not block all trusted World writes. |
| `MC.BlocksChanged(changes,revision,actor)` | SV ordinary transaction; changes include old/new state and kind. Excludes raw Fill/import writes. |
| `MC.WorldFilled(fill,actor)`, `MC.WorldCleared()`, `MC.PreWorldLoad(path,name)`, `MC.WorldLoaded(path,name,blockCount)` | SV bulk world changes/switches. |
| `MC.ChunkHydrated(key,cx,cy,cz)` | SV lazy data hydration, without per-cell events. |
| `MC.ClientBlockStateChanged(bx,by,bz,oldStateId,newStateId,reason)` | CL single-cell projection change. |
| `MC.ClientWorldProjectionChanged(reason,context)` | CL bulk snapshot/load/unload/reset; suitable for rebuilding derived indices. |
| `MC.StateRevisionApplied(generation,revision)` | CL applied an authoritative revision. |
| `MC.PlayerPlacedBlock`, `MC.PlayerBrokeBlock`, `MC.PlayerUsedBlock` | SV committed player actions. |
| `MC.PlayerPickedUpFluid`, `MC.PlayerPlacedFluid` | SV committed bucket inventory transactions. |

Full save, preset, cluster, explosion, vehicle, Workshop, and game-mode event arguments are in the [shared API event table](../addons/mc_engine/lua/mc/api/sh_api.lua). mc_game bridge files supplement it with their own events. `BlocksChanged` is not the sole notification for all world changes. Do not modify chunks directly to bypass transactions and synchronization.
