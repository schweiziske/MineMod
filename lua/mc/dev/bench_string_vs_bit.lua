-- Standalone benchmark for comparing string keys/parsing with numeric and bit keys.
-- GMod's bit library is signed 32-bit, so the bit-packed cases only pack values
-- that fit safely. The full sync cell tuple local(13)+id(16)+orient(6) is 35 bits.
-- Run from the Garry's Mod server console:
--   lua_openscript mc/dev/bench_string_vs_bit.lua
--   mc_bench_string_vs_bit 2000000 3

local bitlib = bit or bit32
local band = bitlib and bitlib.band
local bor = bitlib and bitlib.bor
local lshift = bitlib and bitlib.lshift
local rshift = bitlib and bitlib.rshift

local function now()
	if SysTime then return SysTime() end
	return os.clock()
end

local function line( text )
	if MsgN then
		MsgN( text )
	else
		print( text )
	end
end

local function fmt( seconds )
	return string.format( "%.4fs", seconds )
end

local function bench( name, rounds, fn )
	local best
	local lastSum = 0

	for _ = 1, rounds do
		collectgarbage( "collect" )
		local start = now()
		lastSum = fn()
		local elapsed = now() - start
		if not best or elapsed < best then best = elapsed end
	end

	line( string.format( "[MC bench] %-32s best=%s checksum=%s", name, fmt( best or 0 ), tostring( lastSum ) ) )
	return best or 0
end

local function buildSamples( count )
	local stringParts = {}
	local numericPairs = {}
	local bitPacked = {}
	local bitOK = bitlib ~= nil

	for i = 1, count do
		local li = ( i - 1 ) % 8192
		local paletteIndex = ( i * 17 ) % 4096

		stringParts[i] = tostring( li ) .. ":" .. tostring( paletteIndex )
		numericPairs[i * 2 - 1] = li
		numericPairs[i * 2] = paletteIndex

		if bitOK then
			bitPacked[i] = bor( li, lshift( paletteIndex, 13 ) )
		end
	end

	return table.concat( stringParts, ";" ), numericPairs, bitPacked
end

local function runBenchmark( count, rounds )
	count = math.max( 1, math.floor( tonumber( count ) or tonumber( MC_BENCH_N ) or 500000 ) )
	rounds = math.max( 1, math.floor( tonumber( rounds ) or tonumber( MC_BENCH_ROUNDS ) or 3 ) )

	line( string.format( "[MC bench] string vs bit benchmark: count=%d rounds=%d", count, rounds ) )
	if not bitlib then
		line( "[MC bench] bit/bit32 library not found; bit-packed tests will be skipped." )
	else
		line( "[MC bench] bit note: GMod bit ops are signed 32-bit; packed tests stay below that limit." )
	end

	collectgarbage( "collect" )
	local setupStart = now()
	local packedString, numericPairs, bitPacked = buildSamples( count )
	line( string.format( "[MC bench] sample setup: %s packedStringBytes=%d", fmt( now() - setupStart ), #packedString ) )

	bench( "local key: string concat", rounds, function()
		local t = {}
		local sum = 0
		for i = 1, count do
			local lx = i % 16
			local ly = math.floor( i / 16 ) % 16
			local lz = math.floor( i / 256 ) % 32
			local key = lx .. ":" .. ly .. ":" .. lz
			t[key] = i
			sum = sum + ( t[key] or 0 )
		end
		return sum
	end )

	bench( "local key: numeric index", rounds, function()
		local t = {}
		local sum = 0
		for i = 1, count do
			local lx = i % 16
			local ly = math.floor( i / 16 ) % 16
			local lz = math.floor( i / 256 ) % 32
			local key = lx + ly * 16 + lz * 256
			t[key] = i
			sum = sum + ( t[key] or 0 )
		end
		return sum
	end )

	if bitlib then
		bench( "local key: bit packed", rounds, function()
			local t = {}
			local sum = 0
			for i = 1, count do
				local lx = i % 16
				local ly = math.floor( i / 16 ) % 16
				local lz = math.floor( i / 256 ) % 32
				local key = bor( lx, bor( lshift( ly, 4 ), lshift( lz, 8 ) ) )
				t[key] = i
				sum = sum + ( t[key] or 0 )
			end
			return sum
		end )
	end

	bench( "import cells: string gmatch", rounds, function()
		local sum = 0
		for liText, paletteText in string.gmatch( packedString, "([^:;]+):([^:;]*);?" ) do
			sum = sum + ( tonumber( liText ) or 0 ) + ( tonumber( paletteText ) or 0 )
		end
		return sum
	end )

	bench( "import cells: numeric pairs", rounds, function()
		local sum = 0
		for i = 1, #numericPairs, 2 do
			sum = sum + numericPairs[i] + numericPairs[i + 1]
		end
		return sum
	end )

	if bitlib then
		bench( "import cells: bit packed", rounds, function()
			local sum = 0
			for i = 1, #bitPacked do
				local packed = bitPacked[i]
				sum = sum + band( packed, 8191 ) + rshift( packed, 13 )
			end
			return sum
		end )
	end

	line( "[MC bench] done" )
end

if concommand then
	concommand.Add( "mc_bench_string_vs_bit", function( _, _, args )
		runBenchmark( args and args[1], args and args[2] )
	end )
end

if not MC_BENCH_NO_AUTORUN then
	runBenchmark()
end

return runBenchmark
