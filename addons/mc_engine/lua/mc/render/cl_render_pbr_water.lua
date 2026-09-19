-- Water uses the same minimal IMesh declaration as terrain, with its own
-- COLOR0 contract: raw block/sky light, water-column depth, shoreline weight.
MC = MC or {}
local W = { VERSION = 1, MAX_DEPTH = 16 }
MC.RenderPBRWater = W
local requireValue = MC.RenderL2Resources.Require
local enabled = CreateClientConVar( "mc_pbr_water", "1", true, false, "PBR water in packs that provide a water program", 0, 1 )
local waves = CreateClientConVar( "mc_pbr_water_waves", "0.32", true, false, "Water ripple strength", 0, 1 )
local refraction = CreateClientConVar( "mc_pbr_water_refraction", "1", true, false, "Screen-space water distortion strength; 0 keeps undistorted transmission", 0, 1 )
local density = CreateClientConVar( "mc_pbr_water_density", "1", true, false, "Water absorption per block", 0.1, 4 )
local foam = CreateClientConVar( "mc_pbr_water_foam", "0.32", true, false, "Subtle shoreline foam", 0, 1 )
local floor, min = math.floor, math.min

function W.CurrentMaterial()
    if not enabled:GetBool() then return nil end
    return MC.API.Render.WaterMaterial()
end

local function columnDepth( cache, bx, by, bz )
    local key = MC.CellKey( bx, by, bz )
    local cached = cache[key]
    if cached ~= nil then return cached end
    local state = MC.GetBlockState( bx, by, bz )
    local kind, height = MC.Liquid.DecodeState( state )
    if kind ~= "water" then
        -- A dry solid neighbour contributes shore foam; an open waterfall edge
        -- contributes transparency without a fictitious white shoreline.
        local value = MC.Liquid.StateSolid( state, bx, by, bz ) and -1 or 0
        cache[key] = value
        return value
    end
    local depth = height
    for offset = 1, W.MAX_DEPTH do
        local below = MC.GetBlockState( bx, by, bz - offset )
        local belowKind = MC.Liquid.DecodeState( below )
        if belowKind ~= "water" then break end
        depth = min( depth + 1, W.MAX_DEPTH )
        if depth >= W.MAX_DEPTH then break end
    end
    cache[key] = depth
    return depth
end

function W.BuildOptics( batch, columns )
    requireValue( MC.Liquid and type( MC.Liquid.DecodeState ) == "function"
        and type( MC.Liquid.StateSolid ) == "function" and type( MC.GetBlockState ) == "function"
        and type( MC.CellKey ) == "function", "render_water_geometry_api", "water requires the fluid state/solid queries" )
    local light, data = batch.light, batch.light.data
    local stride = MC.RenderLightBuffer.STRIDE
    local optics = {}
    for sample = 1, light.sampleCount do
        local o = ( sample - 1 ) * stride
        local bx, by, bz, face = data[o + 2], data[o + 3], data[o + 4], data[o + 6]
        local depth, shore = 0.65, 0
        if face == MC.Face.TOP then
            local x, y = bx + floor( data[o + 8] + 0.5 ), by + floor( data[o + 9] + 0.5 )
            depth = 0
            for cy = y - 1, y do
                for cx = x - 1, x do
                    local value = columnDepth( columns, cx, cy, bz )
                    if value < 0 then shore = shore + 0.25 else depth = depth + value * 0.25 end
                end
            end
        end
        optics[sample] = floor( min( depth / W.MAX_DEPTH, 1 ) * 255 + 0.5 )
            + floor( shore * 255 + 0.5 ) * 256
    end
    batch.waterOptics = optics
end

function W.Recolor( batch, localLightChanged )
    local palette = batch.fluidLight
    if localLightChanged then palette = MC.RenderMesh.cacheFluidLightInputs( batch ) end
    if not palette then return nil end
    local verts, colors = batch.verts, {}
    for index, group in ipairs( palette.groups ) do
        local block, sky = floor( group.block * 16 + 0.5 ), floor( group.sky * 16 + 0.5 )
        colors[index] = block + sky * 256
        for _, offset in ipairs( group.offsets ) do
            verts[offset], verts[offset + 1] = block, sky
        end
    end
    local stride = MC.RenderVertexBuffer.STRIDE
    for vertex = 1, verts.count do
        local packed = batch.waterOptics[batch.light[vertex]]
        local o = ( vertex - 1 ) * stride
        verts[o + 13], verts[o + 14] = packed % 256, floor( packed / 256 )
    end
    -- Water consumes raw light on the GPU. Only local light edits come here;
    -- day/night and exposure never re-upload water geometry or vertex colours.
    return { palette = palette, colors = colors, changed = true }
end

local constants, refractionTexture, boundRefractionMaterial
local captureValidated = false
function W.PrepareView()
    if not constants then constants = Matrix() end
    boundRefractionMaterial = nil
    constants:SetField( 2, 1, RealTime() % 4096 )
    constants:SetField( 2, 2, waves:GetFloat() )
    constants:SetField( 2, 3, density:GetFloat() )
    constants:SetField( 2, 4, refraction:GetFloat() )
    constants:SetField( 3, 1, 0.015 )
    constants:SetField( 3, 2, 0.10 )
    constants:SetField( 3, 3, 0.12 )
    constants:SetField( 3, 4, foam:GetFloat() )
    constants:SetField( 4, 1, 0.38 )
    constants:SetField( 4, 2, 0.105 )
    constants:SetField( 4, 3, 0.065 )
    constants:SetField( 4, 4, 1 )
end

function W.CaptureRefraction()
    if not captureValidated then
        requireValue( render.GetScreenEffectTexture and render.UpdateScreenEffectTexture,
            "render_water_refraction_api", "water refraction requires the engine scene-copy texture" )
        captureValidated = true
    end
    local texture = render.GetScreenEffectTexture( 0 )
    requireValue( texture and not texture:IsError() and texture:Width() > 0 and texture:Height() > 0,
        "render_water_refraction_texture", "the scene-copy texture is unavailable" )
    -- One copy per actual view, after shadow preparation and solid animations.
    -- Never cache by FrameNumber: portals/reflections can share a frame clock.
    render.UpdateScreenEffectTexture( 0 )
    refractionTexture = texture
end

function W.Bind( material, record, base )
    local inverse = 1 / record.blockSize
    -- Only the chunk origin is wrapped. Wrapping each vertex would interpolate
    -- backwards at a period boundary; using engine XY would jump on re-origin.
    constants:SetField( 1, 1, record.originBX % 4096 - base.x * inverse )
    constants:SetField( 1, 2, record.originBY % 4096 - base.y * inverse )
    constants:SetField( 1, 3, record.originBZ % 4096 - base.z * inverse )
    constants:SetField( 1, 4, inverse )
    if boundRefractionMaterial ~= material then
        material:SetTexture( "$basetexture", refractionTexture )
        boundRefractionMaterial = material
    end
    MC.RenderPBR.Bind( material )
    material:SetMatrix( "$invviewprojmat", constants )
end
