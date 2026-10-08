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
	for _, entry in ipairs( MC.ResourcePacks.ListPacks() ) do
		local name = entry.name
		if not entry.title or entry.title == "" then entry.title = name end
		entry.description = entry.description or M.Text( "Provided by: ", "提供者：" ) .. entry.owner
		self.packs[#self.packs + 1], self.byName[name] = entry, entry
	end
	if not dirty then self.draft = self.preference end
	if self.focus == nil then self.focus = self.draft end
	return self
end

function M.New()
	return setmetatable( {}, Session ):Refresh()
end

function Session:ClearPending( cancel )
	if not self.pending then return end
	local pending = self.pending
	hook.Remove( "MC.ResourcePackApplyChanged", pending.hook )
	self.pending = nil
	if cancel ~= false then MC.ResourcePacks.CancelApply( pending.id ) end
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
	if MC.ResourcePacks.IsApplying() then return false end
	if entry.bakeID and not entry.runtime and MC.AtlasBaker.IsBusy() and MC.AtlasBaker.Status().pack ~= self.draft then return false end
	return self:IsDirty() or self.active ~= self.draft
end

function Session:Apply(confirmed)
	self:Refresh()
	if self.pending then return true, "baking" end
	local options
	if confirmed then options = {confirmed=confirmed} end
	local ok, id = MC.ResourcePacks.ApplyPack( self.draft, options )
	if not ok then self.error = tostring( id ) return false, id end
	local status = MC.ResourcePacks.GetApplyStatus( id )
	if status.state ~= "baking" then
		self.error = status.error
		self:Refresh()
		if status.state ~= "ready" then return false, status.error end
		return true, status.name
	end
	M.applySerial = ( M.applySerial or 0 ) + 1
	local pending = { id = id, hook = "mc_texture_pack_apply_" .. M.applySerial }
	self.pending, self.error = pending, nil
	hook.Add( "MC.ResourcePackApplyChanged", pending.hook, function( status )
		if status.id ~= pending.id then return end
		if status.state ~= "ready" and status.state ~= "failed" and status.state ~= "cancelled" then return end
		self:ClearPending( false )
		self.error = status.error
		self:Refresh()
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
