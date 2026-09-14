-- CPU geometry diagnostics. World builders publish native L2 records;
-- independent animation/diagnostic consumers can still inspect older records.
MC = MC or {}
local Store = MC.RenderGeometryStore or {}
MC.RenderGeometryStore = Store

Store.VERSION = 1
Store.RECORD_VERSION = 3
Store.SECTION_FIELDS = {
	"opaque", "translucent",
	"lightingRevision", "lightingToken",
	"opaqueBatchCount", "translucentBatchCount",
	"opaqueMaterialId", "opaquePassId",
	"translucentMaterialId", "translucentPassId",
}
Store.RECORD_FIELDS = {
	"mesh", "material", "verts", "light", "l2", "pixels", "request", "stage", "vertexCount",
	"lightByLi", "hasSecondaryUV", "translucent", "materialId", "passId",
}
Store.ABI = {
	space = "MC render space; chunk-local vertex positions",
	vertex = { "packed-v1", "stride=16", "x", "y", "z", "nx", "ny", "nz", "u", "v", "u1", "v1", "r", "g", "b", "a", "normalPresent", "secondaryUVPresent", "count", "legacy-read-supported" },
	light = { "world=quad_corners_v1", "4xRGBA8-per-quad", "blockByte", "skyByte", "shadeByte", "tintCode", "RGB=local-corner-address", "A=opacity", "legacy-read-supported" },
	passes = { "opaque", "translucent" },
}
-- Geometry records are owned by this store. Do not publish the old global
-- table alias: callers must use RenderGeometryStore accessors so record
-- lifetime and ABI validation remain centralized.
Store.sections = Store.sections or {}
Store.generation = Store.generation or 0
Store.payloadGeneration = Store.payloadGeneration or 0
Store.pins = Store.pins or {}

local function summarizeBatch( records, defaultPass )
	local count = records and #records or 0
	local materialId, passId = 0, defaultPass
	for i = 1, count do
		local record = records[i]
		local nextMaterial = record and record.materialId or 0
		local nextPass = record and record.passId or defaultPass
		if i == 1 then
			materialId, passId = nextMaterial, nextPass
		elseif materialId ~= nextMaterial or passId ~= nextPass then
			-- More than one numeric binding means this section contains
			-- multiple batches; zero marks the metadata as non-singular.
			materialId, passId = 0, 0
			break
		end
	end
	return count, materialId, passId
end

-- Section metadata is published once at commit time. Draw/recolor consumers can
-- use the numeric batch contract without inspecting material names or walking
-- records to infer the pass.
function Store.MakeSection( opaque, translucent )
	local opaqueCount, opaqueMaterialId, opaquePassId = summarizeBatch( opaque, 1 )
	local translucentCount, translucentMaterialId, translucentPassId = summarizeBatch( translucent, 3 )
	return {
		opaque = opaque,
		translucent = translucent,
		lightingRevision = 0,
		lightingToken = { revision = 0 },
		opaqueBatchCount = opaqueCount,
		translucentBatchCount = translucentCount,
		opaqueMaterialId = opaqueMaterialId,
		opaquePassId = opaquePassId,
		translucentMaterialId = translucentMaterialId,
		translucentPassId = translucentPassId,
	}
end

function Store.GetSection( key, sectionIndex )
	local chunk = Store.sections[key]
	if not chunk then return nil end
	return chunk[sectionIndex]
end

-- Consumers treat section and record containers as read-only; builders replace
-- whole sections through SetSection instead of mutating container membership.
function Store.GetPassRecords( key, sectionIndex, passName )
	local section = Store.GetSection( key, sectionIndex )
	return section and section[passName] or nil
end

function Store.GetPassBatchMeta( key, sectionIndex, passName )
	local section = Store.GetSection( key, sectionIndex )
	if not section then return 0, 0, 0 end
	if passName == "translucent" then
		return section.translucentBatchCount or 0,
			section.translucentMaterialId or 0,
			section.translucentPassId or 3
	end
	return section.opaqueBatchCount or 0,
		section.opaqueMaterialId or 0,
		section.opaquePassId or 1
end

function Store.SetSection( key, sectionIndex, value, drawSection )
	value.lightingToken = value.lightingToken or { revision = value.lightingRevision or 0 }
	if drawSection then drawSection.lightingToken = value.lightingToken end
	Store.sections[key] = Store.sections[key] or {}
	Store.sections[key][sectionIndex] = value
	Store.generation = Store.generation + 1
	Store.payloadGeneration = Store.payloadGeneration + 1
