-- Shared scene depth and water SSR. GMod draws native colour depth before the ordinary scene,
-- but skips Lua opaque hooks in that pass. Before water, snapshot native depth
-- and explicitly merge MC geometry into a private texture, then capture colour.
-- No previous-frame colour/depth or camera history is sampled.
MC = MC or {}
local S = MC.RenderPBRSSR or { groups = {}, targets = {}, targetBytes = 0, depthCount = 0 }
MC.RenderPBRSSR = S
S.VERSION = 1 -- Shader/pack ABI is unchanged by the Lua depth-snapshot fix.
if S.DEPTH_VERSION ~= 2 then
    -- CreateMaterial retains snapshots across Lua refresh. Retire old materials
    -- which tested hardware Z; the new private merge has no depth attachment.
    for _, group in pairs( S.groups ) do group.depth = {} end
    S.DEPTH_VERSION = 2
end
S.depthRenderers = S.depthRenderers or {}
S.sceneGroups = S.sceneGroups or {}
local requireValue = MC.RenderL2Resources.Require
local enabled = CreateClientConVar( "mc_pbr_water_ssr", "1", true, false, "Screen-space reflections on PBR water; requires an additional scene depth pass", 0, 1 )
local distance = CreateClientConVar( "mc_pbr_water_ssr_distance", "48", true, false, "Maximum water reflection ray length in blocks", 4, 96 )
local steps = CreateClientConVar( "mc_pbr_water_ssr_steps", "32", true, false, "Water reflection ray steps", 8, 48 )
local strength = CreateClientConVar( "mc_pbr_water_ssr_strength", "1", true, false, "Water SSR contribution; misses retain the environment", 0, 1 )
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local waterNames = { "water_still", "water_flow" }
local slots = { "$c0_x", "$c0_y", "$c0_z", "$c0_w", "$c1_x", "$c1_y", "$c1_z", "$c1_w",
    "$c2_x", "$c2_y", "$c2_z", "$c2_w", "$c3_x", "$c3_y", "$c3_z", "$c3_w" }
local frame = { entries = {}, camera = {}, traceCamera = {}, depthCamera = {} }
local emptyRecords = {}
S.request, S.pending, S.depthSerial, S.serial, S.retryAt = nil, nil, nil, 0, 0
S.scene = nil
S.renderingDepth = nil
S.stats = { requests = 0, captures = 0, resolves = 0, depthPasses = 0, failures = 0, status = "idle", traceDraws = 0, compositeDraws = 0 }
local apiValidated, targetPushed, cameraStarted, modelPushed, overrides = false, false, false, false, false

local function validateAPI()
    if apiValidated then return end
    requireValue( render.GetViewSetup and render.GetRenderTarget and render.GetResolvedFullFrameDepth
        and render.PushRenderTarget and render.PopRenderTarget and render.Clear and render.OverrideBlend
        and render.OverrideAlphaWriteEnable and render.OverrideColorWriteEnable and render.OverrideDepthEnable
        and render.UpdateScreenEffectTexture and render.GetScreenEffectTexture
        and cam.Start and cam.End and cam.PushModelMatrix and cam.PopModelMatrix
        and GetRenderTargetEx and Mesh and Matrix and mesh.Begin and mesh.End and mesh.Position and mesh.TexCoord
        and RT_SIZE_LITERAL and MATERIAL_RT_DEPTH_NONE and MATERIAL_RT_DEPTH_SEPARATE
        and IMAGE_FORMAT_RGBA8888 and IMAGE_FORMAT_RGBA16161616F and BLENDFUNC_MIN,
        "render_ssr_api", "water SSR requires colour-depth, float render targets and scoped render state" )
    apiValidated = true
end

local function clean()
    S.renderingDepth = nil
    local first
    local function restore( callback, ... )
        local ok, err = pcall( callback, ... )
        if not ok and not first then first = err end
    end
    if modelPushed then restore( cam.PopModelMatrix ) modelPushed = false end
    if cameraStarted then restore( cam.End ) cameraStarted = false end
    if overrides then
        restore( render.OverrideDepthEnable, false, false )
        restore( render.OverrideAlphaWriteEnable, false, false )
        restore( render.OverrideColorWriteEnable, false, false )
        restore( render.OverrideBlend, false )
        restore( render.SetBlend, 1 )
        restore( render.SetColorModulation, 1, 1, 1 )
        overrides = false
    end
    if targetPushed then restore( render.PopRenderTarget ) targetPushed = false end
    return first
end

-- Only registered MC renderers participate; never replay global engine hooks.
-- A callback receives the captured camera, restores its own matrices/filters,
-- and throws (or returns false, reason) on failure. The coordinator restores
-- the outer RT/camera/blend scope before reporting the failure.
function S.RegisterDepthRenderer( id, callback )
    if type( id ) ~= "string" or id == "" then return false, "invalid_id" end
    if type( callback ) ~= "function" then return false, "invalid_callback" end
    S.depthRenderers[id] = callback
    return true
