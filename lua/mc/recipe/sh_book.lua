--[[----------------------------------------------------------------------------
	Minecraft-style crafting recipe book support.

	The Java client keeps recipe collections separate from the menu and only
	asks the server to place a recipe.  This module follows the same boundary:
	indexing/search/craftability are shared, while the server still owns the
	actual inventory mutation (MC.CraftingPlaceRecipe in sh_crafting.lua).
------------------------------------------------------------------------------]]

MC = MC or {}
MC.RecipeBook = MC.RecipeBook or {}

local Book = MC.RecipeBook

Book.CATEGORY_ORDER = Book.CATEGORY_ORDER or {
	"building",
	"equipment",
	"misc",
	"redstone",
}

Book.CATEGORY_TITLES = Book.CATEGORY_TITLES or {
	building = "Building Blocks",
	equipment = "Equipment",
	misc = "Miscellaneous",
	redstone = "Redstone",
	food = "Food",
	blocks = "Blocks",
}

local function lower( value )
	return string.lower( tostring( value or "" ) )
end

local function recipeCategory( recipe )
	local category = lower( recipe and recipe.category )
	if category == "building" or category == "blocks" then return "building" end
	if category == "equipment" or category == "tools" or category == "combat" then return "equipment" end
	if category == "redstone" then return "redstone" end
	return "misc"
end

local function recipeFitsGrid( recipe, width, height )
	if not recipe or recipe.supported ~= true then return false end
	width = math.floor( tonumber( width ) or 0 )
	height = math.floor( tonumber( height ) or 0 )
	if width < 1 or height < 1 or width * height > 9 then return false end
	if recipe.type == "minecraft:crafting_shaped" then
		return recipe.width <= width and recipe.height <= height
	end
	if recipe.type == "minecraft:crafting_shapeless" then
		return ( recipe.ingredientCount or 0 ) <= width * height
	end
	return false
end

function Book.RecipeCategory( recipe ) return recipeCategory( recipe ) end
function Book.RecipeFitsGrid( recipe, width, height ) return recipeFitsGrid( recipe, width, height ) end

local function addStackCount( counts, stack )
	if MC.IsEmptyItemStack( stack ) then return end
	local item = tostring( stack.item or "" )
	if item == "" then return end
	counts[item] = ( counts[item] or 0 ) + math.max( 0, math.floor( tonumber( stack.count ) or 0 ) )
end

function Book.BuildItemCounts( stacks, additional )
	local counts = {}
	if type( stacks ) == "table" and stacks.item ~= nil then addStackCount( counts, stacks )
	else for _, stack in pairs( stacks or {} ) do addStackCount( counts, stack ) end end
	if type( additional ) == "table" and additional.item ~= nil then addStackCount( counts, additional )
	else for _, stack in pairs( additional or {} ) do addStackCount( counts, stack ) end end
	return counts
end

