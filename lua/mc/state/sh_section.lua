--[[----------------------------------------------------------------------------
	MC : packed 16x16x16 block-state section storage.

	Packed values are zero-based local palette indexes; the Lua palette itself is
	kept one-based so ordinary array operations remain safe. Local index zero is
	not reserved: a uniform section (air or otherwise) therefore uses zero bits.
------------------------------------------------------------------------------]]

MC = MC or {}

local Section = {}
MC.StateSection = Section

Section.SIZE = 16
Section.CELL_COUNT = 16 * 16 * 16

local floor = math.floor
local bit_band = bit.band
local bit_bnot = bit.bnot
local bit_bor = bit.bor
local bit_lshift = bit.lshift
local bit_rshift = bit.rshift

local function integer( value )
	value = tonumber( value )
	if not value or value < 0 or floor( value ) ~= value then return nil end
	return value
end

local function maskForBits( bits )
	return 2 ^ bits - 1
end

local function bitsForPaletteSize( size )
	if size <= 1 then return 0 end
	local bits = 0
	local capacity = 1
	while capacity < size do
		bits = bits + 1
		capacity = capacity * 2
	end
	return bits
end

local function packedGet( words, bits, cellIndex )
	if bits == 0 then return 0 end
	local bitOffset = cellIndex * bits
	local wordIndex = floor( bitOffset / 32 ) + 1
	local shift = bitOffset % 32
	local word = words[wordIndex] or 0
	if shift + bits <= 32 then
		return bit_band( bit_rshift( word, shift ), maskForBits( bits ) )
	end

	local lowBits = 32 - shift
	local highBits = bits - lowBits
	local low = bit_band( bit_rshift( word, shift ), maskForBits( lowBits ) )
	local high = bit_band( words[wordIndex + 1] or 0, maskForBits( highBits ) )
	return low + bit_lshift( high, lowBits )
end

local function packedSet( words, bits, cellIndex, value )
	if bits == 0 then return end
	local bitOffset = cellIndex * bits
	local wordIndex = floor( bitOffset / 32 ) + 1
	local shift = bitOffset % 32
	if shift + bits <= 32 then
		local valueMask = maskForBits( bits )
		local shiftedMask = bit_lshift( valueMask, shift )
		local cleared = bit_band( words[wordIndex] or 0, bit_bnot( shiftedMask ) )
		words[wordIndex] = bit_bor( cleared, bit_lshift( bit_band( value, valueMask ), shift ) )
		return
	end

	local lowBits = 32 - shift
	local highBits = bits - lowBits
	local lowMask = maskForBits( lowBits )
	local shiftedLowMask = bit_lshift( lowMask, shift )
	local clearedLow = bit_band( words[wordIndex] or 0, bit_bnot( shiftedLowMask ) )
	words[wordIndex] = bit_bor( clearedLow, bit_lshift( bit_band( value, lowMask ), shift ) )

	local highMask = maskForBits( highBits )
	local clearedHigh = bit_band( words[wordIndex + 1] or 0, bit_bnot( highMask ) )
	words[wordIndex + 1] = bit_bor( clearedHigh, bit_band( bit_rshift( value, lowBits ), highMask ) )
end

local function resetUniform( section, stateId )
	section.palette = { stateId }
	section.paletteIndex = { [stateId] = 0 }
	section.refCount = { [0] = Section.CELL_COUNT }
	section.paletteSize = 1
	section.bitsPerEntry = 0
	section.words = {}
	section.count = stateId == 0 and 0 or Section.CELL_COUNT
	section.deadPaletteEntries = 0
	return section
end

local function resetEmpty( section )
	return resetUniform( section, 0 )
end

function Section.New()
	return resetEmpty( {} )
end

function Section.GetLocalIndex( section, cellIndex )
	cellIndex = integer( cellIndex )
	if not section or not cellIndex or cellIndex >= Section.CELL_COUNT then return nil end
	return packedGet( section.words, section.bitsPerEntry, cellIndex )
end

function Section.Get( section, cellIndex )
	local localIndex = Section.GetLocalIndex( section, cellIndex )
	if localIndex == nil then return nil end
	return section.palette[localIndex + 1] or 0
end

function Section.Resize( section, bitsPerEntry )
	if not section then return nil, "missing_section" end
	bitsPerEntry = integer( bitsPerEntry )
	local minimum = bitsForPaletteSize( section.paletteSize or 1 )
	if not bitsPerEntry or bitsPerEntry < minimum or bitsPerEntry > 12 then return nil, "invalid_bits_per_entry" end
	if bitsPerEntry == section.bitsPerEntry then return true end

	local oldWords = section.words
	local oldBits = section.bitsPerEntry
	local words = {}
	for cellIndex = 0, Section.CELL_COUNT - 1 do
		packedSet( words, bitsPerEntry, cellIndex, packedGet( oldWords, oldBits, cellIndex ) )
	end
	section.words = words
	section.bitsPerEntry = bitsPerEntry
	return true
end

