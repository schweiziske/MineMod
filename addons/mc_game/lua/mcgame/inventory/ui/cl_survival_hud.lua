-- Minecraft Java survival HUD: hearts, food and experience.

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local API = MC.API or {}
local GameMode = API.GameMode or {}
local HandWeapon = API.HandWeapon or {}
local HEART_CONTAINER = UI.GetGuiMaterial( "sprites/hud/heart/container" )
local HEART_CONTAINER_BLINKING = UI.GetGuiMaterial( "sprites/hud/heart/container_blinking" )
local function heartSprites( prefix )
	local path = "sprites/hud/heart/" .. prefix
	return {
		full = UI.GetGuiMaterial( path .. "full" ),
		half = UI.GetGuiMaterial( path .. "half" ),
		fullBlink = UI.GetGuiMaterial( path .. "full_blinking" ),
		halfBlink = UI.GetGuiMaterial( path .. "half_blinking" ),
	}
end
local HEART_NORMAL = heartSprites( "" )
local HEART_POISONED = heartSprites( "poisoned_" )
local HEART_WITHERED = heartSprites( "withered_" )
local HEART_ABSORBING = heartSprites( "absorbing_" )
local FOOD_EMPTY = UI.GetGuiMaterial( "sprites/hud/food_empty" )
local FOOD_FULL = UI.GetGuiMaterial( "sprites/hud/food_full" )
local FOOD_HALF = UI.GetGuiMaterial( "sprites/hud/food_half" )
local FOOD_EMPTY_HUNGER = UI.GetGuiMaterial( "sprites/hud/food_empty_hunger" )
local FOOD_FULL_HUNGER = UI.GetGuiMaterial( "sprites/hud/food_full_hunger" )
local FOOD_HALF_HUNGER = UI.GetGuiMaterial( "sprites/hud/food_half_hunger" )
local EXPERIENCE_BACKGROUND = UI.GetGuiMaterial( "sprites/hud/experience_bar_background" )
local EXPERIENCE_PROGRESS = UI.GetGuiMaterial( "sprites/hud/experience_bar_progress" )
local EXPERIENCE_COLOR = Color( 128, 255, 32, 255 )
local OUTLINE_COLOR = Color( 0, 0, 0, 255 )

local trackedPlayer
local lastHealthHalves
local displayHealthHalves
local lastHealthChangeAt = 0
local healthBlinkUntilTick = 0
local recentHurtUntil = 0

local function inventoryHandActive( ply )
	local weapon = ply:GetActiveWeapon()
	if not IsValid( weapon ) then
		return type( HandWeapon.IsInventoryActive ) == "function"
			and HandWeapon.IsInventoryActive( ply ) == true or false
	end
	if UI.IsInventoryWeapon then return UI.IsInventoryWeapon( weapon ) end
	if type( HandWeapon.IsInventoryActive ) == "function" then
		return HandWeapon.IsInventoryActive( ply ) == true
	end
	local class = weapon:GetClass()
	return class == "mc_item_hand"
end

function UI.SurvivalHUDBaseActive()
	local ply = LocalPlayer()
	return IsValid( ply ) and ply:Alive()
		and type( GameMode.Get ) == "function" and GameMode.Get( ply ) == "survival"
		and inventoryHandActive( ply )
end

function UI.SurvivalHUDVisible()
	return UI.SurvivalHUDBaseActive()
		and not ( IsValid( UI.Screen ) and UI.Screen:IsVisible() )
end

local function resetHealthTracking( ply, healthHalves )
	trackedPlayer = ply
	lastHealthHalves = healthHalves
	displayHealthHalves = healthHalves
	lastHealthChangeAt = RealTime()
	healthBlinkUntilTick = 0
	recentHurtUntil = 0
end

