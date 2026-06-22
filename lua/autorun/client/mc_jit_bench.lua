if SERVER then return end

MCJitBench = MCJitBench or {}

local Bench = MCJitBench
Bench.Version = 1

local DEFAULT_ITERATIONS = 120000
local DEFAULT_ROUNDS = 5
local AGGRESSIVE_PROFILE = { "hotloop=1", "hotexit=1" }

local bit_bor = bit and bit.bor
local bit_band = bit and bit.band
local bit_lshift = bit and bit.lshift

local function now()
	return SysTime()
end

local function printf( fmt, ... )
	print( "[MC JIT bench] " .. string.format( fmt, ... ) )
end

local function parsePositiveInt( value, fallback, minValue, maxValue )
	local n = math.floor( tonumber( value ) or fallback )
	if minValue and n < minValue then n = minValue end
	if maxValue and n > maxValue then n = maxValue end
	return n
end

local function hasJit()
	return jit and jit.status and jit.on and jit.off and jit.flush
end

local function jitStatusText()
	if not ( jit and jit.status ) then return "unavailable" end
	local values = { jit.status() }
	if #values == 0 then return "unknown" end
	for i = 1, #values do values[i] = tostring( values[i] ) end
	return table.concat( values, "," )
end

local function flushJit()
	if jit and jit.flush then
		jit.flush()
	end
end

local function restoreDefaultJit()
	if not hasJit() then return false, "jit unavailable" end
	jit.on()
	local ok, err = true, nil
	if jit.opt and jit.opt.start then
		ok, err = pcall( jit.opt.start, 3 )
	end
	flushJit()
	return ok, err
end

local function applyAggressiveJit()
	if not hasJit() then return false, "jit unavailable" end
	jit.on()
	local ok, err = true, nil
	if jit.opt and jit.opt.start then
		ok, err = pcall( jit.opt.start, unpack( AGGRESSIVE_PROFILE ) )
	end
	flushJit()
	return ok, err
end

local function applyJitMode( mode )
	if mode == "off" then
		if not hasJit() then return false, "jit unavailable" end
		jit.off()
		flushJit()
		return true
	elseif mode == "default" then
		return restoreDefaultJit()
	elseif mode == "aggressive" then
		return applyAggressiveJit()
	end
	return false, "unknown mode"
end

local function benchBitKeys( iterations )
	if not bit_bor or not bit_lshift or not bit_band then return 0 end
	local acc = 0
	for i = 1, iterations do
		local x = i % 32
		local y = math.floor( i / 7 ) % 32
		local z = math.floor( i / 31 ) % 32
		local extra = i % 4
		local key = bit_bor( x, bit_lshift( y, 6 ), bit_lshift( z, 12 ), bit_lshift( extra, 18 ) )
		acc = bit_band( acc + key, 2147483647 )
	end
	return acc
end

local function benchTableAppend( iterations )
	local verts = {}
	local light = {}
	local acc = 0
	for i = 1, iterations do
		local n = #verts + 1
		local x = ( i % 16 ) * 0.0625
		local y = ( math.floor( i / 16 ) % 16 ) * 0.0625
		local z = ( math.floor( i / 256 ) % 16 ) * 0.0625
		verts[n] = {
			x = x,
			y = y,
			z = z,
			u = x,
			v = y,
			r = 255 - ( i % 64 ),
			g = 220,
			b = 180 + ( i % 32 ),
		}
		light[n] = { bx = i % 4096, by = i % 2048, bz = i % 512, cx = x, cy = y, cz = z }
		acc = acc + verts[n].r + light[n].bz
		if n >= 4096 then
			verts = {}
			light = {}
		end
	end
	return acc
end

