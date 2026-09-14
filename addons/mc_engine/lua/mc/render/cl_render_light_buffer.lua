-- Numeric corner samples plus one sample index per vertex. Published records
-- own their data; copies never retain the source buffer or a build scratch arena.
MC = MC or {}
local Buffer = {}
MC.RenderLightBuffer = Buffer
Buffer.VERSION = 2
Buffer.STRIDE = 18
Buffer.KIND = { BOX = 1, MODEL = 2, GENERATED = 3, CROSS = 4, FLUID = 5 }
-- shadeIndex, block xyz, id, face, li, corner xyz, emission, cubic, quadEmission, tint.
-- lighting kind, selected model ID, source quad, source corner (1..4).
-- -1 represents a missing li/emission; a missing shadeIndex marks invalid metadata.
local STRIDE = Buffer.STRIDE

local function finiteNumber( value )
	return type( value ) == "number" and value == value and value > -math.huge and value < math.huge
end

local function validCount( count )
	return finiteNumber( count ) and count >= 0 and count == math.floor( count )
end

-- Constant-time layout check for record consumers. Scratch arenas may retain
-- a numeric tail, so sample access below checks the live count separately.
function Buffer.IsCompatible( light )
	if type( light ) ~= "table" then return false end
	if light.lightBufferVersion == nil then return true end
	return light.lightBufferVersion == Buffer.VERSION and validCount( light.sampleCount )
		and type( light.data ) == "table" and #light.data == light.sampleCount * STRIDE
		and ( light.recolorKeys == nil or type( light.recolorKeys ) == "table" )
end

function Buffer.New()
	return { lightBufferVersion = Buffer.VERSION, sampleCount = 0, data = {} }
end

function Buffer.Reset( light )
	for i = 1, #light do light[i] = nil end
	for i = 1, #light.data do light.data[i] = nil end
	light.sampleCount, light.recolorKeys = 0, nil
end

-- Only the factory's unpublished arena uses this. Numeric tail capacity is
-- retained up to the largest block, but CopySample only reads live samples.
function Buffer.ResetScratch( light )
	light.sampleCount = 0
end

function Buffer.AddValues( light, shadeIndex, bx, by, bz, id, faceIndex, li, cx, cy, cz, selfEmission, faceCubic, quadLightEmission, tintCode,
	lightingKind, modelId, sourceQuad, cornerIndex )
	local sample = light.sampleCount + 1
	local offset, data = ( sample - 1 ) * STRIDE, light.data
	data[offset + 1] = shadeIndex or -1
	data[offset + 2], data[offset + 3], data[offset + 4] = bx or 0, by or 0, bz or 0
	data[offset + 5], data[offset + 6], data[offset + 7] = id or 0, faceIndex or 0, li or -1
	data[offset + 8], data[offset + 9], data[offset + 10] = cx or 0, cy or 0, cz or 0
	data[offset + 11], data[offset + 12] = selfEmission or -1, faceCubic ~= false and 1 or 0
	data[offset + 13], data[offset + 14] = quadLightEmission or 0, tintCode or 0
	data[offset + 15], data[offset + 16] = lightingKind or 0, modelId or 0
	data[offset + 17], data[offset + 18] = sourceQuad or 0, cornerIndex or 0
	light.sampleCount = sample
	return sample
end

function Buffer.AddLegacy( light, meta )
	if type( meta ) ~= "table" then return 0 end
	local sample = Buffer.AddValues( light, meta.shadeIndex, meta.bx, meta.by, meta.bz, meta.id,
		meta.faceIndex, meta.li, meta.cx, meta.cy, meta.cz, meta.selfEmission,
		meta.faceCubic, meta.quadLightEmission, meta.tintCode,
		meta.lightingKind, meta.modelId, meta.sourceQuad, meta.cornerIndex )
	if meta.recolorKey ~= nil then
		light.recolorKeys = light.recolorKeys or {}
		light.recolorKeys[sample] = meta.recolorKey
	end
	return sample
end

function Buffer.NewCopyMap()
	return { indexes = {} }
end

