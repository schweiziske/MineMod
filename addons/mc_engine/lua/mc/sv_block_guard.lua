--[[----------------------------------------------------------------------------
	MC : block guards.

	Destruction that has no editing player (explosions, GMod bullet/blast
	damage) never reaches MC.CanPlayerEditCell. A guard is the per-cell veto for
	those paths: a guarded cell behaves like an unbreakable block for the
	explosion that reaches it, so it also shields the cells behind it.

	A registry instead of hook.Run because one explosion asks about thousands of
	cells; with no guard registered the check is a single table test.
------------------------------------------------------------------------------]]

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV

SV.BlockGuards = SV.BlockGuards or {}
SV.BlockGuardOrder = SV.BlockGuardOrder or {}

-- Blast resistance applied to a guarded cell; Java's bedrock value.
SV.GUARDED_BLOCK_RESISTANCE = 3600000

local function rebuildOrder()
	local order = {}
	for id, callback in pairs( SV.BlockGuards ) do order[#order + 1] = { id = id, callback = callback } end
	table.sort( order, function( left, right ) return left.id < right.id end )
	SV.BlockGuardOrder = order
end

function SV.RegisterBlockGuard( id, callback )
	if not isstring( id ) or id == "" or #id > 64 then return false, "invalid_guard_id" end
	if not isfunction( callback ) then return false, "invalid_guard_callback" end
	SV.BlockGuards[id] = callback
	rebuildOrder()
	return true
end

function SV.UnregisterBlockGuard( id )
	if not isstring( id ) or SV.BlockGuards[id] == nil then return false end
	SV.BlockGuards[id] = nil
	rebuildOrder()
	return true
end

function SV.HasBlockGuards()
	return SV.BlockGuardOrder[1] ~= nil
end

-- cause: "explosion" | "damage". context: { actor, source }.
-- A guard that errors protects the cell: failing open would let one broken
-- listener void the protection every other guard relies on.
function SV.IsBlockGuarded( bx, by, bz, stateId, cause, context )
	local order = SV.BlockGuardOrder
	for index = 1, #order do
		local entry = order[index]
		local ok, allowed = pcall( entry.callback, bx, by, bz, stateId, cause, context )
		if not ok then
			MC.Fault( "block_guard_error", "%s: %s", entry.id, tostring( allowed ) )
			return true
		end
		if allowed == false then return true end
	end
	return false
end