local function updateHealthTracking( ply, healthHalves, tick )
	if trackedPlayer ~= ply or lastHealthHalves == nil then
		resetHealthTracking( ply, healthHalves )
		return healthHalves, false
	end

	-- Java computes this frame's phase before changing the blink deadline.
	local blink = healthBlinkUntilTick > tick
		and math.floor( ( healthBlinkUntilTick - tick ) / 3 ) % 2 == 1
	local now = RealTime()
	recentHurtUntil = math.max( recentHurtUntil, ply:GetNW2Float( "mc_hud_hurt_until", 0 ) )
	if healthHalves < lastHealthHalves then
		-- Source Health and NW2 can arrive in either order. A visible health loss
		-- also establishes the presentation window locally.
		recentHurtUntil = math.max( recentHurtUntil, CurTime() + 1 )
		lastHealthChangeAt = now
		healthBlinkUntilTick = tick + 20
	elseif healthHalves > lastHealthHalves and CurTime() < recentHurtUntil then
		lastHealthChangeAt = now
		healthBlinkUntilTick = tick + 10
	end
	if now - lastHealthChangeAt > 1 then
		displayHealthHalves = healthHalves
		lastHealthChangeAt = now
	end
	lastHealthHalves = healthHalves
	return displayHealthHalves, blink
end

local function drawHeart( material, x, y, scale )
	UI.DrawTexture( material, x, y, 9 * scale, 9 * scale )
end

local function drawHearts( layout, xLeft, yBase, scale, blink, hearts, regenerationIndex, random )
	-- Poison takes precedence over wither; only the selected WITHERED type
	-- changes absorption. Gold itself never uses a blinking/old-value overlay.
	local absorption = hearts == HEART_WITHERED and HEART_WITHERED or HEART_ABSORBING
	for containerIndex = layout.containerCount - 1, 0, -1 do
		local row = math.floor( containerIndex / 10 )
		local column = containerIndex % 10
		local x = xLeft + column * 8 * scale
		local y = yBase - row * layout.rowHeight * scale
		if layout.currentHalves + layout.absorptionHalves <= 4 then
			y = y + random:NextInt( 2 ) * scale
		end
		if containerIndex < layout.healthContainerCount and containerIndex == regenerationIndex then
			y = y - 2 * scale
		end
		drawHeart( blink and HEART_CONTAINER_BLINKING or HEART_CONTAINER, x, y, scale )

		local halves = containerIndex * 2
		if containerIndex >= layout.healthContainerCount then
			local absorptionIndex = halves - layout.maxHealthContainerHalves
			if absorptionIndex < layout.absorptionHalves then
				drawHeart( absorptionIndex + 1 == layout.absorptionHalves
					and absorption.half or absorption.full, x, y, scale )
			end
		end
		if blink and halves < layout.oldHalves then
			drawHeart( halves + 1 == layout.oldHalves and hearts.halfBlink or hearts.fullBlink, x, y, scale )
		end
		if halves < layout.currentHalves then
			drawHeart( halves + 1 == layout.currentHalves and hearts.half or hearts.full, x, y, scale )
		end
	end
end

local function drawFood( ply, xRight, yBase, scale, tick, random, hungry )
	local food = math.Clamp( ply:GetNWInt( "mc_food_level", 20 ), 0, 20 )
	local saturation = math.max( 0, ply:GetNWFloat( "mc_food_saturation", 5 ) )
	local empty = hungry and FOOD_EMPTY_HUNGER or FOOD_EMPTY
	local full = hungry and FOOD_FULL_HUNGER or FOOD_FULL
	local half = hungry and FOOD_HALF_HUNGER or FOOD_HALF
	for index = 0, 9 do
		local y = yBase
		if saturation <= 0 and tick % ( food * 3 + 1 ) == 0 then
			y = y + ( random:NextInt( 3 ) - 1 ) * scale
		end
		local x = xRight - index * 8 * scale - 9 * scale
		UI.DrawTexture( empty, x, y, 9 * scale, 9 * scale )
		if index * 2 + 1 < food then
			UI.DrawTexture( full, x, y, 9 * scale, 9 * scale )
		elseif index * 2 + 1 == food then
			UI.DrawTexture( half, x, y, 9 * scale, 9 * scale )
		end
	end
