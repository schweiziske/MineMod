-- Native quad construction shares the Lua L2 scheduler, materials and atlas.
-- World/model selection remains authoritative in Lua; C++ owns the indexed
-- vertices, corner-light evaluation and Source IMesh lifetime.
MC = MC or {}
local N = MC.NativeL2 or { active = false }
MC.NativeL2 = N
N.COMMAND_STRIDE = 11

function N.IsActive() return N.active == true end

function N.Probe()
	local module = mcmesh
	if N.probed and N.module == module then return N.available, N.reason end
	N.probed, N.module, N.available = true, module, false
	N.reason = MC.NativeMeshModuleFailureReason or "installed DLL has no L2 interface; update mcswep_native_mesh"
	if type( module ) ~= "table" then return false, N.reason end
	for _, name in ipairs( { "L2Version", "CompileL2Template", "BuildL2Mesh", "GetL2Stats" } ) do
		if type( module[name] ) ~= "function" then return false, N.reason end
	end
	local ok, version = pcall( module.L2Version )
	if not ok or version ~= 1 then
		N.reason = "incompatible Native L2 interface: " .. tostring( version )
		return false, N.reason
	end
	N.available, N.reason = true, nil
	return true
end

local function queueWorld()
	for key in pairs( MC.World or {} ) do MC.MarkChunkDirty( key, true ) end
end

function N.SetEnabled( enabled )
	local available, reason = N.Probe()
	local active = enabled and available or false
	if active ~= N.active then N.active = active queueWorld() end
	if active then N.failure = nil end
	return active, reason
end

function N.DisableAfterFailure( reason )
	N.failure, N.active = tostring( reason ), false
	-- Let the failed builder finish unwinding its section buffers first.
	if N.rebuildQueued then return end
	N.rebuildQueued = true
	timer.Simple( 0, function()
		N.rebuildQueued = nil
		queueWorld()
	end )
end

local function compile( quad, positions, uv, baked, mode, emission )
	local cache, key
	if quad.nativeL2Mutable then
		-- Cubes/crosses provide a stable geometry owner, but their atlas UVs can
		-- vary by state or location. Numeric keys preserve exact UVs without
		-- string rounding. Fluids and dynamic shapes have no immutable owner.
		local owner = quad.nativeL2Owner
		if owner then
			cache = owner.nativeL2Templates
			if not cache then cache = {} owner.nativeL2Templates = cache end
			for corner = 1, 4 do
				for axis = 1, 2 do
					local coordinate = uv[corner][axis]
					local child = cache[coordinate]
					if not child then child = {} cache[coordinate] = child end
					cache = child
				end
			end
			key = "template"
		end
	else
		cache = quad.nativeL2Templates
		if not cache then cache = {} quad.nativeL2Templates = cache end
		key = baked or quad
	end
	local previous = cache and cache[key]
	if previous and previous.module == N.module then return previous.value end
	local flags = 0
	if baked then
		flags = ( baked.cubic and 1 or 0 ) + ( baked.planar and 2 or 0 )
			+ ( baked.partial and 4 or 0 ) + ( baked.smooth and 8 or 0 )
	end
	local data = { mode, baked and baked.face or quad.faceIndex, flags,
		baked and baked.directionShade or 1, baked and baked.flatShade or 255,
		baked and baked.emission or emission, baked and baked.lightFace or 0 }
	for corner = 1, 4 do
		local p, tex = positions[corner], uv[corner]
		for axis = 1, 3 do data[7 + ( corner - 1 ) * 3 + axis] = p[axis] end
		data[20 + ( corner - 1 ) * 2], data[21 + ( corner - 1 ) * 2] = tex[1], tex[2]
	end
	local normal = quad.normal
	data[28], data[29], data[30] = normal.x, normal.y, normal.z
	for corner = 1, 4 do
		for source = 1, 4 do
			local value = 0
			if baked and baked.partial then value = baked.weights[corner][source]
			elseif source == 1 then value = baked and baked.indices[corner] - 1 or corner - 1 end
			data[30 + ( corner - 1 ) * 4 + source] = value
		end
	end
	local value, err = N.module.CompileL2Template( data )
	if value == nil then
		N.DisableAfterFailure( err )
		MC.RenderL2Resources.Require( false, "native_l2_template", "Native L2 template failed: " .. tostring( err ) )
	end
	if cache then cache[key] = { module = N.module, value = value } end
	return value
end

function N.Emit( slice, buffer, quad, positions, uv, baked, bx, by, bz, wx, wy, wz, tint, mode, emission, prepared )
	local template = compile( quad, positions, uv, baked, mode, emission )
	local size = slice.blockSize
	if quad.positions then size, wx, wy, wz = 1, 0, 0, 0 end
	local commands, offset = buffer.nativeCommands, buffer.quadCount * N.COMMAND_STRIDE
	commands[offset + 1] = template
	commands[offset + 2], commands[offset + 3], commands[offset + 4] = bx, by, bz
	commands[offset + 5], commands[offset + 6], commands[offset + 7] = wx, wy, wz
	commands[offset + 8], commands[offset + 9] = size, tint
	commands[offset + 10] = quad.opacity or ( quad.shade and quad.shade.a ) or 255
	commands[offset + 11] = prepared or false
	buffer.nv, buffer.quadCount = buffer.nv + 6, buffer.quadCount + 1
end

function N.Upload( buffer, firstQuad, material )
	local slice = buffer.nativeSlice
	if not slice.nativeReader then
		local snapshot = slice.snapshot
		slice.nativeReader = function( x, y, z )
			local cell = snapshot:Read( x, y, z )
			if not cell then return nil end
			local packed = cell.block + cell.sky * 16 + cell.emission * 256 + cell.dampening * 4096
				+ ( cell.emissive and 65536 or 0 ) + ( cell.viewBlocking and 131072 or 0 )
				+ ( cell.solidRender and 262144 or 0 ) + ( cell.fullCollision and 524288 or 0 )
				+ ( cell.loaded and 1048576 or 0 )
			return packed, cell.shade
		end
	end
	-- Source resolves CreateMaterial entries through its runtime-material prefix.
	local result, err = N.module.BuildL2Mesh( buffer.nativeCommands, slice.nativeReader, slice.snapshot, firstQuad, "!" .. material:GetName() )
	MC.RenderL2Resources.Require( result ~= nil, "native_l2_build", "Native L2 batch failed: " .. tostring( err ) )
	return result
end

if concommand then
	concommand.Add( "mc_native_status", function()
		local available, reason = N.Probe()
		print( "[MC Native L2] requested=" .. tostring( MC.NativeMeshPreference:GetBool() )
			.. " active=" .. tostring( N.active ) .. " available=" .. tostring( available )
			.. " layout=mc:quad_corners_v1 scheduler=Lua-sections" )
		if reason or N.failure then print( "[MC Native L2] " .. tostring( N.failure or reason ) ) end
		if MC.NativeTakeover then PrintTable( MC.NativeTakeover.GetStatus() ) end
		if available then PrintTable( N.module.GetL2Stats() ) end
	end )
	concommand.Add( "mc_native_toggle", function()
		RunConsoleCommand( "mc_native_mesh", MC.NativeMeshPreference:GetBool() and "0" or "1" )
	end )
end
