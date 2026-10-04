-- Animation/texture metadata policy. Pixel work uses Lua or native acceleration;
-- dimensions, frame selection and the 20 Hz clock are controlled by Lua.
MC = MC or {}
MC.ResourceSpriteRules = MC.ResourceSpriteRules or {}
local S = MC.ResourceSpriteRules
local function integer(v, low, high) return type(v) == "number" and v == math.floor(v) and v >= low and v <= high end
local STRATEGIES = {auto = true, mean = true, cutout = true, strict_cutout = true, dark_cutout = true}
function S.Parse(width, height, metadata, pbrClock)
	if not integer(width, 1, 16384) or not integer(height, 1, 16384) then return nil, "sprite_dimensions" end
	if metadata ~= nil and type(metadata) ~= "table" then return nil, "sprite_metadata_object" end
	metadata = metadata or {}
	local result = {width = width, height = height, frames = {{index = 0, time = 1}}, duration = 1,
		interpolate = false, animated = false, diagnostics = {}, strategy = "auto", alphaBias = 0, blur = false, clamp = false}
	local texture, a = metadata.texture, metadata.animation
	if texture ~= nil then
		if type(texture) ~= "table" then return nil, "sprite_texture_object" end
		for _, key in ipairs({"blur", "clamp"}) do
			if texture[key] ~= nil then
				if type(texture[key]) ~= "boolean" then return nil, "sprite_texture_" .. key end
				result[key] = texture[key]
			end
		end
		if texture.mipmap_strategy ~= nil then
			if not STRATEGIES[texture.mipmap_strategy] then return nil, "sprite_mipmap_strategy" end
			result.strategy = texture.mipmap_strategy
		end
		if texture.alpha_cutoff_bias ~= nil then
			local bias = texture.alpha_cutoff_bias
			if type(bias) ~= "number" or bias ~= bias or math.abs(bias) == math.huge then return nil, "sprite_alpha_cutoff_bias" end
			result.alphaBias = bias
		end
	end
	if a == nil then return result end
	if type(a) ~= "table" then return nil, "sprite_animation_object" end
	local function frameTime(v)
		-- Shader companion metadata can use fractional ticks (AVPBR uses 1.5).
		-- The color codec remains strict; companions share the 20 Hz time base.
		return integer(v, 1, 2147483647) or pbrClock == true and type(v) == "number" and v >= 1 and v <= 2147483647
	end
	for _, key in ipairs({"width", "height", "frametime"}) do
		if a[key] ~= nil and not (key == "frametime" and frameTime(a[key]) or integer(a[key], 1, 2147483647)) then return nil, "sprite_animation_" .. key end
	end
	if a.interpolate ~= nil and type(a.interpolate) ~= "boolean" then return nil, "sprite_animation_interpolate" end
	if a.width ~= nil then result.width, result.height = a.width, a.height or height
	elseif a.height ~= nil then result.width, result.height = width, a.height
	else result.width, result.height = math.min(width, height), math.min(width, height) end
	if width % result.width ~= 0 or height % result.height ~= 0 then return nil, "sprite_frame_size_not_divisible" end
	local columns, rows = width / result.width, height / result.height
	local count, frames, used = columns * rows, {}, {}
	if count > 65536 then return nil, "sprite_frame_budget" end
	local defaultTime = a.frametime or 1
	if a.frames == nil then
		for index = 0, count - 1 do frames[#frames + 1] = {index = index, time = defaultTime} end
	else
		if not MC.ResourcePackRules.Array(a.frames, 65536) then return nil, "sprite_animation_frames" end
		for pos, raw in ipairs(a.frames) do
			local index, time
			if type(raw) == "table" then index, time = raw.index, raw.time
			else index = raw end
			if time == nil then time = defaultTime end
			-- AnimationFrame's codec accepts nonnegative indices and positive times.
			if not integer(index, 0, 2147483647) or not frameTime(time) then return nil, "sprite_animation_frame_" .. pos end
			if index >= count then
				result.diagnostics[#result.diagnostics + 1] = {code = "invalid_frame_index", frame = pos - 1, index = index}
			else frames[#frames + 1], used[index] = {index = index, time = time}, true end
		end
		for index = 0, count - 1 do
			if not used[index] then result.diagnostics[#result.diagnostics + 1] = {code = "unused_frame", index = index} end
		end
	end
	result.columns, result.animated = columns, #frames > 1
	-- SpriteContents drops the animation for zero/one valid entries; initial
	-- static upload uses the image's top-left frame (even if frames says [2]).
	if result.animated then
		result.frames, result.duration, result.interpolate = frames, 0, a.interpolate == true
		for _, frame in ipairs(frames) do
			frame.start = result.duration
			result.duration = result.duration + frame.time
		end
	end
	return result
end

-- Absolute elapsed ticks avoid repeated catch-up loops after a pause. Rendering
-- a reflection or shadow never advances this clock. Returns zero-based frames.
function S.Sample(sprite, elapsedTicks)
	if not sprite.animated then return 0, 0, 0 end
	local tick = math.max(0, math.floor(elapsedTicks)) % sprite.duration
	local low, high = 1, #sprite.frames
	while low < high do
		local middle = math.floor((low + high + 1) / 2)
		if sprite.frames[middle].start <= tick then low = middle else high = middle - 1 end
	end
	local frame, fraction = sprite.frames[low], 0
	if sprite.interpolate then fraction = math.floor((tick - frame.start) / frame.time * 1000) / 1000 end
	return frame.index, sprite.frames[low % #sprite.frames + 1].index, fraction
end
