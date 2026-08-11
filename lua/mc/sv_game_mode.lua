-- Server-authoritative per-player game modes and the mc_gamemode command.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
SV.PlayerGameModes = SV.PlayerGameModes or {}
local PDATA_KEY = "mc_gamemode"

local function validMode( value )
	return MC.NormalizeGameMode( value ) or "survival"
end

local function notify( ply, message )
	if IsValid( ply ) then
		ply:ChatPrint( "[MC] " .. tostring( message ) )
		ply:PrintMessage( HUD_PRINTCONSOLE, "[MC] " .. tostring( message ) )
	else
		MsgN( "[MC] " .. tostring( message ) )
	end
end

local function persistentMode( ply )
	if not IsValid( ply ) or ply:IsBot() then return nil end
	local value = ply:GetPData( PDATA_KEY, "" )
	return MC.NormalizeGameMode( value )
end

function SV.GetPlayerGameMode( ply )
	if not IsValid( ply ) then return "survival" end
	local mode = SV.PlayerGameModes[ply]
	if not mode then
		mode = persistentMode( ply )
		if not mode then
			local configured = MC.Config.DefaultGameMode and MC.Config.DefaultGameMode:GetString() or "survival"
			mode = validMode( configured )
		end
		SV.PlayerGameModes[ply] = mode
	end
	if ply:GetNWString( "mc_gamemode", "" ) ~= mode then ply:SetNWString( "mc_gamemode", mode ) end
	return mode
end

function SV.PlayerIsCreative( ply )
	return SV.GetPlayerGameMode( ply ) == "creative"
end

function SV.SetPlayerGameMode( ply, value, actor )
	if not IsValid( ply ) or not ply:IsPlayer() then return false, "invalid_player" end
	local mode = MC.NormalizeGameMode( value )
	if not mode then return false, "invalid_game_mode" end
	local oldMode = SV.GetPlayerGameMode( ply )
	SV.PlayerGameModes[ply] = mode
	ply:SetNWString( "mc_gamemode", mode )
	if not ply:IsBot() then ply:SetPData( PDATA_KEY, mode ) end

	if SV.CancelMining then SV.CancelMining( ply, "game_mode_changed" ) end
	if SV.CancelSelectedItemUse then SV.CancelSelectedItemUse( ply, "game_mode_changed" ) end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if SV.ClosePlayerInventory and record and record.session then
		SV.ClosePlayerInventory( ply, "game_mode_changed" )
	end
	if MC.RunEvent and oldMode ~= mode then MC.RunEvent( "MC.PlayerGameModeChanged", ply, oldMode, mode, actor ) end
	return true, oldMode, mode
end

local function findTargets( query )
	query = string.Trim( tostring( query or "" ) )
	if query == "" then return {} end
	local lowered = string.lower( query )
	local exact, partial = {}, {}
	for _, ply in ipairs( player.GetAll() ) do
		local userID = tostring( ply:UserID() )
		local steamID = string.lower( tostring( ply:SteamID() or "" ) )
		local steam64 = tostring( ply:SteamID64() or "" )
		local nick = string.lower( tostring( ply:Nick() or "" ) )
		if lowered == userID or lowered == steamID or lowered == steam64 or lowered == nick then
			exact[#exact + 1] = ply
		elseif string.find( nick, lowered, 1, true ) then
			partial[#partial + 1] = ply
		end
	end
	return #exact > 0 and exact or partial
end

local function command( ply, _, args )
	if IsValid( ply ) and not ply:IsAdmin() then
		notify( ply, "只有管理员可以修改 Minecraft 游戏模式" )
		return
	end
	local mode = MC.NormalizeGameMode( args[1] )
	if not mode then
		notify( ply, "用法: mc_gamemode <creative|survival> [玩家]" )
		return
	end
	local query = table.concat( args, " ", 2 )
	local targets
	if query == "" and IsValid( ply ) then
		targets = { ply }
	else
		targets = findTargets( query )
	end
	if #targets == 0 then notify( ply, "找不到目标玩家" ) return end
	if #targets > 1 then notify( ply, "目标不唯一，请输入完整玩家名或 SteamID" ) return end
	local target = targets[1]
	local ok, oldMode = SV.SetPlayerGameMode( target, mode, ply )
	if not ok then notify( ply, "修改游戏模式失败: " .. tostring( oldMode ) ) return end
	notify( ply, string.format( "%s 的游戏模式已设置为 %s", target:Nick(), mode ) )
	if target ~= ply then notify( target, string.format( "管理员将你的游戏模式设置为 %s", mode ) ) end
end

concommand.Add( "mc_gamemode", command, nil, "Set a player's Minecraft mode: mc_gamemode <creative|survival> [player]" )

hook.Add( "PlayerInitialSpawn", "mc_initialize_player_game_mode", function( ply )
	timer.Simple( 0, function()
		if IsValid( ply ) then SV.GetPlayerGameMode( ply ) end
	end )
end )

hook.Add( "PlayerDisconnected", "mc_clear_player_game_mode", function( ply )
	SV.PlayerGameModes[ply] = nil
	if SV.MiningSessions then SV.MiningSessions[ply] = nil end
end )

for _, ply in ipairs( player.GetAll() ) do SV.GetPlayerGameMode( ply ) end
