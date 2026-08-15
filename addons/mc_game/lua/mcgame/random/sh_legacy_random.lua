-- Exact 48-bit java.util.Random / Minecraft LegacyRandomSource core.
-- The seed is split into two 24-bit limbs so every multiplication remains
-- below Lua's exact 53-bit integer range.

MC = MC or {}

local LIMB_BITS = 24
local LIMB = 16777216.0 -- 2^24
local LIMB_MASK = 16777215
local MODULUS = 281474976710656.0 -- 2^48
local MULTIPLIER_HIGH = 1502.0
local MULTIPLIER_LOW = 15525485.0
local INCREMENT = 11.0
local INT_31_MODULUS = 2147483648.0
local UINT_32_MODULUS = 4294967296.0

local LegacyRandom = {}
LegacyRandom.__index = LegacyRandom

local function finiteInteger( value )
	value = tonumber( value ) or 0
	if value ~= value or value == math.huge or value == -math.huge then return 0 end
	return math.floor( value )
end

local function splitLow48( value )
	value = finiteInteger( value ) % MODULUS
	return math.floor( value / LIMB ), value % LIMB
end

local function xor24( left, right )
	return bit.band( bit.bxor( left, right ), LIMB_MASK )
end

function LegacyRandom:SetSeed( seed )
	local high, low = splitLow48( seed )
	self.high = xor24( high, MULTIPLIER_HIGH )
	self.low = xor24( low, MULTIPLIER_LOW )
	return self
end

function LegacyRandom:GetSeedParts()
	return self.high, self.low
end

function LegacyRandom:NextBits( bits )
	bits = math.floor( tonumber( bits ) or -1 )
	if bits < 0 or bits > 32 then return nil, "invalid_random_bit_count" end

	local oldHigh, oldLow = self.high, self.low
	local lowProduct = oldLow * MULTIPLIER_LOW + INCREMENT
	local newLow = lowProduct % LIMB
	local carry = math.floor( lowProduct / LIMB )
	local newHigh = ( oldHigh * MULTIPLIER_LOW + oldLow * MULTIPLIER_HIGH + carry ) % LIMB
	self.high, self.low = newHigh, newLow

	if bits == 0 then return 0 end
	if bits <= LIMB_BITS then return math.floor( newHigh / 2 ^ ( LIMB_BITS - bits ) ) end
	return newHigh * 2 ^ ( bits - LIMB_BITS ) + math.floor( newLow / 2 ^ ( 48 - bits ) )
end

function LegacyRandom:NextInt( bound )
	if bound == nil then
		local value = self:NextBits( 32 )
		return value >= INT_31_MODULUS and value - UINT_32_MODULUS or value
	end

	bound = math.floor( tonumber( bound ) or 0 )
	if bound <= 0 or bound > 2147483647 then return nil, "invalid_random_bound" end
	if bit.band( bound, bound - 1 ) == 0 then
		return math.floor( self:NextBits( 31 ) / ( INT_31_MODULUS / bound ) )
	end

	while true do
		local sample = self:NextBits( 31 )
		local modulo = sample % bound
		-- Java evaluates this expression as a signed 32-bit int. A value at
		-- or above 2^31 is precisely the overflow-to-negative rejection case.
		if sample - modulo + ( bound - 1 ) < INT_31_MODULUS then return modulo end
	end
end

function LegacyRandom:NextBoolean()
	return self:NextBits( 1 ) ~= 0
end

function LegacyRandom:NextFloat()
	return self:NextBits( 24 ) / 16777216
end

function LegacyRandom:NextDouble()
	local upper = self:NextBits( 26 )
	local lower = self:NextBits( 27 )
	return ( upper * 134217728 + lower ) / 9007199254740992
end

function LegacyRandom:Copy()
	return setmetatable( { high = self.high, low = self.low }, LegacyRandom )
end

function MC.NewLegacyRandom( seed )
	return setmetatable( {}, LegacyRandom ):SetSeed( seed )
end

MC.LegacyRandomSource = LegacyRandom
