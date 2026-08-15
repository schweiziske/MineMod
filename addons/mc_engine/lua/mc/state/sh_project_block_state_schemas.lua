--[[----------------------------------------------------------------------------
	MC : schemas for project-owned and custom blocks.

	Vanilla schemas are generated from Minecraft's reports. Blocks added by this
	addon do not exist in those reports, so this module gives every registered
	project block a state identity before the immutable registry is frozen.

	Custom blocks may provide stateSchema/blockStateSchema on their definition.
	Otherwise the schema is inferred from the legacy stateRule/orient field.
------------------------------------------------------------------------------]]

MC = MC or {}

local HORIZONTAL_FACING = { "north", "south", "west", "east" }
local FACING = { "down", "up", "north", "south", "west", "east" }

local RULE_SCHEMAS = {
	axis = {
		propertyOrder = { "axis" },
		properties = { axis = { kind = "enum", values = { "x", "y", "z" } } },
		defaults = { axis = "y" },
	},
	facing = {
		propertyOrder = { "facing" },
		properties = { facing = { kind = "enum", values = FACING } },
		defaults = { facing = "north" },
	},
	horizontal_facing = {
		propertyOrder = { "facing" },
		properties = { facing = { kind = "enum", values = HORIZONTAL_FACING } },
		defaults = { facing = "north" },
	},
	slab = {
		propertyOrder = { "type" },
		properties = { type = { kind = "enum", values = { "bottom", "top", "double" } } },
		defaults = { type = "bottom" },
	},
	stairs = {
		propertyOrder = { "facing", "half" },
		properties = {
			facing = { kind = "enum", values = HORIZONTAL_FACING },
			half = { kind = "enum", values = { "bottom", "top" } },
		},
		defaults = { facing = "north", half = "bottom" },
	},
	door = {
		propertyOrder = { "facing", "half", "hinge", "open", "powered" },
		properties = {
			facing = { kind = "enum", values = HORIZONTAL_FACING },
			half = { kind = "enum", values = { "lower", "upper" } },
			hinge = { kind = "enum", values = { "left", "right" } },
			open = { kind = "bool" },
			powered = { kind = "bool" },
		},
		defaults = { facing = "north", half = "lower", hinge = "left", open = false, powered = false },
	},
	trapdoor = {
		propertyOrder = { "facing", "half", "open", "powered" },
		properties = {
			facing = { kind = "enum", values = HORIZONTAL_FACING },
			half = { kind = "enum", values = { "bottom", "top" } },
			open = { kind = "bool" },
			powered = { kind = "bool" },
		},
		defaults = { facing = "north", half = "bottom", open = false, powered = false },
	},
	bed = {
		propertyOrder = { "facing", "part" },
		properties = {
			facing = { kind = "enum", values = HORIZONTAL_FACING },
			part = { kind = "enum", values = { "foot", "head" } },
		},
		defaults = { facing = "north", part = "foot" },
	},
}

local function shallowCopy( input )
	local out = {}
	for key, value in pairs( input or {} ) do out[key] = value end
	return out
end

local function defaultsFromLegacy( block, fallback )
	local defaults = shallowCopy( fallback )
	if not MC.BlockStateText then return defaults end
	local orient = MC.DefaultOrient and MC.DefaultOrient( block.id ) or 0
	local text = MC.BlockStateText( block.id, orient )
	for key, value in string.gmatch( tostring( text or "" ), "([a-z0-9_]+)=([^,]+)" ) do
		if defaults[key] ~= nil then defaults[key] = value end
	end
	return defaults
end

local function inferredDefinition( block )
	if not block.orient then
		return { propertyOrder = {}, properties = {}, defaults = {} }
	end
	local template = RULE_SCHEMAS[block.orient]
	if not template then return nil, "unsupported_state_rule:" .. tostring( block.orient ) end
	return {
		propertyOrder = template.propertyOrder,
		properties = template.properties,
		defaults = defaultsFromLegacy( block, template.defaults ),
	}
end

local function projectDefinition( block )
	local explicit = block.stateSchema
	if explicit ~= nil and type( explicit ) ~= "table" then return nil, "invalid_explicit_schema" end
	local definition, err
	if explicit then
		definition = shallowCopy( explicit )
	else
		definition, err = inferredDefinition( block )
	end
	if not definition then return nil, err end
	definition.name = block.mcid
	definition.blockId = block.id
	return definition
end

function MC.RegisterProjectBlockStateSchema( block )
	if MC.BlockStateRegistryFrozen then return nil, "registry_frozen" end
	if type( MC.RegisterBlockStateSchema ) ~= "function" then return nil, "state_registry_unavailable" end
	if type( block ) ~= "table" or not block.mcid or block.id == nil then return nil, "invalid_block" end
	local existing = MC.PendingBlockStateSchemas[block.mcid]
	if existing then
		if existing.blockId ~= nil and existing.blockId ~= block.id then return nil, "block_id_mismatch" end
		return existing, false
	end
	local definition, definitionError = projectDefinition( block )
	if not definition then return nil, definitionError end
	local schema, registerError = MC.RegisterBlockStateSchema( definition )
	if not schema then return nil, registerError end
	schema.project = true
	return schema, true
end

function MC.RegisterProjectBlockStateSchemas()
	if MC.BlockStateRegistryFrozen then return nil, "registry_frozen" end
	if type( MC.RegisterBlockStateSchema ) ~= "function" then return nil, "state_registry_unavailable" end
	local count = 0
	for _, blockId in ipairs( MC.BlockList or {} ) do
		local block = MC.Blocks and MC.Blocks[blockId] or nil
		if block and block.mcid then
			local schema, created = MC.RegisterProjectBlockStateSchema( block )
			if not schema then return nil, block.mcid .. ":" .. tostring( created ) end
			if created then count = count + 1 end
		end
	end
	return count
end

local count, err = MC.RegisterProjectBlockStateSchemas()
if not count then
	MC.ProjectBlockStateSchemaError = err or "unknown error"
	local message = "[MC] project block-state schemas: " .. tostring( err or "unknown error") .. "\n"
	if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
end
