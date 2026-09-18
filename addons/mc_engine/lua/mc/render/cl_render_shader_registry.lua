-- Precompiled shader variant registry.
-- This is intentionally metadata-only: registration and lookup are cold-path
-- operations, while draw code receives the already-resolved material object.
MC = MC or {}
local Registry = MC.RenderShaderRegistry or {}
MC.RenderShaderRegistry = Registry

Registry.VERSION = 1
Registry._profiles = Registry._profiles or {}
Registry._variants = Registry._variants or {}
Registry._activeRuntime = Registry._activeRuntime
Registry._runtimeSerial = Registry._runtimeSerial or 0

local function validName( value )
	return type( value ) == "string" and value ~= ""
		and string.match( value, "^[a-zA-Z0-9_%-]+$" ) ~= nil
end

function Registry.Register( profileName, definition )
	if not validName( profileName ) or type( definition ) ~= "table" then
		return false, "invalid_shader_profile"
	end
	local vertex = definition.vertex
	local pixel = definition.pixel
	if not validName( vertex ) or not validName( pixel ) then
		return false, "invalid_shader_variant"
	end
	local profile = Registry._profiles[profileName]
	if not profile then
		profile = { name = profileName, variants = {} }
		Registry._profiles[profileName] = profile
	end
	local variantName = definition.variant or "default"
	if not validName( variantName ) then return false, "invalid_shader_variant_name" end
	local variant = profile.variants[variantName]
	if not variant then
		variant = { profile = profileName, variant = variantName }
		profile.variants[variantName] = variant
	end
	variant.vertex = vertex
	variant.pixel = pixel
	variant.flags = definition.flags
	Registry._variants[profileName .. "/" .. variantName] = variant
	return true, variant
end

function Registry.Get( profileName, variantName )
	return Registry._variants[tostring( profileName or "" ) .. "/" .. tostring( variantName or "default" )]
end

function Registry.BuildRuntime( selections )
	if type( selections ) ~= "table" then return nil, "invalid_shader_runtime" end
	local runtime = { version = Registry.VERSION, variants = {}, serial = 0 }
	for passName, selection in pairs( selections ) do
		local profileName, variantName
		if type( selection ) == "table" then
			profileName, variantName = selection.profile, selection.variant
		end
			local variant = Registry.Get( profileName, variantName )
			if not variant then return nil, "missing_shader_variant_" .. tostring( passName ) end
			-- Publish a compact immutable snapshot. Keeping registry entries by
			-- reference would let a later registration mutate an already-active
			-- runtime halfway through a material rebuild.
			runtime.variants[passName] = {
				profile = variant.profile,
				variant = variant.variant,
				vertex = variant.vertex,
				pixel = variant.pixel,
			}
	end
	Registry._runtimeSerial = Registry._runtimeSerial + 1
	runtime.serial = Registry._runtimeSerial
	return runtime
end

function Registry.ValidateRuntime( runtime )
	if type( runtime ) ~= "table" or runtime.version ~= Registry.VERSION
		or type( runtime.variants ) ~= "table" then
		return false, "invalid_shader_runtime"
	end
		for passName, variant in pairs( runtime.variants ) do
			if type( passName ) ~= "string" or type( variant ) ~= "table"
				or not validName( variant.profile ) or not validName( variant.variant )
				or not validName( variant.vertex ) or not validName( variant.pixel ) then
			return false, "invalid_shader_runtime_variant"
		end
	end
	return true
end

function Registry.ActivateRuntime( runtime )
	local valid, err = Registry.ValidateRuntime( runtime )
	if not valid then return false, err end
	local previous = Registry._activeRuntime
	Registry._activeRuntime = runtime
	-- Activation is a cold-path event. Consumers may invalidate/rebuild their
	-- already-created material objects here; the frame draw loop never walks
	-- this hook or allocates runtime descriptors.
	if hook and hook.Run then
		hook.Run( "MCShaderRuntimeChanged", runtime, previous )
	end
	return true, runtime.serial
end

