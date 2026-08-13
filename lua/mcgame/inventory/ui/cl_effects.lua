-- Minecraft Java 26.2 active-effect HUD and inventory sidebar.
-- The MCITEM potion runtime publishes a compact NW2 JSON snapshot containing
-- an absolute server expiry.  Rendering derives the remaining ticks locally,
-- so this layer does not need a per-frame or per-tick network update.

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local EFFECT_KEY = "MCITEMPotionEffects"
local cache = setmetatable({}, { __mode = "k" })

local ROMAN = { "", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }
local SORT_DURATION_THRESHOLD = 32147

local function decode(entity)
	if not IsValid(entity) then return {} end
	local raw = entity:GetNW2String(EFFECT_KEY, "")
	local old = cache[entity]
	if old and old.raw == raw then return old.effects end
	local effects = raw ~= "" and util.JSONToTable(raw) or {}
	if not istable(effects) then effects = {} end
	cache[entity] = { raw = raw, effects = effects }
	return effects
end

local function remainingTicks(effect)
	if effect.infinite == true or tonumber(effect.durationTicks) == -1 then return -1 end
	local expiresAt = tonumber(effect.expiresAt)
	if expiresAt then return math.max(0, math.ceil((expiresAt - CurTime()) * 20)) end
	return math.max(0, math.floor(tonumber(effect.durationTicks) or 0))
end

local function isBeneficial(effect)
	return effect.category == "beneficial"
end

local function sortEffects(effects, reverse)
	table.sort(effects, function(a, b)
		local ad = tonumber(a.durationTicks) or 0
		local bd = tonumber(b.durationTicks) or 0
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
		return reverse and result > 0 or result < 0
	end)
	return effects
end

local function visibleEffects(entity)
	local result = {}
	for _, effect in ipairs(decode(entity)) do
		local ticks = remainingTicks(effect)
		-- `visible` controls particles only.  Java's HUD is gated by showIcon.
		if effect.showIcon ~= false and (ticks == -1 or ticks > 0) then
			result[#result + 1] = effect
		end
	end
	return result
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
	if ticks == -1 then return MC.Language and MC.Language() == "zh_cn" and "无限" or "∞" end
	if ticks <= 0 then return "0:00" end
	local seconds = math.floor(ticks / 20)
	local minutes = math.floor(seconds / 60)
	seconds = seconds % 60
	return string.format("%d:%02d", minutes, seconds)
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

function UI.DrawActiveEffectsHUD(entity)
	if not IsValid(entity) then return end
	local effects = sortEffects(visibleEffects(entity), true)
	local scale = UI.GuiScale and UI.GuiScale() or 1
	local beneficialIndex, harmfulIndex = 0, 0
	for _, effect in ipairs(effects) do
		local ticks = remainingTicks(effect)
		local index
		local y = 1 * scale
		if isBeneficial(effect) then
			beneficialIndex = beneficialIndex + 1
			index = beneficialIndex
		else
			harmfulIndex = harmfulIndex + 1
			index = harmfulIndex
			y = 27 * scale
		end
		local x = ScrW() - 25 * index * scale
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
	local effects = sortEffects(visibleEffects(entity), false)
	if #effects == 0 then return false end
	local available = ScrW() - (screen.Left + screen.ContentW * screen.Scale + 2 * screen.Scale)
	if available < 32 * screen.Scale then return false end
	local width = available >= 120 * screen.Scale and available - 7 * screen.Scale or 32 * screen.Scale
	local spacing = #effects > 5 and math.floor(132 * screen.Scale / (#effects - 1)) or 33 * screen.Scale
	for index, effect in ipairs(effects) do
		local y = screen.Top + (index - 1) * spacing
		local background = UI.GetEffectBackgroundMaterial(effect.ambient == true, true)
		UI.WithPointFiltering(function()
			UI.DrawTexture(background, screen.Left + screen.ContentW * screen.Scale + 2 * screen.Scale, y,
				width, 32 * screen.Scale)
			drawIcon(effect, screen.Left + screen.ContentW * screen.Scale + 7 * screen.Scale,
				y + 9 * screen.Scale, 18 * screen.Scale, 1)
		end)
		if width >= 120 * screen.Scale then
			local textX = screen.Left + screen.ContentW * screen.Scale + 32 * screen.Scale
			UI.DrawText(effectName(effect), textX, y + 6 * screen.Scale, screen.Scale, UI.Colors.text, TEXT_ALIGN_LEFT, true)
			UI.DrawText(formatDuration(remainingTicks(effect)), textX, y + 16 * screen.Scale, screen.Scale,
				Color(210, 210, 210), TEXT_ALIGN_LEFT, true)
		end
	end
	return true
end

hook.Add("HUDPaint", "mc_inventory_active_effects_hud", function()
	if IsValid(UI.Screen) and UI.Screen:IsVisible() then return end
	if not IsValid(LocalPlayer()) or not LocalPlayer():Alive() then return end
	UI.DrawActiveEffectsHUD(LocalPlayer())
end)
