-- Server-authoritative external merchant menus.

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local MERCHANT_SLOTS = 3
local INVENTORY_SIZE = 36
local MAX_STATE_BYTES = 60000
local STATE_VERSION = 1
local ActiveByMerchant = setmetatable( {}, { __mode = "k" } )

util.AddNetworkString( "mc_merchant_state" )
util.AddNetworkString( "mc_merchant_select" )

if resource and resource.AddFile then
	resource.AddFile( "materials/mc/gui/container/villager.png" )
	for _, fileName in ipairs( file.Find( "materials/mc/gui/sprites/container/villager/*.png", "GAME" ) or {} ) do
		resource.AddFile( "materials/mc/gui/sprites/container/villager/" .. fileName )
	end
end

local function integer( value, fallback, minimum, maximum )
	value = math.floor( tonumber( value ) or tonumber( fallback ) or 0 )
	if minimum ~= nil then value = math.max( minimum, value ) end
	if maximum ~= nil then value = math.min( maximum, value ) end
	return value
end

local function merchantMethod( merchant, name )
	local method = IsValid( merchant ) and merchant[name] or nil
	return type( method ) == "function" and method or nil
end

local function invokeMerchant( merchant, name, ... )
	local method = merchantMethod( merchant, name )
	if not method then return nil, "merchant_method_missing_" .. string.lower( name ) end
	local called, first, second = pcall( method, merchant, ... )
	if not called then
		if ErrorNoHalt then
			ErrorNoHalt( "[MC Merchant] " .. name .. " failed: " .. tostring( first ) .. "\n" )
		end
		return nil, "merchant_method_error_" .. string.lower( name )
	end
	return first, second
end

local function tradePermissionMethod( merchant )
	if merchantMethod( merchant, "CanBMBMerchantTrade" ) then return "CanBMBMerchantTrade" end
	if merchantMethod( merchant, "CanBMBVillagerTrade" ) then return "CanBMBVillagerTrade" end
	return nil
end

local function merchantContractComplete( merchant )
	if not IsValid( merchant ) or merchant.BMBMerchantContract ~= true then return false end
	if not tradePermissionMethod( merchant ) then return false end
	for _, name in ipairs( {
		"GetBMBMerchantSnapshot", "ReserveBMBMerchantOffer",
		"RollbackBMBMerchantReservation", "CommitBMBMerchantReservation",
		"FinalizeBMBMerchantTrade", "IsBMBMerchantSessionOwner",
		"OnBMBMerchantSessionOpened", "OnBMBMerchantSessionClosed",
	} ) do
		if not merchantMethod( merchant, name ) then return false end
	end
	return true
end

local function merchantAllowsPlayer( merchant, ply )
	local name = tradePermissionMethod( merchant )
	if not name then return false, "merchant_permission_missing" end
	local allowed, reason = invokeMerchant( merchant, name, ply )
	return allowed == true, reason or "merchant_unavailable"
end

local function merchantSessionOwnedBy( merchant, ply )
	local owned, reason = invokeMerchant( merchant, "IsBMBMerchantSessionOwner", ply )
	return owned == true, reason or "merchant_session_owner_mismatch"
end

local function normalizedMerchantSnapshot( merchant, ply )
	local raw, snapshotError = invokeMerchant( merchant, "GetBMBMerchantSnapshot", ply )
	if type( raw ) ~= "table" then return nil, snapshotError or "merchant_snapshot_missing" end
	local snapshot, normalizeError = MC.MerchantNormalizeSnapshot( raw )
	if not snapshot then return nil, normalizeError or "merchant_snapshot_invalid" end
	if snapshot.entityIndex ~= merchant:EntIndex()
	or snapshot.entityClass ~= merchant:GetClass() then return nil, "merchant_snapshot_identity_mismatch" end
	local seen = {}
	for _, offer in ipairs( snapshot.offers or {} ) do
		if seen[offer.index] then return nil, "merchant_offer_index_duplicate" end
		seen[offer.index] = true
	end
	return snapshot
end

local function merchantStillValid( ply, merchant )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive()
	or not merchantContractComplete( merchant ) then return false end
	if merchantSessionOwnedBy( merchant, ply ) ~= true then return false end
	return merchantAllowsPlayer( merchant, ply ) == true
end

local function playerSlots( storage, offset )
	local definitions, map, reverse, hotbar = {}, {}, {}, {}
	for playerIndex = 0, INVENTORY_SIZE - 1 do
		local menuIndex = offset + playerIndex
		definitions[#definitions + 1] = {
			index = menuIndex,
			storage = storage,
			storageIndex = playerIndex + 1,
			group = playerIndex < 9 and "hotbar" or "main",
		}
		map[playerIndex], reverse[menuIndex] = menuIndex, playerIndex
		if playerIndex < 9 then hotbar[playerIndex + 1] = menuIndex end
	end
	return definitions, map, reverse, hotbar
end