function Registry.ActiveRuntime()
	return Registry._activeRuntime
end

-- Hot-path consumers use this scalar lookup after runtime activation. It
-- intentionally returns the already-resolved variant table and never walks the
-- registry or parses a profile name.
function Registry.ActiveVariant( passName )
	local runtime = Registry._activeRuntime
	local variants = runtime and runtime.variants
	return variants and variants[passName] or nil
end

function Registry.ActiveSerial()
	local runtime = Registry._activeRuntime
	return runtime and runtime.serial or 0
end

function Registry.List()
	local result = {}
	for key, variant in pairs( Registry._variants ) do
		result[#result + 1] = {
			key = key, profile = variant.profile, variant = variant.variant,
			vertex = variant.vertex, pixel = variant.pixel,
		}
	end
	table.sort( result, function( left, right ) return left.key < right.key end )
	return result
end

function Registry.Validate()
	local result = { variants = 0, invalid = 0, errors = {} }
	for key, variant in pairs( Registry._variants ) do
		result.variants = result.variants + 1
		if type( variant ) ~= "table" or not validName( variant.vertex )
			or not validName( variant.pixel ) then
			result.invalid = result.invalid + 1
			if #result.errors < 16 then result.errors[#result.errors + 1] = key end
		end
	end
	return result
end

-- No built-in L1 programs. World shaders are owned by JSON render packs.

if concommand and concommand.Add then
	concommand.Add( "mc_render_shader_abi", function()
		local validation = Registry.Validate()
		local runtime = Registry.ActiveRuntime()
		print( string.format( "[MC shader] version=%d variants=%d",
			Registry.VERSION, validation.variants ) )
		for _, variant in ipairs( Registry.List() ) do
			print( string.format( "[MC shader] %s vertex=%s pixel=%s",
				variant.key, variant.vertex, variant.pixel ) )
		end
		for _, key in ipairs( validation.errors ) do
			print( "[MC shader] invalid " .. key )
		end
			print( string.format( "[MC shader] activeRuntime=%s serial=%s",
				tostring( runtime ~= nil ), tostring( runtime and runtime.serial or 0 ) ) )
			for _, passName in ipairs( { "opaque", "translucent" } ) do
				local active = Registry.ActiveVariant( passName )
				print( string.format( "[MC shader] active %s=%s/%s",
					passName, active and active.profile or "none",
					active and active.variant or "none" ) )
			end
	end )
	concommand.Add( "mc_render_abi_validate_all", function()
		local shader = Registry.Validate()
		local activeRuntime = Registry.ActiveRuntime()
		local geometry = MC.RenderGeometryStore and MC.RenderGeometryStore.Validate
			and MC.RenderGeometryStore.Validate() or nil
		print( string.format( "[MC ABI] shaderVersion=%d shaderVariants=%d shaderInvalid=%d",
			Registry.VERSION, shader.variants, shader.invalid ) )
		print( string.format( "[MC ABI] shaderRuntime=%s serial=%s",
			tostring( activeRuntime ~= nil ),
			tostring( activeRuntime and activeRuntime.serial or 0 ) ) )
		if geometry then
			print( string.format( "[MC ABI] geometryVersion=%d recordVersion=%d records=%d valid=%d invalid=%d",
				MC.RenderGeometryStore.VERSION, MC.RenderGeometryStore.RECORD_VERSION,
				geometry.records, geometry.validRecords, geometry.invalidRecords ) )
		else
			print( "[MC ABI] geometry unavailable" )
		end
		local materialABI = MC.RenderMaterialABI
		if materialABI and materialABI.Resolve then
			local opaqueId, opaquePass = materialABI.Resolve( MC.Material, false, false )
			local transId, transPass = materialABI.Resolve( MC.MaterialTranslucent, true, false )
			print( string.format( "[MC ABI] materialVersion=%d opaque=%d/%d translucent=%d/%d",
				materialABI.VERSION, opaqueId, opaquePass, transId, transPass ) )
		else
			print( "[MC ABI] material unavailable" )
		end
	end )
end
