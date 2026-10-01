-- Selection and bake-on-apply state. Pending requests outlive the VGUI panel.
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
	local entries, registered = MC.ListTexturePacks(), {}
	for _, entry in ipairs( entries ) do registered[entry.name] = true end
	if MC.AtlasBaker and MC.AtlasBaker.ListPreparedPacks then
		for _, entry in ipairs( MC.AtlasBaker.ListPreparedPacks() ) do
			if not registered[entry.name] then entries[#entries + 1] = entry end
		end
	end
	for _, entry in ipairs( entries ) do
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
		entry.available = entry.bakeID ~= nil or entry.runtime == true or entry.inheritBase == true or name == self.active
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

function Session:ClearPending()
	if not self.pending then return end
	hook.Remove( "MC.AtlasBakeChanged", self.pending.hook )
	self.pending = nil
end

function Session:Choose( name )
	local entry = self.byName[name]
	if not entry then return false, "texture_pack_not_registered" end
	if not entry.available then return false, "missing_atlas_" .. name end
	if name ~= self.draft then self:ClearPending() end
	self.draft, self.focus, self.error = name, name, nil
	return true
end

function Session:Revert()
	self:ClearPending()
	self:Refresh()
	self.draft, self.focus, self.error = self.preference, self.preference, nil
end

function Session:CanApply()
	local entry = self.byName[self.draft]
	if self.pending or self.leaseOwner or not entry or not entry.available then return false end
	if entry.bakeID and MC.AtlasBaker.IsBusy() and MC.AtlasBaker.Status().pack ~= self.draft then return false end
	return self:IsDirty() or self.active ~= self.draft
end

function Session:ApplyRegistered()
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

function Session:Apply()
	self:Refresh()
	if self.pending then return true, "baking" end
	if self.leaseOwner then return false, "texture_pack_controlled_by_mode" end
	local entry = self.byName[self.draft]
	if not entry then return false, "texture_pack_not_registered" end
	if not entry.available then return false, "missing_atlas_" .. self.draft end
	if not entry.bakeID then return self:ApplyRegistered() end
	local baker = MC.AtlasBaker
	if baker.IsBusy() then
		if baker.Status().pack ~= self.draft then return false, "bake_already_running" end
	else
		local ok, err = baker.Start( entry.bakeID )
		if not ok then self.error = tostring( err ) return false, err end
	end
	M.applySerial = ( M.applySerial or 0 ) + 1
	local pending = { name = self.draft, preference = self.preference, serial = baker.Status().serial,
		hook = "mc_texture_pack_apply_" .. M.applySerial }
	self.pending, self.error = pending, nil
	hook.Add( "MC.AtlasBakeChanged", pending.hook, function( status )
		if status.serial ~= pending.serial then return end
		if status.state ~= "ready" and status.state ~= "failed" and status.state ~= "cancelled" then return end
		self:ClearPending()
		self:Refresh()
		if status.state ~= "ready" then self.error = status.error or "atlas_bake_cancelled" return end
		-- Recheck selection/ownership after the asynchronous boundary, before changing preference.
		if self.draft ~= pending.name or self.preference ~= pending.preference then
			self.error = "texture_pack_selection_changed" return
		end
		if self.leaseOwner then self.error = "texture_pack_controlled_by_mode" return end
		local ready = self.byName[pending.name]
		if not ready or not ready.runtime or ready.owner ~= "mc.atlas_baker" then
			self.error = "atlas_bake_not_registered"
			MC.Fault( "texture_pack_manager_bake_publish", "Completed atlas %s is not registered", pending.name )
			return
		end
		self:ApplyRegistered()
	end )
	return true, "baking"
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
