-- Server authority for creative inventory v2 state selections.

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local MAX_SPEC_BYTES = 512

local function setSelection( ply, id, stateId, spec )
	if not IsValid( ply ) then return false end
	ply:SetNWInt( "mc_block", id )
	if stateId then
		local projectedId, orient = MC.LegacyFromState( stateId )
		ply:SetNWInt( "mc_block_state", stateId )
		ply:SetNWString( "mc_block_state_spec", spec or "" )
		ply:SetNWBool( "mc_block_state_explicit", true )
		ply:SetNWInt( "mc_block_orient", projectedId == id and ( orient or 0 ) or -1 )
	else
		ply:SetNWInt( "mc_block_state", -1 )
		ply:SetNWString( "mc_block_state_spec", "" )
		ply:SetNWBool( "mc_block_state_explicit", false )
		ply:SetNWInt( "mc_block_orient", -1 )
	end
	return true
end

function SV.SelectCreativeLegacy( ply, id, orient )
	id = math.floor( tonumber( id ) or -1 )
	if id <= 0 or not MC.IsValidBlock( id ) then return false end
	orient = tonumber( orient )
	if not orient or orient < 0 then return setSelection( ply, id ) end
	orient = MC.NormalizeOrient( id, orient )
	local stateId = MC.StateFromLegacy( id, orient )
	local spec = stateId and MC.FormatBlockState( stateId ) or nil
	if not stateId or not spec then return false end
	return setSelection( ply, id, stateId, spec )
end

function SV.SelectCreativeStateSpec( ply, id, spec )
	id = math.floor( tonumber( id ) or -1 )
	if id <= 0 or not MC.IsValidBlock( id ) then return false, "invalid_block" end
	spec = tostring( spec or "" )
	if spec == "" or spec == "-" then return setSelection( ply, id ) end
	if #spec > MAX_SPEC_BYTES or string.find( spec, "%c" ) then return false, "invalid_state_spec" end
	local stateId, parseError = MC.ParseBlockState( spec )
	if not stateId or stateId == 0 then return false, parseError or "invalid_state" end
	if MC.BlockTypeForState( stateId ) ~= id then return false, "state_block_mismatch" end
	local canonical = MC.FormatBlockState( stateId )
	if canonical ~= spec then return false, "non_canonical_state" end
	return setSelection( ply, id, stateId, canonical )
end

concommand.Add( "mc_block_sel_v2", function( ply, _, args )
	if not IsValid( ply ) then return end
	SV.SelectCreativeStateSpec( ply, args[1], args[2] )
end )
