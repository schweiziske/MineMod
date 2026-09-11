-- L1/L2 material boundary.
-- This is a cold-path descriptor: draw and mesh hot paths consume numeric IDs
-- and already-resolved materials, never parse these names per vertex.
MC = MC or {}
local ABI = MC.RenderMaterialABI or {}
MC.RenderMaterialABI = ABI

ABI.VERSION = 1
ABI.SURFACE_VERSION = 1
ABI.PASSES = ABI.PASSES or { "opaque", "cutout", "translucent" }
ABI.SURFACE_FIELDS = ABI.SURFACE_FIELDS or {
	"baseColor", "normal", "roughness", "metallic", "emission",
}
ABI.LIGHT_FIELDS = ABI.LIGHT_FIELDS or {
	"blockLight", "skyLight", "ao", "tint",
}

ABI.DEFAULT_SURFACE = ABI.DEFAULT_SURFACE or {
	roughness = 1,
	metallic = 0,
	emission = 0,
}

ABI._materialIds = ABI._materialIds or setmetatable( {}, { __mode = "k" } )
ABI._materialNames = ABI._materialNames or {}
ABI._nextMaterialId = ABI._nextMaterialId or 0
ABI.PASS_IDS = ABI.PASS_IDS or { opaque = 1, cutout = 2, translucent = 3 }

function ABI.PassId( passName )
	return ABI.PASS_IDS[passName] or ABI.PASS_IDS.opaque
end

function ABI.MaterialId( material )
	if material == nil then return 0 end
	local id = ABI._materialIds[material]
	if id then return id end
	ABI._nextMaterialId = ABI._nextMaterialId + 1
	id = ABI._nextMaterialId
	ABI._materialIds[material] = id
	ABI._materialNames[id] = material
	return id
end

function ABI.Resolve( material, translucent, cutout )
	local passName = ABI.PassName( translucent, cutout )
	return ABI.MaterialId( material ), ABI.PassId( passName ), passName
end

function ABI.GetMaterial( materialId )
	return ABI._materialNames[materialId]
end

function ABI.PassName( translucent, cutout )
	if translucent then return "translucent" end
	if cutout then return "cutout" end
	return "opaque"
end

function ABI.DescribeMaterial( material, passName )
	return {
		material = material,
		pass = passName or "opaque",
		surfaceVersion = ABI.SURFACE_VERSION,
		lightFields = ABI.LIGHT_FIELDS,
		surfaceFields = ABI.SURFACE_FIELDS,
	}
end

if concommand and concommand.Add then
	concommand.Add( "mc_render_material_abi", function()
		print( string.format(
			"[MC material] version=%d surfaceVersion=%d passes=%s surface=%s light=%s",
			ABI.VERSION, ABI.SURFACE_VERSION,
			table.concat( ABI.PASSES, "," ),
			table.concat( ABI.SURFACE_FIELDS, "," ),
			table.concat( ABI.LIGHT_FIELDS, "," )
		) )
	end )
	concommand.Add( "mc_render_material_bindings", function()
		local rows = {
			{ name = "opaque", material = MC.Material, pass = "opaque" },
			{ name = "translucent", material = MC.MaterialTranslucent, pass = "translucent" },
			{ name = "gpu_opaque", material = MC.MaterialGpuOpaque, pass = "opaque" },
			{ name = "gpu_lighttex", material = MC.MaterialGpuLightTexture, pass = "opaque" },
		}
		for _, row in ipairs( rows ) do
			local materialId, passId = ABI.Resolve( row.material, row.pass == "translucent", false )
			print( string.format( "[MC material] %s materialId=%d passId=%d present=%s",
				row.name, materialId, passId, tostring( row.material ~= nil ) ) )
		end
	end )
end
