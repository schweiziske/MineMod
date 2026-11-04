--[[----------------------------------------------------------------------------
	MC : server-side admin bridge for the config menu.
------------------------------------------------------------------------------]]

MC = MC or {}

util.AddNetworkString( "mc_config_set" )
util.AddNetworkString( "mc_config_get" )
util.AddNetworkString( "mc_config_values" )

local function canSetServerConfig( ply )
	return IsValid( ply ) and ply:IsAdmin()
end

local function countServerConfigValues()
	local count = 0
	for _, category in ipairs( MC.ConfigConVars.server or {} ) do
		for _, item in ipairs( category.items or {} ) do
			if GetConVar( item.name ) then
				count = count + 1
			end
		end
	end
	return count
end

-- Entries whose choices only the server knows, such as its loaded locales.
local function serverChoiceLists()
	local lists = {}
	for _, category in ipairs( MC.ConfigConVars.server or {} ) do
		for _, item in ipairs( category.items or {} ) do
			if item.serverChoices and #lists < 255 then
				local values = {}
				for index, entry in ipairs( item.serverChoices() ) do
					if index > 255 then break end
					values[index] = tostring( entry.value )
				end
				lists[#lists + 1] = { name = item.name, values = values }
			end
		end
	end
	return lists
end

local function sendServerConfigValues( ply )
	if not IsValid( ply ) then return end

	local lists = serverChoiceLists()
	net.Start( "mc_config_values" )
		net.WriteUInt( countServerConfigValues(), 12 )
		for _, category in ipairs( MC.ConfigConVars.server or {} ) do
			for _, item in ipairs( category.items or {} ) do
				local cvar = GetConVar( item.name )
				if cvar then
					net.WriteString( item.name )
					net.WriteString( cvar:GetString() )
				end
			end
		end
		net.WriteUInt( #lists, 8 )
		for _, list in ipairs( lists ) do
			net.WriteString( list.name )
			net.WriteUInt( #list.values, 8 )
			for _, value in ipairs( list.values ) do net.WriteString( value ) end
		end
	net.Send( ply )
end

net.Receive( "mc_config_get", function( _, ply )
	sendServerConfigValues( ply )
end )

net.Receive( "mc_config_set", function( _, ply )
	if not canSetServerConfig( ply ) then return end

	local name = string.Trim( net.ReadString() or "" )
	local value = string.Trim( net.ReadString() or "" )
	if name == "" or #name > 96 or #value > 512 then return end
	if not MC.FindConfigConVar( "server", name ) then return end

	local cvar = GetConVar( name )
	if not cvar then return end
	cvar:SetString( value )
	sendServerConfigValues( ply )
end )
