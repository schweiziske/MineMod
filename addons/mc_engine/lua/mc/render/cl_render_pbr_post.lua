-- Main-view post lighting. Scene depth is owned by the SSR coordinator, even
-- on dry land or with water disabled. No history buffer or frame-time noise.
MC = MC or {}
local P = MC.RenderPBRPost or { groups = {}, targets = {}, quads = {}, quadCount = 0, targetBytes = 0 }
MC.RenderPBRPost = P
P.VERSION = 1
P.retryAt = 0
P.stats = { ao = 0, failures = 0, status = "idle" }
local requireValue = MC.RenderL2Resources.Require
local S = MC.RenderPBRSSR
local aoEnabled = CreateClientConVar( "mc_pbr_ssao", "1", true, false, "Screen-space contact occlusion on opaque surfaces", 0, 1 )
local aoStrength = CreateClientConVar( "mc_pbr_ssao_strength", "0.75", true, false, "Screen-space occlusion strength", 0, 1.5 )
local aoRadius = CreateClientConVar( "mc_pbr_ssao_radius", "1.5", true, false, "Contact occlusion radius in blocks", 0.25, 4 )
local aoDistance = CreateClientConVar( "mc_pbr_ssao_distance", "24", true, false, "Fade contact occlusion beyond this distance in blocks", 4, 64 )
local aoDebug = CreateClientConVar( "mc_pbr_ssao_debug", "0", false, false, "Show the SSAO visibility buffer", 0, 1 )
local min, max, ceil = math.min, math.max, math.ceil
local targetPushed, overrides = false, false

local function parameters( program, source, colour )
    return { ["$vertexshader"] = program.vertex, ["$pixshader"] = program.pixel,
        ["$basetexture"] = source:GetName(), ["$texture1"] = source:GetName(), ["$texture2"] = source:GetName(),
        ["$x360appchooser"] = 1, ["$vertexcolor"] = 1, ["$nocull"] = 1, ["$nofog"] = 1,
        ["$depthtest"] = 0, ["$writedepth"] = 0, ["$ignorez"] = 0,
        ["$linearread_basetexture"] = colour and 0 or 1,
        ["$linearread_texture1"] = 1, ["$linearread_texture2"] = 1, ["$linearwrite"] = colour and 0 or 1 }
end

function P.Register( definition, blockSize )
    local key = definition.build .. "/" .. blockSize
    if P.groups[key] then return P.groups[key] end
    local source = MC.RenderPackResources.shared.lightmap
    local programs = definition.programs
    requireValue( programs.post_ssao and programs.post_ssao_composite and source,
        "render_post_programs", "post lighting requires the AO/resolve programs and shared resources" )
    local prefix = "mc_post1_" .. definition.build:sub( 1, 20 ) .. "_" .. blockSize
    local group = { blockSize = blockSize, depth = S.RegisterScene( definition, blockSize, source ),
        ao = CreateMaterial( prefix .. "_ao", "screenspace_general_8tex", parameters( programs.post_ssao, source, false ) ),
        aoComposite = CreateMaterial( prefix .. "_ao_composite", "screenspace_general_8tex",
            parameters( programs.post_ssao_composite, source, true ) ) }
    requireValue( group.ao and not group.ao:IsError() and group.aoComposite and not group.aoComposite:IsError(),
        "render_post_material", "post lighting material creation failed" )
    P.groups[key] = group
    return group
end

function P.Active()
    local active = MC.RenderPackRuntime.active
    if not active or not active.postProcess then return nil end
    if active.blockSize ~= MC.API.Coords.BlockSize() or active.worldGeneration ~= MC.StateWorldGeneration then return nil end
    return active.postProcess
end

function P.NeedsDepth()
    return P.Active() ~= nil and aoEnabled:GetBool() and ( aoStrength:GetFloat() > 0 or aoDebug:GetBool() )
end

function P.DepthGroup( view )
    if not P.NeedsDepth() or SysTime() < P.retryAt then return nil end
    -- A partial player viewport needs a separate compositor. Never let a portal
    -- or monitor acquire the main-view depth or draw over its outside region.
    local scene = render.GetScreenEffectTexture( 0 )
    if view.x ~= 0 or view.y ~= 0 or view.width ~= scene:Width() or view.height ~= scene:Height() then
        P.stats.status = "unsupported_viewport"
        return nil
    end
    return P.Active().depth
end

local function clean()
    local first
    local function restore( callback, ... )
        local ok, err = pcall( callback, ... )
        if not ok and not first then first = err end
    end
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

local function pass( material, quad, target )
    if target then render.PushRenderTarget( target ) targetPushed = true end
    overrides = true
    render.OverrideDepthEnable( false, false )
    render.OverrideBlend( true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD )
    render.OverrideAlphaWriteEnable( true, target ~= nil )
    render.OverrideColorWriteEnable( true, true )
    render.SetBlend( 1 ) render.SetColorModulation( 1, 1, 1 )
    render.SetMaterial( material )
    quad:Draw()
    local err = clean()
    if err then error( err, 0 ) end