local function benchRecolor( iterations )
	local entries = {}
	for i = 1, 2048 do
		entries[i] = {
			shade = 178 + ( i % 65 ),
			light = i % 16,
			ao = 0.62 + ( ( i * 13 ) % 38 ) * 0.01,
		}
	end

	local acc = 0
	for i = 1, iterations do
		local e = entries[( i % 2048 ) + 1]
		local brightness = ( e.light + ( i % 4 ) ) / 18
		if brightness > 1 then brightness = 1 end
		local mul = brightness * e.ao
		local r = math.Clamp( math.floor( e.shade * mul + 0.5 ), 0, 255 )
		local g = math.Clamp( math.floor( 220 * mul + 0.5 ), 0, 255 )
		local b = math.Clamp( math.floor( 180 * mul + 0.5 ), 0, 255 )
		acc = acc + r + g + b
	end
	return acc
end

local function benchColorAlloc( iterations )
	local acc = 0
	for i = 1, iterations do
		local r = ( i * 37 ) % 256
		local g = ( i * 17 + 64 ) % 256
		local b = ( i * 29 + 128 ) % 256
		local color = Color( r, g, b, 255 )
		acc = acc + color.r + color.g + color.b + color.a
	end
	return acc
end

local function benchColorReuse( iterations )
	local color = Color( 0, 0, 0, 255 )
	local acc = 0
	for i = 1, iterations do
		color.r = ( i * 37 ) % 256
		color.g = ( i * 17 + 64 ) % 256
		color.b = ( i * 29 + 128 ) % 256
		color.a = 255
		acc = acc + color.r + color.g + color.b + color.a
	end
	return acc
end

local function benchColorNumeric( iterations )
	local acc = 0
	for i = 1, iterations do
		local r = ( i * 37 ) % 256
		local g = ( i * 17 + 64 ) % 256
		local b = ( i * 29 + 128 ) % 256
		acc = acc + r + g + b + 255
	end
	return acc
end

local COLOR_STORAGE_SIZE = 4096
local colorObjectSource
local colorObjectOutput
local colorNumericR
local colorNumericG
local colorNumericB
local colorNumericA
local colorNumericOutR
local colorNumericOutG
local colorNumericOutB
local colorNumericOutA
local colorStorageLight
local colorStorageAO

local function ensureColorStorageBenchData()
	if colorObjectSource then return end

	colorObjectSource = {}
	colorObjectOutput = {}
	colorNumericR = {}
	colorNumericG = {}
	colorNumericB = {}
	colorNumericA = {}
	colorNumericOutR = {}
	colorNumericOutG = {}
	colorNumericOutB = {}
	colorNumericOutA = {}
	colorStorageLight = {}
	colorStorageAO = {}

	for i = 1, COLOR_STORAGE_SIZE do
		local r = ( i * 37 ) % 256
		local g = ( i * 17 + 64 ) % 256
		local b = ( i * 29 + 128 ) % 256
		local a = 255

		colorObjectSource[i] = Color( r, g, b, a )
		colorObjectOutput[i] = Color( 0, 0, 0, a )

		colorNumericR[i] = r
		colorNumericG[i] = g
		colorNumericB[i] = b
		colorNumericA[i] = a
		colorNumericOutR[i] = 0
		colorNumericOutG[i] = 0
		colorNumericOutB[i] = 0
		colorNumericOutA[i] = a

		colorStorageLight[i] = i % 16
		colorStorageAO[i] = 0.62 + ( ( i * 13 ) % 38 ) * 0.01
	end
end

local function benchColorObjectStorage( iterations )
	ensureColorStorageBenchData()

	local source = colorObjectSource
	local output = colorObjectOutput
	local lights = colorStorageLight
	local aos = colorStorageAO
	local count = COLOR_STORAGE_SIZE
	local acc = 0

	for i = 1, iterations do
		local idx = ( i % count ) + 1
		local color = source[idx]
		local brightness = ( lights[idx] + ( i % 4 ) ) / 18
		if brightness > 1 then brightness = 1 end
		local mul = brightness * aos[idx]
		local r = math.floor( color.r * mul + 0.5 )
		local g = math.floor( color.g * mul + 0.5 )
		local b = math.floor( color.b * mul + 0.5 )
		local out = output[idx]
		out.r = r
		out.g = g
		out.b = b
		out.a = color.a
		acc = acc + r + g + b + out.a
	end

	return acc
