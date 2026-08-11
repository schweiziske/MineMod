--[[----------------------------------------------------------------------------
	Minecraft recipe and item-tag registry.

	The data payload is generated from out/data/minecraft/recipe and item tags.
	Crafting matching follows CraftingInput/ ShapedRecipePattern semantics from
	the reference sources: trim the outer empty border, require exact dimensions,
	try the mirrored shaped pattern, and use bipartite matching for shapeless
	ingredients so overlapping tags cannot make a valid recipe fail.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.RecipeAbsoluteMaxResult = 99
MC.PendingRecipes = MC.PendingRecipes or {}
MC.Recipes = MC.Recipes or {}
MC.RecipesById = MC.RecipesById or {}
MC.RecipesByType = MC.RecipesByType or {}
MC.PendingItemTags = MC.PendingItemTags or {}
MC.ItemTags = MC.ItemTags or {}
MC.RecipeRegistryFrozen = MC.RecipeRegistryFrozen or false
MC.RecipeRegistryHash = MC.RecipeRegistryHash or nil

local COOKING_DEFAULT_TICKS = {
	["minecraft:smelting"] = 200,
	["minecraft:blasting"] = 100,
}

local function trim( value )
	return string.match( tostring( value or "" ), "^%s*(.-)%s*$" )
end

local function normalizeName( value )
	local name = string.lower( trim( value ) )
	if name == "" then return nil end
	if not string.find( name, ":", 1, true ) then name = "minecraft:" .. name end
	if not string.match( name, "^[a-z0-9_.-]+:[a-z0-9_./-]+$" ) then return nil end
	return name
end

local function normalizeTagName( value )
	value = trim( value )
	if string.sub( value, 1, 1 ) == "#" then value = string.sub( value, 2 ) end
	return normalizeName( value )
end

local function copyValue( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, item in pairs( value ) do out[copyValue( key, seen )] = copyValue( item, seen ) end
	return out
end

local function arrayLength( value )
	if type( value ) ~= "table" then return 0 end
	return #value
end

local function normalizeIngredient( value )
	if isstring( value ) then
		value = trim( value )
		if value == "" then return nil, "empty_ingredient" end
		if string.sub( value, 1, 1 ) == "#" then
			local tag = normalizeTagName( value )
			if not tag then return nil, "invalid_ingredient_tag" end
			return { kind = "tag", tag = tag }
		end
		local item = normalizeName( value )
		if not item then return nil, "invalid_ingredient_item" end
		return { kind = "item", item = item }
	end
	if type( value ) ~= "table" then return nil, "invalid_ingredient" end
	if value.item ~= nil or value.tag ~= nil then
		if value.item ~= nil then
			local item = normalizeName( value.item )
			if not item then return nil, "invalid_ingredient_item" end
			return { kind = "item", item = item }
		end
		local tag = normalizeTagName( value.tag )
		if not tag then return nil, "invalid_ingredient_tag" end
		return { kind = "tag", tag = tag }
	end
	if #value < 1 then return nil, "empty_ingredient_alternatives" end
	local alternatives = {}
	for _, candidate in ipairs( value ) do
		local normalized, err = normalizeIngredient( candidate )
		if not normalized then return nil, err end
		if normalized.kind == "alternatives" then
			for _, nested in ipairs( normalized.items ) do alternatives[#alternatives + 1] = nested end
		else
			alternatives[#alternatives + 1] = normalized
		end
	end
	return { kind = "alternatives", items = alternatives }
end

local function normalizeResult( result )
	if type( result ) ~= "table" then return nil, "missing_recipe_result" end
	local item = normalizeName( result.id or result.item )
	if not item then return nil, "invalid_recipe_result_item" end
	local count = math.floor( tonumber( result.count ) or 1 )
	if count < 1 or count > MC.RecipeAbsoluteMaxResult then return nil, "invalid_recipe_result_count" end
	local stack, stackError = MC.NormalizeItemStack( {
		item = item,
		count = count,
		components = result.components,
		damage = result.damage,
	} )
	if not stack then return nil, stackError or "invalid_recipe_result" end
	return stack
end

local function normalizeCooking( recipeType, source )
	local ingredient, ingredientError = normalizeIngredient( source.ingredient )
	if not ingredient then return nil, ingredientError end
	local result, resultError = normalizeResult( source.result )
	if not result then return nil, resultError end
	local cookingTime = math.floor( tonumber( source.cookingtime or source.cooking_time )
		or COOKING_DEFAULT_TICKS[recipeType] or 200 )
	if cookingTime < 1 or cookingTime > 72000 then return nil, "invalid_cooking_time" end
	local experience = tonumber( source.experience ) or 0
	if experience ~= experience or experience == math.huge or experience == -math.huge
		or experience < 0 or experience > 1024 then
		return nil, "invalid_cooking_experience"
	end
	return {
		ingredient = ingredient,
		result = result,
		cookingTime = cookingTime,
		experience = experience,
	}
end

local function firstNonEmpty( line )
	local index = 1
	while index <= #line and string.sub( line, index, index ) == " " do index = index + 1 end
	return index
end

local function lastNonEmpty( line )
	local index = #line
	while index >= 1 and string.sub( line, index, index ) == " " do index = index - 1 end
	return index
end

local function shrinkPattern( pattern )
	if type( pattern ) ~= "table" or #pattern < 1 or #pattern > 3 then return nil, "invalid_recipe_pattern" end
	local width = #tostring( pattern[1] or "" )
	if width < 1 or width > 3 then return nil, "invalid_recipe_pattern_width" end
	local left, right, top, bottom = width, 0, 1, 0
	for rowIndex, rawLine in ipairs( pattern ) do
		local line = tostring( rawLine or "" )
		if #line ~= width then return nil, "inconsistent_recipe_pattern_width" end
		local first, last = firstNonEmpty( line ), lastNonEmpty( line )
		if last < first then
			if top == rowIndex then top = top + 1 end
			bottom = bottom + 1
		else
			left = math.min( left, first )
			right = math.max( right, last )
			bottom = 0
		end
	end
	if bottom == #pattern then return nil, "empty_recipe_pattern" end
	local rows = {}
	for rowIndex = top, #pattern - bottom do
		rows[#rows + 1] = string.sub( tostring( pattern[rowIndex] ), left, right )
	end
	return rows, right - left + 1, #rows
end

local function normalizeShaped( data )
	local rows, width, height = shrinkPattern( data.pattern )
	if not rows then return nil, width end
	if type( data.key ) ~= "table" then return nil, "missing_recipe_key" end
	local key, used = {}, {}
	for symbol, rawIngredient in pairs( data.key ) do
		if not isstring( symbol ) or #symbol ~= 1 or symbol == " " then return nil, "invalid_recipe_symbol" end
		local ingredient, err = normalizeIngredient( rawIngredient )
		if not ingredient then return nil, err end
		key[symbol] = ingredient
	end
	local ingredients = {}
	for _, row in ipairs( rows ) do
		for index = 1, #row do
			local symbol = string.sub( row, index, index )
			if symbol == " " then
				ingredients[#ingredients + 1] = false
			else
				if not key[symbol] then return nil, "pattern_symbol_missing_from_key" end
				used[symbol] = true
				ingredients[#ingredients + 1] = key[symbol]
			end
		end
	end
	for symbol in pairs( key ) do if not used[symbol] then return nil, "unused_recipe_symbol" end end
	local symmetrical = true
	for y = 0, height - 1 do
		for x = 0, math.floor( width / 2 ) - 1 do
			local leftIngredient = ingredients[x + y * width + 1]
			local rightIngredient = ingredients[width - x - 1 + y * width + 1]
			if not MC.IngredientsEqual( leftIngredient, rightIngredient ) then symmetrical = false end
		end
	end
	return {
		width = width,
		height = height,
		pattern = rows,
		ingredients = ingredients,
		ingredientCount = (function()
			local count = 0
			for index = 1, width * height do if ingredients[index] then count = count + 1 end end
			return count
		end)(),
		symmetrical = symmetrical,
	}, nil
end

local function normalizeShapeless( data )
	if type( data.ingredients ) ~= "table" or #data.ingredients < 1 or #data.ingredients > 9 then
		return nil, "invalid_shapeless_ingredients"
	end
	local ingredients = {}
	for _, rawIngredient in ipairs( data.ingredients ) do
		local ingredient, err = normalizeIngredient( rawIngredient )
		if not ingredient then return nil, err end
		ingredients[#ingredients + 1] = ingredient
	end
	return { ingredients = ingredients, ingredientCount = #ingredients }, nil
end

function MC.IngredientsEqual( left, right )
	if left == right then return true end
	if not left or not right or left.kind ~= right.kind then return false end
	if left.kind == "item" then return left.item == right.item end
	if left.kind == "tag" then return left.tag == right.tag end
	if #left.items ~= #right.items then return false end
	for index = 1, #left.items do if not MC.IngredientsEqual( left.items[index], right.items[index] ) then return false end end
	return true
end

function MC.RegisterItemTag( name, values, options )
	if MC.RecipeRegistryFrozen then return nil, "registry_frozen" end
	local tag = normalizeTagName( name )
	if not tag or type( values ) ~= "table" then return nil, "invalid_item_tag" end
	options = type( options ) == "table" and options or {}
	local existing = MC.PendingItemTags[tag]
	if existing and options.replace ~= true then
		for _, value in ipairs( values ) do existing.values[#existing.values + 1] = value end
	else
		MC.PendingItemTags[tag] = { values = copyValue( values ) }
	end
	return MC.PendingItemTags[tag]
end

local function tagValueName( value )
	if isstring( value ) then return value end
	if type( value ) == "table" then return value.id or value.tag end
	return nil
end

function MC.FinalizeItemTags()
	local resolved, resolving = {}, {}
	local function resolve( tag )
		if resolved[tag] then return resolved[tag] end
		if resolving[tag] then return {} end
		resolving[tag] = true
		local list, seen = {}, {}
		local source = MC.PendingItemTags[tag]
		for _, raw in ipairs( source and source.values or {} ) do
			local value = tagValueName( raw )
			if isstring( value ) and string.sub( value, 1, 1 ) == "#" then
				local nestedEntry = resolve( normalizeTagName( value ) )
				for _, nested in ipairs( nestedEntry.items or {} ) do
					if not seen[nested] then seen[nested] = true; list[#list + 1] = nested end
				end
			elseif value then
				local item = normalizeName( value )
				if item and not seen[item] then seen[item] = true; list[#list + 1] = item end
			end
		end
		table.sort( list )
		local set = {}
		for _, item in ipairs( list ) do set[item] = true end
		resolved[tag] = { items = list, set = set }
		resolving[tag] = nil
		return resolved[tag]
	end
	for tag in pairs( MC.PendingItemTags ) do resolve( tag ) end
	MC.ItemTags = resolved
	return resolved
end

function MC.ItemInTag( item, tag )
	local itemName = normalizeName( type( item ) == "table" and item.item or item )
	local tagName = normalizeTagName( tag )
	local entry = tagName and MC.ItemTags[tagName] or nil
	return itemName ~= nil and entry ~= nil and entry.set[itemName] == true
end

function MC.IngredientMatches( ingredient, stack )
	if not ingredient or MC.IsEmptyItemStack( stack ) then return false end
	local itemName = normalizeName( stack.item )
	if not itemName then return false end
	if ingredient.kind == "item" then return itemName == ingredient.item end
	if ingredient.kind == "tag" then return MC.ItemInTag( itemName, ingredient.tag ) end
	for _, candidate in ipairs( ingredient.items or {} ) do
		if MC.IngredientMatches( candidate, stack ) then return true end
	end
	return false
end

function MC.IngredientChoices( ingredient )
	if not ingredient then return {} end
	if ingredient.kind == "item" then return { ingredient.item } end
	if ingredient.kind == "tag" then
		local entry = MC.ItemTags[ingredient.tag]
		return entry and entry.items or {}
	end
	local output, seen = {}, {}
	for _, candidate in ipairs( ingredient.items or {} ) do
		for _, item in ipairs( MC.IngredientChoices( candidate ) ) do
			if not seen[item] then seen[item] = true; output[#output + 1] = item end
		end
	end
	table.sort( output )
	return output
end

function MC.RegisterRecipe( idOrDefinition, data )
	if MC.RecipeRegistryFrozen then return nil, "registry_frozen" end
	local id, source
	if type( idOrDefinition ) == "table" then
		source = idOrDefinition.data or idOrDefinition
		id = idOrDefinition.id or source.id
	else
		id, source = idOrDefinition, data
	end
	id = normalizeName( id )
	if not id or type( source ) ~= "table" then return nil, "invalid_recipe_definition" end
	if MC.PendingRecipes[id] then return nil, "duplicate_recipe" end
	local recipeType = normalizeName( source.type or "minecraft:crafting_shaped" )
	if not recipeType then return nil, "invalid_recipe_type" end
	local recipe = {
		id = id,
		type = recipeType,
		group = isstring( source.group ) and source.group or "",
		category = isstring( source.category ) and source.category or "misc",
		showNotification = source.show_notification ~= false,
		raw = copyValue( source ),
		supported = false,
	}
	if recipeType == "minecraft:crafting_shaped" then
		local normalized, err = normalizeShaped( source )
		if not normalized then return nil, err end
		local result, resultError = normalizeResult( source.result )
		if not result then return nil, resultError end
		for key, value in pairs( normalized ) do recipe[key] = value end
		recipe.result = result
		recipe.supported = true
	elseif recipeType == "minecraft:crafting_shapeless" then
		local normalized, err = normalizeShapeless( source )
		if not normalized then return nil, err end
		local result, resultError = normalizeResult( source.result )
		if not result then return nil, resultError end
		for key, value in pairs( normalized ) do recipe[key] = value end
		recipe.result = result
		recipe.supported = true
	elseif COOKING_DEFAULT_TICKS[recipeType] then
		local normalized, err = normalizeCooking( recipeType, source )
		if not normalized then return nil, err end
		for key, value in pairs( normalized ) do recipe[key] = value end
		recipe.supported = true
	else
		-- Keep every vanilla JSON recipe addressable. Machine/special recipe
		-- behavior can be attached later without changing the registry format.
		if source.result then recipe.result = normalizeResult( source.result ) end
	end
	MC.PendingRecipes[id] = recipe
	return recipe
end

function MC.FinalizeRecipeRegistry()
	if MC.RecipeRegistryFrozen then return #MC.Recipes end
	MC.FinalizeItemTags()
	local ids = {}
	for id in pairs( MC.PendingRecipes ) do ids[#ids + 1] = id end
	table.sort( ids )
	local byId, byType, ordered, canonical = {}, {}, {}, { "mc-recipe-registry-v1\n" }
	for _, id in ipairs( ids ) do
		local recipe = MC.PendingRecipes[id]
		byId[id] = recipe
		ordered[#ordered + 1] = recipe
		byType[recipe.type] = byType[recipe.type] or {}
		byType[recipe.type][#byType[recipe.type] + 1] = recipe
		canonical[#canonical + 1] = id .. "\0" .. recipe.type .. "\0" .. tostring( recipe.supported == true ) .. "\n"
	end
	MC.Recipes, MC.RecipesById, MC.RecipesByType = ordered, byId, byType
	MC.CraftingRecipes = {}
	MC.CookingRecipes = {}
	for _, recipe in ipairs( ordered ) do
		if recipe.type == "minecraft:crafting_shaped" or recipe.type == "minecraft:crafting_shapeless" then
			MC.CraftingRecipes[#MC.CraftingRecipes + 1] = recipe
		elseif COOKING_DEFAULT_TICKS[recipe.type] then
			MC.CookingRecipes[#MC.CookingRecipes + 1] = recipe
		end
	end
	local canonicalText = table.concat( canonical )
	MC.RecipeRegistryHash = util and util.SHA256 and util.SHA256( canonicalText )
		or util and util.CRC and util.CRC( canonicalText ) or canonicalText
	MC.RecipeRegistryFrozen = true
	return #ordered
end

function MC.GetRecipe( id ) return MC.RecipesById[normalizeName( id )] end
function MC.GetRecipes( recipeType ) return MC.RecipesByType[normalizeName( recipeType )] or {} end

local function gridInfo( grid, width, height )
	width, height = math.floor( tonumber( width ) or 0 ), math.floor( tonumber( height ) or 0 )
	if width < 1 or height < 1 or width * height > 9 then return nil end
	local zeroBased = grid[0] ~= nil
	local function get( index ) return grid[zeroBased and index or index + 1] end
	local left, right, top, bottom = width, -1, height, -1
	local nonEmpty = 0
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			local stack = get( x + y * width )
			if not MC.IsEmptyItemStack( stack ) then
				nonEmpty = nonEmpty + 1
				left, right = math.min( left, x ), math.max( right, x )
				top, bottom = math.min( top, y ), math.max( bottom, y )
			end
		end
	end
	if nonEmpty == 0 then return { width = 0, height = 0, count = 0, items = {} } end
	local trimmedWidth, trimmedHeight = right - left + 1, bottom - top + 1
	local items, occupied = {}, {}
	for y = 0, trimmedHeight - 1 do
		for x = 0, trimmedWidth - 1 do
			local stack = get( ( x + left ) + ( y + top ) * width )
			if MC.IsEmptyItemStack( stack ) then stack = false else occupied[#occupied + 1] = stack end
			items[#items + 1] = stack
		end
	end
	return { width = trimmedWidth, height = trimmedHeight, count = nonEmpty, items = items, occupied = occupied }
end

local function shapedMatches( recipe, info )
	if recipe.width ~= info.width or recipe.height ~= info.height or recipe.ingredientCount ~= info.count then return false end
	local function orientationMatches( mirrored )
		for index, actual in ipairs( info.items ) do
			local x = ( index - 1 ) % recipe.width
			local y = math.floor( ( index - 1 ) / recipe.width )
			local expectedIndex = ( mirrored and ( recipe.width - x - 1 ) or x ) + y * recipe.width + 1
			local expected = recipe.ingredients[expectedIndex]
			if expected then
				if not MC.IngredientMatches( expected, actual ) then return false end
			elseif not MC.IsEmptyItemStack( actual ) then
				return false
			end
		end
		return true
	end
	if not recipe.symmetrical and orientationMatches( true ) then return true end
	return orientationMatches( false )
end

local function shapelessMatches( recipe, info )
	if recipe.ingredientCount ~= info.count then return false end
	local used = {}
	local function visit( ingredientIndex )
		if ingredientIndex > #recipe.ingredients then return true end
		local ingredient = recipe.ingredients[ingredientIndex]
		for slotIndex, stack in ipairs( info.occupied or {} ) do
			if not used[slotIndex] and MC.IngredientMatches( ingredient, stack ) then
				used[slotIndex] = true
				if visit( ingredientIndex + 1 ) then return true end
				used[slotIndex] = nil
			end
		end
		return false
	end
	return visit( 1 )
end

function MC.RecipeMatchesGrid( recipe, grid, width, height )
	if not recipe or recipe.supported ~= true or type( grid ) ~= "table" then return false end
	local info = gridInfo( grid, width, height )
	if not info then return false end
	if recipe.type == "minecraft:crafting_shaped" then return shapedMatches( recipe, info ) end
	if recipe.type == "minecraft:crafting_shapeless" then return shapelessMatches( recipe, info ) end
	return false
end

function MC.FindCraftingRecipe( grid, width, height )
	for _, recipe in ipairs( MC.CraftingRecipes or {} ) do
		if MC.RecipeMatchesGrid( recipe, grid, width, height ) then return recipe end
	end
	return nil
end

function MC.FindCookingRecipe( stack, recipeType )
	recipeType = normalizeName( recipeType or "minecraft:smelting" )
	if not recipeType or MC.IsEmptyItemStack( stack ) then return nil end
	for _, recipe in ipairs( MC.RecipesByType[recipeType] or {} ) do
		if recipe.supported == true and MC.IngredientMatches( recipe.ingredient, stack ) then return recipe end
	end
	return nil
end

function MC.AssembleRecipe( recipe ) return recipe and MC.CopyItemStack( recipe.result ) or nil end

function MC.LoadGeneratedRecipePayload( recipeJSON, tagJSON )
	if not util or not util.JSONToTable then return nil, "json_decoder_unavailable" end
	local tags = util.JSONToTable( tagJSON or "" )
	local recipes = util.JSONToTable( recipeJSON or "" )
	if not istable( tags ) or not istable( recipes ) then return nil, "generated_recipe_json_invalid" end
	for _, row in ipairs( tags ) do
		local data = row.data or row
		local ok, err = MC.RegisterItemTag( row.id, data.values or {}, { replace = true } )
		if not ok then return nil, "item_tag_registration_failed:" .. tostring( err ) end
	end
	for _, row in ipairs( recipes ) do
		local registered, err = MC.RegisterRecipe( row.id, row.data or row )
		if not registered then return nil, "recipe_registration_failed:" .. tostring( row.id ) .. ":" .. tostring( err ) end
	end
	return MC.FinalizeRecipeRegistry()
end
