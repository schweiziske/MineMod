--[[----------------------------------------------------------------------------
	MC : client command helpers.

	Clientside command registration gives the console an autocomplete hook while
	the actual fill operation is still handled by the server's /fill command.
------------------------------------------------------------------------------]]

MC = MC or {}

local function selectedBlockSpec()
	local ply = LocalPlayer()
	local id = IsValid( ply ) and ply:GetNWInt( "mc_block", 1 ) or 1
	local block = MC.Blocks and MC.Blocks[id]

	return tostring( block and block.name or id )
end

local function aimedFillCoords()
	local ply = LocalPlayer()
	if not IsValid( ply ) or not MC.PlayerBlockAim then return nil end
	local hit = MC.PlayerBlockAim( ply )
	if not hit or not hit.bx then return nil end
	return { tostring( hit.bx ), tostring( hit.by ), tostring( hit.bz ) }
end

local function splitAutocompleteArgs( args )
	local raw = tostring( args or "" ):TrimLeft()
	if raw == "" then return {}, false end

	local out = {}
	for part in string.gmatch( raw, "%S+" ) do out[#out + 1] = part end
	return out, string.match( raw, "%s$" ) ~= nil
end

local function copyArgs( args )
	local out = {}
	for i = 1, #args do out[i] = args[i] end
	return out
end

local function buildAutocompleteCommand( cmd, args )
	local out = { cmd or "mc_fill" }
	for i = 1, #args do out[#out + 1] = args[i] end
	return table.concat( out, " " )
end

local function appendCoordsCompletion( out, coords, startCoord )
	for i = startCoord, 3 do out[#out + 1] = coords[i] end
end

local function completeCoordGroup( cmd, args, coords, offset, hasTrailing )
	local out = copyArgs( args )
	local startCoord = offset + 1

	if not hasTrailing and offset > 0 then
		local current = args[#args] or ""
		local target = coords[offset]
		if not target:StartsWith( current ) then return {} end
		out[#out] = target
	end

	appendCoordsCompletion( out, coords, startCoord )
	return { buildAutocompleteCommand( cmd, out ) }
end

local function completeBlock( cmd, args, hasTrailing )
	local block = selectedBlockSpec()
	local out = copyArgs( args )

	if #args == 6 then
		out[#out + 1] = block
	elseif #args == 7 and not hasTrailing then
		local current = args[7] or ""
		if not block:StartsWith( current ) then return {} end
		out[7] = block
	else
		return {}
	end

	return { buildAutocompleteCommand( cmd, out ) }
end

local function shouldFinishCurrentZ( args, coords, hasTrailing )
	if hasTrailing then return false end

	local current = args[#args] or ""
	local target = coords[3]
	return current ~= target and target:StartsWith( current )
end

local function fillAutocomplete( cmd, args )
	local coords = aimedFillCoords()
	if not coords then return {} end

	local parsedArgs, hasTrailing = splitAutocompleteArgs( args )
	local numArgs = #parsedArgs

	if numArgs < 3 then
		return completeCoordGroup( cmd, parsedArgs, coords, numArgs, hasTrailing )
	elseif numArgs == 3 and shouldFinishCurrentZ( parsedArgs, coords, hasTrailing ) then
		return completeCoordGroup( cmd, parsedArgs, coords, 3, hasTrailing )
	elseif numArgs < 6 then
		return completeCoordGroup( cmd, parsedArgs, coords, numArgs - 3, hasTrailing )
	elseif numArgs == 6 and shouldFinishCurrentZ( parsedArgs, coords, hasTrailing ) then
		return completeCoordGroup( cmd, parsedArgs, coords, 3, hasTrailing )
	end

	return completeBlock( cmd, parsedArgs, hasTrailing )
end

local function runFillFromClient( _, _, args )
	RunConsoleCommand( "say", "/fill " .. table.concat( args or {}, " " ) )
end

concommand.Add( "mc_fill", runFillFromClient, fillAutocomplete, "Fill MC blocks; autocomplete inserts the aimed block coordinates." )