end

function Store.ClearSection( key, sectionIndex )
	local chunk = Store.sections[key]
	if not chunk or chunk[sectionIndex] == nil then return end
	chunk[sectionIndex] = nil
	if next( chunk ) == nil then Store.sections[key] = nil end
	Store.generation = Store.generation + 1
end

function Store.ClearChunk( key )
	if Store.sections[key] == nil then return end
	Store.sections[key] = nil
	Store.generation = Store.generation + 1
end

function Store.GetChunk( key )
	return Store.sections[key]
end

function Store.TouchLighting( section )
	section.lightingRevision = ( section.lightingRevision or 0 ) + 1
	section.lightingToken = section.lightingToken or {}
	section.lightingToken.revision = section.lightingRevision
	Store.generation = Store.generation + 1
	Store.payloadGeneration = Store.payloadGeneration + 1
end

function Store.Generation()
	return Store.generation
end

function Store.PayloadGeneration()
	return Store.payloadGeneration
end

-- A rebuilding consumer pins only its bounded outstanding requests, not the world.
function Store.PinSection( key, index )
	local pins = Store.pins[key]
	if not pins then pins = {} Store.pins[key] = pins end
	pins[index] = ( pins[index] or 0 ) + 1
end

function Store.UnpinSection( key, index )
	local pins = Store.pins[key]
	if not pins or not pins[index] then
		return MC.Fault( "render_geometry_pin_refs", "unbalanced section pin %s/%s", tostring( key ), tostring( index ) )
	end
	pins[index] = pins[index] - 1
	if pins[index] == 0 then pins[index] = nil end
	if next( pins ) == nil then Store.pins[key] = nil end
end

function Store.IsSectionPinned( key, index )
	local pins = Store.pins[key]
	return pins ~= nil and pins[index] ~= nil
end

-- Read-only view for schedulers; acquire/release ownership through the pin APIs.
function Store.GetPinnedSections( key )
	return Store.pins[key]
end

local function validNativeCorners( record, count )
	if count % 6 ~= 0 or not record.verts.vertexBufferVersion
		or record.light ~= nil or record.hasSecondaryUV ~= false
		or type( record.pixels ) ~= "table" or #record.pixels ~= count / 6 * 4 then return false end
	local floor = math.floor
	local order = { 1, 3, 2, 1, 4, 3 }
	for i = 1, count / 6 * 4 do
		local pixel = record.pixels[i]
		if type( pixel ) ~= "number" or pixel < 0 or pixel > 4294967295 or pixel ~= floor( pixel ) then return false end
	end
	for i = 0, count - 1 do
		local offset, verts = i * MC.RenderVertexBuffer.STRIDE, record.verts
		local address = floor( i / 6 ) * 4 + order[i % 6 + 1] - 1
		if verts[offset + 11] ~= address % 256 or verts[offset + 12] ~= floor( address / 256 ) % 256
			or verts[offset + 13] ~= floor( address / 65536 )
			or verts[offset + 14] < 0 or verts[offset + 14] > 255 or verts[offset + 14] ~= floor( verts[offset + 14] )
			or verts[offset + 9] ~= 0 or verts[offset + 10] ~= 0 or verts[offset + 16] ~= 0 then return false end
	end
	return true
end

