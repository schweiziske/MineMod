-- Shared enchanting-table interaction binding. The table itself stays in the
-- normal static block mesh; only its floating book is a client block-entity
-- visual, implemented by cl_enchanting.lua.

MC = MC or {}

local API = MC.API or {}
local Blocks = API.Blocks or {}
local BLOCK_ENTITY_TYPE = "minecraft:enchanting_table"
local HANDLERS = {
	OnUse = function( ply, bx, by, bz )
		if not SERVER or not MC.SV or not MC.SV.OpenEnchantingTable then return false end
		return MC.SV.OpenEnchantingTable( ply, bx, by, bz ) == true
	end,
}

local function reportRegistrationError( action, err )
	if not ErrorNoHalt then return end
	ErrorNoHalt( "[MC Enchanting] failed to " .. action .. ": "
		.. tostring( err or "unknown" ) .. "\n" )
end

-- Java 26.2 models the enchanting table as a real Block Entity. Its animation
-- fields are transient client state; the only persistent vanilla field is an
-- optional custom name, which the current item-placement layer does not yet
-- transfer. Register an empty client-visible record so the public Block Entity
-- index can discover every loaded table without walking MC.World.
local blockEntityReady = false
if type( Blocks.IsBlockEntityTypeRegistered ) == "function"
and Blocks.IsBlockEntityTypeRegistered( BLOCK_ENTITY_TYPE ) then
	blockEntityReady = true
elseif type( Blocks.RegisterBlockEntityType ) == "function" then
	local ok, err = Blocks.RegisterBlockEntityType( {
		name = BLOCK_ENTITY_TYPE,
		codecVersion = 1,
		affectsGeometry = false,
		affectsCollision = false,
		CreateDefault = function()
			return { type = BLOCK_ENTITY_TYPE, codecVersion = 1, data = {} }
		end,
		Validate = function( data )
			return type( data ) == "table", "invalid_enchanting_table_data"
		end,
		Encode = function( data )
			if type( data ) ~= "table" then return nil, "invalid_enchanting_table_data" end
			return {}
		end,
		Decode = function( data )
			if type( data ) ~= "table" then return nil, "invalid_enchanting_table_data" end
			return {}
		end,
	} )
	blockEntityReady = ok == true
	if not blockEntityReady then reportRegistrationError( "register enchanting-table Block Entity", err ) end
else
	reportRegistrationError( "register enchanting-table Block Entity", "block_entity_api_unavailable" )
end

if blockEntityReady and type( Blocks.BindBlockEntityType ) == "function" then
	local ok, err = Blocks.BindBlockEntityType( "minecraft:enchanting_table", BLOCK_ENTITY_TYPE )
	if ok ~= true then reportRegistrationError( "bind enchanting-table Block Entity", err ) end
elseif blockEntityReady then
	reportRegistrationError( "bind enchanting-table Block Entity", "block_entity_api_unavailable" )
end

if type( Blocks.SetHandlers ) == "function" then
	local ok, err = Blocks.SetHandlers( "minecraft:enchanting_table", HANDLERS )
	if ok ~= true then reportRegistrationError( "bind enchanting-table handlers", err ) end
end

function MC.IsEnchantingTableBlock( id )
	if type( Blocks.Resolve ) ~= "function" then return false end
	local block = Blocks.Resolve( id )
	return block and ( block.mcid == "minecraft:enchanting_table" or block.name == "enchanting_table" ) or false
end
