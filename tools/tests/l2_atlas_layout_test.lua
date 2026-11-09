-- Run from the repository root with Lua 5.1/LuaJIT.
local source = "addons/mc_engine/lua/mc/render/cl_render_atlas_layout.lua"
local function client( width, height, preference, native )
	local state = { preference = preference, queries = 0, faults = {}, messages = {} }
	local env = setmetatable( {}, { __index = _G } )
	local callback
	env.MC = {
		LightAtlasSize = { GetString = function() return state.preference end },
		T = function( key ) return key end,
		Fault = function( _, message ) state.faults[#state.faults + 1] = message end,
	}
	env.cvars = { AddChangeCallback = function( _, fn ) callback = fn end }
	env.print = function( message ) state.messages[#state.messages + 1] = message end
	env.RunConsoleCommand = function( name, value )
		assert( name == "mc_light_atlas_size" )
		local previous = state.preference
		state.preference = value
		callback( name, previous, value )
	end
	env.render = {
		MaxTextureWidth = function() return width end,
		MaxTextureHeight = function() return height end,
	}
	if native then
		env.mcmesh = { GetL2PixelTextureLimits = function()
			state.queries = state.queries + 1
			if native == "failure" then return nil, "l2_texture_hardware_config_unavailable" end
			return { maxWidth = width, maxHeight = height }
		end }
		if native == "old" then env.mcmesh.GetL2PixelTextureLimits = nil end
	end
	local function load()
		setfenv( assert( loadfile( source ) ), env )()
	end
	load()
	return env.MC.RenderAtlasLayout, state, load, env
end

for _, native in ipairs( { false, true } ) do
	for _, size in ipairs( { 16384, 8192, 4096 } ) do
		local layout, state = client( size, size, "auto", native )
		assert( layout.active.size == size and state.preference == "auto" )
		local fixed = client( 16384, 16384, tostring( size ), native )
		assert( fixed.active.size == size )
	end
end
local layout = client( 16384, 8192, "auto", true )
assert( layout.active.size == 8192 )
layout = client( 6000, 8192, "auto", true )
assert( layout.active.size == 4096 )
layout = client( 32768, 32768, "auto", true )
assert( layout.active.size == 16384 )
for _, preference in ipairs( { "auto", "16384", "8192", "4096" } ) do
	layout = client( 2048, 2048, preference, true )
	assert( not layout.active and layout.error:find( "l2_texture_device_limit", 1, true ) )
end
layout = client( 8192, 8192, "16384", true )
assert( not layout.active and layout.error:find( "maximum=8192x8192", 1, true ) )
for _, preference in ipairs( { "", "8192.5", "1024", "16K" } ) do
	layout = client( 16384, 16384, preference, true )
	assert( not layout.active and layout.error:find( "l2_atlas_size_invalid", 1, true ) )
end
for _, limit in ipairs( { 0, -1, 8192.5, math.huge, 0 / 0 } ) do
	local size, err = layout.Resolve( "auto", limit, 16384 )
	assert( size == nil and err == "l2_texture_device_limits_invalid" )
end
for _, native in ipairs( { "failure", "old" } ) do
	layout = client( 16384, 16384, "auto", native )
	assert( not layout.active and layout.error )
end

local state, reload
layout, state, reload = client( 8192, 8192, "auto", true )
local ok, err = layout.SetPreference( "16384" )
assert( ok == false and err and state.preference == "auto" )
assert( layout.SetPreference( "4096" ) )
assert( state.preference == "4096" and layout.active.size == 8192 and #state.messages == 1 )
local queries = state.queries
reload()
assert( state.queries == queries and layout.active.size == 8192 )
assert( layout.SetPreference( "auto" ) )
assert( state.preference == "auto" and layout.active.size == 8192 )

-- Cross-check the shader's bank decode and physical coordinates with Lua uploads.
for _, size in ipairs( { 16384, 8192, 4096 } ) do
	local _, _, _, env = client( 16384, 16384, tostring( size ), true )
	setfenv( assert( loadfile( "addons/mc_engine/lua/mc/render/cl_render_l2_resources.lua" ) ), env )()
	local r = env.MC.RenderL2Resources
	local capacity = size * math.floor( size / 5 )
	assert( r.CAPACITY == capacity )
	local function checkQuad( quad )
		if quad < 0 or quad >= capacity then return end
		local bank = math.floor( quad / r.BANK_QUADS )
		local localQuad = quad % r.BANK_QUADS
		local addressX, addressY = localQuad % 512, math.floor( localQuad / 512 )
		local parameter = r.AtlasParameter( bank )
		local code = math.floor( parameter / 64 )
		local scale = code + 1
		local columns = 8 / scale
		local row = math.floor( addressY * scale / 8 )
		local x = ( addressX + ( addressY - row * columns ) * 512 ) * 4
		local y = row + ( parameter - code * 64 ) * 256 * scale
		local inverseSize, quarterWidth = scale / 16384, columns * 512
		assert( inverseSize == 1 / size )
		for corner = 0, 3 do
			local actualX, actualY = r.CornerTexel( quad * 4 + corner )
			assert( actualX == x + corner and actualY == math.floor( ( y + 0.5 ) * 1.25 ) )
			assert( actualX < size and actualY < size )
		end
		local group = math.floor( y / 4 )
		local aoX, aoY = r.OcclusionTexel( quad )
		assert( aoX == x / 4 + ( y - group * 4 ) * quarterWidth and aoY == group * 5 + 2 )
	end
	for first = 0, capacity - 1, size / 4 do
		checkQuad( first - 1 )
		checkQuad( first )
	end
	checkQuad( capacity - 1 )
end
print( "PASS: atlas choices, limits, saved Auto, session lifetime, corner/AO rows and banks" )