end

function S.UnregisterDepthRenderer( id )
    if type( id ) ~= "string" or id == "" then return false, "invalid_id" end
    S.depthRenderers[id] = nil
    return true
end

local function fault( code, err )
    S.request, S.pending, S.depthSerial, S.scene = nil, nil, nil, nil
    S.retryAt = SysTime() + 1
    S.stats.failures, S.stats.status = S.stats.failures + 1, "fault"
    if type( err ) == "table" then return MC.Fault( err.code or code, "%s", tostring( err.message ) ) end
    return MC.Fault( code, "%s", tostring( err ) )
end

local function writeState( depth )
    overrides = true
    render.OverrideBlend( true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD )
    render.OverrideAlphaWriteEnable( true, true )
    render.OverrideColorWriteEnable( true, true )
    render.OverrideDepthEnable( depth ~= nil, depth == true )
    render.SetBlend( 1 )
    render.SetColorModulation( 1, 1, 1 )
end

local function params( program, source, depth )
    return { ["$vertexshader"] = program.vertex, ["$pixshader"] = program.pixel,
        ["$basetexture"] = source:GetName(), ["$x360appchooser"] = 1, ["$vertexcolor"] = 1,
        ["$nocull"] = 1, ["$depthtest"] = depth and 1 or 0, ["$writedepth"] = 0, ["$ignorez"] = 0,
        ["$linearread_basetexture"] = 1, ["$linearwrite"] = 1 }
end

local function sourceCopy( prefix, programs, source )
    if not programs.ssr_source then return nil end
    local p = params( programs.ssr_source, source, false )
    p["$texture1"], p["$linearread_texture1"] = source:GetName(), 1
    local material = CreateMaterial( prefix .. "_sourcecopy", "screenspace_general_8tex", p )
    requireValue( material and not material:IsError(), "render_ssr_source_material", "depth-aware source material failed to load" )
    return material
end

-- Post effects register independently of water materials or visible fluids.
function S.RegisterScene( definition, blockSize, source )
    local key = definition.build .. "/" .. blockSize
    local group = S.sceneGroups[key]
    if group then return group end
    requireValue( definition.programs.post_scene_depth and definition.programs.post_depth_copy and definition.programs.ssr_copy,
        "render_scene_programs", "scene effects require depth and copy programs" )
    group = { blockSize = blockSize, programs = definition.programs, depth = {}, precisionDepth = true,
        copy = CreateMaterial( "mc_scene_copy3_" .. definition.build:sub( 1, 20 ) .. "_" .. blockSize,
            "screenspace_general_8tex", params( definition.programs.ssr_copy, source, false ) ),
        depthCopy = CreateMaterial( "mc_scene_native3_" .. definition.build:sub( 1, 20 ) .. "_" .. blockSize,
            "screenspace_general_8tex", params( definition.programs.post_depth_copy, source, false ) ) }
    requireValue( group.copy and not group.copy:IsError() and group.depthCopy and not group.depthCopy:IsError(),
        "render_scene_copy_material", "scene copy material failed to load" )
    group.sourceCopy = sourceCopy( "mc_scene_" .. definition.build:sub( 1, 20 ) .. "_" .. blockSize, definition.programs, source )
    S.sceneGroups[key] = group
    return group
end

-- Called while the selected pack's resources are being bound, never per vertex.
function S.Register( waterMaterial, definition, maps, blockSize )
    if not definition.programs.water_ssr then return end
    local old = S.groups[waterMaterial]
    if old then return old end
    local programs = definition.programs
    requireValue( programs.scene_depth and programs.ssr_copy and programs.water_ssr_composite,
        "render_ssr_programs", "water SSR requires scene depth, source copy, trace and composite programs" )
    local prefix = "mc_water_ssr1_" .. definition.build:sub( 1, 20 )
    local trace = params( programs.water_ssr, maps.normal, true )
    trace["$texture1"], trace["$texture3"] = maps.normal:GetName(), maps.normal:GetName()
    trace["$linearread_texture1"], trace["$linearread_texture3"] = 1, 1
    local composite = params( programs.water_ssr_composite, maps.normal, true )
    composite["$texture1"], composite["$texture2"] = maps.normal:GetName(), MC.RenderPackResources.shared.lightmap:GetName()
    MC.RenderPBR.Parameters( composite, maps )
    composite["$linearread_basetexture"], composite["$linearread_texture1"], composite["$linearread_texture4"] = 0, 1, 0
    local group = { blockSize = blockSize, programs = programs, depth = {},
        trace = CreateMaterial( prefix .. "_trace", "screenspace_general_8tex", trace ),
        composite = CreateMaterial( prefix .. "_composite", "screenspace_general_8tex", composite ),
        copy = CreateMaterial( prefix .. "_copy", "screenspace_general_8tex", params( programs.ssr_copy, maps.normal, false ) ) }
    group.sourceCopy = sourceCopy( prefix, programs, maps.normal )
    group.halfXY, group.halfZ = MC.CS * blockSize * 0.5, MC.CH * blockSize * 0.5
    group.radius = math.sqrt( 2 * group.halfXY * group.halfXY + group.halfZ * group.halfZ )
    requireValue( group.trace and not group.trace:IsError() and group.composite and not group.composite:IsError()
        and group.copy and not group.copy:IsError(), "render_ssr_materials", "water SSR materials failed to load" )
    MC.RenderPBR.Register( group.composite )
    S.groups[waterMaterial] = group
    return group
