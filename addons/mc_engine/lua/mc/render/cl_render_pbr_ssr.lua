-- Water/terrain reflection geometry adapters. Scheduling and depth are scene-owned.
local S = MC.RenderScene
local requireValue = MC.RenderL2Resources.Require
local state = S.DrawState
local clean, writeState, params = S.Clean, S.WriteState, S.MaterialParameters
local sourceCopy, captureDepth = S.SourceCopy, S.CaptureRawDepth
local fault, validView, currentScene, discard = S.Fault, S.ValidView, S.CurrentScene, S.Discard
local sameView = S.SameView
local enabled = MC.RenderPackSettings.Handle( "water_ssr" )
local distance = MC.RenderPackSettings.Handle( "water_ssr_distance" )
local steps = MC.RenderPackSettings.Handle( "water_ssr_steps" )
local strength = MC.RenderPackSettings.Handle( "water_ssr_strength" )
local blockEnabled = MC.RenderPackSettings.Handle( "block_ssr" )
local blockStrength = MC.RenderPackSettings.Handle( "block_ssr_strength" )
local blockRoughness = MC.RenderPackSettings.Handle( "block_ssr_roughness" )
local blockDistance = MC.RenderPackSettings.Handle( "block_ssr_distance" )
local blockSteps = MC.RenderPackSettings.Handle( "block_ssr_steps" )
-- Mirrors facing the camera send rays back along the view direction, so any
-- shell behind a near object is hit by a wide fan of rays and the object is
-- smeared across the mirror. Refined true hits land within a sliver of the
-- surface; rays passing behind a silhouette end with the full gap.
local blockThickness = MC.RenderPackSettings.Handle( "block_ssr_thickness" )
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
-- Full-resolution depth + trace + colour is about 48 MiB at 1080p. The cap
-- bounds Source's non-freeable RT cache across a few resolution changes.
local TARGET_BUDGET = 128 * 1048576
-- Trace hit thickness in blocks. MC terrain is solid: a ray passing behind a
-- block edge meets that block's hidden side, so it counts as a hit.
local HIT_THICKNESS = 4
local waterNames = { "water_still", "water_flow" }
local slots = { "$c0_x", "$c0_y", "$c0_z", "$c0_w", "$c1_x", "$c1_y", "$c1_z", "$c1_w",
    "$c2_x", "$c2_y", "$c2_z", "$c2_w", "$c3_x", "$c3_y", "$c3_z", "$c3_w" }
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

local function capture( c, scene, waterConstants )
    requireValue( scene:Width() == c.frameWidth and scene:Height() == c.frameHeight,
        "render_ssr_scene_resize", "framebuffer changed between scene depth and water capture" )
    if S.depthSerial ~= c.serial then captureDepth( c ) end
    local group = c.group
    -- Waves belong to the actual water colour draw, which happens after depth.
    for row = 2, 4 do for col = 1, 4 do c.wave:SetField( row, col, waterConstants:GetField( row, col ) ) end end
    -- A same-size source is an exact copy. A reduced one (above 1080p) keeps
    -- only each 2x2 block's front surface, so silhouettes do not blend.
    local reduced = c.target.width ~= c.frameWidth or c.target.height ~= c.frameHeight
    local copy = reduced and group.sourceCopy or group.copy
    copy:SetTexture( "$basetexture", scene )
    if copy == group.sourceCopy then
        copy:SetTexture( "$texture1", c.depthTexture )
        copy:SetFloat( "$c0_x", 1 / c.frameWidth ) copy:SetFloat( "$c0_y", 1 / c.frameHeight )
        copy:SetFloat( "$c0_z", 1 / c.depthTexture:Width() ) copy:SetFloat( "$c0_w", 1 / c.depthTexture:Height() )
    end
    render.PushRenderTarget( c.target.source ) state.targetPushed = true
    writeState( nil )
    render.SetMaterial( copy )
    c.target.quad:Draw()
    render.PopRenderTarget() state.targetPushed = false
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

