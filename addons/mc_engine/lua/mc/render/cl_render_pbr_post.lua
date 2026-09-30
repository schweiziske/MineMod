-- PBR data bindings for the pack-owned screen pipeline. No hooks, RTs or draws.
MC = MC or {}
local P = {}
MC.RenderPBRPost = P
P.VERSION, P.VOLUMETRIC_VERSION = 1, 1
local requireValue = MC.RenderL2Resources.Require
local S = MC.RenderPBRSSR
local processing = MC.RenderPackProcessing
local aoEnabled = MC.RenderPackSettings.Handle( "ssao" )
local aoStrength = MC.RenderPackSettings.Handle( "ssao_strength" )
local aoRadius = MC.RenderPackSettings.Handle( "ssao_radius" )
local aoDistance = MC.RenderPackSettings.Handle( "ssao_distance" )
local aoDebug = CreateClientConVar( "mc_pbr_ssao_debug", "0", false, false, "Show the SSAO visibility buffer", 0, 1 )
local fogEnabled = MC.RenderPackSettings.Handle( "fog" )
local fogDensity = MC.RenderPackSettings.Handle( "fog_density" )
local fogStart = MC.RenderPackSettings.Handle( "fog_start" )
local fogHeightDensity = MC.RenderPackSettings.Handle( "fog_height_density" )
local fogBase = MC.RenderPackSettings.Handle( "fog_height" )
local fogScale = MC.RenderPackSettings.Handle( "fog_height_scale" )
local fogDistance = MC.RenderPackSettings.Handle( "fog_distance" )
local bloomEnabled = MC.RenderPackSettings.Handle( "bloom" )
local bloomStrength = MC.RenderPackSettings.Handle( "bloom_strength" )
local bloomThreshold = MC.RenderPackSettings.Handle( "bloom_threshold" )
local bloomKnee = MC.RenderPackSettings.Handle( "bloom_knee" )
local bloomRadius = MC.RenderPackSettings.Handle( "bloom_radius" )
local bloomDebug = CreateClientConVar( "mc_pbr_bloom_debug", "0", false, false, "Show extracted and blurred highlights", 0, 1 )
local volumeEnabled = MC.RenderPackSettings.Handle( "volumetric" )
local volumeStrength = MC.RenderPackSettings.Handle( "volumetric_strength" )
local volumeDistance = MC.RenderPackSettings.Handle( "volumetric_distance" )
local volumeSteps = MC.RenderPackSettings.Handle( "volumetric_steps" )
local volumeDebug = CreateClientConVar( "mc_pbr_volumetric_debug", "0", false, false, "Show scattered sunlight alone", 0, 1 )
local min, max, ceil = math.min, math.max, math.ceil

function P.Register( definition, blockSize, instance )
    requireValue( definition.pipeline and definition.pipeline.version == 2,
        "render_post_pipeline", "screen effects require pipeline version 2" )
    local source = MC.RenderPackResources.shared.lightmap
    local group = { blockSize = blockSize, depth = S.RegisterScene( definition, blockSize, source, instance ),
        blockSSR = definition.programs.block_ssr, bindings = {} }
    for _, pass in ipairs( definition.pipeline.passes ) do
        if pass.binding then group.bindings[pass.binding] = true end
    end
    group.fog = group.bindings.fog
    group.bloom = group.bindings.bloom_prefilter
    if group.bindings.volumetric then group.volume = { camera = Matrix(), shadow = Matrix() } end
    if group.fog or group.volume then
        requireValue( MC.API.Coords.RenderToWorld and MC.API.Coords.WorldToCell and MC.API.Light and MC.API.Light.SampleCell
            and MC.API.Liquid and MC.API.Liquid.AtPos and MC.DayCycleSkyBrightness and MC.DayCycleHorizonBlend,
            "render_atmosphere_api", "atmosphere requires coordinates, voxel light and day-cycle sampling" )
    end
    return group
end

function P.Active()
    local active = MC.RenderPackRuntime.active
    if not active or not active.postProcess then return nil end
    if active.blockSize ~= MC.API.Coords.BlockSize() or active.worldGeneration ~= MC.StateWorldGeneration then return nil end
    return active.postProcess
end

local function wantsAO()
    return aoEnabled:GetBool() and ( aoStrength:GetFloat() > 0 or aoDebug:GetBool() )
end

local function wantsFog( group )
    return group and group.fog and fogEnabled:GetBool() and ( fogDensity:GetFloat() > 0 or fogHeightDensity:GetFloat() > 0 )
end

