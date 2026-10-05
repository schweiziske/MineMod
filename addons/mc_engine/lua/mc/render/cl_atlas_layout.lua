-- Minecraft 26.2 Pre-Release 4 Stitcher/SpriteLoader, implemented in Lua.
-- Stable logical tile ids are independent of packing order. No work yields.
MC = MC or {}
MC.AtlasLayout = MC.AtlasLayout or {}
local L = MC.AtlasLayout
L.VERSION = 2
local min, max, floor = math.min, math.max, math.floor
local function integer(v, low, high) return type(v) == "number" and v == floor(v) and v >= low and v <= high end
local function power(v) local p = 1 if v == 0 then return 0 end while p < v do p = p * 2 end return p end
local function lowest(v) local p = 1 while v % 2 == 0 do p, v = p * 2, v / 2 end return p end
local function log2(v) local n = 0 while v >= 2 do v, n = floor(v / 2), n + 1 end return n end
local function node(x, y, w, h) return {x = x, y = y, width = w, height = h} end
local function add(n, item)
	if n.holder or item.width > n.width or item.height > n.height then return false end
	if item.width == n.width and item.height == n.height then n.holder = item return true end
	if not n.children then
		local x, y, w, h = n.x, n.y, item.width, item.height
		local dw, dh = n.width - w, n.height - h
		local children = {node(x, y, w, h)}
		if dw > 0 and dh > 0 then
			if max(n.height, dw) >= max(n.width, dh) then
				children[2], children[3] = node(x, y + h, w, dh), node(x + w, y, dw, n.height)
			else children[2], children[3] = node(x + w, y, dw, h), node(x, y + h, n.width, dh) end
		elseif dw == 0 then children[2] = node(x, y + h, w, dh)
		elseif dh == 0 then children[2] = node(x + w, y, dw, h) end
		n.children = children
	end
	for _, child in ipairs(n.children) do if add(child, item) then return true end end
	return false
end
local function gather(n, sprites, result)
	if n.holder then
		local index, pad = n.holder.index, result.padding
		local s = sprites[index]
		result.regions[index] = {n.x + pad, n.y + pad, s.width, s.height}
	else for _, child in ipairs(n.children or {}) do gather(child, sprites, result) end end
end
function L.Stitch(sprites, maxWidth, maxHeight, requestedMip, anisotropyBit)
	if type(sprites) ~= "table" or #sprites == 0 or #sprites > 65536 or not integer(maxWidth, 1, 16384)
		or not integer(maxHeight, 1, 16384) or not integer(requestedMip, 0, 14) or not integer(anisotropyBit, 0, 5) then
		return nil, "invalid_atlas_layout_settings"
	end
	local minimum, low, ids = 16384, 2 ^ requestedMip, {}
	for _, s in ipairs(sprites) do
		if type(s) ~= "table" or not MC.ResourcePackRules.Identifier(s.id) or not integer(s.width, 1, 16384)
			or not integer(s.height, 1, 16384) then return nil, "invalid_atlas_sprite" end
		if ids[s.id] then return nil, "duplicate_atlas_sprite", s.id end
		ids[s.id] = true
		minimum, low = min(minimum, s.width, s.height), min(low, lowest(s.width), lowest(s.height))
	end
	local mip = min(requestedMip, log2(min(minimum, low)))
	local align, padding = 2 ^ mip, 2 ^ mip * 2 ^ max(0, min(4, anisotropyBit - 1))
	local result = {width = 0, height = 0, mip = mip, padding = padding, regions = {}}
	local holders, storage = {}, {}
	for i, s in ipairs(sprites) do
		local ns, path = MC.ResourcePackRules.Identifier(s.id)
		holders[i] = {index = i, width = floor((s.width + 2 * padding + align - 1) / align) * align,
			height = floor((s.height + 2 * padding + align - 1) / align) * align, ns = ns, path = path}
	end
	table.sort(holders, function(a, b)
		if a.height ~= b.height then return a.height > b.height end
		if a.width ~= b.width then return a.width > b.width end
		if a.path ~= b.path then return a.path < b.path end
		return a.ns < b.ns
	end)
	for _, holder in ipairs(holders) do
		if holder.width > maxWidth or holder.height > maxHeight then return nil, "atlas_full", sprites[holder.index].id end
		local added = false
		for _, n in ipairs(storage) do if add(n, holder) then added = true break end end
		if not added then
			local cx, cy = power(result.width), power(result.height)
			local nx, ny = power(result.width + holder.width), power(result.height + holder.height)
			local canX, canY = nx <= maxWidth, ny <= maxHeight
			if not canX and not canY then return nil, "atlas_full", sprites[holder.index].id end
			local willX, willY = canX and cx ~= nx, canY and cy ~= ny
			local growX
			if willX ~= willY then growX = willX else growX = canX and cx <= cy end
			local slot
			if growX then
				if result.height == 0 then result.height = ny end
				slot = node(result.width, 0, nx - result.width, result.height) result.width = nx
			else slot = node(0, result.height, result.width, ny - result.height) result.height = ny end
			if not add(slot, holder) then return nil, "atlas_region_invariant", sprites[holder.index].id end
			storage[#storage + 1] = slot
		end
	end
	for _, n in ipairs(storage) do gather(n, sprites, result) end
	result.bytes = 0
	for level = 0, mip do result.bytes = result.bytes + max(1, floor(result.width / 2 ^ level)) * max(1, floor(result.height / 2 ^ level)) * 4 end
	return result
end

-- Keep frequent uploads spatially local without changing the reference Stitcher.
-- The island is an ordinary packed rectangle; logical tile indices stay stable.
function L.StitchAnimated(sprites, maxWidth, maxHeight, requestedMip, anisotropyBit)
	local original, err, id = L.Stitch(sprites, maxWidth, maxHeight, requestedMip, anisotropyBit)
	if not original then return nil, err, id end
	local animated, indices, static, staticIndices = {}, {}, {}, {}
	for index, sprite in ipairs(sprites) do
		if sprite.cacheAnimated or sprite.animated then
			animated[#animated + 1], indices[#indices + 1] = sprite, index
		else
			static[#static + 1], staticIndices[#staticIndices + 1] = sprite, index
		end
	end
	if #animated == 0 or #static == 0 then return original end
	local island = L.Stitch(animated, maxWidth, maxHeight, original.mip, anisotropyBit)
	if not island then return original end
	local islandID = "mc:internal/animation_island"
	local used = {}
	for _, sprite in ipairs(sprites) do used[sprite.id] = true end
	while used[islandID] do islandID = islandID .. "_" end
	static[#static + 1] = {id = islandID, width = island.width, height = island.height}
	local packed = L.Stitch(static, maxWidth, maxHeight, original.mip, anisotropyBit)
	-- Locality must not require a larger GPU allocation or reject a pack that fits.
	if not packed or packed.bytes > original.bytes then return original end
	local regions, origin = {}, packed.regions[#static]
	for i, index in ipairs(staticIndices) do regions[index] = packed.regions[i] end
	for i, index in ipairs(indices) do
		local r = island.regions[i]
		regions[index] = {origin[1] + r[1], origin[2] + r[2], r[3], r[4]}
	end
	packed.regions = regions
	packed.animationRegion = {origin[1], origin[2], island.width, island.height}
	return packed
end