end

local function copyQuad( width, height )
    local quad = Mesh()
    mesh.Begin( quad, MATERIAL_QUADS, 1 )
    -- D3D9 pixel centres are integers. The full-size depth copy must land on
    -- individual source texels; colour reduction uses its own half-size quad.
    local x0, x1, y0, y1 = -1 - 1 / width, 1 - 1 / width, 1 + 1 / height, -1 + 1 / height
    for _, vertex in ipairs( { { x0, y0, 0, 0 }, { x1, y0, 1, 0 }, { x1, y1, 1, 1 }, { x0, y1, 0, 1 } } ) do
        mesh.Position( Vector( vertex[1], vertex[2], 0 ) )
        mesh.TexCoord( 0, vertex[3], vertex[4] )
        mesh.AdvanceVertex()
    end
    mesh.End()
    return quad
end
S.CopyQuad = copyQuad

function S.ReserveTargetBytes( bytes )
    requireValue( S.targetBytes + bytes <= 50331648, "render_ssr_target_budget",
        "scene effect target cache reached 48 MiB after resolution changes; restart to release engine render targets" )
    -- Source render targets cannot be freed; account even for a failed allocation.
    S.targetBytes = S.targetBytes + bytes
end

local function sceneTargets( width, height, water )
    local scale = min( 1, 1920 / width, 1080 / height )
    local dw, dh = max( 1, ceil( width * scale ) ), max( 1, ceil( height * scale ) )
    local traceScale = min( 0.5, 1280 / width, 720 / height )
    local w, h = max( 1, ceil( width * traceScale ) ), max( 1, ceil( height * traceScale ) )
    local key = "scene3_" .. dw .. "x" .. dh .. "_" .. w .. "x" .. h
    local t = S.targets[key]
    if not t then
        S.ReserveTargetBytes( dw * dh * 8 )
        t = { width = w, height = h, depthWidth = dw, depthHeight = dh }
        t.depth = GetRenderTargetEx( "mc_" .. key .. "_depth", dw, dh, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE,
            bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA16161616F )
        requireValue( t.depth and not t.depth:IsError() and t.depth:Width() == dw and t.depth:Height() == dh,
            "render_scene_depth_target", "floating-point scene depth allocation failed" )
        t.depthQuad = copyQuad( dw, dh )
        S.targets[key] = t
    end
    if water and not t.trace then
        S.ReserveTargetBytes( w * h * 16 )
        local source = GetRenderTargetEx( "mc_" .. key .. "_source", w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE,
            bit.bor( 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 )
        local trace = GetRenderTargetEx( "mc_" .. key .. "_trace", w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE,
            bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA16161616F )
        for _, texture in ipairs( { source, trace } ) do
            requireValue( texture and not texture:IsError() and texture:Width() == w and texture:Height() == h,
                "render_ssr_target", "water SSR target allocation or dimensions failed" )
        end
        t.source, t.trace = source, trace
        t.quad = copyQuad( w, h )
    end
    return t
end

local function targets( width, height )
    -- Half resolution, capped at 1280x720 with aspect preserved. Reuse each
    -- encountered size; the byte budget bounds Source's non-freeable RT cache.
    local scale = min( 0.5, 1280 / width, 720 / height )
    local w, h = max( 1, ceil( width * scale ) ), max( 1, ceil( height * scale ) )
    local key = "depth2_" .. width .. "x" .. height
    local t = S.targets[key]
    if t then return t end
    -- RGBA8 colour + RGBA16F trace + trace D24S8, and full-size RGBA8 depth.
    local bytes = w * h * 16 + width * height * 4
    requireValue( S.targetBytes + bytes <= 50331648, "render_ssr_target_budget",
        "water SSR target cache reached 48 MiB after resolution changes; restart to release engine render targets" )
    local prefix = "mc_water_ssr2_" .. key
    t = { width = w, height = h,
        source = GetRenderTargetEx( prefix .. "_source", w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE,
            bit.bor( 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 ),
        trace = GetRenderTargetEx( prefix .. "_trace", w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE,
            bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA16161616F ),
        depth = GetRenderTargetEx( prefix .. "_depth", width, height, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE,
            bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 ) }
    for _, texture in ipairs( { t.source, t.trace } ) do
        requireValue( texture and not texture:IsError() and texture:Width() == w and texture:Height() == h,
            "render_ssr_target", "water SSR target allocation or dimensions failed" )
    end
    requireValue( t.depth and not t.depth:IsError() and t.depth:Width() == width and t.depth:Height() == height,
        "render_ssr_depth_target", "water SSR private depth allocation or dimensions failed" )
    t.quad, t.depthQuad = copyQuad( w, h ), copyQuad( width, height )
    S.targets[key], S.targetBytes = t, S.targetBytes + bytes
    return t
end

local function validView( view )
    return view and not view.ortho and not view.offcenter and view.width and view.width > 0
        and view.height and view.height > 0 and view.origin and view.angles
        and ( view.aspect == nil or view.aspect >= 0 )
        and view.fov and view.fov > 0 and view.fov < 179 and view.znear and view.znear > 0 and view.zfar and view.zfar > view.znear
end

local function viewAspect( view )
    -- CViewSetup may leave aspect at zero to derive it from the viewport.
    if view.aspect and view.aspect > 0 then return view.aspect end
    return view.width / view.height
end

local function sameView( view, c )
    if not validView( view ) then return false end
    local o, a = view.origin, view.angles
    return o.x == c.ox and o.y == c.oy and o.z == c.oz and a.p == c.ap and a.y == c.ay and a.r == c.ar
        and view.fov == c.fov and viewAspect( view ) == c.aspect and view.znear == c.near and view.zfar == c.far
        and view.x == c.x and view.y == c.y and view.width == c.width and view.height == c.height
end
S.SameView = sameView

local function prepareDepth( view, records, scene, postGroup, postRequired )
    local c = frame
    c.active, c.generation, c.revision = MC.RenderPackRuntime.active, MC.StateWorldGeneration, MC.AppliedStateRevision
    c.frameWidth, c.frameHeight = scene:Width(), scene:Height()
    c.ox, c.oy, c.oz = view.origin.x, view.origin.y, view.origin.z
    c.ap, c.ay, c.ar = view.angles.p, view.angles.y, view.angles.r
    c.x, c.y, c.width, c.height = view.x, view.y, view.width, view.height
    c.fov, c.aspect, c.near, c.far = view.fov, viewAspect( view ), view.znear, view.zfar
    c.wave = c.wave or Matrix()
    c.projection = c.projection or Matrix()
    c.composition = c.composition or Matrix()
    local camera = c.camera
    camera.type, camera.origin, camera.angles = "3D", camera.origin or Vector(), camera.angles or Angle()
    camera.origin.x, camera.origin.y, camera.origin.z = c.ox, c.oy, c.oz
    camera.angles.p, camera.angles.y, camera.angles.r = c.ap, c.ay, c.ar
    camera.x, camera.y, camera.w, camera.h = c.x, c.y, c.width, c.height
    camera.aspect, camera.znear, camera.zfar = c.aspect, c.near, c.far
    -- cam.Start copies its fov argument directly into the view passed to
    -- Push3DView. Match the captured, already-adjusted horizontal FOV exactly;
    -- its default player view need not match a CalcView override of this view.
    camera.fov = c.fov
    local right, up, forward = camera.angles:Right(), camera.angles:Up(), camera.angles:Forward()
    local tangent = math.tan( math.rad( c.fov ) * 0.5 )
    local tanX, tanY = tangent * 1.05, tangent / c.aspect * 1.05
    local edgeX, edgeY = math.sqrt( 1 + tanX * tanX ), math.sqrt( 1 + tanY * tanY )
    local count, far = 0, min( c.far, 3980 )
    c.group, c.postGroup = postGroup, postRequired and postGroup or nil
    -- Conservative chunk spheres in render space: no vertex scan, and no
    -- extra full-scene depth draw when all nearby water is outside this view.
    for _, record in ipairs( records ) do
        local group = record.hasWater and S.groups[record.waterMaterial]
        if group then
            local base, radius = record.drawBase, group.radius
            local dx, dy, dz = base.x + group.halfXY - c.ox, base.y + group.halfXY - c.oy, base.z + group.halfZ - c.oz
            local z = dx * forward.x + dy * forward.y + dz * forward.z
            local x = dx * right.x + dy * right.y + dz * right.z
            local y = dx * up.x + dy * up.y + dz * up.z
            if z + radius >= c.near and z - radius <= far
                and math.abs( x ) <= z * tanX + radius * edgeX and math.abs( y ) <= z * tanY + radius * edgeY then
                count = count + 1
                local entry = c.entries[count]
                if not entry then entry = { base = Vector() } c.entries[count] = entry end
                entry.record, entry.group = record, group
                entry.base.x, entry.base.y, entry.base.z = base.x, base.y, base.z
                c.group = c.group or group
            end
        end
    end
    for i = count + 1, c.count or 0 do c.entries[i].record, c.entries[i].group = nil, nil end
    c.count = count
    if count == 0 and not postRequired then S.stats.status = "no_visible_water" return false end
    if postGroup then c.target = sceneTargets( c.frameWidth, c.frameHeight, count > 0 )
    else c.target = targets( c.frameWidth, c.frameHeight ) end
    c.nativeDepth = render.GetResolvedFullFrameDepth()
    requireValue( c.nativeDepth and not c.nativeDepth:IsError() and c.nativeDepth:Width() == c.frameWidth
        and c.nativeDepth:Height() == c.frameHeight, "render_ssr_depth_texture", "SSAO colour depth must match the current full frame" )
    c.depthTexture = c.target.depth
    for key, value in pairs( camera ) do c.depthCamera[key] = value end
    local depthSX, depthSY = c.depthTexture:Width() / c.frameWidth, c.depthTexture:Height() / c.frameHeight
    c.depthCamera.x, c.depthCamera.y = floor( c.x * depthSX ), floor( c.y * depthSY )
    c.depthCamera.w, c.depthCamera.h = max( 1, floor( c.width * depthSX ) ), max( 1, floor( c.height * depthSY ) )
    local trace = c.traceCamera
    for key, value in pairs( camera ) do trace[key] = value end
    local sx, sy = c.target.width / c.frameWidth, c.target.height / c.frameHeight
    trace.x, trace.y = floor( c.x * sx ), floor( c.y * sy )
    trace.w, trace.h = max( 1, floor( c.width * sx ) ), max( 1, floor( c.height * sy ) )
    c.scaleX, c.scaleY = trace.w / c.width, trace.h / c.height
    local horizontal = 0.5 / tangent
    local projection = c.projection
    for row, vector in ipairs( { right, up, forward } ) do
        projection:SetField( row, 1, vector.x ) projection:SetField( row, 2, vector.y ) projection:SetField( row, 3, vector.z )
    end
    projection:SetField( 1, 4, horizontal ) projection:SetField( 2, 4, horizontal * c.aspect )
    projection:SetField( 3, 4, c.near * 1.01 )
    projection:SetField( 4, 1, c.x / c.frameWidth ) projection:SetField( 4, 2, c.y / c.frameHeight )
    projection:SetField( 4, 3, c.width / c.frameWidth ) projection:SetField( 4, 4, c.height / c.frameHeight )
    c.composition:SetField( 1, 1, forward.x ) c.composition:SetField( 1, 2, forward.y ) c.composition:SetField( 1, 3, forward.z )
    c.composition:SetField( 2, 1, c.target.width ) c.composition:SetField( 2, 2, c.target.height )
    c.composition:SetField( 2, 3, 1 / c.target.width ) c.composition:SetField( 2, 4, 1 / c.target.height )
    c.composition:SetField( 3, 1, 1 / c.depthTexture:Width() ) c.composition:SetField( 3, 2, 1 / c.depthTexture:Height() )
    c.composition:SetField( 3, 3, c.group.precisionDepth and 1 or 0 )
    c.composition:SetField( 3, 4, c.group.sourceCopy and 1 or 0 )
    S.serial = S.serial + 1
    c.serial, c.frame = S.serial, FrameNumber()
    S.request = c
    S.stats.requests, S.stats.status = S.stats.requests + 1, "awaiting_capture"
    return true
end

local function discard( status )
    S.request, S.pending, S.depthSerial, S.scene = nil, nil, nil, nil
    S.stats.status = status
    return false
end

local function currentScene( c )
    return c.active == MC.RenderPackRuntime.active and c.generation == MC.StateWorldGeneration
        and c.revision == MC.AppliedStateRevision
end

local function requestDepth()
    validateAPI()
    local view = render.GetViewSetup( true )
    -- This hook is called in DrawSetup with VIEW_ILLEGAL (-2), before
    -- DrawExecute sets VIEW_MAIN (0). Do not apply Capture's view-ID guard here.
    if render.GetRenderTarget() ~= nil then
        -- A foreign depth request before our snapshot can overwrite native
        -- depth. A completed private snapshot is independent of that texture.
        if S.request and S.depthSerial ~= S.request.serial then return discard( "native_depth_interrupted" ) end
        return false
    end
    if not validView( view ) then return discard( "unsupported_view" ) end
    S.request, S.pending, S.depthSerial, S.scene = nil, nil, nil, nil
    local postGroup
    if MC.RenderPBRPost then postGroup = MC.RenderPBRPost.DepthGroup( view ) end
    local postRequired = postGroup ~= nil
    local records = emptyRecords
    if enabled:GetBool() and strength:GetFloat() > 0 then
        local material = MC.RenderPBRWater.CurrentMaterial()
        if material and S.groups[material] then
            requireValue( type( MC.CollectWaterSSRRecords ) == "function", "render_ssr_water_source",
                "water SSR requires the current fluid mesh collector before NeedsDepthPass" )
            records = MC.CollectWaterSSRRecords( view.origin ) or emptyRecords
        elseif not postGroup then return discard( "no_ssr_material" ) end
    end
    -- Keep the precision/cache family stable when SSAO/fog are toggled or a
    -- post pass is retrying. Visible water still uses the current pack's depth.
    if not postGroup and #records > 0 and MC.RenderPBRPost then postGroup = MC.RenderPBRPost.DepthGroup( view, true ) end
    if #records == 0 and not postGroup then return discard( "no_visible_water" ) end
    local scene = render.GetScreenEffectTexture( 0 )
    requireValue( scene and not scene:IsError() and scene:Width() > 0 and scene:Height() > 0,
        "render_ssr_scene_texture", "water SSR requires the current full-frame scene texture" )
    return prepareDepth( view, records, scene, postGroup, postRequired )
end

function S.RequestDepth()
    if ( not enabled:GetBool() or strength:GetFloat() == 0 )
        and ( not MC.RenderPBRPost or not MC.RenderPBRPost.NeedsDepth() ) then return discard( "disabled" ) end
    if SysTime() < S.retryAt then return false end
    local ok, result = pcall( requestDepth )
    if not ok then return fault( "render_ssr_request", result ) end
    return result
end

local function captureDepth( c )
    local group = c.group
    render.PushRenderTarget( c.depthTexture ) targetPushed = true
    writeState( nil )
    local depthCopy = group.depthCopy or group.copy
    depthCopy:SetTexture( "$basetexture", c.nativeDepth )
    render.SetMaterial( depthCopy )
    c.target.depthQuad:Draw()
    cam.Start( c.depthCamera ) cameraStarted = true
    S.renderingDepth = c
    for id, draw in pairs( S.depthRenderers ) do
        writeState( nil )
        -- Linear clip-W is monotonic. MIN keeps the nearest native/MC surface
        -- regardless of submission order, without sharing/writing main-view Z.
        render.OverrideBlend( true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MIN, BLEND_ONE, BLEND_ONE, BLENDFUNC_MIN )
        local result, err = draw( c.depthCamera )
        if result == false then
            requireValue( false, "render_ssr_depth_renderer", "scene depth renderer " .. id .. ": " .. tostring( err ) )
        end
        if S.request ~= c or not currentScene( c ) then
            requireValue( false, "render_ssr_depth_invalidated", "scene depth renderer invalidated the current capture: " .. id )
        end
    end
    S.renderingDepth = nil
    cam.End() cameraStarted = false
    render.PopRenderTarget() targetPushed = false
    S.depthSerial = c.serial
    S.scene = c
    S.stats.depthPasses = S.stats.depthPasses + 1
end

function S.CaptureDepth( view )
    if not validView( view ) or view.viewid ~= 0 or render.GetRenderTarget() ~= nil then return nil end
    local c = S.request or S.scene
    if not c or c.frame ~= FrameNumber() or not sameView( view, c ) or not currentScene( c ) then return nil end
    if S.depthSerial == c.serial then return c end
    local ok, err = pcall( captureDepth, c )
    local restoreError = clean()
    if not ok or restoreError then fault( "render_scene_depth_capture", not ok and err or restoreError ) return nil end
    return c
end

local function includeWaterDepth( c, records )
    render.PushRenderTarget( c.depthTexture ) targetPushed = true
    writeState( nil )
    render.OverrideBlend( true, BLEND_ONE, BLEND_ONE, BLENDFUNC_MIN, BLEND_ONE, BLEND_ONE, BLENDFUNC_MIN )
    cam.Start( c.depthCamera ) cameraStarted = true
    S.renderingDepth = c
    -- A zero cutoff accepts all water fragments; only its geometric surface
    -- depth is needed. The colour copy material supplies an existing texture.
    render.SetMaterial( S.DepthMaterial( c.group.copy, false ) )
    for _, record in ipairs( records ) do
        if record.hasWater then
            record.matrix:SetTranslation( record.drawBase )
            cam.PushModelMatrix( record.matrix ) modelPushed = true
            for _, name in ipairs( waterNames ) do
                local batches = record.meshes[name]
                if batches then for _, batch in ipairs( batches ) do batch.mesh:Draw() end end
            end
            cam.PopModelMatrix() modelPushed = false
        end
    end
    S.renderingDepth = nil
    cam.End() cameraStarted = false
    render.PopRenderTarget() targetPushed = false
    c.waterDepthComplete = c.serial
end

-- Atmosphere runs after SSR has consumed opaque depth. Only then may water
-- become a receiver in this texture; this never changes main-view hardware Z.
function S.IncludeWaterDepth( c, records )
    if c.waterDepthComplete == c.serial or not records or #records == 0 then return true end
    requireValue( S.pending == nil and c == S.scene and S.depthSerial == c.serial,
        "render_scene_water_order", "water depth must follow SSR and the completed scene snapshot" )
    local ok, err = pcall( includeWaterDepth, c, records )
    local restoreError = clean()
    if not ok or restoreError then return fault( "render_scene_water_depth", not ok and err or restoreError ) end
    return true
end

local function capture( c, scene, waterConstants )
    requireValue( scene:Width() == c.frameWidth and scene:Height() == c.frameHeight,
        "render_ssr_scene_resize", "framebuffer changed between scene depth and water capture" )
    if S.depthSerial ~= c.serial then captureDepth( c ) end
    local group = c.group
    -- Waves belong to the actual water colour draw, which happens after depth.
    for row = 2, 4 do for col = 1, 4 do c.wave:SetField( row, col, waterConstants:GetField( row, col ) ) end end
    local copy = group.sourceCopy or group.copy
    copy:SetTexture( "$basetexture", scene )
    if group.sourceCopy then
        copy:SetTexture( "$texture1", c.depthTexture )
        copy:SetFloat( "$c0_x", 1 / c.frameWidth ) copy:SetFloat( "$c0_y", 1 / c.frameHeight )
        copy:SetFloat( "$c0_z", 1 / c.depthTexture:Width() ) copy:SetFloat( "$c0_w", 1 / c.depthTexture:Height() )
    end
    render.PushRenderTarget( c.target.source ) targetPushed = true
    writeState( nil )
    render.SetMaterial( copy )
    c.target.quad:Draw()
    render.PopRenderTarget() targetPushed = false
    S.request, S.pending = nil, c
    S.stats.captures, S.stats.status = S.stats.captures + 1, "awaiting_resolve"
    return true
end

function S.Capture( view, records, scene, waterConstants )
    if not enabled:GetBool() or strength:GetFloat() == 0 or SysTime() < S.retryAt then return false end
    -- Engine SSAO updates only the primary view. Portals/monitors retain their
    -- ordinary water reflection and cannot replace this view's pending data.
    if not validView( view ) or view.viewid ~= 0 or render.GetRenderTarget() ~= nil then return false end
    local found = false
    for _, record in ipairs( records ) do if record.hasWater and S.groups[record.waterMaterial] then found = true break end end
    if not found then return false end
    local c = S.request
    if not c then return discard( "depth_not_requested" ) end
    if c.frame ~= FrameNumber() then return discard( "depth_frame_expired" ) end
    if not sameView( view, c ) then return discard( "depth_view_changed" ) end
    if not currentScene( c ) then return discard( "world_or_pack_changed" ) end
    -- Post effects can request depth after all water has been culled. Keep that
    -- request alive, but only capture SSR for its frozen water selection.
    if c.count == 0 then return false end
    local ok, err = pcall( capture, c, scene, waterConstants )
    local restoreError = clean()
    if not ok or restoreError then return fault( "render_ssr_capture", not ok and err or restoreError ) end
    return err
end

function S.Invalidate()
    discard( "invalidated" )
end

function S.BeginDepth()
    local c = S.renderingDepth
    return c ~= nil and c == S.request and c.frame == FrameNumber() and render.GetRenderTarget() == c.depthTexture
end

-- Depth draws use independent snapshots. Never change the colour material's
-- WRITEDEPTH flag: screenspace_general would then select DepthFunc(ALWAYS).
function S.DepthMaterial( surface, cutout )
    local group = S.renderingDepth.group
    local kind = cutout and 2 or 1
    local byKind = group.depth[surface]
    if not byKind then byKind = {} group.depth[surface] = byKind end
    local cached = byKind[kind]
    if cached then return cached end
    requireValue( S.depthCount < 2048, "render_ssr_depth_budget", "2048 cached scene-depth materials reached" )
    local source = MC.RenderL2Resources.SourceTexture( surface )
    local p = params( group.precisionDepth and group.programs.post_scene_depth or group.programs.scene_depth, source, false )
    p["$c0_w"] = cutout and "0.5" or "0"
    S.depthCount = S.depthCount + 1
    local material = CreateMaterial( "mc_scene_depth2_" .. S.depthCount, "screenspace_general_8tex", p )
    requireValue( material and not material:IsError(), "render_ssr_depth_material", "scene-depth material failed to load" )
    byKind[kind] = material
    return material
end

local function setTraceConstants( material, c, group )
    local bs = group.blockSize
    local values = c.traceValues
    if not values then values = {} c.traceValues = values end
    values[1], values[2], values[3], values[4] = c.ox, c.oy, c.oz, 0
    local thickness = c.group.sourceCopy and bs * 0.08 or bs * 0.22 + 4000 / 255
    values[5], values[6], values[7], values[8] = distance:GetFloat() * bs, floor( steps:GetFloat() ), thickness, bs * 0.03
    local dw, dh = c.depthTexture:Width(), c.depthTexture:Height()
    values[9], values[10], values[11], values[12] = dw, dh, 1 / dw, 1 / dh
    values[13], values[14], values[15], values[16] = c.scaleX, c.scaleY, strength:GetFloat(), c.group.precisionDepth and 1 or 0
    for index, value in ipairs( values ) do material:SetFloat( slots[index], value ) end
    material:SetTexture( "$texture1", c.depthTexture )
    material:SetMatrix( "$viewprojmat", c.projection )
end

local function drawWater( c, trace, scene )
    local bound
    for index = 1, c.count do
        local entry = c.entries[index]
        local group, record = entry.group, entry.record
        local material = trace and group.trace or group.composite
        if group ~= bound then
            if trace then setTraceConstants( material, c, group )
            else
                MC.RenderPBR.Bind( material )
                c.composition:SetField( 1, 4, group.blockSize )
                material:SetMatrix( "$viewprojmat", c.composition )
                material:SetTexture( "$basetexture", scene )
                material:SetTexture( "$texture1", c.target.trace )
                material:SetTexture( "$texture4", c.target.source )
                material:SetTexture( "$texture7", c.depthTexture )
            end
            render.SetMaterial( material )
            bound = group
        end
        MC.RenderPBRWater.SetOrigin( c.wave, record, entry.base )
        material:SetMatrix( "$invviewprojmat", c.wave )
        record.matrix:SetTranslation( entry.base )
        cam.PushModelMatrix( record.matrix ) modelPushed = true
        for _, name in ipairs( waterNames ) do
            local batches = record.meshes[name]
            if batches then for _, batch in ipairs( batches ) do
                batch.mesh:Draw()
                if trace then S.stats.traceDraws = S.stats.traceDraws + 1
                else S.stats.compositeDraws = S.stats.compositeDraws + 1 end
            end end
        end
        cam.PopModelMatrix() modelPushed = false
    end
end

local function resolve( c )
    MC.RenderPBR.PrepareView( c.ox, c.oy, c.oz )
    render.PushRenderTarget( c.target.trace ) targetPushed = true
    render.Clear( 0, 0, 0, 0, true, true )
    writeState( true )
    cam.Start( c.traceCamera ) cameraStarted = true
    drawWater( c, true )
    cam.End() cameraStarted = false
    render.PopRenderTarget() targetPushed = false
    local restoreError = clean()
    if restoreError then error( restoreError, 0 ) end
    -- Preserve the already-composited refraction, direct light and later scene
    -- drawing. The composite shader changes only environmental reflection.
    render.UpdateScreenEffectTexture( 0 )
    local scene = render.GetScreenEffectTexture( 0 )
    requireValue( scene and not scene:IsError() and scene:Width() == c.frameWidth and scene:Height() == c.frameHeight,
        "render_ssr_scene_resize", "framebuffer changed between water capture and SSR composition" )
    writeState( false )
    cam.Start( c.camera ) cameraStarted = true
    drawWater( c, false, scene )
    cam.End() cameraStarted = false
    S.stats.resolves, S.stats.status = S.stats.resolves + 1, "ready"
end

function S.Resolve()
    local c = S.pending
    if not c then return end
    -- A nested RenderView can run post effects before the outer main view.
    -- It must neither consume nor overwrite the outer view's pending source.
    if render.GetRenderTarget() ~= nil then return end
    if c.frame == FrameNumber() and not sameView( render.GetViewSetup( true ), c ) then return end
    S.pending = nil
    if not enabled:GetBool() or strength:GetFloat() == 0 or c.frame ~= FrameNumber() or S.depthSerial ~= c.serial
        or not currentScene( c )
        or render.GetRenderTarget() ~= nil or not sameView( render.GetViewSetup( true ), c ) then
        S.stats.status = "view_or_depth_changed"
        return
    end
    S.stats.traceDraws, S.stats.compositeDraws = 0, 0
    local ok, err = pcall( resolve, c )
    local restoreError = clean()
    if not ok or restoreError then return fault( "render_ssr_resolve", not ok and err or restoreError ) end
    return true
end

hook.Add( "NeedsDepthPass", "mc_water_ssr", function()
    -- Returning nil, rather than false, preserves other addons' depth requests.
    if S.RequestDepth() then return true end
end )
hook.Remove( "PreDrawOpaqueRenderables", "mc_water_ssr_depth" )
hook.Add( "RenderScreenspaceEffects", "mc_water_ssr", S.Resolve )
hook.Add( "MCWorldAdapterChanged", "mc_water_ssr", S.Invalidate )
cvars.AddChangeCallback( "mc_pbr_water_ssr", S.Invalidate, "mc_water_ssr" )
concommand.Add( "mc_pbr_water_ssr_stats", function()
    local stats = S.stats
    print( string.format( "[MC water SSR] %s requests=%d depthPasses=%d captures=%d resolves=%d traceDraws=%d compositeDraws=%d failures=%d targetMiB=%.2f GPU=unmeasured",
        stats.status, stats.requests, stats.depthPasses, stats.captures, stats.resolves, stats.traceDraws, stats.compositeDraws,
        stats.failures, S.targetBytes / 1048576 ) )
end )