end

local function benchColorNumericStorage( iterations )
	ensureColorStorageBenchData()

	local sourceR = colorNumericR
	local sourceG = colorNumericG
	local sourceB = colorNumericB
	local sourceA = colorNumericA
	local outputR = colorNumericOutR
	local outputG = colorNumericOutG
	local outputB = colorNumericOutB
	local outputA = colorNumericOutA
	local lights = colorStorageLight
	local aos = colorStorageAO
	local count = COLOR_STORAGE_SIZE
	local acc = 0

	for i = 1, iterations do
		local idx = ( i % count ) + 1
		local brightness = ( lights[idx] + ( i % 4 ) ) / 18
		if brightness > 1 then brightness = 1 end
		local mul = brightness * aos[idx]
		local r = math.floor( sourceR[idx] * mul + 0.5 )
		local g = math.floor( sourceG[idx] * mul + 0.5 )
		local b = math.floor( sourceB[idx] * mul + 0.5 )
		local a = sourceA[idx]
		outputR[idx] = r
		outputG[idx] = g
		outputB[idx] = b
		outputA[idx] = a
		acc = acc + r + g + b + a
	end

	return acc
end

local function benchShapeVisibility( iterations )
	local boxes = {
		{ 0.0, 0.0, 0.0, 1.0, 1.0, 0.25 },
		{ 0.25, 0.25, 0.25, 0.75, 0.75, 1.0 },
		{ 0.0, 0.375, 0.375, 1.0, 0.625, 0.625 },
	}
	local acc = 0
	for i = 1, iterations do
		local box = boxes[( i % #boxes ) + 1]
		local face = ( i % 6 ) + 1
		local plane
		if face == 1 then plane = box[6]
		elseif face == 2 then plane = box[3]
		elseif face == 3 then plane = box[4]
		elseif face == 4 then plane = box[1]
		elseif face == 5 then plane = box[5]
		else plane = box[2] end
		if plane > 0.49 and plane < 1.01 then
			acc = acc + face * 3 + math.floor( plane * 1000 )
		else
			acc = acc + face
		end
	end
	return acc
end

local BENCHES = {
	{ name = "bit_keys", fn = benchBitKeys },
	{ name = "table_append", fn = benchTableAppend },
	{ name = "recolor_math", fn = benchRecolor },
	{ name = "color_alloc", fn = benchColorAlloc },
	{ name = "color_reuse", fn = benchColorReuse },
	{ name = "color_numeric", fn = benchColorNumeric },
	{ name = "shape_visibility", fn = benchShapeVisibility },
}

local COLOR_STORAGE_BENCHES = {
	{ name = "color_object_store", fn = benchColorObjectStorage },
	{ name = "color_numeric_store", fn = benchColorNumericStorage },
}

local function timeBench( bench, iterations )
	local start = now()
	local checksum = bench.fn( iterations )
	return ( now() - start ) * 1000, checksum
end

local function runMode( mode, iterations, rounds, benches )
	benches = benches or BENCHES

	local ok, err = applyJitMode( mode )
	if not ok then
		printf( "mode=%s skipped reason=%s", mode, tostring( err ) )
		return nil
	end

	for i = 1, #benches do
		benches[i].fn( math.max( 1000, math.floor( iterations / 8 ) ) )
	end

	local result = { mode = mode, totalMS = 0, checksum = 0, cases = {} }
	for i = 1, #benches do
		local bench = benches[i]
		local bestMS, checksum
		for round = 1, rounds do
			local ms, sum = timeBench( bench, iterations )
			if not bestMS or ms < bestMS then
				bestMS = ms
				checksum = sum
			end
		end
		result.totalMS = result.totalMS + bestMS
		result.checksum = result.checksum + checksum
		result.cases[#result.cases + 1] = { name = bench.name, ms = bestMS, checksum = checksum }
	end
	return result
end

local function printResult( result )
	if not result then return end
	for i = 1, #result.cases do
		local case = result.cases[i]
		printf(
			"case=%s mode=%s ms=%.3f checksum=%s",
			case.name,
			result.mode,
			case.ms,
			tostring( case.checksum )
		)
	end
	printf( "summary mode=%s totalMS=%.3f checksum=%s", result.mode, result.totalMS, tostring( result.checksum ) )
end

local function caseMS( result, name )
	if not result then return nil end
	for i = 1, #result.cases do
		local case = result.cases[i]
		if case.name == name then return case.ms end
	end
	return nil
end

local function speedupText( base, nextResult )
	if not base or not nextResult or not base.totalMS or not nextResult.totalMS or nextResult.totalMS <= 0 then
		return "n/a"
	end
	return string.format( "%.2fx", base.totalMS / nextResult.totalMS )
end

local function ratioText( a, b )
	if not a or not b or b <= 0 then return "n/a" end
	return string.format( "%.2fx", a / b )
end

local function printColorStorageResult( result )
	if not result then return end
	local objectMS = caseMS( result, "color_object_store" )
	local numericMS = caseMS( result, "color_numeric_store" )
	printf(
		"[color-store] jit=%s Color()=%.3f numeric=%.3f Color()/numeric=%s checksum=%s",
		result.mode,
		objectMS or 0,
		numericMS or 0,
		ratioText( objectMS, numericMS ),
		tostring( result.checksum )
	)
end

function Bench.Run( iterations, rounds )
	iterations = parsePositiveInt( iterations, DEFAULT_ITERATIONS, 1000, 5000000 )
	rounds = parsePositiveInt( rounds, DEFAULT_ROUNDS, 1, 20 )

	printf( "run iterations=%d rounds=%d jitStatusBefore=%s", iterations, rounds, jitStatusText() )
	local off = runMode( "off", iterations, rounds )
	local default = runMode( "default", iterations, rounds )
	local aggressive = runMode( "aggressive", iterations, rounds )

	printResult( off )
	printResult( default )
	printResult( aggressive )

	printf(
		"compare default_vs_off=%s aggressive_vs_default=%s jitStatusAfter=%s",
		speedupText( off, default ),
		speedupText( default, aggressive ),
		jitStatusText()
	)
	restoreDefaultJit()
end

function Bench.RunColor( iterations, rounds )
	iterations = parsePositiveInt( iterations, DEFAULT_ITERATIONS, 1000, 5000000 )
	rounds = parsePositiveInt( rounds, DEFAULT_ROUNDS, 1, 20 )

	printf( "[color-store] run iterations=%d rounds=%d jitStatusBefore=%s", iterations, rounds, jitStatusText() )
	local default = runMode( "default", iterations, rounds, COLOR_STORAGE_BENCHES )

	printColorStorageResult( default )

	printf( "[color-store] jitStatusAfter=%s", jitStatusText() )
	restoreDefaultJit()
end

function Bench.Apply( mode )
	mode = tostring( mode or "default" ):lower()
	local ok, err = applyJitMode( mode )
	if ok then
		printf( "applied mode=%s jitStatus=%s", mode, jitStatusText() )
	else
		printf( "apply failed mode=%s reason=%s", mode, tostring( err ) )
	end
end

concommand.Add( "mc_jit_bench_run", function( _ply, _cmd, args )
	Bench.Run( args and args[1], args and args[2] )
end )

concommand.Add( "mc_jit_bench_color", function( _ply, _cmd, args )
	Bench.RunColor( args and args[1], args and args[2] )
end )

concommand.Add( "mc_jit_bench_apply", function( _ply, _cmd, args )
	Bench.Apply( args and args[1] or "aggressive" )
end )

concommand.Add( "mc_jit_bench_restore", function()
	local ok, err = restoreDefaultJit()
	if ok then
		printf( "restored default jitStatus=%s", jitStatusText() )
	else
		printf( "restore failed reason=%s", tostring( err ) )
	end
end )

printf( "loaded commands: mc_jit_bench_run [iterations] [rounds], mc_jit_bench_color [iterations] [rounds], mc_jit_bench_apply aggressive|default|off, mc_jit_bench_restore" )