local function javaAutofillTargets( offset )
	local targets = {}
	for playerIndex = 9, 35 do targets[#targets + 1] = offset + playerIndex end
	for playerIndex = 0, 8 do targets[#targets + 1] = offset + playerIndex end
	return targets
end

local function javaReversePlayerTargets( offset )
	local targets = {}
	for playerIndex = 8, 0, -1 do targets[#targets + 1] = offset + playerIndex end
	for playerIndex = 35, 9, -1 do targets[#targets + 1] = offset + playerIndex end
	return targets
end

local function sameResult( left, right )
	return not MC.IsEmptyItemStack( left ) and not MC.IsEmptyItemStack( right )
		and MC.ItemStacksEqual( left, right, true )
end

local function insertResultCursor( container, result )
	local carried = container.cursor
	if MC.IsEmptyItemStack( carried ) then return MC.ContainerSetCursor( container, result ) end
	if not sameResult( carried, result ) then return false, "merchant_result_cursor_different_item" end
	local nextCount = carried.count + result.count
	if nextCount > MC.ItemStackMaxCount( carried ) then return false, "merchant_result_cursor_full" end
	return MC.ContainerSetCursor( container, MC.CopyItemStack( carried, nextCount ) )
end

local function insertResultHotbar( container, result, button, context )
	local menuIndex = container.hotbarSlots[( tonumber( button ) or -1 ) + 1]
	local slot = menuIndex ~= nil and MC.ContainerGetSlot( container, menuIndex ) or nil
	if not slot then return false, "merchant_hotbar_slot_missing" end
	local existing = MC.InventorySlotGet( slot )
	if MC.IsEmptyItemStack( existing ) then
		if not MC.InventorySlotMayPlace( slot, result, context )
		or result.count > MC.InventorySlotLimit( slot, result ) then
			return false, "merchant_result_hotbar_denied"
		end
		return MC.InventorySlotSet( slot, result )
	end
	if not sameResult( existing, result ) then return false, "merchant_result_hotbar_occupied" end
	local nextCount = existing.count + result.count
	if nextCount > MC.InventorySlotLimit( slot, result ) then return false, "merchant_result_hotbar_full" end
	return MC.InventorySlotSet( slot, MC.CopyItemStack( existing, nextCount ) )
end

local function consumePayment( menu, slotIndex, cost )
	if MC.IsEmptyItemStack( cost ) then return true end
	local stack = MC.ContainerGetStack( menu, slotIndex )
	if not MC.MerchantItemCostMatches( stack, cost )
	or ( tonumber( stack and stack.count ) or 0 ) < cost.count then return false, "merchant_payment_changed" end
	local remaining = stack.count > cost.count and MC.CopyItemStack( stack, stack.count - cost.count ) or nil
	return MC.ContainerSetStack( menu, slotIndex, remaining )
end

local function tradeUpdateInputsChanged( data, paymentA, paymentB )
	local changed = data.lastTradeUpdateSelection ~= data.selection
		or not MC.ItemStacksEqual( data.lastTradeUpdatePaymentA, paymentA )
		or not MC.ItemStacksEqual( data.lastTradeUpdatePaymentB, paymentB )
	data.lastTradeUpdateSelection = data.selection
	data.lastTradeUpdatePaymentA = MC.CopyItemStack( paymentA )
	data.lastTradeUpdatePaymentB = MC.CopyItemStack( paymentB )
	return changed
end

local function refreshResult( menu )
	local data = menu and menu.merchant
	if not data then return false, "merchant_data_missing" end
	if data.pendingUse then
		data.activeOffer, data.paymentSwapped = nil, false
		return MC.ContainerSetStack( menu, data.resultSlot, nil )
	end
	local paymentA = MC.ContainerGetStack( menu, data.paymentASlot )
	local paymentB = MC.ContainerGetStack( menu, data.paymentBSlot )
	local offer, swapped = MC.MerchantFindActiveOffer(
		data.snapshot,
		data.selection,
		paymentA,
		paymentB
	)
	data.activeOffer, data.paymentSwapped = offer, swapped == true
	local updated, updateError = MC.ContainerSetStack( menu, data.resultSlot,
		offer and MC.CopyItemStack( offer.result ) or nil )
	if not updated then return false, updateError end

	if tradeUpdateInputsChanged( data, paymentA, paymentB )
	and ( not MC.IsEmptyItemStack( paymentA ) or not MC.IsEmptyItemStack( paymentB ) )
	and merchantMethod( data.entity, "OnBMBMerchantTradeUpdated" ) then
		invokeMerchant( data.entity, "OnBMBMerchantTradeUpdated", offer ~= nil, true )
	end
	return true
end

local function takeResult( menu, slotIndex, button, _, context, mode )
	local data = menu and menu.merchant
	if not data or slotIndex ~= data.resultSlot then return false, "invalid_result_slot" end
	if data.pendingUse then return false, "merchant_trade_pending" end
	local refreshed, refreshError = refreshResult( menu )
	if not refreshed then return false, refreshError or "merchant_result_refresh_failed" end
	local offer, result = data.activeOffer, MC.ContainerGetStack( menu, data.resultSlot )
	if not offer or MC.IsEmptyItemStack( result ) then return false, "merchant_offer_not_satisfied" end

	local inserted, insertError
	if mode == "quick_move" then
		local remaining, moved = MC.ContainerMoveStackTo(
			menu, result, data.playerReturnTargets, context )
		inserted = moved == true and MC.IsEmptyItemStack( remaining )
		insertError = inserted and nil or "merchant_inventory_full"
	elseif mode == "swap" then
		inserted, insertError = insertResultHotbar( menu, result, button, context )
	else
		if button ~= 0 and button ~= 1 then return false, "invalid_button" end
		inserted, insertError = insertResultCursor( menu, result )
	end
	if not inserted then return false, insertError or "merchant_result_insert_failed" end

	local firstSlot = data.paymentSwapped and data.paymentBSlot or data.paymentASlot
	local secondSlot = data.paymentSwapped and data.paymentASlot or data.paymentBSlot
	local ok, err = consumePayment( menu, firstSlot, offer.costA )
	if not ok then return false, err end
	ok, err = consumePayment( menu, secondSlot, offer.costB )
	if not ok then return false, err end
	ok, err = MC.ContainerSetStack( menu, data.resultSlot, nil )
	if not ok then return false, err end
	data.activeOffer, data.paymentSwapped = nil, false
	data.pendingUse = {
		offerIndex = offer.index,
		expectedRevision = data.snapshot.revision,
	}
	return true
end

local function wireStack( stack )
	return MC.IsEmptyItemStack( stack ) and nil or MC.InventoryDataStack( stack )
end

local function activeOfferPosition( data )
	if not data or not data.activeOffer then return -1 end
	for position, offer in ipairs( data.snapshot and data.snapshot.offers or {} ) do
		if offer == data.activeOffer then return position - 1 end
	end
	return -1
end

local function merchantWireState( menu, errorCode )
	local data = menu and menu.merchant
	local snapshot = data and data.snapshot
	if not snapshot then return nil, "merchant_state_missing" end
	local output = {
		version = STATE_VERSION,
		entityIndex = snapshot.entityIndex,
		entityClass = snapshot.entityClass,
		revision = snapshot.revision,
		profession = snapshot.profession,
		villagerType = snapshot.villagerType,
		level = snapshot.level,
		experience = snapshot.experience,
		nextLevelExperience = snapshot.nextLevelExperience,
		showProgressBar = snapshot.showProgressBar == true,
		canRestock = snapshot.canRestock == true,
		selected = integer( data.selection, 0, 0, math.max( 0, #snapshot.offers - 1 ) ),
		activeOffer = activeOfferPosition( data ),
		futureExperience = data.activeOffer and integer( data.activeOffer.xp, 0, 0 ) or 0,
		error = errorCode and tostring( errorCode ) or nil,
		offers = {},
	}
	for position, offer in ipairs( snapshot.offers or {} ) do
		output.offers[position] = {
			index = offer.index,
			id = offer.id,
			level = offer.level,
			baseCostA = wireStack( offer.baseCostA ),
			costA = wireStack( offer.costA ),
			costB = wireStack( offer.costB ),
			result = wireStack( offer.result ),
			uses = offer.uses,
			maxUses = offer.maxUses,
			availableUses = offer.availableUses,
			xp = offer.xp,
			outOfStock = offer.outOfStock == true,
			unavailable = offer.unavailable == true,
			unavailableReason = offer.unavailableReason,
		}
	end
	return output
end

local function sendMerchantState( record, errorCode )
	local session = record and record.session
	local menu = session and session.container
	local ply = record and record.owner
	if not IsValid( ply ) or not session or session.kind ~= "merchant" or not menu then return false end
	local state, stateError = merchantWireState( menu, errorCode )
	if not state then return false, stateError end
	local json = util.TableToJSON( state, false )
	local payload = json and util.Compress( json ) or nil
	if not payload or #payload < 1 or #payload > MAX_STATE_BYTES then
		if ErrorNoHalt then ErrorNoHalt( "[MC Merchant] state payload rejected\n" ) end
		return false, "merchant_state_too_large"
	end
	net.Start( "mc_merchant_state" )
		net.WriteUInt( menu.id, 16 )
		net.WriteString( session.token or "" )
		net.WriteUInt( #json, 20 )
		net.WriteUInt( #payload, 16 )
		net.WriteData( payload, #payload )
	net.Send( ply )
	return true
end

local function appendChangedSlot( result, index )
	for _, existing in ipairs( result.changedSlots or {} ) do if existing == index then return end end
	result.changedSlots[#result.changedSlots + 1] = index
	table.sort( result.changedSlots )
end

local function syncRecordRevision( record, menu, result )
	local playerChanged = false
	for _, index in ipairs( result.changedSlots or {} ) do
		if menu.menuPlayerMap and menu.menuPlayerMap[index] ~= nil then playerChanged = true break end
	end
	menu.revision = math.max( menu.revision, record.container.revision or 0 )
	record.container.revision, record.revision = menu.revision, menu.revision
	if playerChanged then
		record.dirty = true
		if SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( record ) end
	end
end

local function setLatestSnapshot( menu, snapshot )
	if not menu or not menu.merchant or not snapshot then return false end
	menu.merchant.snapshot = snapshot
	menu.merchant.selection = math.Clamp( menu.merchant.selection or 0, 0, math.max( 0, #snapshot.offers - 1 ) )
	return refreshResult( menu )
end

local function adoptMerchantSnapshot( record, menu, snapshot, context )
	local data = menu and menu.merchant
	if not data or not snapshot then return false, "merchant_snapshot_missing" end
	local previous = {
		snapshot = data.snapshot,
		selection = data.selection,
		activeOffer = data.activeOffer,
		paymentSwapped = data.paymentSwapped,
		lastTradeUpdateSelection = data.lastTradeUpdateSelection,
		lastTradeUpdatePaymentA = data.lastTradeUpdatePaymentA,
		lastTradeUpdatePaymentB = data.lastTradeUpdatePaymentB,
	}
	local before = MC.ContainerSnapshot( menu )
	local refreshed, refreshError = setLatestSnapshot( menu, snapshot )
	if not refreshed then
		for key, value in pairs( previous ) do data[key] = value end
		MC.ContainerRestore( menu, before )
		return false, refreshError or "merchant_snapshot_refresh_failed"
	end
	local changed = MC.ContainerChangedSlots( menu, before )
	if #changed > 0 then
		menu.revision = menu.revision + 1
		local result = {
			ok = true,
			revision = menu.revision,
			changedSlots = changed,
			cursorChanged = false,
			cursor = MC.CopyItemStack( menu.cursor ),
			drops = {},
		}
		syncRecordRevision( record, menu, result )
		if SV.PublishActiveInventoryCommit then
			SV.PublishActiveInventoryCommit( record, result, context or {} )
		end
	end
	return true
end

local function buildMenu( ply, record, merchant, snapshot )
	local paymentStorage, resultStorage = {}, {}
	local slots = {
		{ index = 0, storage = paymentStorage, storageIndex = 1,
			group = "merchant_payment_a", meta = { role = "input" } },
		{ index = 1, storage = paymentStorage, storageIndex = 2,
			group = "merchant_payment_b", meta = { role = "input" } },
		{ index = 2, storage = resultStorage, storageIndex = 1,
			group = "merchant_result", mayPlace = function() return false end,
			meta = { role = "result" } },
	}
	local playerOffset = MERCHANT_SLOTS
	local definitions, playerMap, menuMap, hotbar = playerSlots( record.storage, playerOffset )
	for _, definition in ipairs( definitions ) do slots[#slots + 1] = definition end
	local menu, err = MC.NewInventoryContainer( {
		id = record.nextContainerId or 2,
		kind = "merchant",
		revision = record.container.revision,
		slots = slots,
		hotbarSlots = hotbar,
		transferRules = {
			merchant_payment_a = { targets = { "main", "hotbar" } },
			merchant_payment_b = { targets = { "main", "hotbar" } },
			merchant_result = { targets = { "main", "hotbar" }, reverse = true },
			main = { targets = { "hotbar" } },
			hotbar = { targets = { "main" } },
		},
		context = { player = ply, merchant = merchant },
	} )
	if not menu then return nil, err end
	record.nextContainerId = ( menu.id + 1 ) % 65535
	if record.nextContainerId == 0 or record.nextContainerId == 1 then record.nextContainerId = 2 end
	menu.playerOffset, menu.playerMenuMap, menu.menuPlayerMap = playerOffset, playerMap, menuMap
	menu.merchant = {
		entity = merchant,
		record = record,
		snapshot = snapshot,
		selection = 0,
		paymentASlot = 0,
		paymentBSlot = 1,
		resultSlot = 2,
		playerAutofillTargets = javaAutofillTargets( playerOffset ),
		playerReturnTargets = javaReversePlayerTargets( playerOffset ),
	}
	menu.takeResult = takeResult

	menu.beforeCommit = function( committed )
		local data = committed.merchant
		if not merchantStillValid( record.owner, data.entity ) then return false, "merchant_unavailable" end
		local latest, latestError = normalizedMerchantSnapshot( data.entity, record.owner )
		if not latest then return false, latestError or "merchant_snapshot_failed" end
		if latest.revision ~= data.snapshot.revision then
			data.rollbackSnapshot = latest
			return false, "merchant_revision_mismatch"
		end
		data.snapshot = latest
		local use = data.pendingUse
		if not use then return refreshResult( committed ) end
		if use.expectedRevision ~= latest.revision then return false, "merchant_revision_mismatch" end
		local token, reserveError = invokeMerchant(
			data.entity, "ReserveBMBMerchantOffer", record.owner, use.offerIndex, use.expectedRevision )
		if not token then return false, reserveError or "merchant_reservation_failed" end
		use.reservationToken = token
		use.reservationOpen = true
		-- MC.ExecuteContainerInput can reject only from beforeCommit.  Finish the
		-- external merchant mutation here, before the authoritative inventory delta
		-- can become visible; onCommit is intentionally notification-only.
		local committedOffer, commitDetail = invokeMerchant(
			data.entity, "CommitBMBMerchantReservation", token )
		if committedOffer ~= true then
			invokeMerchant( data.entity, "RollbackBMBMerchantReservation", token )
			use.reservationOpen = false
			return false, commitDetail or "merchant_commit_failed"
		end
		use.reservationOpen = false
		use.externallyCommitted = true
		use.finalizationToken = commitDetail
		return true
	end

	menu.onInputRollback = function( committed, _, _, errorCode )
		local data = committed.merchant
		local use = data and data.pendingUse
		if use and use.reservationOpen and use.reservationToken then
			invokeMerchant( data.entity, "RollbackBMBMerchantReservation", use.reservationToken )
		end
		data.pendingUse = nil
		local before = MC.ContainerSnapshot( committed )
		local latest = data.rollbackSnapshot or select( 1, normalizedMerchantSnapshot( data.entity, record.owner ) )
		data.rollbackSnapshot = nil
		if latest then setLatestSnapshot( committed, latest ) else refreshResult( committed ) end
		local changed = MC.ContainerChangedSlots( committed, before )
		if #changed > 0 then
			committed.revision = committed.revision + 1
			record.container.revision, record.revision = committed.revision, committed.revision
		end
		sendMerchantState( record, errorCode )
		timer.Simple( 0, function()
			if IsValid( record.owner ) and record.session and record.session.container == committed
			and SV.SendActiveInventorySnapshot then
				SV.SendActiveInventorySnapshot( record.owner, "merchant_rollback" )
			end
		end )
	end

	menu.onCommit = function( committed, result, context )
		local data = committed.merchant
		local completedUse = data.pendingUse
		data.pendingUse = nil

		local resultBeforeRefresh = MC.CopyItemStack( MC.ContainerGetStack( committed, data.resultSlot ) )
		local latest = select( 1, normalizedMerchantSnapshot( data.entity, record.owner ) )
		if latest then setLatestSnapshot( committed, latest ) else refreshResult( committed ) end
		if not MC.ItemStacksEqual( resultBeforeRefresh, MC.ContainerGetStack( committed, data.resultSlot ) ) then
			appendChangedSlot( result, data.resultSlot )
		end
		syncRecordRevision( record, committed, result )
		if SV.PublishActiveInventoryCommit then
			SV.PublishActiveInventoryCommit( record, result, context or {} )
		end
		if completedUse and completedUse.externallyCommitted
		and completedUse.finalizationToken then
			local finalized, finalizeError = invokeMerchant(
				data.entity, "FinalizeBMBMerchantTrade", completedUse.finalizationToken )
			if finalized ~= true and ErrorNoHalt then
				ErrorNoHalt( "[MC Merchant] trade finalization failed: "
					.. tostring( finalizeError or "unknown" ) .. "\n" )
			end
		end
		if record.session and record.session.container == committed then
			sendMerchantState( record )
		end
		return true
	end

	local refreshed, refreshError = refreshResult( menu )
	if not refreshed then return nil, refreshError or "merchant_result_refresh_failed" end
	return menu
end

local function playerCanReceiveReturnedPayment( ply )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false end
	if type( ply.IsConnected ) == "function" and not ply:IsConnected() then return false end
	return true
end

local function allPlayerInventoryTargets()
	local targets = {}
	for playerIndex = 0, INVENTORY_SIZE - 1 do targets[#targets + 1] = playerIndex end
	return targets
end

local function queueMerchantRecoveryStack( record, stack, reason )
	if not record or MC.IsEmptyItemStack( stack ) then return true end
	record.recoveryStacks = record.recoveryStacks or {}
	local remaining = MC.CopyItemStack( stack )
	for index, existing in ipairs( record.recoveryStacks ) do
		if MC.ItemStacksCanMerge( existing, remaining ) then
			local limit = MC.ItemStackMaxCount( existing )
			local moved = math.min( math.max( 0, limit - existing.count ), remaining.count )
			if moved > 0 then
				record.recoveryStacks[index] = MC.CopyItemStack( existing, existing.count + moved )
				remaining = remaining.count > moved
					and MC.CopyItemStack( remaining, remaining.count - moved ) or nil
				if MC.IsEmptyItemStack( remaining ) then break end
			end
		end
	end
	if not MC.IsEmptyItemStack( remaining ) then
		record.recoveryStacks[#record.recoveryStacks + 1] = MC.CopyItemStack( remaining )
	end
	record.dirty = true
	if ErrorNoHalt then
		ErrorNoHalt( "[MC Merchant] preserved returned payment in recovery storage: "
			.. tostring( reason or "unknown" ) .. "\n" )
	end
	return true
end

local function spawnReturnedPayment( position, stack, owner, reason )
	if MC.IsEmptyItemStack( stack ) or type( SV.SpawnItemDrop ) ~= "function" then return false end
	local called, entity = pcall( SV.SpawnItemDrop, position, stack, owner, {
		noMerge = true,
		reason = reason or "merchant_close",
	} )
	return called and IsValid( entity )
end

local function returnPaymentStack( record, menu, slotIndex, position, returnToInventory )
	local stack = MC.ContainerGetStack( menu, slotIndex )
	if MC.IsEmptyItemStack( stack ) then return true end
	local cleared, clearError = MC.ContainerSetStack( menu, slotIndex, nil )
	if not cleared then
		queueMerchantRecoveryStack( record, stack, clearError or "merchant_payment_clear_failed" )
		return false, clearError or "merchant_payment_clear_failed"
	end
	local remaining = stack
	if returnToInventory then
		remaining = select( 1, MC.ContainerMoveStackTo(
			record.container, stack, allPlayerInventoryTargets(), { reason = "merchant_close" } ) )
	end
	if not MC.IsEmptyItemStack( remaining )
	and not spawnReturnedPayment( position, remaining,
		IsValid( record.owner ) and record.owner or nil, "merchant_close" ) then
		queueMerchantRecoveryStack( record, remaining,
			type( SV.SpawnItemDrop ) == "function" and "merchant_drop_failed"
				or "merchant_drop_unavailable" )
	end
	return true
end

local function closeMerchantSession( record, session, reason )
	local menu, data = session and session.container, session and session.container and session.container.merchant
	if not menu or not data then return end
	if data.closeHandled then return end
	data.closeHandled = true
	local merchant = data.entity
	if ActiveByMerchant[merchant] == record.owner then ActiveByMerchant[merchant] = nil end
	-- MerchantMenu.removed unbinds tradingPlayer before returning either payment
	-- slot.  Do the same so callbacks cannot observe an orphaned active owner.
	if IsValid( merchant ) then
		invokeMerchant( merchant, "OnBMBMerchantSessionClosed", record.owner, reason or "closed" )
	end
	local position = IsValid( record.owner ) and record.owner:GetPos()
		or IsValid( merchant ) and merchant:GetPos() or vector_origin
	local before = MC.ContainerSnapshot( record.container )
	local returnToInventory = playerCanReceiveReturnedPayment( record.owner )
	returnPaymentStack( record, menu, data.paymentASlot, position, returnToInventory )
	returnPaymentStack( record, menu, data.paymentBSlot, position, returnToInventory )
	local resultCleared, resultClearError = MC.ContainerSetStack( menu, data.resultSlot, nil )
	if not resultCleared and ErrorNoHalt then
		ErrorNoHalt( "[MC Merchant] result clear failed: "
			.. tostring( resultClearError or "unknown" ) .. "\n" )
	end
	local changed = MC.ContainerChangedSlots( record.container, before )
	if #changed > 0 then
		record.container.revision = math.max( record.container.revision + 1, menu.revision )
		record.revision, record.dirty = record.container.revision, true
		if SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( record ) end
	end
	if IsValid( record.owner ) and SV.SendActiveInventorySnapshot then
		SV.SendActiveInventorySnapshot( record.owner, "merchant_close" )
	end
end

function SV.OpenExternalMerchant( ply, merchant, reason )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false, "invalid_player" end
	if not merchantContractComplete( merchant ) then return false, "merchant_contract_invalid" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply ) or nil
	if not record then return false, "inventory_not_loaded" end
	local current = record.session
	if current and current.kind == "merchant" and current.container
	and current.container.merchant and current.container.merchant.entity == merchant then
		if merchantStillValid( ply, merchant ) then
			sendMerchantState( record )
			return true, "already_open"
		end
		if SV.ClosePlayerInventory then SV.ClosePlayerInventory( ply, "merchant_orphaned" ) end
		current = record.session
	end
	local allowed, permissionError = merchantAllowsPlayer( merchant, ply )
	if not allowed then return false, permissionError or "merchant_unavailable" end
	if current and SV.ClosePlayerInventory then SV.ClosePlayerInventory( ply, "switch" ) end
	local snapshot, snapshotError = normalizedMerchantSnapshot( merchant, ply )
	if not snapshot then return false, snapshotError end
	if #snapshot.offers == 0 then return false, "merchant_has_no_offers" end
	local menu, menuError = buildMenu( ply, record, merchant, snapshot )
	if not menu then return false, menuError end
	menu.cursor = MC.CopyItemStack( record.carried )
	record.carried = nil
	local tokenSeed = table.concat( { ply:EntIndex(), merchant:EntIndex(), SysTime(), math.random(), "merchant" }, ":" )
	local session = {
		token = util.SHA256 and util.SHA256( tokenSeed ) or util.CRC( tokenSeed ),
		kind = "merchant",
		container = menu,
		creative = false,
		openedAt = CurTime(),
		lastActionId = nil,
		playerOffset = menu.playerOffset,
		playerMenuMap = menu.playerMenuMap,
		menuPlayerMap = menu.menuPlayerMap,
		resultSlot = 2,
		merchant = true,
		validate = function() return merchantStillValid( ply, merchant ) end,
		onClose = function( closedRecord, closedSession, closeReason )
			closeMerchantSession( closedRecord, closedSession, closeReason )
		end,
	}
	record.session = session
	local opened, openError = invokeMerchant( merchant, "OnBMBMerchantSessionOpened", ply )
	if opened == false then
		record.session = nil
		record.carried = MC.CopyItemStack( menu.cursor )
		return false, openError or "merchant_open_rejected"
	end
	if merchantSessionOwnedBy( merchant, ply ) ~= true then
		record.session = nil
		invokeMerchant( merchant, "OnBMBMerchantSessionClosed", ply, "merchant_owner_not_bound" )
		record.carried = MC.CopyItemStack( menu.cursor )
		return false, "merchant_owner_not_bound"
	end
	ActiveByMerchant[merchant] = ply
	if not SV.SendActiveInventoryOpen or not SV.SendActiveInventoryOpen( ply, record, reason or "merchant" ) then
		SV.ClosePlayerInventory( ply, "merchant_open_failed" )
		return false, "merchant_open_failed"
	end
	sendMerchantState( record )
	return true
end

local function selectionRateAllowed( session )
	local now = CurTime()
	local rate = session.merchantSelectRate
	if not rate or now - rate.startedAt >= 1 then
		session.merchantSelectRate = { startedAt = now, count = 1 }
		return true
	end
	if rate.count >= 20 then return false end
	rate.count = rate.count + 1
	return true
end

local function directMerchantMutation( record, menu, mutate, context )
	local before = MC.ContainerSnapshot( menu )
	local ok, err = mutate()
	if ok ~= true then MC.ContainerRestore( menu, before ) return nil, err or "merchant_mutation_rejected" end
	local changed = MC.ContainerChangedSlots( menu, before )
	local cursorChanged = not MC.ItemStacksEqual( menu.cursor, before.cursor )
	if #changed > 0 or cursorChanged then menu.revision = menu.revision + 1 end
	local result = {
		ok = true,
		revision = menu.revision,
		changedSlots = changed,
		cursorChanged = cursorChanged,
		cursor = MC.CopyItemStack( menu.cursor ),
		drops = {},
	}
	if #changed > 0 or cursorChanged then
		local called, committed, commitError = pcall( menu.onCommit, menu, result, context or {} )
		if not called or committed == false then
			MC.ContainerRestore( menu, before )
			return nil, called and ( commitError or "merchant_commit_rejected" ) or "merchant_commit_error"
		end
	else
		sendMerchantState( record )
	end
	return result
end

net.Receive( "mc_merchant_select", function( bytes, ply )
	if bytes > 4096 then return end
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local containerRevision = net.ReadUInt( 32 )
	local merchantRevision = net.ReadUInt( 32 )
	local selection = net.ReadUInt( 6 )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	local session = record and record.session
	local menu = session and session.container
	local data = menu and menu.merchant
	if not data or session.kind ~= "merchant" or containerId ~= menu.id or token ~= session.token then return end
	if not merchantStillValid( ply, data.entity ) then
		SV.ClosePlayerInventory( ply, "merchant_unavailable" )
		return
	end
	if not selectionRateAllowed( session ) then sendMerchantState( record, "rate_limited" ) return end
	if containerRevision ~= menu.revision or merchantRevision ~= data.snapshot.revision then
		sendMerchantState( record, "merchant_revision_mismatch" )
		if SV.SendActiveInventorySnapshot then SV.SendActiveInventorySnapshot( ply, "merchant_select_mismatch" ) end
		return
	end
	local latest, latestError = normalizedMerchantSnapshot( data.entity, ply )
	if not latest then
		sendMerchantState( record, latestError or "merchant_snapshot_failed" )
		if SV.SendActiveInventorySnapshot then SV.SendActiveInventorySnapshot( ply, "merchant_select_snapshot_failed" ) end
		return
	end
	if latest.revision ~= data.snapshot.revision then
		local adopted, adoptError = adoptMerchantSnapshot(
			record, menu, latest, { merchantSelectionRefresh = true } )
		sendMerchantState( record, adopted and "merchant_revision_mismatch"
			or ( adoptError or "merchant_snapshot_refresh_failed" ) )
		if SV.SendActiveInventorySnapshot then SV.SendActiveInventorySnapshot( ply, "merchant_select_mismatch" ) end
		return
	end
	data.snapshot = latest
	if selection < 0 or selection >= #latest.offers then
		sendMerchantState( record, "invalid_offer" )
		return
	end
	local result, mutationError = directMerchantMutation( record, menu, function()
		data.selection = selection
		local moved, moveError = MC.MerchantTryMoveItems(
			menu, data.snapshot, selection, data.paymentASlot, data.paymentBSlot,
			data.playerAutofillTargets, data.playerReturnTargets,
			{ player = ply, merchantSelection = true } )
		if not moved then return false, moveError end
		return refreshResult( menu )
	end, { player = ply, merchantSelection = true } )
	if not result then
		sendMerchantState( record, mutationError or "merchant_select_failed" )
		if SV.SendActiveInventorySnapshot then SV.SendActiveInventorySnapshot( ply, "merchant_select_failed" ) end
	end
end )

hook.Add( "BMB.OpenMerchant", "mcgame_external_merchant_open", function( ply, merchant )
	if not IsValid( merchant ) or merchant.BMBMerchantContract ~= true then return nil end
	return SV.OpenExternalMerchant( ply, merchant, "entity_use" )
end )

hook.Add( "BMB.MerchantUnavailable", "mcgame_external_merchant_unavailable", function( merchant, reason )
	local ply = ActiveByMerchant[merchant]
	local record = IsValid( ply ) and SV.GetPlayerInventoryRecord
		and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if record and record.session and record.session.kind == "merchant"
	and record.session.container.merchant.entity == merchant and SV.ClosePlayerInventory then
		SV.ClosePlayerInventory( ply, tostring( reason or "merchant_unavailable" ) )
	end
end )

hook.Add( "EntityRemoved", "mcgame_external_merchant_removed", function( entity )
	local ply = ActiveByMerchant[entity]
	local record = IsValid( ply ) and SV.GetPlayerInventoryRecord
		and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if record and record.session and record.session.kind == "merchant"
	and record.session.container.merchant.entity == entity and SV.ClosePlayerInventory then
		SV.ClosePlayerInventory( ply, "merchant_removed" )
	end
end )

timer.Create( "mcgame_external_merchant_refresh", 0.25, 0, function()
	for merchant, ply in pairs( ActiveByMerchant ) do
		local record = IsValid( ply ) and SV.GetPlayerInventoryRecord
			and SV.GetPlayerInventoryRecord( ply, false ) or nil
		local session = record and record.session
		local menu = session and session.container
		local data = menu and menu.merchant
		if not data or session.kind ~= "merchant" or data.entity ~= merchant
		or not merchantStillValid( ply, merchant ) then
			ActiveByMerchant[merchant] = nil
			if record and session and session.kind == "merchant" and SV.ClosePlayerInventory then
				SV.ClosePlayerInventory( ply, "merchant_unavailable" )
			end
		else
			local latest = select( 1, normalizedMerchantSnapshot( merchant, ply ) )
			if latest and latest.revision ~= data.snapshot.revision and not data.pendingUse then
				local adopted, adoptError = adoptMerchantSnapshot(
					record, menu, latest, { merchantBackground = true } )
				sendMerchantState( record, adopted and nil
					or ( adoptError or "merchant_snapshot_refresh_failed" ) )
			end
		end
	end
end )

local function drainMerchantRecovery( record )
	if not record or not playerCanReceiveReturnedPayment( record.owner )
	or type( record.recoveryStacks ) ~= "table" or #record.recoveryStacks == 0 then return false end
	local original = {}
	for index, stack in ipairs( record.recoveryStacks ) do
		original[index] = MC.CopyItemStack( stack )
	end
	local before = MC.ContainerSnapshot( record.container )
	local remaining = {}
	for _, stack in ipairs( original ) do
		local overflow = select( 1, MC.ContainerMoveStackTo(
			record.container, stack, allPlayerInventoryTargets(),
			{ reason = "merchant_recovery" } ) )
		if not MC.IsEmptyItemStack( overflow ) then remaining[#remaining + 1] = overflow end
	end
	local changed = MC.ContainerChangedSlots( record.container, before )
	if #changed > 0 then
		local committed = SV.CommitPlayerInventoryMutation
			and SV.CommitPlayerInventoryMutation( record, before, {
				player = record.owner,
				reason = "merchant_recovery",
			} ) or nil
		if not committed then
			MC.ContainerRestore( record.container, before )
			return false
		end
	end

	local position = record.owner:GetPos()
	local kept = {}
	for _, stack in ipairs( remaining ) do
		if not spawnReturnedPayment( position, stack, record.owner, "merchant_recovery" ) then
			kept[#kept + 1] = MC.CopyItemStack( stack )
		end
	end
	record.recoveryStacks = kept
	record.dirty = true
	return #kept == 0
end

timer.Create( "mcgame_external_merchant_recovery", 1, 0, function()
	for _, record in pairs( SV.PlayerInventories or {} ) do
		drainMerchantRecovery( record )
	end
end )
