-- Registration and locale changes are the only points that rebuild menu text.
MCITEM = MCITEM or {}
local function refresh()
    if not MC or not MC.I18n then
        ErrorNoHalt("[MCITEM] mc_engine is required for localization.\n")
        return
    end
    local function localize(definition)
        local phrase = definition.PrintName
        if type(phrase) == "string" and phrase:sub(1, 1) == "#" then
            local key = phrase:sub(2)
            if definition.MCPotionDefinition then
                MC.I18n.BindPhraseProducer(key, function()
                    return MCITEM.Potions.WeaponDisplayName(definition.MCPotionBottleType, definition.MCPotionDefinition)
                end)
            else
                MC.I18n.BindPhrase(key, key)
            end
        end
        local category = definition.Category
        if type(category) == "string" and category:sub(1, 1) == "#" then
            MC.I18n.BindPhrase(category:sub(2), category:sub(2))
        end
        local key = definition.MCInstructionsKey
        if key then
            definition.Instructions = MC.T(key)
            if definition.MCPotionDefinition then
                definition.Instructions = MCITEM.Potions.WeaponInstructions(definition.MCPotionBottleType, definition.MCPotionDefinition)
            end
            definition.InfoMarkup = nil
        end
    end
    for _, definition in ipairs(weapons.GetList()) do
        local class = definition.ClassName
        if class and class:StartWith("weapon_mcitem_") then
            local stored = weapons.GetStored(class) or definition
            localize(stored)
            definition.Instructions = stored.Instructions
            definition.InfoMarkup = nil
            local listed = list.Get("Weapon")[class]
            if listed then listed.Instructions = stored.Instructions end
        end
    end
    for class, entry in pairs(scripted_ents.GetList()) do
        if class:StartWith("mcitem_") then localize(entry.t) end
    end
    for _, weapon in ipairs(ents.FindByClass("weapon_mcitem_*")) do
        local stored = weapons.GetStored(weapon:GetClass())
        if stored then weapon.Instructions = stored.Instructions end
        weapon.InfoMarkup = nil
    end
end

MCITEM.RefreshLocalizedWeapons = refresh
hook.Add("PreReloadToolsMenu", "mcitem_localized_weapons", refresh)
hook.Add("InitPostEntity", "mcitem_localized_weapons", refresh)
hook.Add("OnReloaded", "mcitem_localized_weapons", refresh)
hook.Add("MC.LanguageChanged", "mcitem_localized_weapons", function()
    refresh()
    if not IsValid(g_SpawnMenu) then return end
    -- Use Sandbox's deferred refresh contract to preserve unsaved spawn lists.
    if g_SpawnMenu.m_UnsavedModifications or g_SpawnMenu:IsVisible() then
        g_SpawnMenu.m_NeedsLanguageRefresh = true
    else
        RunConsoleCommand("spawnmenu_reload")
    end
end)
