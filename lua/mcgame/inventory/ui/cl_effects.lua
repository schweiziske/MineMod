-- Minecraft Java 26.2 active-effect HUD and inventory sidebar.
-- The MCITEM potion runtime publishes a compact NW2 JSON snapshot containing
-- an absolute server expiry.  Rendering derives the remaining ticks locally,
-- so this layer does not need a per-frame or per-tick network update.

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local EFFECT_KEY = "MCITEMPotionEffects"
local cache = setmetatable({}, { __mode = "k" })

local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }
local SORT_DURATION_THRESHOLD = 32147

local function decode(entity)
	if not IsValid(entity) then return {} end
	local potions = MCITEM and MCITEM.Potions
	if potions and isfunction(potions.ClientEffects) then
		return potions.ClientEffects(entity)
	end

	-- Compatibility path for a server/client pair without MCITEM's chunked
	-- status reader.  Valid MCITEM clients use the shared cache above so the
	-- HUD and entity particles can never disagree about the active collection.
	local raw = entity:GetNW2String(EFFECT_KEY, "")
	local old = cache[entity]
	if old and old.raw == raw then return old.effects end
	local effects = raw ~= "" and util.JSONToTable(raw) or {}
	if not istable(effects) then return old and old.effects or {} end
	cache[entity] = { raw = raw, effects = effects }
	return effects
end

local function remainingTicks(effect)
	if effect.infinite == true or tonumber(effect.durationTicks) == -1 then return -1 end
	local expiresAt = tonumber(effect.expiresAt)
	if expiresAt then return math.max(0, math.floor((expiresAt - CurTime()) * 20)) end
	return math.max(0, math.floor(tonumber(effect.durationTicks) or 0))
end

local function isBeneficial(effect)
	return effect.category == "beneficial"
end

local function sortEffects(effects, reverse, ticksFor)
	table.sort(effects, function(a, b)
		local ad = ticksFor and ticksFor(a) or remainingTicks(a)
		local bd = ticksFor and ticksFor(b) or remainingTicks(b)
		local aa = a.ambient == true
		local ba = b.ambient == true
		local ai = a.infinite == true or ad == -1
		local bi = b.infinite == true or bd == -1
		local colorA = tonumber(a.color) or 0
		local colorB = tonumber(b.color) or 0
		local result
		-- MobEffectInstance.compareTo (Java 26.2).  HUD uses the natural
		-- ordering reversed; inventory uses it directly.
		if (ad > SORT_DURATION_THRESHOLD and bd > SORT_DURATION_THRESHOLD) or (aa and ba) then
			if aa ~= ba then result = aa and 1 or -1
			elseif colorA ~= colorB then result = colorA < colorB and -1 or 1 end
		else
			if aa ~= ba then result = aa and 1 or -1
			elseif ai ~= bi then result = ai and 1 or -1
			elseif ad ~= bd then result = ad < bd and -1 or 1
			elseif colorA ~= colorB then result = colorA < colorB and -1 or 1 end
		end
		if result == nil then
			local ac, bc = tostring(a.id or ""), tostring(b.id or "")
			if ac ~= bc then result = ac < bc and -1 or 1
			else
				local ampA, ampB = tonumber(a.amplifier) or 0, tonumber(b.amplifier) or 0
				result = ampA == ampB and 0 or (ampA < ampB and -1 or 1)
			end
		end
		-- Keep the comparator strict in both directions.  `reverse and result > 0
		-- or result < 0` falls through to the final clause when reverse is true,
		-- making both a<b and b<a true for every unequal pair.
		if reverse then return result > 0 end
		return result < 0
	end)
	return effects
end