end

local function drawExperience( ply, centerX, bottom, scale )
	local x = math.floor( centerX - 91 * scale )
	local y = bottom - 29 * scale
	local progress = math.Clamp( ply:GetNWFloat( "mc_experience_progress", 0 ), 0, 1 )
	local progressWidth = math.floor( progress * 183 )
	UI.DrawTexture( EXPERIENCE_BACKGROUND, x, y, 182 * scale, 5 * scale )
	if progressWidth > 0 then
		UI.DrawTexture( EXPERIENCE_PROGRESS, x, y, progressWidth * scale, 5 * scale,
			0, 0, progressWidth / 182, 1 )
	end

	local level = math.max( 0, ply:GetNWInt( "mc_experience_level", 0 ) )
	if level <= 0 then return end
	local textX = centerX
	local textY = bottom - 35 * scale
	for _, offset in ipairs( { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } ) do
		UI.DrawText( level, textX + offset[1] * scale, textY + offset[2] * scale,
			scale, OUTLINE_COLOR, TEXT_ALIGN_CENTER, false )
	end
	UI.DrawText( level, textX, textY, scale, EXPERIENCE_COLOR, TEXT_ALIGN_CENTER, false )
end

hook.Add( "HUDPaint", "mc_inventory_survival_status", function()
	if not UI.SurvivalHUDBaseActive() then
		trackedPlayer = nil
		lastHealthHalves = nil
		displayHealthHalves = nil
		return
	end
	if IsValid( UI.Screen ) and UI.Screen:IsVisible() then return end
	local ply = LocalPlayer()
	local scale = UI.HUDScale and UI.HUDScale() or UI.GuiScale()
	local offsetX, offsetY = 0, 0
	if UI.HUDOffset then offsetX, offsetY = UI.HUDOffset() end
	local tick = math.max( 0, math.floor( CurTime() * 20 ) )
	local currentHalves = MC.GModHealthToMinecraftHalves( ply:Health() )
	local absorptionHalves = math.ceil( MC.PlayerMinecraftAbsorptionAmount
		and MC.PlayerMinecraftAbsorptionAmount( ply ) or 0 )
	local oldHalves, blink = updateHealthTracking( ply, currentHalves, tick )
	local layout = MC.BuildSurvivalHeartLayout(
		ply.GetMaxHealth and ply:GetMaxHealth() or 100,
		ply:Health(),
		oldHalves * 5,
		absorptionHalves
	)
	local centerX = ScrW() * 0.5 + offsetX
	local bottom = ScrH() + offsetY
	local yBase = bottom - 39 * scale
	local xLeft = math.floor( centerX - 91 * scale )
	local xRight = math.floor( centerX + 91 * scale )
	local random = MC.NewLegacyRandom( tick * 312871 )
	local poisoned, withered, hungry, regenerating = UI.SurvivalHUDEffects( ply )
	local hearts = poisoned and HEART_POISONED or withered and HEART_WITHERED or HEART_NORMAL
	local regenerationIndex = regenerating and tick % math.ceil( layout.maxHealthHalves + 5 ) or -1

	UI.WithPointFiltering( function()
		drawHearts( layout, xLeft, yBase, scale, blink, hearts, regenerationIndex, random )
		drawFood( ply, xRight, yBase, scale, tick, random, hungry )
		drawExperience( ply, centerX, bottom, scale )
	end )
end )

hook.Add( "HUDShouldDraw", "mc_inventory_hide_source_survival_status", function( name )
	if not UI.SurvivalHUDBaseActive() then return end
	if name == "CHudHealth" or name == "CHudBattery" then return false end
end )