function Section.Compact( section )
	if not section then return nil, "missing_section" end
	if ( section.count or 0 ) <= 0 then
		resetEmpty( section )
		return true
	end

	local states = {}
	for cellIndex = 0, Section.CELL_COUNT - 1 do
		states[cellIndex] = Section.Get( section, cellIndex ) or 0
	end

	section.palette = {}
	section.paletteIndex = {}
	section.refCount = {}
	section.paletteSize = 0
	section.bitsPerEntry = 0
	section.words = {}
	section.deadPaletteEntries = 0
	for cellIndex = 0, Section.CELL_COUNT - 1 do
		local stateId = states[cellIndex]
		local localIndex = section.paletteIndex[stateId]
		if localIndex == nil then
			localIndex = section.paletteSize
			section.paletteSize = localIndex + 1
			section.palette[localIndex + 1] = stateId
			section.paletteIndex[stateId] = localIndex
			section.refCount[localIndex] = 0
		end
		section.refCount[localIndex] = section.refCount[localIndex] + 1
	end

	section.bitsPerEntry = bitsForPaletteSize( section.paletteSize )
	section.words = {}
	for cellIndex = 0, Section.CELL_COUNT - 1 do
		local stateId = states[cellIndex]
		packedSet( section.words, section.bitsPerEntry, cellIndex, section.paletteIndex[stateId] )
	end
	return true
end

function Section.Set( section, cellIndex, stateId )
	cellIndex = integer( cellIndex )
	stateId = integer( stateId )
	if not section or not cellIndex or cellIndex >= Section.CELL_COUNT then return nil, "invalid_cell_index" end
	if not stateId then return nil, "invalid_state_id" end

	local oldLocalIndex = packedGet( section.words, section.bitsPerEntry, cellIndex )
	local oldStateId = section.palette[oldLocalIndex + 1] or 0
	if oldStateId == stateId then return false, oldStateId end

	local newLocalIndex = section.paletteIndex[stateId]
	local newEntryWasDead = newLocalIndex ~= nil and ( section.refCount[newLocalIndex] or 0 ) == 0
	if newLocalIndex == nil and ( section.refCount[oldLocalIndex] or 0 ) == 1 then
		-- The old state disappears with this write, so reuse its palette slot.
		-- This keeps the maximum palette at 4096 entries and turns a section
		-- whose final air cell becomes non-air into a 12-bit palette directly.
		section.paletteIndex[oldStateId] = nil
		section.palette[oldLocalIndex + 1] = stateId
		section.paletteIndex[stateId] = oldLocalIndex
		if oldStateId == 0 then section.count = section.count + 1 end
		if stateId == 0 then section.count = section.count - 1 end
		return true, oldStateId
	end
	if newLocalIndex == nil then
		local capacity = 2 ^ section.bitsPerEntry
		if section.deadPaletteEntries > 0 and section.paletteSize >= capacity then
			Section.Compact( section )
			oldLocalIndex = packedGet( section.words, section.bitsPerEntry, cellIndex )
			newLocalIndex = section.paletteIndex[stateId]
			newEntryWasDead = newLocalIndex ~= nil and ( section.refCount[newLocalIndex] or 0 ) == 0
		end
		if newLocalIndex == nil then
			newLocalIndex = section.paletteSize
			section.paletteSize = newLocalIndex + 1
			section.palette[newLocalIndex + 1] = stateId
			section.paletteIndex[stateId] = newLocalIndex
			section.refCount[newLocalIndex] = 0
			local neededBits = bitsForPaletteSize( section.paletteSize )
			if neededBits ~= section.bitsPerEntry then
				local resized, resizeError = Section.Resize( section, neededBits )
				if not resized then return nil, resizeError end
			end
		end
	end

	packedSet( section.words, section.bitsPerEntry, cellIndex, newLocalIndex )
	section.refCount[oldLocalIndex] = ( section.refCount[oldLocalIndex] or 0 ) - 1
	section.refCount[newLocalIndex] = ( section.refCount[newLocalIndex] or 0 ) + 1
	if section.refCount[oldLocalIndex] == 0 then
		section.deadPaletteEntries = section.deadPaletteEntries + 1
	end
	if newEntryWasDead and section.refCount[newLocalIndex] == 1 and section.deadPaletteEntries > 0 then
		section.deadPaletteEntries = section.deadPaletteEntries - 1
	end

	if oldStateId == 0 then section.count = section.count + 1 end
	if stateId == 0 then section.count = section.count - 1 end
	if section.count <= 0 then resetEmpty( section ) end
	if section.paletteSize > 1 and section.deadPaletteEntries >= section.paletteSize - 1 then
		-- Only one palette entry is still live, so every cell is stateId. Avoid a
		-- synchronous 4096-cell compact scan on the last write of a bulk fill.
		resetUniform( section, stateId )
	end
	return true, oldStateId
end

function Section.ForEach( section, cb )
	if not section or not cb or ( section.count or 0 ) <= 0 then return end
	for cellIndex = 0, Section.CELL_COUNT - 1 do
		local stateId = Section.Get( section, cellIndex )
		if stateId and stateId ~= 0 then cb( cellIndex, stateId ) end
	end
end