local function activeEffects(entity, iconsOnly)
	local result = {}
	for _, effect in ipairs(decode(entity)) do
		local ticks = remainingTicks(effect)
		-- `visible` controls particles only.  The HUD is gated by showIcon,
		-- while the inventory sidebar receives the complete active collection.
		if (not iconsOnly or effect.showIcon ~= false) and (ticks == -1 or ticks > 0) then
			result[#result + 1] = effect
		end
	end
	return result
end

local function visibleEffects(entity)
	return activeEffects(entity, true)
end

local function inventoryEffects(entity)
	return activeEffects(entity, false)
end

local function effectName(effect)
	local definition = MCITEM and MCITEM.Potions and MCITEM.Potions.EffectDefinition
		and MCITEM.Potions.EffectDefinition(effect.id) or nil
	local name = definition and definition.name or tostring(effect.id or "")
	if MC.Language and MC.Language() == "zh_cn" then
		local zh = {
			absorption = "伤害吸收", fire_resistance = "抗火", regeneration = "生命恢复",
			resistance = "抗性提升", poison = "中毒", hunger = "饥饿", nausea = "反胃",
			instant_health = "瞬间治疗", instant_damage = "瞬间伤害", jump_boost = "跳跃提升",
			speed = "速度", slowness = "缓慢", strength = "力量", weakness = "虚弱",
			night_vision = "夜视", invisibility = "隐身", water_breathing = "水下呼吸",
			slow_falling = "缓降", luck = "幸运", unluck = "霉运", glowing = "发光",
		}
		name = zh[tostring(effect.id or "")] or name
	end
	local amplifier = tonumber(effect.amplifier) or 0
	if amplifier >= 1 and amplifier <= 9 then name = name .. " " .. ROMAN[amplifier + 1] end
	return name
end

local function formatDuration(ticks)
	if ticks == -1 then return MC.Language and MC.Language() == "zh_cn" and "无限" or "Infinite" end
	if ticks <= 0 then return "0:00" end
	local seconds = math.floor(ticks / 20)
	local minutes = math.floor(seconds / 60)
	seconds = seconds % 60
	local hours = math.floor(minutes / 60)
	minutes = minutes % 60
	if hours > 0 then return string.format("%02d:%02d:%02d", hours, minutes, seconds) end
	return string.format("%02d:%02d", minutes, seconds)
end

local function textWidth(text, scale)
	return UI.MeasureText and UI.MeasureText(text, scale) or #tostring(text or "") * 6 * scale
end

local function clipText(text, maxWidth, scale)
	text = tostring(text or "")
	if maxWidth <= 0 then return "" end
	if textWidth(text, scale) <= maxWidth then return text end
	local suffix = "..."
	if textWidth(suffix, scale) > maxWidth then return "" end
	local characters = {}
	for character in string.gmatch(text, "[%z\1-\127\194-\244][\128-\191]*") do
		characters[#characters + 1] = character
	end
	local low, high = 0, #characters
	while low < high do
		local middle = math.ceil((low + high) * 0.5)
		if textWidth(table.concat(characters, "", 1, middle) .. suffix, scale) <= maxWidth then low = middle
		else high = middle - 1 end
	end
	return table.concat(characters, "", 1, low) .. suffix
end

local function drawIcon(effect, x, y, size, alpha)
	local material = UI.GetMobEffectMaterial(effect.id)
	if not material then return end
	UI.DrawTexture(material, x, y, size, size, nil, nil, nil, nil, Color(255, 255, 255, math.floor(255 * (alpha or 1))))
end

local function hudAlpha(effect, ticks)
	if effect.ambient == true then return 1 end
	if ticks == -1 or ticks > 200 then return 1 end
	-- Java Hud.extractEffects 26.2, bytecode order preserved.
	local phase = 10 - math.floor(ticks / 20)
	local alpha = math.Clamp(ticks / 100, 0, 0.5)
		+ math.cos(ticks * math.pi / 5) * math.Clamp(phase / 10 * 0.25, 0, 0.25)
	return math.Clamp(alpha, 0, 1)
end

function UI.ActiveEffects(entity)
	return visibleEffects(entity or LocalPlayer())
end

function UI.ActiveEffectHUDLayout(width, height, scale, effects, ticksFor)
	width, height = math.max(0, tonumber(width) or 0), math.max(0, tonumber(height) or 0)
	scale = math.max(1, tonumber(scale) or 1)
	effects = sortEffects(table.Copy(effects or {}), true, ticksFor)
	local layout = {}
	local maxColumns = math.max(1, math.floor(math.max(24 * scale, width) / (25 * scale)))
	local pairHeight = 52 * scale
	local pairRows = math.max(1, math.floor(math.max(0, height - 51 * scale) / pairHeight) + 1)
	local beneficialIndex, harmfulIndex = 0, 0
	for _, effect in ipairs(effects) do
		local index
		local baseY = isBeneficial(effect) and 1 or 27
		if isBeneficial(effect) then beneficialIndex = beneficialIndex + 1; index = beneficialIndex
		else harmfulIndex = harmfulIndex + 1; index = harmfulIndex end
		local row = math.floor((index - 1) / maxColumns)
		row = row % pairRows
		local column = (index - 1) % maxColumns + 1
		layout[#layout + 1] = {
			effect = effect,
			x = math.max(0, width - 25 * column * scale),
			y = math.min(math.max(0, height - 24 * scale), baseY * scale + row * pairHeight),
			ticks = ticksFor and ticksFor(effect) or remainingTicks(effect),
		}
	end
	return layout
end

function UI.ActiveEffectInventoryLayout(screen, effects, ticksFor)
	if not screen then return nil end
	local scale = math.max(1, tonumber(screen.Scale) or 1)
	local screenW, screenH = tonumber(screen.ScreenW) or ScrW(), tonumber(screen.ScreenH) or ScrH()
	local x = (tonumber(screen.Left) or 0) + (tonumber(screen.ContentW) or 0) * scale + 2 * scale
	local available = screenW - x
	if available < 32 * scale then return nil end
	effects = sortEffects(table.Copy(effects or {}), false, ticksFor)
	if #effects == 0 then return nil end
	local maxWidth = available >= 120 * scale and available - 7 * scale or 32 * scale
	local spacingUnits = #effects > 5 and math.floor(132 / (#effects - 1)) or 33
	local spacing = math.max(1, spacingUnits * scale)
	local top = math.max(0, math.min(tonumber(screen.Top) or 0, math.max(0, screenH - 32 * scale)))
	if #effects > 1 then spacing = math.min(spacing, math.max(0, math.floor((screenH - top - 32 * scale) / (#effects - 1)))) end
	local entries = {}
	for index, effect in ipairs(effects) do
		local ticks = ticksFor and ticksFor(effect) or remainingTicks(effect)
		local name, duration = effectName(effect), formatDuration(ticks)
		local needed = math.max(32 * scale + textWidth(name, scale) + 7 * scale,
			32 * scale + textWidth(duration, scale) + 7 * scale)
		local width = math.min(maxWidth, needed)
		local textWidthAvailable = math.max(0, width - 39 * scale)
		entries[#entries + 1] = {
			effect = effect,
			x = x,
			y = top + (index - 1) * spacing,
			width = width,
			name = clipText(name, textWidthAvailable, scale),
			duration = duration,
			textWidth = textWidthAvailable,
		}
	end
	return { entries = entries, x = x, top = top, available = available, maxWidth = maxWidth, spacing = spacing }
end

function UI.DrawActiveEffectsHUD(entity)
	if not IsValid(entity) then return end
	local scale = UI.GuiScale and UI.GuiScale() or 1
	for _, entry in ipairs(UI.ActiveEffectHUDLayout(ScrW(), ScrH(), scale, visibleEffects(entity))) do
		local effect, x, y, ticks = entry.effect, entry.x, entry.y, entry.ticks
		local background = UI.GetEffectBackgroundMaterial(effect.ambient == true, false)
		UI.WithPointFiltering(function()
			UI.DrawTexture(background, x, y, 24 * scale, 24 * scale, nil, nil, nil, nil, Color(255,255,255,255))
			drawIcon(effect, x + 3 * scale, y + 3 * scale, 18 * scale, hudAlpha(effect, ticks))
		end)
	end
end

function UI.DrawActiveEffectsInventory(screen)
	if not IsValid(screen) then return false end
	local entity = LocalPlayer()
	local layout = UI.ActiveEffectInventoryLayout(screen, inventoryEffects(entity))
	if not layout then return false end
	for _, entry in ipairs(layout.entries) do
		local effect, x, y, width = entry.effect, entry.x, entry.y, entry.width
		local background = UI.GetEffectBackgroundMaterial(effect.ambient == true, true)
		UI.WithPointFiltering(function()
			UI.DrawTexture(background, x, y, width, 32 * screen.Scale)
			drawIcon(effect, x + 7 * screen.Scale, y + 7 * screen.Scale, 18 * screen.Scale, 1)
		end)
		if entry.textWidth > 0 then
			local textX = x + 32 * screen.Scale
			UI.DrawText(entry.name, textX, y + 7 * screen.Scale, screen.Scale, UI.Colors.text, TEXT_ALIGN_LEFT, true)
			UI.DrawText(entry.duration, textX, y + 16 * screen.Scale, screen.Scale,
				Color(210, 210, 210), TEXT_ALIGN_LEFT, true)
		end
	end
	return true
end

hook.Add("HUDPaint", "mc_inventory_active_effects_hud", function()
	if IsValid(UI.Screen) and UI.Screen:IsVisible()
		and UI.ActiveEffectInventoryLayout(UI.Screen, inventoryEffects(LocalPlayer())) ~= nil
	then return end
	if not IsValid(LocalPlayer()) or not LocalPlayer():Alive() then return end
	UI.DrawActiveEffectsHUD(LocalPlayer())
end)
