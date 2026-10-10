-- Main-view stage order: opaque -> world (before viewmodels) -> final.
-- One coordinator owns these Hooks; the selected pack declares the actual work.
MC = MC or {}
-- Each opaque boundary starts a serial, including redraws in the same frame.
-- worldDone/finalDone latch until that serial ends; viewModelsStarted records
-- the serial that reached the viewmodel boundary.
local Screen = {
    serial = 0,
    retryAt = 0,
    stats = { views = 0, failures = 0, world = 0, final = 0 }
}
MC.RenderPackScreen = Screen

local Scene = MC.RenderScene
local Post = MC.RenderPBRPost
local Processing = MC.RenderPackProcessing
local requireValue = MC.RenderL2Resources.Require

local function mainView()
    if render.GetRenderTarget() ~= nil then return end

    local view = render.GetViewSetup( true )
    if view.viewid ~= 0 or not Scene.ValidView( view ) or view.x ~= 0 or view.y ~= 0 then return end

    local texture = render.GetScreenEffectTexture( 0 )
    if view.width ~= texture:Width() or view.height ~= texture:Height() then return end
    return view
end

-- Reuse scalar storage: engine camera vectors may be modified in place.
-- FrameNumber alone is insufficient because one frame can draw several views.
local viewIdentity = {}
local function rememberView( view )
    local offsetX, offsetY, offsetZ = MC.ChunkRenderFrameOffset()
    local origin, angles = view.origin, view.angles
    viewIdentity.frame = FrameNumber()
    viewIdentity.cameraX, viewIdentity.cameraY, viewIdentity.cameraZ = origin.x, origin.y, origin.z
    viewIdentity.pitch, viewIdentity.yaw, viewIdentity.roll = angles.p, angles.y, angles.r
    viewIdentity.fov, viewIdentity.aspect = view.fov, view.aspect or 0
    viewIdentity.width, viewIdentity.height = view.width, view.height
    viewIdentity.near, viewIdentity.far = view.znear, view.zfar
    viewIdentity.offsetX, viewIdentity.offsetY, viewIdentity.offsetZ = offsetX, offsetY, offsetZ
    viewIdentity.blockSize = MC.API.Coords.BlockSize()
    viewIdentity.generation = MC.StateWorldGeneration
end

local function ownsCurrentFrame()
    return Screen.owner ~= nil and Screen.owner == MC.RenderPackRuntime.active
        and viewIdentity.frame == FrameNumber()
end

local function matchesView( view )
    local offsetX, offsetY, offsetZ = MC.ChunkRenderFrameOffset()
    local origin, angles = view.origin, view.angles
    return viewIdentity.cameraX == origin.x and viewIdentity.cameraY == origin.y and viewIdentity.cameraZ == origin.z
        and viewIdentity.pitch == angles.p and viewIdentity.yaw == angles.y and viewIdentity.roll == angles.r
        and viewIdentity.fov == view.fov and viewIdentity.aspect == ( view.aspect or 0 )
        and viewIdentity.width == view.width and viewIdentity.height == view.height
        and viewIdentity.near == view.znear and viewIdentity.far == view.zfar
        and viewIdentity.offsetX == offsetX and viewIdentity.offsetY == offsetY and viewIdentity.offsetZ == offsetZ
        and viewIdentity.blockSize == MC.API.Coords.BlockSize()
        and viewIdentity.generation == MC.StateWorldGeneration
end

local function currentView()
    -- Inactive, retired and stale owners have no work requiring an engine query.
    if not ownsCurrentFrame() then return end
    local view = mainView()
    if view and matchesView( view ) then return view end
end

function Screen.Invalidate()
    Screen.owner = nil
    Screen.worldDone, Screen.finalDone = nil, nil
    Post.ResetExposure()
    MC.RenderTAA.Reset()
    Scene.Invalidate()
end

-- Return success plus the callback's single Hook result, preserving nil/false.
local function tryRender( callback, ... )
    if SysTime() < Screen.retryAt then return false end
    local ok, result = pcall( callback, ... )
    if ok then return true, result end

    Screen.Invalidate()
    Screen.retryAt = SysTime() + 1
    Screen.stats.failures = Screen.stats.failures + 1
    if type( result ) == "table" then
        MC.Fault( result.code, "%s", tostring( result.message ) )
    else
        MC.Fault( "render_screen_stage", "%s", tostring( result ) )
    end
    return false
end

local function runPostStage( stage, scene )
    local ok, err = Post.Run( stage, scene, Screen.serial )
    if not ok then error( err, 0 ) end
end

local function beginOpaqueStage( view )
    rememberView( view )
    Screen.serial = Screen.serial + 1
    Screen.owner = MC.RenderPackRuntime.active
    Screen.worldDone, Screen.finalDone = nil, nil
    Screen.stats.views = Screen.stats.views + 1

    if not Post.NeedsDepth() then return end
    local scene = Scene.CaptureDepth( view )
    if scene and scene.postGroup then runPostStage( "opaque", scene ) end
end

local function prepareWorldDepth( view, scene, wantsWorld )
    if not wantsWorld or not scene or scene.frame ~= FrameNumber()
        or not Scene.SameView( view, scene ) or not Scene.CurrentScene( scene ) then return end

    requireValue( Scene.CaptureDepth( view ) == scene,
        "render_screen_depth", "world depth capture was invalidated" )
    if not Post.PrepareWorld( scene ) then return end

    local waterRecords = MC.CollectWaterSSRRecords( scene.camera.origin )
    requireValue( Scene.IncludeWaterDepth( scene, waterRecords ),
        "render_screen_water_depth", "water depth merge failed" )
