-- One owner for main-view effect boundaries. Geometry adapters remain geometry;
-- full-screen work is declared by the selected pack and run by processing.
MC = MC or {}
local P = { serial = 0, retryAt = 0, stats = { views = 0, failures = 0, world = 0, final = 0 } }
MC.RenderPackScreen = P
local S, post = MC.RenderScene, MC.RenderPBRPost
local processing = MC.RenderPackProcessing
local requireValue = MC.RenderL2Resources.Require

local function mainView()
    if render.GetRenderTarget() ~= nil then return nil end
    local view = render.GetViewSetup( true )
    if view.viewid ~= 0 or not S.ValidView( view ) or view.x ~= 0 or view.y ~= 0 then return nil end
    local texture = render.GetScreenEffectTexture( 0 )
    if view.width ~= texture:Width() or view.height ~= texture:Height() then return nil end
    return view
end

local function identity( view )
    local x, y, z = MC.ChunkRenderFrameOffset()
    return MC.RenderPackSchema.Canonical( { frame = FrameNumber(), x = view.origin.x, y = view.origin.y, z = view.origin.z,
        p = view.angles.p, yaw = view.angles.y, r = view.angles.r, fov = view.fov, aspect = view.aspect or 0,
        width = view.width, height = view.height, near = view.znear, far = view.zfar,
        originX = x, originY = y, originZ = z, blockSize = MC.API.Coords.BlockSize(), generation = MC.StateWorldGeneration } )
end

local function current( view )
    return view and P.owner == MC.RenderPackRuntime.active and P.key == identity( view )
end

function P.Invalidate()
    P.key, P.owner, P.worldDone, P.finalDone = nil, nil, nil, nil
    S.Invalidate()
end

local function protected( callback, ... )
    if SysTime() < P.retryAt then return false end
    local ok, err = pcall( callback, ... )
    if ok then return true end
    P.Invalidate()
    P.retryAt = SysTime() + 1
    P.stats.failures = P.stats.failures + 1
    if type( err ) == "table" then MC.Fault( err.code, "%s", tostring( err.message ) )
    else MC.Fault( "render_screen_stage", "%s", tostring( err ) ) end
    return false
end

local function run( stage, scene )
    local ok, err = post.Run( stage, scene, P.serial )
    if not ok then error( err, 0 ) end
end

local function opaque( view )
    P.serial, P.key, P.owner = P.serial + 1, identity( view ), MC.RenderPackRuntime.active
    P.worldDone, P.finalDone = nil, nil
    P.stats.views = P.stats.views + 1
    if not post.NeedsDepth() then return end
    local c = S.CaptureDepth( view )
    if not c or not c.postGroup then return end
    run( "opaque", c )
end

function P.BeforeTranslucent( depth, sky, sky3D )
    if depth or sky3D or not post.Active() then return end
    local view = mainView()
    if view then protected( opaque, view ) end
end

function P.BeforeWater( view, records, texture, constants )
    if not current( view ) or SysTime() < P.retryAt then return false end
    return S.Capture( view, records, texture, constants )
end

local function finishWorld( view )
    if P.worldDone then return end
    local c = S.scene
    local wantsWorld = post.WantsWorld()
    local steps = P.owner.processing.definition.pipeline.geometry or {}
    for _, step in ipairs( steps ) do
        if step == "water_reflections" then
            S.Resolve()
            if c and S.scene ~= c then error( "reflection resolve invalidated the scene", 0 ) end
        elseif step == "water_depth" then
            if wantsWorld and c and c.frame == FrameNumber() and S.SameView( view, c ) and S.CurrentScene( c ) then
                requireValue( S.CaptureDepth( view ) == c, "render_screen_depth", "world depth capture was invalidated" )
                if post.PrepareWorld( c ) then
                    local records = MC.CollectWaterSSRRecords( c.camera.origin )
                    requireValue( S.IncludeWaterDepth( c, records ), "render_screen_water_depth", "water depth merge failed" )
                end
            end
        elseif step == "terrain_reflections" then
            if wantsWorld and c and c.waterDepthReady == c.serial and c.atmosphereAllowed then post.ResolveBlocks( c ) end
        end
    end
    if wantsWorld and c and c.waterDepthReady == c.serial and c.atmosphereAllowed then run( "world", c ) end
    P.worldDone = true
    P.stats.world = P.stats.world + 1
end

function P.BeforeViewModels()
    local view = mainView()
    if current( view ) then
        P.viewModelsStarted = P.serial
        protected( finishWorld, view )
    end
end
function P.BeforeEffects()
    local view = mainView()
    if current( view ) and P.viewModelsStarted ~= P.serial then protected( finishWorld, view ) end
end
function P.AfterEffects()
    local view = mainView()
    if not current( view ) or P.finalDone then return end
    protected( function()
        if not P.worldDone then
            -- Never repair a failed world stage on top of an already drawn gun.
            requireValue( P.viewModelsStarted ~= P.serial, "render_screen_order", "world stage did not finish before viewmodels" )
            finishWorld( view )
        end
        run( "final", S.scene or { ox = view.origin.x, oy = view.origin.y, oz = view.origin.z } )
        P.finalDone = true
        P.stats.final = P.stats.final + 1
    end )
end

-- Retire callbacks left behind by an engine Lua refresh; never run both chains.
for _, event in ipairs( { "NeedsDepthPass", "PreDrawTranslucentRenderables", "PreDrawViewModels",
    "PreDrawEffects", "RenderScreenspaceEffects", "PreDrawViewModel", "PreDrawPlayerHands", "MCWorldAdapterChanged" } ) do
    hook.Remove( event, "mc_water_ssr" )
    hook.Remove( event, "mc_pbr_post" )
end
hook.Remove( "PreDrawOpaqueRenderables", "mc_water_ssr_depth" )

hook.Add( "NeedsDepthPass", "mc_pack_screen", function()
    if SysTime() >= P.retryAt and S.RequestDepth() then return true end
end )
hook.Add( "PreDrawTranslucentRenderables", "mc_pack_screen", P.BeforeTranslucent )
hook.Add( "PreDrawViewModels", "mc_pack_screen", P.BeforeViewModels )
hook.Add( "PreDrawEffects", "mc_pack_screen", P.BeforeEffects )
hook.Add( "RenderScreenspaceEffects", "mc_pack_screen", P.AfterEffects )
hook.Add( "PreDrawViewModel", "mc_pack_screen", S.SkipNativeViewModel )
hook.Add( "PreDrawPlayerHands", "mc_pack_screen", S.SkipNativeViewModel )
hook.Add( "MCWorldAdapterChanged", "mc_pack_screen", P.Invalidate )
for _, key in ipairs( { "ssao", "fog", "volumetric", "block_ssr", "water_ssr" } ) do
    MC.RenderPackSettings.OnChange( key, "mc_pack_screen", P.Invalidate )
end
concommand.Add( "mc_pbr_post_stats", function()
    local s = P.stats
    print( string.format( "[MC screen] views=%d world=%d final=%d failures=%d sharedMiB=%.2f GPU=unmeasured",
        s.views, s.world, s.final, s.failures, processing.targetBytes / 1048576 ) )
end )