function Buffer.ResetCopyMap( copies )
	for key in pairs( copies.indexes ) do copies.indexes[key] = nil end
	copies.source, copies.target = nil, nil
end

local function copyIndexes( copies, target, source )
	if copies.source ~= source or copies.target ~= target then
		Buffer.ResetCopyMap( copies )
		copies.source, copies.target = source, target
	end
	return copies.indexes
end

local function validSampleIndex( sample, count )
	return finiteNumber( sample ) and sample >= 1 and sample <= count and sample == math.floor( sample )
end

local function validSample( light, sample )
	return type( light ) == "table" and light.lightBufferVersion == Buffer.VERSION
		and validCount( light.sampleCount ) and type( light.data ) == "table"
		and validSampleIndex( sample, light.sampleCount )
end

local function sampleDataOffset( data, sample )
	local offset = ( sample - 1 ) * STRIDE
	for i = 1, STRIDE do
		if not finiteNumber( data[offset + i] ) then return nil end
	end
	local li, cubic = data[offset + 7], data[offset + 12]
	if data[offset + 1] < 0 or li < -1 or li ~= math.floor( li ) then return nil end
	if cubic ~= 0 and cubic ~= 1 then return nil end
	for i = 15, 18 do
		if not validCount( data[offset + i] ) then return nil end
	end
	if data[offset + 15] > 5 or data[offset + 18] > 4 then return nil end
	return offset
end

local function sampleOffset( light, sample )
	if not validSample( light, sample ) then return nil end
	return sampleDataOffset( light.data, sample )
end

function Buffer.CopySample( target, source, sample, copies )
	if not validSample( source, sample ) then return 0 end
	local indexes = copyIndexes( copies, target, source )
	local copied = indexes[sample]
	if copied then return copied end
	local from = sampleDataOffset( source.data, sample )
	if from == nil then return 0 end
	copied = target.sampleCount + 1
	local to = target.sampleCount * STRIDE
	local targetData, sourceData = target.data, source.data
	for i = 1, STRIDE do targetData[to + i] = sourceData[from + i] end
	target.sampleCount, indexes[sample] = copied, copied
	return copied
end

-- Synchronous numeric copying has no callbacks. This bounded map is emptied
-- before returning so it cannot keep block caches or old sections alive.
local appendCopies = Buffer.NewCopyMap()
function Buffer.AppendRange( target, source, first, count )
	Buffer.ResetCopyMap( appendCopies )
	local n = #target
	for i = first, first + count - 1 do
		local sample
		if source.lightBufferVersion ~= nil then
			if target.lightBufferVersion ~= nil then
				sample = Buffer.CopySample( target, source, source[i], appendCopies )
			else
				local indexes = copyIndexes( appendCopies, target, source )
				local sourceSample = source[i]
				if validSample( source, sourceSample ) then
					sample = indexes[sourceSample]
					if not sample then
						sample = Buffer.Read( source, i, {} )
						indexes[sourceSample] = sample
					end
				end
			end
		elseif target.lightBufferVersion ~= nil then
			local meta = source[i]
			local indexes = copyIndexes( appendCopies, target, source )
			local validMeta = type( meta ) == "table"
			sample = validMeta and indexes[meta]
			if not sample then
				sample = Buffer.AddLegacy( target, meta )
				if validMeta then indexes[meta] = sample end
			end
		else
			sample = source[i]
		end
		n = n + 1
		target[n] = sample or false
	end
	Buffer.ResetCopyMap( appendCopies )
end