-- Explicit diagnostic only. Nothing in the draw/build hot path calls this.
function Store.Validate()
	local result = {
		chunks = 0, sections = 0, records = 0, validRecords = 0,
		opaqueRecords = 0, translucentRecords = 0, invalidRecords = 0,
		packedRecords = 0, legacyRecords = 0, l2Records = 0, cornerTexels = 0,
		packedLightRecords = 0, legacyLightRecords = 0, lightSamples = 0,
		vertices = 0, faces = 0, errors = {},
	}
	for key, sections in pairs( Store.sections ) do
		result.chunks = result.chunks + 1
		for sectionIndex, section in pairs( sections or {} ) do
			result.sections = result.sections + 1
			if type( section ) ~= "table" then
				result.invalidRecords = result.invalidRecords + 1
				result.errors[#result.errors + 1] = tostring( key ) .. "/" .. tostring( sectionIndex ) .. ": section"
			else
					for passName, records in pairs( section ) do
						if passName == "opaque" or passName == "translucent" then
						if type( records ) ~= "table" then
							result.invalidRecords = result.invalidRecords + 1
							if #result.errors < 16 then
								result.errors[#result.errors + 1] = tostring( key ) .. "/" ..
									tostring( sectionIndex ) .. "/" .. passName .. ": records"
							end
							else
							local expectedCount = passName == "opaque"
								and section.opaqueBatchCount or section.translucentBatchCount
							if expectedCount ~= nil and expectedCount ~= #records then
								result.invalidRecords = result.invalidRecords + 1
								if #result.errors < 16 then
									result.errors[#result.errors + 1] = tostring( key ) .. "/" ..
										tostring( sectionIndex ) .. "/" .. passName .. ": batch_count"
								end
							end
							for recordIndex, record in ipairs( records ) do
							result.records = result.records + 1
							local verts = record and record.verts
							local light = record and record.light
							if type( verts ) == "table" then
								if verts.vertexBufferVersion then
									result.packedRecords = result.packedRecords + 1
								else
									result.legacyRecords = result.legacyRecords + 1
								end
							end
							if type( light ) == "table" then
								if light.lightBufferVersion then
									result.packedLightRecords = result.packedLightRecords + 1
								else
									result.legacyLightRecords = result.legacyLightRecords + 1
								end
							end
							local vertexCount = 0
							if record then
								if type( record.vertexCount ) == "number" then
									vertexCount = record.vertexCount
								elseif type( verts ) == "table" then
									vertexCount = MC.RenderVertexBuffer.Count( verts )
								end
							end
								local valid = type( record ) == "table"
									and record.mesh ~= nil and record.material ~= nil
									and type( verts ) == "table"
										and vertexCount > 0 and vertexCount == MC.RenderVertexBuffer.Count( verts )
										and MC.RenderVertexBuffer.Validate( verts )
								if valid then
									if record.l2 then
										valid = validNativeCorners( record, vertexCount )
									else
										valid = type( light ) == "table" and vertexCount == #light
											and MC.RenderLightBuffer.Validate( light )
									end
								end
								if valid then
								result.validRecords = result.validRecords + 1
								result.vertices = result.vertices + vertexCount
								result.faces = result.faces + math.floor( vertexCount / 6 )
									if record.l2 then
										result.l2Records = result.l2Records + 1
										result.cornerTexels = result.cornerTexels + #record.pixels
									else
										result.lightSamples = result.lightSamples + ( light.sampleCount or 0 )
									end
								if passName == "opaque" then
									result.opaqueRecords = result.opaqueRecords + 1
								else
									result.translucentRecords = result.translucentRecords + 1
								end
							else
								result.invalidRecords = result.invalidRecords + 1
								if #result.errors < 16 then
									result.errors[#result.errors + 1] = tostring( key ) .. "/" ..
										tostring( sectionIndex ) .. "/" .. passName .. "/" ..
										tostring( recordIndex )
								end
							end
						end
						end
					end
				end
			end
		end
	end
	return result
end

if concommand and concommand.Add then
	concommand.Add( "mc_render_geometry_validate", function()
		local result = Store.Validate()
		print( string.format(
			"[MC geometry] chunks=%d sections=%d records=%d valid=%d invalid=%d opaque=%d translucent=%d vertices=%d faces=%d packed=%d legacy=%d packedLight=%d legacyLight=%d lightSamples=%d l2=%d cornerTexels=%d",
			result.chunks, result.sections, result.records, result.validRecords,
			result.invalidRecords, result.opaqueRecords, result.translucentRecords,
			result.vertices, result.faces, result.packedRecords, result.legacyRecords,
			result.packedLightRecords, result.legacyLightRecords, result.lightSamples, result.l2Records, result.cornerTexels
		) )
		for i = 1, #result.errors do
			print( "[MC geometry] error " .. result.errors[i] )
		end
		end )
		concommand.Add( "mc_render_geometry_abi", function()
			print( string.format(
					"[MC geometry] storeVersion=%d recordVersion=%d sections=%s records=%s space=%s vertex=%s light=%s batchMeta=count,materialId,passId",
					Store.VERSION, Store.RECORD_VERSION,
					table.concat( Store.SECTION_FIELDS, "," ),
					table.concat( Store.RECORD_FIELDS, "," ),
					Store.ABI.space,
					table.concat( Store.ABI.vertex, "," ),
					table.concat( Store.ABI.light, "," )
			) )
	end )
end