local function wantsVolume( group )
    local shadows = MC.RenderPBRShadows
    return group and group.volume and volumeEnabled:GetBool() and volumeStrength:GetFloat() > 0
        and ( fogDensity:GetFloat() > 0 or fogHeightDensity:GetFloat() > 0 )
        and shadows and shadows.VolumeEnabled()
end

local function wantsReflections( group )
    return group ~= nil and S.BlockWanted( group.blockSSR )
end

function P.NeedsDepth()
    local group = P.Active()
    return group ~= nil and ( group.bindings.ssao and wantsAO() or wantsFog( group ) or wantsVolume( group ) or wantsReflections( group ) )
end

function P.DepthGroup( view, waterOnly )
    local group = P.Active()
    if not group or not waterOnly and ( not P.NeedsDepth() ) then return nil end
    -- A partial player viewport needs a separate compositor. Never let a portal
    -- or monitor acquire the main-view depth or draw over its outside region.
    local scene = render.GetScreenEffectTexture( 0 )
    if view.x ~= 0 or view.y ~= 0 or view.width ~= scene:Width() or view.height ~= scene:Height() then
        return nil
    end
    return group.depth
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

local function atmosphere( c, group )
    local world, err = MC.API.Coords.RenderToWorld( c.camera.origin )
    requireValue( world ~= nil, "render_fog_world_position", tostring( err ) )
    local bx, by, bz = MC.API.Coords.WorldToCell( world )
    requireValue( bx ~= nil and by ~= nil and bz ~= nil, "render_fog_world_cell", "camera has no MC world cell" )
    local brightness, level, block, sky = MC.API.Light.SampleCell( bx, by, bz, 0 )
    requireValue( type( block ) == "number" and type( sky ) == "number",
        "render_fog_light", "camera voxel light sample failed: " .. tostring( level ) )
    local liquid = MC.API.Liquid.AtPos( world )
    if liquid and ( liquid.kind == "water" or liquid.kind == "lava" ) then return false end
    local day = MC.DayCycleSkyBrightness()
    local sunset = MC.DayCycleHorizonBlend() * day
    local skyLight, blockLight = ( sky / 15 ) ^ 2, ( block / 15 ) ^ 3
    local r = ( 0.30 + sunset * 0.16 ) * day * skyLight + 0.005 + blockLight * 0.025
    local g = ( 0.43 - sunset * 0.12 ) * day * skyLight + 0.009 + blockLight * 0.015
    local b = ( 0.57 - sunset * 0.29 ) * day * skyLight + 0.019 + blockLight * 0.006
    c.fogR, c.fogG, c.fogB, c.fogHeight = r, g, b, world.z / group.blockSize
    return true
end
P.PrepareAtmosphere = atmosphere

function P.AtmosphereConstants( material, c, group )
    material:SetFloat( "$c0_x", c.fogR ) material:SetFloat( "$c0_y", c.fogG ) material:SetFloat( "$c0_z", c.fogB )
    material:SetFloat( "$c0_w", fogDensity:GetFloat() )
    material:SetFloat( "$c1_x", fogStart:GetFloat() )
    material:SetFloat( "$c1_y", fogHeightDensity:GetFloat() )
    material:SetFloat( "$c1_z", fogBase:GetFloat() )
    material:SetFloat( "$c1_w", 1 / fogScale:GetFloat() )
    material:SetFloat( "$c2_x", c.fogHeight ) material:SetFloat( "$c2_y", 1 / group.blockSize )
    material:SetFloat( "$c2_z", c.projection:GetField( 1, 4 ) )
    material:SetFloat( "$c2_w", c.projection:GetField( 2, 4 ) )
    material:SetFloat( "$c3_x", 1 / c.depthTexture:Width() )
    material:SetFloat( "$c3_y", 1 / c.depthTexture:Height() )
    material:SetFloat( "$c3_z", min( fogDistance:GetFloat(), c.far / group.blockSize ) )
    material:SetFloat( "$c3_w", 0.90 )
    material:SetMatrix( "$viewprojmat", c.projection )
end


local binders = {}
binders.ssao = function( material, c, target, inputs, group )
    aoConstants( material, c, target, group )
end
binders.ssao_composite = function( material, c, target, inputs, group )
    aoConstants( material, c, { width = inputs.s1:Width(), height = inputs.s1:Height() }, group )
end
binders.fog = function( material, c, target, inputs, group )
    P.AtmosphereConstants( material, c, group )
end
binders.volumetric = function( material, c, target, inputs, group )
    local eye, volume = c.camera.origin, group.volume
    local shadow, bias, shadowWeight = c.volumeShadow, c.volumeBias, c.volumeWeight
    P.AtmosphereConstants( material, c, group )
    material:SetFloat( "$c3_z", min( volumeDistance:GetFloat(), fogDistance:GetFloat(), c.far / group.blockSize ) )