end
P.Pass, P.Parameters = pass, parameters

function P.ScreenQuad( width, height )
    local key = width .. "x" .. height
    local quad = P.quads[key]
    if quad then return quad end
    requireValue( P.quadCount < 32, "render_post_quad_budget", "32 post-process viewport sizes reached" )
    quad = S.CopyQuad( width, height )
    P.quads[key], P.quadCount = quad, P.quadCount + 1
    return quad
end

local function aoTarget( width, height )
    local scale = min( 0.5, 960 / width, 540 / height )
    local w, h = max( 1, ceil( width * scale ) ), max( 1, ceil( height * scale ) )
    local key = "ao1_" .. w .. "x" .. h
    local target = P.targets[key]
    if target then return target end
    local bytes = w * h * 8
    S.ReserveTargetBytes( bytes )
    P.targetBytes = P.targetBytes + bytes
    local texture = GetRenderTargetEx( "mc_" .. key, w, h, RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE,
        bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA16161616F )
    requireValue( texture and not texture:IsError() and texture:Width() == w and texture:Height() == h,
        "render_ssao_target", "SSAO target allocation failed" )
    target = { texture = texture, width = w, height = h, quad = S.CopyQuad( w, h ) }
    P.targets[key] = target
    return target
end

local function aoConstants( material, c, target, group )
    material:SetFloat( "$c0_x", 1 / c.depthTexture:Width() )
    material:SetFloat( "$c0_y", 1 / c.depthTexture:Height() )
    material:SetFloat( "$c0_z", 1 / target.width )
    material:SetFloat( "$c0_w", 1 / target.height )
    material:SetFloat( "$c1_x", group.blockSize * aoRadius:GetFloat() )
    material:SetFloat( "$c1_y", group.blockSize * 0.045 )
    material:SetFloat( "$c1_z", group.blockSize * aoDistance:GetFloat() )
    material:SetFloat( "$c1_w", aoStrength:GetFloat() )
    material:SetFloat( "$c2_x", aoDebug:GetBool() and 1 or 0 )
    material:SetFloat( "$c2_y", c.projection:GetField( 1, 4 ) )
    material:SetFloat( "$c2_z", c.projection:GetField( 2, 4 ) )
end

local function drawAO( c, group )
    local target = aoTarget( c.frameWidth, c.frameHeight )
    local material = group.ao
    aoConstants( material, c, target, group )
    material:SetTexture( "$basetexture", c.depthTexture )
    pass( material, target.quad, target.texture )
    render.UpdateScreenEffectTexture( 0 )
    local scene = render.GetScreenEffectTexture( 0 )
    requireValue( scene and not scene:IsError() and scene:Width() == c.frameWidth and scene:Height() == c.frameHeight,
        "render_post_scene_resize", "scene changed during post lighting" )
    material = group.aoComposite
    aoConstants( material, c, target, group )
    material:SetTexture( "$basetexture", scene )
    material:SetTexture( "$texture1", target.texture )
    material:SetTexture( "$texture2", c.depthTexture )
    pass( material, P.ScreenQuad( c.frameWidth, c.frameHeight ) )
    c.aoComplete = c.serial
    P.stats.ao, P.stats.status = P.stats.ao + 1, "ready"
end

function P.BeforeTranslucent( depth, sky, sky3D )
    if depth or sky3D or not P.NeedsDepth() or SysTime() < P.retryAt then return end
    if render.GetRenderTarget() ~= nil then return end
    local view = render.GetViewSetup( true )
    local c = S.CaptureDepth( view )
    if not c or not c.postGroup or c.aoComplete == c.serial then return end
    local ok, err = pcall( drawAO, c, P.Active() )
    local restoreError = clean()
    if not ok or restoreError then
        P.retryAt = SysTime() + 1
        P.stats.failures, P.stats.status = P.stats.failures + 1, "fault"
        local failure = not ok and err or restoreError
        if type( failure ) == "table" then return MC.Fault( failure.code, "%s", failure.message ) end
        return MC.Fault( "render_ssao_draw", "%s", tostring( failure ) )
    end
end

hook.Add( "PreDrawTranslucentRenderables", "mc_pbr_post", P.BeforeTranslucent )
cvars.AddChangeCallback( "mc_pbr_ssao", S.Invalidate, "mc_pbr_post" )
concommand.Add( "mc_pbr_post_stats", function()
    print( string.format( "[MC post] %s ao=%d failures=%d postMiB=%.2f sharedSceneMiB=%.2f GPU=unmeasured",
        P.stats.status, P.stats.ao, P.stats.failures, P.targetBytes / 1048576, S.targetBytes / 1048576 ) )
end )
