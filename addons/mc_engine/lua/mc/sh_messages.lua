-- Player notifications carry message specs, never server-rendered translations.
-- This protocol has no client-to-server receiver and transfers no dictionaries.
MC.Messages = MC.Messages or {}
local Messages = MC.Messages
local I18n = MC.I18n
local MAX_BYTES = 8192
local MAX_STRING = 2048
local MAX_VARS = 32
local MAX_VALUES = 128
local MAX_DEPTH = 4
local CHANNELS = { chat = 0, console = 1, both = 2 }

function Messages.Spec( key, vars )
	return { key = key, vars = vars }
end

-- Copy and validate at the transport boundary. Numeric placeholder indices
-- become strings so JSON object/array conversion cannot change their meaning.
local function normalize( spec )
	if type( spec ) == "string" then spec = Messages.Spec( spec ) end
	local values = 0
	local function visit( node, depth )
		if depth > MAX_DEPTH or type( node ) ~= "table" then return nil, "invalid_message_spec" end
		if not I18n.ValidKey( node.key ) then return nil, "invalid_message_key" end
		for field in pairs( node ) do
			if field ~= "key" and field ~= "vars" then return nil, "invalid_message_field" end
		end
		local result = { key = node.key }
		if node.vars ~= nil then
			if type( node.vars ) ~= "table" then return nil, "invalid_message_vars" end
			local vars, count = {}, 0
			for name, value in pairs( node.vars ) do
				count, values = count + 1, values + 1
				if count > MAX_VARS or values > MAX_VALUES then return nil, "message_too_many_vars" end
				if type( name ) == "number" and name >= 1 and name <= MAX_VALUES and name == math.floor( name ) then
					name = tostring( name )
				end
				if type( name ) ~= "string" or #name > 64 or not string.match( name, "^[%w_]+$" )
					or vars[name] ~= nil then return nil, "invalid_message_var_name" end
				local kind = type( value )
				if kind == "table" then
					local child, err = visit( value, depth + 1 )
					if not child then return nil, err end
					vars[name] = child
				elseif kind == "string" then
					if #value > MAX_STRING then return nil, "message_string_too_long" end
					vars[name] = value
				elseif kind == "number" and value == value and value ~= math.huge and value ~= -math.huge then
					vars[name] = value
				else
					return nil, "invalid_message_value"
				end
			end
			-- An absent vars object and an empty one mean the same thing.
			if count > 0 then result.vars = vars end
		end
		return result
	end
	return visit( spec, 0 )
end

function Messages.Encode( spec )
	if spec == nil then return "" end
	local checked, err = normalize( spec )
	if not checked then return nil, err end
	local payload = util.TableToJSON( checked )
	if type( payload ) ~= "string" then return nil, "message_encode_failed" end
	if #payload > MAX_BYTES then return nil, "message_too_large" end
	return payload
end

function Messages.Decode( payload )
	if payload == "" then return nil end
	if type( payload ) ~= "string" or #payload > MAX_BYTES then return nil, "invalid_message_payload" end
	local ok, spec = pcall( util.JSONToTable, payload, false, true )
	if not ok or type( spec ) ~= "table" then return nil, "invalid_message_payload" end
	return normalize( spec )
end

function Messages.Read()
	local spec, err = Messages.Decode( net.ReadString() )
	if err then MC.Fault( "message_decode", "%s", err ) end
	return spec, err
end

function Messages.Console( key, vars )
	MsgN( "[MC] " .. I18n.Resolve( key, vars, I18n.ConsoleLanguage() ) )
end

function Messages.Notify( ply, key, vars, channel )
	if not SERVER then return false, "server_only" end
	if not IsValid( ply ) or not ply:IsPlayer() then return false, "invalid_player" end
	local channelID = CHANNELS[channel or "chat"]
	if channelID == nil then return false, "invalid_message_channel" end
	local spec = type( key ) == "string" and Messages.Spec( key, vars ) or key
	if spec == nil then return false, "invalid_message_spec" end
	local payload, err = Messages.Encode( spec )
	if not payload then
		MC.Fault( "message_encode", "%s", err )
		return false, err
	end
	net.Start( "mc_message" )
		net.WriteUInt( channelID, 2 )
		net.WriteString( payload )
	net.Send( ply )
	return true
end

-- Command callbacks receive an invalid player for the server console.
function Messages.Reply( ply, key, vars, channel )
	if IsValid( ply ) then return Messages.Notify( ply, key, vars, channel ) end
	Messages.Console( key, vars )
	return true
end

if CLIENT then
	net.Receive( "mc_message", function()
		local channel = net.ReadUInt( 2 )
		local spec, err = Messages.Read()
		if err or not spec then return end
		if channel > 2 then MC.Fault( "message_channel", "invalid channel %d", channel ) return end
		local text = "[MC] " .. I18n.Resolve( spec )
		if channel == 0 or channel == 2 then chat.AddText( text ) end
		if channel == 1 or channel == 2 then MsgN( text ) end
	end )
end
