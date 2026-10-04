-- Synchronous CPU planning. This does not publish textures or change selection.
-- A GPU consumer must accept the complete layout before it can be applied.
MC = MC or {}
MC.ResourceCompiler = MC.ResourceCompiler or {}
local C = MC.ResourceCompiler
C.VERSION = 3
local prepareResources
local function uint32(bytes, offset)
	local a, b, c, d = bytes:byte(offset, offset + 3)
	return ((a * 256 + b) * 256 + c) * 256 + d
end

-- The shipped recipe maps stable project tile IDs to exact Java resources.
-- Fixed tint/overlay variants are independent sprites, never deduplicated only
-- by PNG path. The ordinary Prepare API remains useful for plugin consumers.
function C.PrepareTiles(ids, revision, options, checkpoint)
	local baseOK, baseError = MC.ResourceDefaults.Ensure()
	if not baseOK then return nil, baseError end
	local refs, seen = {}, {}
	for _, tile in ipairs(MC.ResourceDefaults.tiles) do
		for _, id in ipairs({tile.resource, tile.overlay}) do
			if not seen[id] then refs[#refs+1], seen[id] = id, true end
		end
	end
	local sourcePlan, err = prepareResources(ids, revision, refs, options, true, checkpoint)
	if not sourcePlan then return nil, err end
	local sprites, byTile, key = {}, {}, {sourcePlan.key, MC.ResourceDefaults.digest, "tile-variants=1"}
	for index, tile in ipairs(MC.ResourceDefaults.tiles) do
		local base, overlay = sourcePlan.byID[tile.resource], sourcePlan.byID[tile.overlay]
		local sprite = {} for k,v in pairs(base) do sprite[k]=v end
		sprite.id, sprite.resource, sprite.tint = "mc:compiled/tile_" .. tile.tile, tile.resource, tile.tint
		sprite.item = tile.resource:find(":textures/item/",1,true) ~= nil
		if overlay then
			if base.animated and overlay.animated then
				if base.duration ~= overlay.duration or base.interpolate ~= overlay.interpolate or #base.frames ~= #overlay.frames then
					return nil, "resource_overlay_animation_mismatch:" .. tile.name
				end
				for i,frame in ipairs(base.frames) do
					if frame.index ~= overlay.frames[i].index or frame.time ~= overlay.frames[i].time then
						return nil, "resource_overlay_animation_mismatch:" .. tile.name
					end
				end
			end
			if overlay.animated then
				sprite.frames, sprite.duration, sprite.interpolate, sprite.animated = overlay.frames, overlay.duration, overlay.interpolate, true
			end
			sprite.baseWidth, sprite.baseHeight = base.width, base.height
			sprite.overlayWidth, sprite.overlayHeight, sprite.overlayPNG = overlay.width, overlay.height, overlay.png
			sprite.overlayNormalPNG, sprite.overlaySpecularPNG = overlay.normalPNG, overlay.specularPNG
			sprite.width, sprite.height = math.max(base.width,overlay.width), math.max(base.height,overlay.height)
		end
		sprites[index], byTile[tile.tile] = sprite, index - 1
		key[#key+1] = table.concat({tile.tile,tile.resource,tile.overlay or "",table.concat(tile.tint,",")},":")
	end
	options = options or {}
	local layout, reason, id = MC.AtlasLayout.Stitch(sprites, options.maxWidth or 16384,
		options.maxHeight or 16384, options.mip or 4, options.anisotropy or 0)
	if not layout then return nil, reason .. (id and ":" .. id or "") end
	sourcePlan.sprites, sourcePlan.byID, sourcePlan.byTile, sourcePlan.layout = sprites, nil, byTile, layout
	sourcePlan.key = util.SHA256(table.concat(key,"\n"))
	return sourcePlan
end
local function size(bytes)
	if #bytes < 33 or bytes:sub(1, 8) ~= "\137PNG\13\10\26\10" or uint32(bytes, 9) ~= 13 or bytes:sub(13, 16) ~= "IHDR" then
		return nil, "resource_png_header"
	end
	local w, h = uint32(bytes, 17), uint32(bytes, 21)
	if w < 1 or h < 1 or w > 16384 or h > 16384 then return nil, "resource_png_dimensions" end
	return w, h
end

-- refs are exact resource ids, independent of logical tile indices. Never infer
-- a renamed resource by basename and never treat a complete atlas as an overlay.
prepareResources = function(ids, revision, refs, options, skipLayout, checkpoint)
	if options == nil then options = {} end
	if type(options) ~= "table" or not MC.ResourcePackRules.Array(refs, 65536) or #refs == 0 then return nil, "resource_compile_arguments" end
	if options.pbr ~= nil and type(options.pbr) ~= "boolean" then return nil, "resource_compile_pbr_boolean" end
	local mip, width, height, aniso = options.mip, options.maxWidth, options.maxHeight, options.anisotropy
	if mip == nil then mip = 4 end
	if width == nil then width = 16384 end
	if height == nil then height = 16384 end
	if aniso == nil then aniso = 0 end
	local source, err = MC.ResourceRepository.OpenSelection(ids, revision, options.confirmed)
	if not source then return nil, err end
	local function prepare()
		local sprites, byID, bytes, pixels = {}, {}, 0, 0
		local pbr = options.pbr == true
		for _, id in ipairs(refs) do
			if not MC.ResourcePackRules.Identifier(id) or id:sub(-4) ~= ".png" then return nil, "resource_compile_texture_id" end
			if byID[id] then return nil, "resource_compile_duplicate:" .. id end
			local png, metadata, origin = source:Read(id)
			if not png then return nil, metadata end
			local w, h = size(png)
			if not w then return nil, id .. ":" .. h end
			bytes, pixels = bytes + #png, pixels + w * h
			if bytes > 268435456 or pixels > 67108864 then return nil, "resource_compile_input_budget:" .. id end
			local sprite, parseError = MC.ResourceSpriteRules.Parse(w, h, metadata)
			if not sprite then return nil, id .. ":" .. parseError end
			sprite.id, sprite.png, sprite.origin, sprite.imageWidth, sprite.imageHeight = id, png, origin, w, h
			if options.pbr ~= false then
				for _, channel in ipairs({{"_n", "normalPNG"}, {"_s", "specularPNG"}}) do
					local data, meta = source:ReadCompanion(origin, channel[1])
					if data == nil then return nil, id .. ":" .. tostring(meta) end
					if data then
						pbr = true
						local dw, dh = size(data)
						if dw ~= w or dh ~= h then return nil, "resource_pbr_dimensions:" .. id .. channel[1] end
						-- Missing companion animation metadata inherits the color clock.
						if meta and meta.animation then
							local parsed, reason = MC.ResourceSpriteRules.Parse(dw, dh, meta)
							if not parsed then return nil, id .. channel[1] .. ":" .. reason end
							if parsed.width ~= sprite.width or parsed.height ~= sprite.height or parsed.duration ~= sprite.duration
								or parsed.interpolate ~= sprite.interpolate or #parsed.frames ~= #sprite.frames then
								return nil, "resource_pbr_animation:" .. id .. channel[1]
							end
							for i, frame in ipairs(parsed.frames) do
								if frame.index ~= sprite.frames[i].index or frame.time ~= sprite.frames[i].time then
									return nil, "resource_pbr_animation:" .. id .. channel[1]
								end
							end
						end
						bytes, pixels = bytes + #data, pixels + dw * dh
						if bytes > 268435456 or pixels > 67108864 then return nil, "resource_compile_input_budget:" .. id end
						sprite[channel[2]] = data
					end
				end
			end
			sprites[#sprites + 1], byID[id] = sprite, sprite
			if checkpoint then checkpoint("prepare",#sprites,#refs) end
		end
		local layout
		if not skipLayout then
			local layoutError,spriteID
			layout,layoutError,spriteID=MC.AtlasLayout.Stitch(sprites,width,height,mip,aniso)
			if not layout then return nil,layoutError..(spriteID and ":"..spriteID or "") end
		end
		local valid, changed = source:Validate()
		if not valid then return nil, changed end
		local key = source:ContentKey() .. ":compiler=" .. C.VERSION .. ":layout=" .. MC.AtlasLayout.VERSION
			.. ":mip=" .. mip .. ":aniso=" .. aniso .. ":max=" .. width .. "x" .. height
			.. ":pbr=" .. tostring(pbr) .. ":sprites=" .. table.concat(refs, ",")
		return {selection = source.selection, catalogRevision = revision, sprites = sprites, byID = byID,
			layout = layout, pbr = pbr, key = util.SHA256(key), encodedBytes = bytes, decodedBytes = pixels * 4,
			-- Header validation cannot prove a PNG decodes. Never label this ready
			-- for rendering until the consuming backend has decoded all sources.
			state = "planned", pixelsValidated = false}
	end
	local ok, result, prepareError = pcall(prepare)
	source:Close()
	if not ok then
		if result=="resource_apply_cancelled" then return nil,result end
		MC.Fault("resource_compile_internal", "%s", tostring(result))
		return nil, tostring(result)
	end
	return result, prepareError
end
function C.Prepare(ids, revision, refs, options)
	return prepareResources(ids, revision, refs, options, false)
end
