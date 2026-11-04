--[[----------------------------------------------------------------------------
	Minimal Garry's Mod API for offline LuaJIT tests of the localization
	runtime. The Python harness supplies the virtual file system and JSON
	decoder through the TEST table before this file runs.
------------------------------------------------------------------------------]]

local TEST = TEST

CLIENT = TEST.realm == "client"
SERVER = not CLIENT

FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED, FCVAR_USERINFO = 128, 256, 8192, 512
HUD_PRINTCONSOLE, HUD_PRINTTALK = 2, 3

TEST.output = {}
function MsgN( ... )
	local parts = {}
	for index = 1, select( "#", ... ) do parts[index] = tostring( ( select( index, ... ) ) ) end
	TEST.output[#TEST.output + 1] = table.concat( parts )
end
Msg = MsgN
print = MsgN
function ErrorNoHalt( message ) TEST.output[#TEST.output + 1] = "ERROR " .. tostring( message ) end

function IsValid( value )
	return type( value ) == "table" and value.valid == true
end

function tobool( value )
	return value ~= nil and value ~= false and value ~= 0 and value ~= "0" and value ~= "false"
end

function isstring( value ) return type( value ) == "string" end
function isnumber( value ) return type( value ) == "number" end
function istable( value ) return type( value ) == "table" end
function isfunction( value ) return type( value ) == "function" end
function isvector() return false end

function CurTime() return 0 end
function SysTime() return os.clock() end

-------------------------------------------------------------------- string
function string.Trim( value ) return ( string.match( value, "^%s*(.-)%s*$" ) ) end
function string.StartWith( value, prefix ) return string.sub( value, 1, #prefix ) == prefix end

-------------------------------------------------------------------- convars
local convars = {}
local callbacks = {}

local ConVar = {}
ConVar.__index = ConVar
function ConVar:GetString() return self.value end
function ConVar:GetBool() return tobool( self.value ) end
function ConVar:GetInt() return math.floor( tonumber( self.value ) or 0 ) end
function ConVar:GetFloat() return tonumber( self.value ) or 0 end
function ConVar:GetName() return self.name end
function ConVar:SetString( value ) TEST.SetConVar( self.name, value ) end

local function createConVar( name, default )
	if not convars[name] then
		convars[name] = setmetatable( { name = name, value = tostring( default ) }, ConVar )
	end
	return convars[name]
end
CreateConVar = createConVar
function CreateClientConVar( name, default ) return createConVar( name, default ) end
function GetConVar( name ) return convars[name] end
function ConVarExists( name ) return convars[name] ~= nil end

function TEST.SetConVar( name, value )
	local cvar = createConVar( name, "" )
	local old = cvar.value
	cvar.value = tostring( value )
	for _, callback in pairs( callbacks[name] or {} ) do callback( name, old, cvar.value ) end
end
-- Changes a convar without notifying Lua (like an engine path that skips it).
function TEST.SetConVarSilently( name, value )
	createConVar( name, "" ).value = tostring( value )
end
function RunConsoleCommand( name, ... ) TEST.SetConVar( name, table.concat( { ... }, " " ) ) end

cvars = {}
function cvars.AddChangeCallback( name, callback, identifier )
	callbacks[name] = callbacks[name] or {}
	callbacks[name][identifier or tostring( callback )] = callback
end
function cvars.RemoveChangeCallback( name, identifier )
	if callbacks[name] then callbacks[name][identifier] = nil end
end

createConVar( "gmod_language", TEST.gameLanguage or "en" )

-------------------------------------------------------------------- misc libraries
TEST.commands = {}
concommand = {}
function concommand.Add( name, callback ) TEST.commands[name] = callback end

TEST.timers = {}
timer = {}
function timer.Create( name, _, _, callback ) TEST.timers[name] = callback end
function timer.Simple( _, callback ) TEST.timers[#TEST.timers + 1] = callback end
function timer.Remove( name ) TEST.timers[name] = nil end

TEST.hooks = {}
hook = {}
function hook.Add( event, name, callback )
	TEST.hooks[event] = TEST.hooks[event] or {}
	TEST.hooks[event][name] = callback
end
function hook.Remove( event, name ) if TEST.hooks[event] then TEST.hooks[event][name] = nil end end
function hook.Run( event, ... )
	TEST.events = TEST.events or {}
	TEST.events[#TEST.events + 1] = { event, ... }
	for _, callback in pairs( TEST.hooks[event] or {} ) do
		local result = callback( ... )
		if result ~= nil then return result end
	end
end
function hook.GetTable() return TEST.hooks end

TEST.phrases = {}
language = {}
function language.Add( name, text ) TEST.phrases[name] = text end
function language.GetPhrase( name ) return TEST.phrases[name] or name end

-------------------------------------------------------------------- files
file = {}
function file.Find( pattern, pathID ) return TEST.Find( pattern, pathID ) end
function file.Read( path, pathID ) return TEST.Read( path, pathID ) end
function file.Size( path, pathID ) return TEST.Size( path, pathID ) end
function file.Exists( path, pathID ) return TEST.Read( path, pathID ) ~= nil end

util = {}
function util.JSONToTable( text ) return TEST.DecodeJSON( text ) end
function util.TableToJSON( value ) return TEST.EncodeJSON( value ) end

net = {}
