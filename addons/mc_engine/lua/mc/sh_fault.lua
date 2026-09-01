--[[----------------------------------------------------------------------------
	Unified fault reporting.

	Nearly every cross-module call in this addon is written defensively:

	    if MC.BindMeshShadowMap then MC.BindMeshShadowMap( material ) end
	    local ok = pcall( something )
	    local id = MC.GetBlockState( bx, by, bz ) or 0

	That style cannot crash, which is why it was chosen - but it also cannot
	REPORT. A missing function silently draws nothing, a swallowed pcall
	silently skips a pass, and `or 0` silently claims "air" where it meant "no
	data" (cl_sky_column.lua paid for that one: sealed rock baked as daylight
	because three different failures all collapsed into the same 0). The
	symptom then surfaces frames later, far from its cause, as a visual
	artefact with no console output attached to it.

	This module keeps the defensive shape but attaches a report to it. A
	guarded site becomes a NAMED fault, and one convar decides what a fault
	does:

	    mc_strict 0   record and continue (default - behaves as before)
	    mc_strict 1   raise a Lua error at the fault site

	Develop with 1 so a broken assumption stops where it broke. Ship with 0 so
	one bad chunk cannot black out the world. Both modes COUNT the fault, so
	`mc_faults` lists what went wrong even when nothing was thrown - that list
	is the point of the module, not the throwing.
------------------------------------------------------------------------------]]

MC = MC or {}

local strict = ConVarExists and ConVarExists( "mc_strict" ) and GetConVar( "mc_strict" )
	or ( CreateConVar and CreateConVar( "mc_strict", "0", FCVAR_ARCHIVE,
		"MC fault handling: 0 records faults and continues, 1 raises a Lua error at the fault site" ) )

-- code -> { count, detail, where, firstTime, lastTime }; `order` keeps report
-- output in first-seen order rather than pairs() order, so a run is comparable
-- to the previous run.
local faults = {}
local order = {}

function MC.StrictFaults()
	return strict ~= nil and strict:GetBool()
end

-- Report a fault.
--
-- `code` is a stable short identifier ("sky_column_no_store"), not a sentence -
-- it is the dedup key and what you grep for. `message` plus varargs is the
-- human half and is only formatted when the fault actually fires, so a guarded
-- site costs one comparison on the happy path.
--
-- Returns false, so a caller can `return MC.Fault( ... )` from a function whose
-- failure value is falsy.
function MC.Fault( code, message, ... )
	code = tostring( code or "unknown" )
	local detail = tostring( message or code )
	if select( "#", ... ) > 0 then
		-- A wrong format string must not become the error being reported -
		-- that replaces a real diagnosis with a lie about string.format.
		local ok, formatted = pcall( string.format, detail, ... )
		if ok then detail = formatted end
	end

	local record = faults[code]
	if not record then
		record = { count = 0, code = code }
		faults[code] = record
		order[#order + 1] = record
	end
	record.count = record.count + 1
	record.detail = detail
	record.lastTime = CurTime and CurTime() or 0
	if record.count == 1 then
		record.firstTime = record.lastTime
		-- Level 3: past Fault and past the guard helper that called it, so the
		-- location points at the site that actually made the assumption.
		record.where = debug and debug.getinfo and debug.getinfo( 3, "Sl" ) or nil
	end

	if MC.StrictFaults() then
		error( "[MC fault] " .. code .. ": " .. detail, 3 )
	end

	-- Repeat faults are counted but not printed: several of these sites sit in
	-- per-frame or per-face loops, and a flooded console hides the first one.
	if record.count == 1 then
		local at = record.where and ( " @ " .. tostring( record.where.short_src )
			.. ":" .. tostring( record.where.currentline ) ) or ""
		MsgN( "[MC fault] " .. code .. ": " .. detail .. at
			.. "  (mc_strict 1 to raise; mc_faults to list)" )
	end
	return false
end

-- `if not MC.Check( ok, ... ) then return end` in place of a bare `if ok then`.
function MC.Check( ok, code, message, ... )
	if ok then return true end
	return MC.Fault( code, message, ... )
end

-- Replacement for the `X and X( ... )` idiom: returns the value when it is
-- present and names the missing dependency when it is not, instead of skipping
-- the call and leaving no trace.
function MC.Need( value, code, message, ... )
	if value ~= nil then return value end
	MC.Fault( code, message, ... )
	return nil
end

-- Replacement for a bare pcall whose error is dropped. Same return shape as
-- pcall, but the error is reported (and in strict mode re-raised with context)
-- rather than discarded.
function MC.Try( code, fn, ... )
	if fn == nil then
		MC.Fault( code, "MC.Try called with no function" )
		return false, nil
	end
	local ok, result = pcall( fn, ... )
	if ok then return true, result end
	MC.Fault( code, "%s", tostring( result ) )
	return false, result
end

function MC.FaultReport()
	return order
end

function MC.ClearFaults()
	faults = {}
	order = {}
end

if concommand and concommand.Add then
	concommand.Add( "mc_faults", function()
		if #order == 0 then
			MsgN( "[MC] no faults recorded (mc_strict "
				.. ( MC.StrictFaults() and "1" or "0" ) .. ")" )
			return
		end
		MsgN( "[MC] " .. #order .. " distinct fault(s), mc_strict "
			.. ( MC.StrictFaults() and "1" or "0" ) .. ":" )
		for i = 1, #order do
			local r = order[i]
			local at = r.where and ( "  " .. tostring( r.where.short_src )
				.. ":" .. tostring( r.where.currentline ) ) or ""
			MsgN( string.format( "  %4dx  %-38s %s%s", r.count, r.code,
				tostring( r.detail ), at ) )
		end
	end )
	concommand.Add( "mc_faults_clear", function()
		MC.ClearFaults()
		MsgN( "[MC] fault log cleared" )
	end )
end
