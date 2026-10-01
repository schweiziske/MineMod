-- Session state for the pre-baked texture pack manager. No VGUI dependencies.
MC = MC or {}
MC.TexturePackManager = MC.TexturePackManager or {}
local M = MC.TexturePackManager
local Session = {}
Session.__index = Session

function M.Text( english, chinese )
	if MC.Language() == "zh_cn" then return chinese end
	return english
end

function Session:IsDirty()
	return self.draft ~= self.preference
end

function Session:Refresh()
	local dirty = self.draft ~= nil and self:IsDirty()
	self.preference = MC.TexturePack:GetString()
	self.active = MC.TexturePackName()
	self.leaseOwner = MC.TexturePackLeaseOwner()
	self.packs, self.byName = {}, {}
	for _, entry in ipairs( MC.ListTexturePacks() ) do
		local name = entry.name
		if name == "default" then
			entry.title = M.Text( "Default", "默认资源" )
			entry.description = M.Text( "The default Minecraft textures.", "Minecraft 的默认贴图。" )
		elseif name == "programmer_art" then
			entry.title = "Programmer Art"
			entry.description = M.Text( "The classic look of Minecraft.", "Minecraft 的经典外观。" )
		elseif name == "vanilla_baked" and entry.owner == "mc.atlas_baker" then
			entry.title = M.Text( "Vanilla (in-game bake)", "原版（游戏内烘焙）" )
			entry.description = M.Text( "Vanilla textures assembled in game.", "在游戏内生成的原版材质。" )
		elseif name == "avpbr_baked" and entry.owner == "mc.atlas_baker" then
			entry.title = M.Text( "AVPBR (in-game bake)", "AVPBR（游戏内烘焙）" )
			entry.description = M.Text( "JoaquiX · Color, LabPBR normals and specular. Missing colors use vanilla; missing maps are neutral.",
				"JoaquiX · 颜色、LabPBR 法线与材质；缺失颜色由原版补齐，缺失材质使用中性值。" )
		else
			if not entry.title or entry.title == "" then entry.title = name end
			entry.description = entry.description or M.Text( "Provided by: ", "提供者：" ) .. entry.owner
		end
		entry.available = entry.runtime == true or entry.inheritBase == true or name == self.active
		if not entry.available and entry.opaquePath then
			local path = entry.opaquePath:gsub( "%.png$", "" )
			entry.available = file.Exists( "materials/" .. path .. ".png", "GAME" )
		end
		self.packs[#self.packs + 1], self.byName[name] = entry, entry
	end
	if not dirty then self.draft = self.preference end
	if self.focus == nil then self.focus = self.draft end
	return self
end

function M.New()
	return setmetatable( {}, Session ):Refresh()
end

function Session:Choose( name )
	local entry = self.byName[name]
	if not entry then return false, "texture_pack_not_registered" end
	if not entry.available then return false, "missing_atlas_" .. name end
	self.draft, self.focus, self.error = name, name, nil
	return true
end

function Session:Revert()
	self:Refresh()
	self.draft, self.focus, self.error = self.preference, self.preference, nil
end

function Session:CanApply()
	local entry = self.byName[self.draft]
	return ( self:IsDirty() or self.active ~= self.draft ) and self.leaseOwner == nil and entry ~= nil and entry.available == true
end

function Session:Apply()
	self:Refresh()
	if self.leaseOwner then return false, "texture_pack_controlled_by_mode" end
	local entry = self.byName[self.draft]
	if not entry then return false, "texture_pack_not_registered" end
	if not entry.available then return false, "missing_atlas_" .. self.draft end
	local ok, result = MC.SetTexturePackPreference( self.draft )
	if not ok then
		self.error = tostring( result )
		MC.Fault( "texture_pack_manager_apply", "Could not select %s: %s", self.draft, self.error )
		return false, result
	end
	self.error = nil
	self:Refresh()
	return true, result
end

function Session:VisiblePacks( query )
	local result = {}
	query = string.lower( query or "" )
	for _, entry in ipairs( self.packs ) do
		if entry.name ~= self.draft then
			local text = string.lower( entry.name .. " " .. entry.title .. " " .. entry.description )
			if query == "" or string.find( text, query, 1, true ) then result[#result + 1] = entry end
		end
	end
	return result
end
