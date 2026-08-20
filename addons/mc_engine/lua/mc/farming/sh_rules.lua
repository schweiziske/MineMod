-- Minecraft Java 26.2 farming state families and tag projections.
-- This shared file is data/rule-only; authoritative writes stay server-side.

MC = MC or {}
MC.Farming = MC.Farming or {}

local Farming = MC.Farming

Farming.Crops = {
	["minecraft:wheat"] = { maxAge = 7, boneMin = 2, boneMax = 5 },
	["minecraft:carrots"] = { maxAge = 7, boneMin = 2, boneMax = 5 },
	["minecraft:potatoes"] = { maxAge = 7, boneMin = 2, boneMax = 5 },
	["minecraft:beetroots"] = {
		maxAge = 3, boneMin = 2, boneMax = 5, boneDivisor = 3, randomSkipDivisor = 3,
	},
	["minecraft:torchflower_crop"] = {
		maxAge = 2, storedMaxAge = 1, boneMin = 1, boneMax = 1,
		randomSkipDivisor = 3, matureBlock = "minecraft:torchflower",
	},
}

Farming.Stems = {
	["minecraft:melon_stem"] = {
		fruit = "minecraft:melon", attached = "minecraft:attached_melon_stem",
	},
	["minecraft:pumpkin_stem"] = {
		fruit = "minecraft:pumpkin", attached = "minecraft:attached_pumpkin_stem",
	},
}

Farming.AttachedStems = {
	["minecraft:attached_melon_stem"] = {
		fruit = "minecraft:melon", stem = "minecraft:melon_stem",
	},
	["minecraft:attached_pumpkin_stem"] = {
		fruit = "minecraft:pumpkin", stem = "minecraft:pumpkin_stem",
	},
}

Farming.PlantableBlocks = {
	["minecraft:wheat"] = true,
	["minecraft:carrots"] = true,
	["minecraft:potatoes"] = true,
	["minecraft:beetroots"] = true,
	["minecraft:melon_stem"] = true,
	["minecraft:pumpkin_stem"] = true,
	["minecraft:sweet_berry_bush"] = true,
	["minecraft:nether_wart"] = true,
	["minecraft:torchflower_crop"] = true,
	["minecraft:pitcher_crop"] = true,
}

-- Exact Java 26.2 tag expansion used by VegetationBlock and stem fruit support:
-- supports_vegetation = substrate_overworld + farmland.
Farming.SupportsVegetation = {
	["minecraft:dirt"] = true,
	["minecraft:coarse_dirt"] = true,
	["minecraft:rooted_dirt"] = true,
	["minecraft:mud"] = true,
	["minecraft:muddy_mangrove_roots"] = true,
	["minecraft:moss_block"] = true,
	["minecraft:pale_moss_block"] = true,
	["minecraft:grass_block"] = true,
	["minecraft:podzol"] = true,
	["minecraft:mycelium"] = true,
	["minecraft:farmland"] = true,
}

Farming.MaintainsFarmland = {
	["minecraft:pumpkin_stem"] = true,
	["minecraft:attached_pumpkin_stem"] = true,
	["minecraft:melon_stem"] = true,
	["minecraft:attached_melon_stem"] = true,
	["minecraft:beetroots"] = true,
	["minecraft:carrots"] = true,
	["minecraft:potatoes"] = true,
	["minecraft:torchflower_crop"] = true,
	["minecraft:torchflower"] = true,
	["minecraft:pitcher_crop"] = true,
	["minecraft:wheat"] = true,
	["minecraft:moving_piston"] = true,
}

local Horizontal = {
	north = { 0, -1 },
	south = { 0, 1 },
	west = { -1, 0 },
	east = { 1, 0 },
}
Farming.HorizontalDirections = Horizontal
Farming.HorizontalDirectionOrder = { "north", "south", "west", "east" }

function Farming.StateName( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and schema.name or nil
end

function Farming.StateAge( stateId )
	return MC.GetStateProperty and MC.GetStateProperty( stateId, "age" ) or nil
end

function Farming.WithAge( stateId, age )
	return MC.StateWith and MC.StateWith( stateId, "age", age ) or nil
end

function Farming.StateFacing( stateId )
	return MC.GetStateProperty and MC.GetStateProperty( stateId, "facing" ) or nil
end

function Farming.IsCropName( name )
	return Farming.Crops[name] ~= nil
end

function Farming.SupportsCropsState( stateId )
	return Farming.StateName( stateId ) == "minecraft:farmland"
end

function Farming.SupportsNetherWartState( stateId )
	return Farming.StateName( stateId ) == "minecraft:soul_sand"
end

function Farming.SupportsVegetationState( stateId )
	return Farming.SupportsVegetation[Farming.StateName( stateId )] == true
end

function Farming.MaintainsFarmlandState( stateId )
	local name = Farming.StateName( stateId )
	if Farming.MaintainsFarmland[name] then return true end
	return isstring( name ) and string.match( name, "_fence_gate$" ) ~= nil or false
end

function Farming.InitialPlantState( stateId )
	local name = Farming.StateName( stateId )
	if not Farming.PlantableBlocks[name] then return nil, "not_plantable" end
	local initial = MC.DefaultBlockState and MC.DefaultBlockState( name ) or nil
	if not initial then return nil, "plant_state_unavailable" end
	if name == "minecraft:pitcher_crop" then
		initial = MC.StateWith( initial, "age", 0 ) or initial
		initial = MC.StateWith( initial, "half", "lower" ) or initial
	elseif MC.GetStateProperty( initial, "age" ) ~= nil then
		initial = MC.StateWith( initial, "age", 0 ) or initial
	end
	return initial
end