local function recipeIngredients( recipe )
	if recipe and recipe._bookIngredients then return recipe._bookIngredients end
	local output = {}
	if recipe and recipe.ingredient then
		output[1] = recipe.ingredient
	elseif recipe.type == "minecraft:crafting_shaped" then
		for _, ingredient in ipairs( recipe.ingredients or {} ) do
			if ingredient then output[#output + 1] = ingredient end
		end
	else
		for _, ingredient in ipairs( recipe.ingredients or {} ) do output[#output + 1] = ingredient end
	end
	if recipe then recipe._bookIngredients = output end
	return output
end

local function cookingCategory( recipe )
	local category = lower( recipe and recipe.category )
	if category == "food" then return "food" end
	if category == "blocks" then return "blocks" end
	return "misc"
end

local function copyCounts( counts )
	local output = {}
	for item, count in pairs( counts or {} ) do output[item] = count end
	return output
end

local choiceCache = {}

local function ingredientKey( ingredient )
	if not ingredient then return "nil" end
	if ingredient.kind == "item" then return "item:" .. tostring( ingredient.item ) end
	if ingredient.kind == "tag" then return "tag:" .. tostring( ingredient.tag ) end
	local parts = { "alternatives" }
	for _, candidate in ipairs( ingredient.items or {} ) do parts[#parts + 1] = ingredientKey( candidate ) end
	return table.concat( parts, "|" )
end

local function choicesFor( ingredient )
	local key = ingredientKey( ingredient )
	if choiceCache[key] then return choiceCache[key] end
	local choices = MC.IngredientChoices and MC.IngredientChoices( ingredient ) or {}
	if #choices == 0 then
		-- Alternatives can contain an item that is not in the generated tag
		-- table.  Keep the direct item path useful for custom registrations.
		if ingredient and ingredient.kind == "item" then choices = { ingredient.item } end
	end
	choiceCache[key] = choices
	return choices
end

local function canSatisfy( ingredients, counts, amount )
	amount = math.max( 1, math.floor( tonumber( amount ) or 1 ) )
	local demands = {}
	for _ = 1, amount do
		for _, ingredient in ipairs( ingredients ) do demands[#demands + 1] = ingredient end
	end
	if #demands == 0 then return true end

	-- Ingredients with fewer alternatives are assigned first.  This is the
	-- same constraint ordering used by the tag-aware shapeless matcher and
	-- prevents a broad tag from consuming an item needed by a narrow tag.
	table.sort( demands, function( left, right )
		return #choicesFor( left ) < #choicesFor( right )
	end )

	local remaining = copyCounts( counts )
	local function visit( index )
		if index > #demands then return true end
		local ingredient = demands[index]
		for _, item in ipairs( choicesFor( ingredient ) ) do
			if ( remaining[item] or 0 ) > 0 then
				remaining[item] = remaining[item] - 1
				if visit( index + 1 ) then return true end
				remaining[item] = remaining[item] + 1
			end
		end
		return false
	end
	return visit( 1 )
end

function Book.RecipeIngredients( recipe ) return recipeIngredients( recipe ) end

function Book.RecipeCanCraft( recipe, stacksOrCounts, amount )
	if not recipe or recipe.supported ~= true then return false end
	local counts
	if type( stacksOrCounts ) ~= "table" then counts = {}
	elseif stacksOrCounts.item ~= nil then counts = Book.BuildItemCounts( { stacksOrCounts } )
	else
		local looksLikeCounts = true
		for key, value in pairs( stacksOrCounts ) do
			if type( key ) ~= "string" or type( value ) ~= "number" then looksLikeCounts = false break end
		end
		counts = looksLikeCounts and copyCounts( stacksOrCounts ) or Book.BuildItemCounts( stacksOrCounts )
	end
	return canSatisfy( recipeIngredients( recipe ), counts, amount )
end

function Book.MaxCraftCount( recipe, stacksOrCounts, maximum )
	maximum = math.max( 1, math.min( 64, math.floor( tonumber( maximum ) or 64 ) ) )
	local counts
	if type( stacksOrCounts ) == "table" and stacksOrCounts.item == nil then
		local looksLikeCounts = true
		for key, value in pairs( stacksOrCounts ) do
			if type( key ) ~= "string" or type( value ) ~= "number" then looksLikeCounts = false break end
		end
		counts = looksLikeCounts and copyCounts( stacksOrCounts ) or Book.BuildItemCounts( stacksOrCounts )
	else
		counts = Book.BuildItemCounts( { stacksOrCounts } )
	end
	if not canSatisfy( recipeIngredients( recipe ), counts, 1 ) then return 0 end
	local low, high = 1, maximum
	while low < high do
		local middle = math.ceil( ( low + high + 1 ) * 0.5 )
		if canSatisfy( recipeIngredients( recipe ), counts, middle ) then low = middle else high = middle - 1 end
	end
	return low
end

local function displayName( recipe )
	local result = recipe and recipe.result
	local item = result and result.item or ""
	return lower( MC.ItemDisplayName and MC.ItemDisplayName( item ) or item )
end

local function recipeSearchText( recipe )
	return lower( table.concat( {
		tostring( recipe and recipe.id or "" ),
		tostring( recipe and recipe.group or "" ),
		displayName( recipe ),
	}, " " ) )
end

local function entrySort( left, right )
	local leftName, rightName = displayName( left.recipe ), displayName( right.recipe )
	if leftName ~= rightName then return leftName < rightName end
	return tostring( left.recipe.id ) < tostring( right.recipe.id )
end

function Book.BuildEntries( width, height, options )
	options = type( options ) == "table" and options or {}
	local category = options.category and lower( options.category ) or nil
	local query = lower( options.query )
	local onlyCraftable = options.onlyCraftable == true
	local counts = options.counts or Book.BuildItemCounts( options.stacks, options.additionalStacks )
	local known = options.known
	local groups, order = {}, {}
	for _, recipe in ipairs( MC.CraftingRecipes or {} ) do
		local recipeCategoryName = recipeCategory( recipe )
		local allowed = recipeFitsGrid( recipe, width, height )
		if allowed and category and category ~= "search" and category ~= recipeCategoryName then
			allowed = false
		end
		if allowed and query ~= "" and string.find( recipeSearchText( recipe ), query, 1, true ) == nil then
			allowed = false
		end
		if allowed then
			if type( known ) == "function" then allowed = known( recipe ) ~= false
			elseif type( known ) == "table" and known[recipe.id] == false then allowed = false end
		end
		if allowed then
			local groupKey = recipeCategoryName .. "\0" .. ( recipe.group ~= "" and recipe.group or recipe.id )
			local entry = groups[groupKey]
			if not entry then
				entry = { key = groupKey, category = recipeCategoryName, recipes = {}, recipe = recipe }
				groups[groupKey] = entry
				order[#order + 1] = entry
			end
			entry.recipes[#entry.recipes + 1] = recipe
		end
	end

	local output = {}
	for _, entry in ipairs( order ) do
		local selected = entry.recipes[1]
		local craftable = false
		for _, recipe in ipairs( entry.recipes ) do
			if Book.RecipeCanCraft( recipe, counts, 1 ) then
				selected, craftable = recipe, true
				break
			end
		end
		entry.recipe, entry.craftable = selected, craftable
		if not onlyCraftable or craftable then output[#output + 1] = entry end
	end
	table.sort( output, entrySort )
	return output
end

function Book.BuildCookingEntries( recipeType, options )
	options = type( options ) == "table" and options or {}
	recipeType = lower( recipeType or "minecraft:smelting" )
	local category = options.category and lower( options.category ) or nil
	local query = lower( options.query )
	local counts = options.counts or Book.BuildItemCounts( options.stacks, options.additionalStacks )
	local onlyCraftable = options.onlyCraftable == true
	local groups, order = {}, {}
	for _, recipe in ipairs( MC.RecipesByType and MC.RecipesByType[recipeType] or {} ) do
		local recipeCategoryName = cookingCategory( recipe )
		local allowed = recipe.supported == true
			and ( not category or category == "search" or category == recipeCategoryName )
		if allowed and query ~= "" and string.find( recipeSearchText( recipe ), query, 1, true ) == nil then
			allowed = false
		end
		if allowed then
			local groupKey = recipeCategoryName .. "\0" .. ( recipe.group ~= "" and recipe.group or recipe.id )
			local entry = groups[groupKey]
			if not entry then
				entry = { key = groupKey, category = recipeCategoryName, recipes = {}, recipe = recipe }
				groups[groupKey], order[#order + 1] = entry, entry
			end
			entry.recipes[#entry.recipes + 1] = recipe
		end
	end
	local output = {}
	for _, entry in ipairs( order ) do
		local selected, craftable = entry.recipes[1], false
		for _, recipe in ipairs( entry.recipes ) do
			if Book.RecipeCanCraft( recipe, counts, 1 ) then selected, craftable = recipe, true break end
		end
		entry.recipe, entry.craftable = selected, craftable
		if not onlyCraftable or craftable then output[#output + 1] = entry end
	end
	table.sort( output, entrySort )
	return output
end

function Book.EntryByRecipeId( entries, id )
	for _, entry in ipairs( entries or {} ) do
		for _, recipe in ipairs( entry.recipes or {} ) do
			if recipe.id == id then return entry end
		end
	end
	return nil
end