local function setTraceConstants( material, c, group, rayLength, stepCount, amount, hitThickness )
    local bs = group.blockSize
    local values = c.traceValues
    if not values then values = {} c.traceValues = values end
    values[1], values[2], values[3], values[4] = c.ox, c.oy, c.oz, 0
    local thickness = bs * hitThickness
    values[5], values[6], values[7], values[8] = rayLength * bs, floor( stepCount ), thickness, bs * 0.03
    local dw, dh = c.depthTexture:Width(), c.depthTexture:Height()
    values[9], values[10], values[11], values[12] = dw, dh, 1 / dw, 1 / dh
    values[13], values[14], values[15], values[16] = c.scaleX, c.scaleY, amount, c.group.precisionDepth and 1 or 0
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
            if trace then setTraceConstants( material, c, group, distance:GetFloat(), steps:GetFloat(), strength:GetFloat(), HIT_THICKNESS )
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
        cam.PushModelMatrix( record.matrix ) state.modelPushed = true
        for _, name in ipairs( waterNames ) do
            local batches = record.meshes[name]
            if batches then for _, batch in ipairs( batches ) do
                batch.mesh:Draw()
                if trace then S.stats.traceDraws = S.stats.traceDraws + 1
                else S.stats.compositeDraws = S.stats.compositeDraws + 1 end
            end end
        end
        cam.PopModelMatrix() state.modelPushed = false
    end
end

local function resolve( c )
    MC.RenderPBR.PrepareView( c.ox, c.oy, c.oz )
    render.PushRenderTarget( c.target.trace ) state.targetPushed = true
    render.Clear( 0, 0, 0, 0, true, true )
    -- No depth write: like the colour pass, the last water layer drawn owns
    -- each pixel, so the composite only corrects the layer left on screen.
    writeState( false )
    cam.Start( c.traceCamera ) state.cameraStarted = true
    drawWater( c, true )
    cam.End() state.cameraStarted = false
    render.PopRenderTarget() state.targetPushed = false
    local restoreError = clean()
    if restoreError then error( restoreError, 0 ) end
    -- Preserve the already-composited refraction, direct light and later scene
    -- drawing. The composite shader changes only environmental reflection.
    render.UpdateScreenEffectTexture( 0 )
    local scene = render.GetScreenEffectTexture( 0 )
    requireValue( scene and not scene:IsError() and scene:Width() == c.frameWidth and scene:Height() == c.frameHeight,
        "render_ssr_scene_resize", "framebuffer changed between water capture and SSR composition" )
    writeState( false )
    cam.Start( c.camera ) state.cameraStarted = true
    drawWater( c, false, scene )
    cam.End() state.cameraStarted = false
    S.stats.resolves, S.stats.status = S.stats.resolves + 1, "ready"
    S.debugTarget, S.debugDepth = c.target, c.depthTexture
end

function S.BlockWanted( program )
    return program ~= nil and blockEnabled:GetBool() and blockStrength:GetFloat() > 0
end

-- One cached material per terrain surface and cutout mode. Constants and the
-- per-frame scene/depth textures are written once per resolve.
local function blockMaterial( block, surface, cutout )
    local byKind = S.blockMaterials[surface]
    if not byKind then byKind = {} S.blockMaterials[surface] = byKind end
    local kind = cutout and 2 or 1
    local entry = byKind[kind]
    if not entry or entry.program ~= block.program then
        requireValue( S.depthCount < 2048, "render_block_ssr_budget", "2048 cached scene-effect materials reached" )
        local p = params( block.program, MC.RenderL2Resources.SourceTexture( surface ), false )
        for _, key in ipairs( { "$texture3", "$texture4", "$texture7" } ) do
            local texture = surface:GetTexture( key )
            requireValue( texture and not texture:IsError(), "render_block_ssr_maps", "block SSR surface lacks " .. key )
            p[key], p["$linearread_" .. key:sub( 2 )] = texture:GetName(), 1
        end
        p["$texture1"], p["$texture2"] = p["$texture3"], p["$texture3"]
        p["$linearread_texture1"], p["$linearread_texture2"], p["$linearwrite"] = 1, 0, 0
        S.depthCount = S.depthCount + 1
        entry = { program = block.program, extra = Matrix(), cutoff = cutout and 0.5 or 0,
            material = CreateMaterial( "mc_block_ssr1_" .. S.depthCount, "screenspace_general_8tex", p ) }
        requireValue( entry.material and not entry.material:IsError(), "render_block_ssr_material", "block SSR material failed to load" )
        byKind[kind] = entry
    end
    if entry.serial ~= block.serial then
        local material, extra, c = entry.material, entry.extra, block.c
        material:SetTexture("$basetexture",MC.RenderL2Resources.SourceTexture(surface))
        for _, key in ipairs({"$texture3", "$texture4", "$texture7"}) do material:SetTexture(key,surface:GetTexture(key)) end
        setTraceConstants( material, c, c.group, blockDistance:GetFloat(), blockSteps:GetFloat(), blockStrength:GetFloat(), blockThickness:GetFloat() )
        material:SetTexture( "$texture2", block.scene )
        extra:SetField( 1, 1, 1 / c.frameWidth ) extra:SetField( 1, 2, 1 / c.frameHeight )
        extra:SetField( 1, 3, entry.cutoff ) extra:SetField( 1, 4, blockRoughness:GetFloat() )
        if MC.ResourceGeneration then
            MC.RenderPBR.BindSampling(material,MC.RenderL2Resources.SourceTexture(surface),extra)
        else material:SetMatrix( "$invviewprojmat", extra ) end
        entry.serial = block.serial
    end
    return entry.material
