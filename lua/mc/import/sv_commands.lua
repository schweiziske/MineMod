-- Admin/chat commands for the strict Phase 5 Minecraft world importer.

MC = MC or {}
MC.Import = MC.Import or {}
MC.SV = MC.SV or {}

local Import, SV = MC.Import, MC.SV
local USAGE = "Usage: mc_import <mc_import/file.json> [replace|append] [reject|preserve]"

local function tell( ply, message )
	message = tostring( message or "" )
	if IsValid( ply ) then ply:ChatPrint( message ) else MsgN( "[MC] " .. message ) end
end

local function commandArgs( args )
	local first = string.lower( tostring( args[1] or "" ) )
	local base = ( first == "/mc_import" or first == "!mc_import" or first == "mc_import" ) and 2 or 1
	local path = Import.NormalizePath( args[base] )
	local mode = string.lower( tostring( args[base + 1] or "replace" ) )
	local unknownPolicy = string.lower( tostring( args[base + 2] or "reject" ) )
	if not path or ( mode ~= "replace" and mode ~= "append" )
	or ( unknownPolicy ~= "reject" and unknownPolicy ~= "preserve" ) then
		return nil, USAGE
	end
	return { path = path, mode = mode, unknownPolicy = unknownPolicy }
end

local function runImport( ply, args )
	if IsValid( ply ) and not ply:IsAdmin() then return end
	local options, argumentError = commandArgs( args )
	if not options then tell( ply, argumentError ) return end
	local result, importError, errorIndex = SV.ImportWorldPath( options.path, options )
	if not result then
		tell( ply, "Import failed: " .. tostring( importError ) .. ( errorIndex and ( " #" .. tostring( errorIndex ) ) or "" ) )
		return
	end
	tell( ply, "Import complete: " .. tostring( result.imported ) .. " state cells, current total " .. tostring( result.total ) )
	tell( ply, "Validation: DataVersion=" .. tostring( result.dataVersion ) .. " " .. tostring( result.lossSummary or "" ) )
	MsgN( "[MC] imported " .. options.path .. " (" .. options.mode .. ", " .. options.unknownPolicy .. ")" )
end

hook.Add( "PlayerSay", "mc_import_command", function( ply, text )
	local args = string.Explode( "%s+", string.Trim( text ), true )
	local command = string.lower( tostring( args[1] or "" ) )
	if command == "/mc_import" or command == "!mc_import" then
		runImport( ply, args )
		return ""
	end
end )

concommand.Add( "mc_import", function( ply, _, args ) runImport( ply, args ) end )

concommand.Add( "mc_import_probe", function( ply, _, args )
	if IsValid( ply ) and not ply:IsAdmin() then return end
	local path = Import.NormalizePath( args[1] )
	if not path then tell( ply, USAGE ) return end
	local source, readError = Import.ReadBundle( path )
	if not source then tell( ply, "probe failed: " .. tostring( readError ) ) return end
	local plan, preflightError, errorIndex = Import.Preflight( source, {
		unknownPolicy = tostring( args[2] or "reject" ),
		worldBoundsOK = SV.WorldImportHost.worldBoundsOK,
	} )
	if not plan then
		tell( ply, "probe rejected: " .. tostring( preflightError ) .. ( errorIndex and ( " #" .. tostring( errorIndex ) ) or "" ) )
		return
	end
	tell( ply, "probe ok: chunks=" .. tostring( #plan.chunks ) .. " states=" .. tostring( plan.cellCount ) ..
		" opaqueBE=" .. tostring( plan.opaqueBlockEntityCount ) .. " " .. Import.LossSummary( source.manifest ) )
end )