end
binders.volumetric_composite = function( material, c, target, inputs, group )
    material:SetFloat( "$c0_x", 1 / inputs.s1:Width() ) material:SetFloat( "$c0_y", 1 / inputs.s1:Height() )
    material:SetFloat( "$c0_z", group.blockSize ) material:SetFloat( "$c0_w", volumeDebug:GetBool() and 1 or 0 )
    material:SetFloat( "$c1_x", 1 / c.depthTexture:Width() ) material:SetFloat( "$c1_y", 1 / c.depthTexture:Height() )
end
binders.bloom_prefilter = function( material, c, target )
    material:SetFloat( "$c0_x", 1 / ( 3 * target.width ) ) material:SetFloat( "$c0_y", 1 / ( 3 * target.height ) )
    material:SetFloat( "$c0_z", bloomThreshold:GetFloat() ) material:SetFloat( "$c0_w", bloomKnee:GetFloat() )
end
binders.bloom_horizontal = function( material, c, target )
    material:SetFloat( "$c0_x", bloomRadius:GetFloat() / target.width ) material:SetFloat( "$c0_y", 0 )
end
binders.bloom_vertical = function( material, c, target )
    material:SetFloat( "$c0_x", 0 ) material:SetFloat( "$c0_y", bloomRadius:GetFloat() / target.height )
end
binders.bloom_composite = function( material )
    material:SetFloat( "$c0_x", bloomStrength:GetFloat() ) material:SetFloat( "$c0_y", bloomDebug:GetBool() and 1 or 0 )
end

function P.Enabled( binding, context )
    return context.enabled[binding] == true
end

function P.Input( semantic, context )
    local c = context.scene
    if semantic == "scene_color" then
        render.UpdateScreenEffectTexture( 0 )
        local texture = render.GetScreenEffectTexture( 0 )
        requireValue( texture and not texture:IsError() and texture:Width() == context.view_width
            and texture:Height() == context.view_height, "render_post_scene_resize", "scene changed during screen processing" )
        return texture
    end
    if semantic == "opaque_depth" then
        requireValue( c.waterDepthComplete ~= c.serial, "render_processing_depth_revision", "opaque depth was already replaced by water depth" )
        return c.depthTexture
    end
    if semantic == "scene_depth" then
        requireValue( c.waterDepthReady == c.serial, "render_processing_depth_revision", "world depth is not ready" )
        return c.depthTexture
    end
    if semantic == "volume_shadow" then return c.volumeTexture end
end

function P.Bind( binding, material, context, target, outputs, inputs )
    binders[binding]( material, context.scene, target, inputs, context.group )
end

function P.Run( stage, c, viewSerial )
    local group = P.Active()
    if not group then return true end
    local active = MC.RenderPackRuntime.active
    local enabled = {}
    if stage == "opaque" then
        enabled.ssao = wantsAO()
        enabled.ssao_composite = enabled.ssao
    elseif stage == "world" then
        if c.atmosphereAllowed then
            enabled.fog = wantsFog( group ) and true or false
            if wantsVolume( group ) then
                local eye = c.camera.origin
                c.volumeTexture, c.volumeShadow, c.volumeBias, c.volumeWeight = MC.RenderPBRShadows.VolumeSnapshot( eye.x, eye.y, eye.z )
                enabled.volumetric = c.volumeTexture ~= nil
                enabled.volumetric_composite = enabled.volumetric
            end
        end
    elseif stage == "final" then
        local bloom = group.bloom and bloomEnabled:GetBool() and ( bloomStrength:GetFloat() > 0 or bloomDebug:GetBool() )
        for _, name in ipairs( { "bloom_prefilter", "bloom_horizontal", "bloom_vertical", "bloom_composite" } ) do enabled[name] = bloom and true or false end
    end
    local context = processing.Context( active.processing, active, c.ox or 0, c.oy or 0, c.oz or 0 )
    context.key = context.key .. "/screen/" .. viewSerial
    context.scene, context.group, context.enabled = c, group, enabled
    return processing.RunScreen( active.processing, stage, context, P )
end

function P.PrepareWorld( c )
    c.atmosphereAllowed = atmosphere( c, P.Active() )
    return c.atmosphereAllowed
end

function P.WantsWorld()
    local group = P.Active()
    return wantsFog( group ) or wantsVolume( group ) or wantsReflections( group )
end
function P.ResolveBlocks( c )
    local group = P.Active()
    if wantsReflections( group ) then S.ResolveBlocks( c, group.blockSSR ) end
end