end

local function finishWorldStage( view )
    if Screen.worldDone then return end
    local scene = Scene.scene
    local wantsWorld = Post.WantsWorld()
    local geometrySteps = Screen.owner.processing.definition.pipeline.geometry

    if geometrySteps then
        for _, step in ipairs( geometrySteps ) do
            if step == "water_reflections" then
                Scene.Resolve()
                if scene and Scene.scene ~= scene then error( "reflection resolve invalidated the scene", 0 ) end
            elseif step == "water_depth" then
                prepareWorldDepth( view, scene, wantsWorld )
            elseif step == "terrain_reflections" then
                if wantsWorld and scene and scene.waterDepthReady == scene.serial and scene.atmosphereAllowed then
                    Post.ResolveBlocks( scene )
                end
            end
        end
    end

    if wantsWorld and scene and scene.waterDepthReady == scene.serial and scene.worldEffectsAllowed then
        runPostStage( "world", scene )
    end
    Screen.worldDone = true
    Screen.stats.world = Screen.stats.world + 1
end

local function finishFinalStage( view )
    if not Screen.worldDone then
        -- Never repair a failed world stage on top of an already drawn gun.
        requireValue( Screen.viewModelsStarted ~= Screen.serial,
            "render_screen_order", "world stage did not finish before viewmodels" )
        finishWorldStage( view )
    end

    local scene = Scene.scene
    if not scene then
        scene = { ox = view.origin.x, oy = view.origin.y, oz = view.origin.z }
    end
    runPostStage( "final", scene )
    Screen.finalDone = true
    Screen.stats.final = Screen.stats.final + 1
end

function Screen.BeforeTranslucent( depth, sky, sky3D )
    if depth or sky3D or not Post.Active() then return end
    local view = mainView()
    if view then tryRender( beginOpaqueStage, view ) end
end

function Screen.BeforeWater( view, records, texture, constants )
    if not view or not ownsCurrentFrame() or SysTime() < Screen.retryAt then return false end
    if not matchesView( view ) then return false end
    return Scene.Capture( view, records, texture, constants )
end

function Screen.BeforeViewModels()
    local view = currentView()
    if not view then return end
    Screen.viewModelsStarted = Screen.serial
    tryRender( finishWorldStage, view )
end

function Screen.BeforeEffects()
    -- A cancelled PreDrawViewModel/PreDrawPlayerHands has no matching post hook.
    MC.RenderTAA.EndViewModel()
    if Screen.viewModelsStarted == Screen.serial or Screen.worldDone then return end

    local view = currentView()
    if view then tryRender( finishWorldStage, view ) end
end

function Screen.AfterEffects()
    if Screen.finalDone then return end
    local view = currentView()
    if view then tryRender( finishFinalStage, view ) end
end

local function beginMainView( origin, angles, fov )
    local ok, result = tryRender( MC.RenderTAA.BeginView, origin, angles, fov )
    if ok then return result end
end

local function beforeNativeViewModel()
    if Scene.SkipNativeViewModel() then return true end
    MC.RenderTAA.BeginViewModel()
end

-- Retire callbacks left behind by an engine Lua refresh; never run both chains.
for _, event in ipairs( {
    "NeedsDepthPass", "PreDrawTranslucentRenderables", "PreDrawViewModels", "PreDrawEffects",
    "RenderScreenspaceEffects", "PreDrawViewModel", "PreDrawPlayerHands", "MCWorldAdapterChanged"
} ) do
    hook.Remove( event, "mc_water_ssr" )
    hook.Remove( event, "mc_pbr_post" )
end
hook.Remove( "PreDrawOpaqueRenderables", "mc_water_ssr_depth" )

hook.Add( "RenderScene", "mc_pack_screen", beginMainView )
hook.Add( "NeedsDepthPass", "mc_pack_screen", function()
    if SysTime() >= Screen.retryAt and Scene.RequestDepth() then return true end
end )
hook.Add( "PreDrawTranslucentRenderables", "mc_pack_screen", Screen.BeforeTranslucent )
hook.Add( "PreDrawViewModels", "mc_pack_screen", Screen.BeforeViewModels )
hook.Add( "PreDrawEffects", "mc_pack_screen", Screen.BeforeEffects )
hook.Add( "RenderScreenspaceEffects", "mc_pack_screen", Screen.AfterEffects )
hook.Add( "PreDrawViewModel", "mc_pack_screen", beforeNativeViewModel )
hook.Add( "PreDrawPlayerHands", "mc_pack_screen", beforeNativeViewModel )
hook.Add( "PostDrawViewModel", "mc_pack_screen", function() MC.RenderTAA.EndViewModel() end )
hook.Add( "PostDrawPlayerHands", "mc_pack_screen", function() MC.RenderTAA.EndViewModel() end )
hook.Add( "MCWorldAdapterChanged", "mc_pack_screen", Screen.Invalidate )
for _, key in ipairs( {
    "ssao", "fog", "volumetric", "block_ssr", "water_ssr",
    "underwater_fog", "underwater_volumetric", "auto_exposure", "taa"
} ) do
    MC.RenderPackSettings.OnChange( key, "mc_pack_screen", Screen.Invalidate )
end
concommand.Add( "mc_pbr_post_stats", function()
    local stats = Screen.stats
    print( string.format( "[MC screen] views=%d world=%d final=%d failures=%d sharedMiB=%.2f GPU=unmeasured",
        stats.views, stats.world, stats.final, stats.failures, Processing.targetBytes / 1048576 ) )
end )