end

local blockFrame = { serial = 0 }
blockFrame.resolve = function( surface, cutout ) return blockMaterial( blockFrame, surface, cutout ) end

local function resolveBlocks( c, program )
    requireValue( type( MC.DrawTerrainOverride ) == "function", "render_block_ssr_draw", "terrain override drawing is unavailable" )
    render.UpdateScreenEffectTexture( 0 )
    local scene = render.GetScreenEffectTexture( 0 )
    requireValue( scene and not scene:IsError() and scene:Width() == c.frameWidth and scene:Height() == c.frameHeight,
        "render_block_ssr_scene", "framebuffer changed between scene depth and block reflections" )
    blockFrame.c, blockFrame.scene, blockFrame.program = c, scene, program
    blockFrame.serial = blockFrame.serial + 1
    -- The copy is both reflection source and background; every covered pixel
    -- is rewritten from it, so no hardware depth or blending takes part.
    writeState( nil )
    cam.Start( c.camera ) state.cameraStarted = true
    MC.DrawTerrainOverride( blockFrame.resolve )
    cam.End() state.cameraStarted = false
    S.stats.blockResolves = S.stats.blockResolves + 1
    S.debugTarget, S.debugDepth = c.target, c.depthTexture
end

-- Called by the post chain after water SSR and water depth, before fog, so
-- blocks reflect water and reflections are fogged with their receivers.
function S.ResolveBlocks( c, program )
    local ok, err = pcall( resolveBlocks, c, program )
    blockFrame.c, blockFrame.scene = nil, nil
    local restoreError = clean()
    if ok and not restoreError then return end
    local failure = not ok and err or restoreError
    if type( failure ) == "table" then error( failure, 0 ) end
    error( { code = "render_block_ssr", message = tostring( failure ) }, 0 )
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

concommand.Add( "mc_pbr_water_ssr_stats", function()
    local stats = S.stats
    print( string.format( "[MC water SSR] %s requests=%d depthPasses=%d captures=%d resolves=%d traceDraws=%d compositeDraws=%d blockResolves=%d failures=%d targetMiB=%.2f GPU=unmeasured",
        stats.status, stats.requests, stats.depthPasses, stats.captures, stats.resolves, stats.traceDraws, stats.compositeDraws,
        stats.blockResolves, stats.failures, S.targetBytes / 1048576 ) )
end )

-- Development view of the last resolved frame, drawn over the HUD in quadrants:
-- live frame, trace (R/G hit UV; hits show coloured, misses black), private
-- scene depth (R = clip W / 4000) and pre-water source colour.
local debugView = CreateClientConVar( "mc_pbr_water_ssr_debug", "0", false, false, "Show water SSR intermediate targets", 0, 1 )
local debugMaterials, debugNames = {}, { "live frame", "trace", "scene depth", "source colour" }
for index = 1, 4 do
    debugMaterials[index] = CreateMaterial( "mc_water_ssr_debug_view" .. index, "UnlitGeneric", { ["$basetexture"] = "color/white", ["$ignorez"] = 1 } )
end
hook.Add( "HUDPaint", "mc_water_ssr_debug", function()
    if not debugView:GetBool() then return end
    local t = S.debugTarget
    render.UpdateScreenEffectTexture( 0 )
    local textures = { render.GetScreenEffectTexture( 0 ), t and t.trace, t and S.debugDepth, t and t.source }
    local hw, hh = floor( ScrW() / 2 ), floor( ScrH() / 2 )
    for index = 1, 4 do
        local x, y = ( index - 1 ) % 2 * hw, floor( ( index - 1 ) / 2 ) * hh
        if textures[index] then
            debugMaterials[index]:SetTexture( "$basetexture", textures[index] )
            surface.SetMaterial( debugMaterials[index] )
            surface.SetDrawColor( 255, 255, 255, 255 )
            surface.DrawTexturedRect( x, y, hw, hh )
        end
        draw.SimpleTextOutlined( "[SSR debug] " .. debugNames[index] .. ( textures[index] and "" or ": no resolved frame" ),
            "DermaDefaultBold", x + 8, y + 8, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, color_black )
    end
end )