-- The caller may reuse out; it is a borrowed view, never a retained sample.
-- Legacy cache entries keep their original object identity.
function Buffer.Read( light, index, out )
	if type( light ) ~= "table" then return nil end
	if light.lightBufferVersion == nil then
		local meta = light[index]
		if type( meta ) == "table" then return meta end
		return nil
	end
	local sample = light[index]
	local offset = sampleOffset( light, sample )
	if offset == nil then return nil end
	local data = light.data
	out = out or {}
	out.shadeIndex = data[offset + 1]
	out.bx, out.by, out.bz = data[offset + 2], data[offset + 3], data[offset + 4]
	out.id, out.faceIndex = data[offset + 5], data[offset + 6]
	local li, emission = data[offset + 7], data[offset + 11]
	out.li = li >= 0 and li or nil
	out.cx, out.cy, out.cz = data[offset + 8], data[offset + 9], data[offset + 10]
	out.selfEmission = emission >= 0 and emission or nil
	out.faceCubic = data[offset + 12] ~= 0
	out.quadLightEmission, out.tintCode = data[offset + 13], data[offset + 14]
	out.lightingKind, out.modelId = data[offset + 15], data[offset + 16]
	out.sourceQuad, out.cornerIndex = data[offset + 17], data[offset + 18]
	out.shade, out.shared = nil, nil
	out.recolorKey = type( light.recolorKeys ) == "table" and light.recolorKeys[sample] or nil
	return out
end

function Buffer.LocalIndex( light, index )
	if type( light ) ~= "table" then return nil end
	if light.lightBufferVersion == nil then
		local meta = light[index]
		if type( meta ) ~= "table" then return nil end
		local li = meta.li
		if validCount( li ) then return li end
		return nil
	end
	local sample = light[index]
	if not validSample( light, sample ) then return nil end
	local li = light.data[( sample - 1 ) * STRIDE + 7]
	if validCount( li ) then return li end
	return nil
end

function Buffer.SetLocalIndex( light, index, li )
	if type( light ) ~= "table" or ( li ~= nil and not validCount( li ) ) then return false end
	if light.lightBufferVersion == nil then
		local meta = light[index]
		if type( meta ) ~= "table" then return false end
		meta.li = li
	else
		if not validSample( light, light[index] ) then return false end
		light.data[( light[index] - 1 ) * STRIDE + 7] = li or -1
	end
	return true
end

function Buffer.RecolorKey( light, index, keyFn )
	if type( light ) ~= "table" then return nil end
	if light.lightBufferVersion == nil then
		local meta = light[index]
		if type( meta ) ~= "table" or meta.shadeIndex == nil then return nil end
		if meta.recolorKey ~= nil then return meta.recolorKey end
		if not keyFn then return nil end
		local key = keyFn( meta.shadeIndex, meta.bx, meta.by, meta.bz, meta.faceIndex,
			meta.cx, meta.cy, meta.cz, meta.selfEmission, meta.tintCode )
		meta.recolorKey = key
		return key
	end
	local sample = light[index]
	local offset = sampleOffset( light, sample )
	if offset == nil then return nil end
	local data = light.data
	local keys = light.recolorKeys
	if keys ~= nil and type( keys ) ~= "table" then return nil end
	if keys and keys[sample] ~= nil then return keys[sample] end
	if not keyFn then return nil end
	local emission = data[offset + 11]
	local key = keyFn( data[offset + 1], data[offset + 2], data[offset + 3], data[offset + 4],
		data[offset + 6], data[offset + 8], data[offset + 9], data[offset + 10],
		emission >= 0 and emission or nil, data[offset + 14] )
	if not keys then
		keys = {}
		light.recolorKeys = keys
	end
	keys[sample] = key
	return key
end

function Buffer.ClearRecolorKeys( light )
	if type( light ) ~= "table" then return end
	if light.lightBufferVersion ~= nil then
		light.recolorKeys = nil
	else
		for i = 1, #light do
			local meta = light[i]
			if type( meta ) == "table" then meta.recolorKey = nil end
		end
	end
end

-- Full scan for diagnostics and block-cache admission, never per draw.
function Buffer.Validate( light )
	if not Buffer.IsCompatible( light ) then return false end
	if light.lightBufferVersion == nil then return true end
	-- IsCompatible already checked the shared layout and count. Validate every
	-- sample and reference without repeating those table checks per vertex.
	local count, data = light.sampleCount, light.data
	for sample = 1, count do
		if sampleDataOffset( data, sample ) == nil then return false end
	end
	for i = 1, #light do
		if not validSampleIndex( light[i], count ) then return false end
	end
	return true
end
