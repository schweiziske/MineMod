-- Reuse the tested sky-pass capture, without test planes or stencil replay.
local API = MC.API.Render
if not MC.Check( type( API.SetSkyTexture ) == "function" and type( API.SkyTextureNeeded ) == "function",
	"skybox_engine_version", "mc_skybox_block requires the sky-texture material adapter" ) then return end
if not MC.Check( type( render.GetViewSetup ) == "function" and type( render.GetRenderTarget ) == "function",
	"skybox_view_api", "sky capture requires current view and render-target queries" ) then return end

local targets, targetCount = {}, 0
local capturedFrame, capturedPriority = -1, -1
local captureSource = "none"
local captureViewId = -1

local function mainSkyView( width, height )
	-- Reflection/refraction can draw the sky before the main view in this frame.
	-- VIEW_MAIN=0, VIEW_3DSKY=1; an offscreen sky must not populate the main capture.
	if render.GetRenderTarget() ~= nil then return end
	local view = render.GetViewSetup( true )
	if not MC.Check( type( view ) == "table", "skybox_view_missing", "no current sky view" ) then return end
	if view.viewid ~= 0 and view.viewid ~= 1 then return end
	if view.x ~= 0 or view.y ~= 0 or view.width ~= width or view.height ~= height or view.ortho then return end
	return view.viewid
end

local function capture( source, priority )
	if not API.SkyTextureNeeded() then return end
	local width, height = ScrW(), ScrH()
	if width <= 0 or height <= 0 then return end
	local viewId = mainSkyView( width, height )
	if viewId == nil then return end
	local frame = FrameNumber()
	if capturedFrame == frame and priority <= capturedPriority then return end
	local key = width .. "x" .. height
	local target = targets[key]
	if not target then
		if not MC.Check( targetCount < 8, "skybox_target_budget", "8 sky RT sizes reached; restart the client" ) then return end
		target = GetRenderTargetEx( "mc_skybox_capture_v1_" .. key, width, height,
			RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 )
		if not MC.Check( target and not target:IsError(), "skybox_target_create", "sky RT allocation failed" ) then return end
		targets[key], targetCount = target, targetCount + 1
	end
	render.CopyRenderTargetToTexture( target )
	local ok, err = API.SetSkyTexture( target )
	if not MC.Check( ok, "skybox_capture_publish", "%s", tostring( err ) ) then return end
	capturedFrame, capturedPriority, captureSource = frame, priority, source
	captureViewId = viewId
end

hook.Add( "PostDraw2DSkyBox", "mc_skybox_capture_2d", function() capture( "2d", 1 ) end )
-- Remove the old, non-engine callback on Lua refresh too.
hook.Remove( "PostDraw3DSkyBox", "mc_skybox_capture_3d" )
hook.Add( "PostDrawSkyBox", "mc_skybox_capture_3d", function() capture( "3d", 2 ) end )
concommand.Add( "mc_skybox_status", function()
	print( string.format( "[MC skybox] needed=%s capture=%s view=%d target=backbuffer age=%d targets=%d",
		tostring( API.SkyTextureNeeded() ), captureSource, captureViewId,
		capturedFrame < 0 and -1 or FrameNumber() - capturedFrame, targetCount ) )
end )
