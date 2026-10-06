-- Main-view projection and temporal camera data. Screen passes own the images;
-- cl_render_pack_screen owns the hooks and commits history only after success.
MC = MC or {}
-- Post processing holds this table across automatic Lua refreshes.
local T = MC.RenderTAA or { sequence = 0, stats = { resolved = 0, resets = 0 } }
MC.RenderTAA = T
local enabled = MC.RenderPackSettings.Handle( "taa" )
local requireValue = MC.RenderL2Resources.Require
local samples = {
    { 0, -1 / 6 }, { -1 / 4, 1 / 6 }, { 1 / 4, -7 / 18 }, { -3 / 8, -1 / 18 },
    { 1 / 8, 5 / 18 }, { -1 / 8, -5 / 18 }, { 3 / 8, 1 / 18 }, { -7 / 16, 7 / 18 }
}

function T.Wanted( group )
    return group ~= nil and group.taa ~= nil and enabled:GetBool()
end

function T.Reset()
    local group = MC.RenderPBRPost.Active()
    if group and group.taa then group.taa.previous = nil end
end

function T.IsView( view )
    local v = T.view
    if not v or v.frame ~= FrameNumber() or v.owner ~= MC.RenderPackRuntime.active or not view or not view.offcenter then return false end
    local o = view.offcenter
    return view.width == v.width and view.height == v.height and view.x == 0 and view.y == 0
        and view.origin == v.origin and view.angles == v.angles and view.fov == v.fov
        and math.abs( o.left + v.jx ) < 0.000001 and math.abs( o.right - 1 + v.jx ) < 0.000001
        and math.abs( o.bottom - v.jy ) < 0.000001 and math.abs( o.top - 1 - v.jy ) < 0.000001
end

function T.Jitter( view )
    if T.IsView( view ) then return T.view.jx, T.view.jy end
    return 0, 0
end

function T.BeginView( origin, angles, fov )
    local group = MC.RenderPBRPost.Active()
    local view = render.GetViewSetup( true )
    if not T.Wanted( group ) then T.view = nil T.Reset() return end
    if render.GetRenderTarget() ~= nil or view.viewid ~= 0 or view.ortho or view.offcenter
        or view.x ~= 0 or view.y ~= 0 or view.width ~= ScrW() or view.height ~= ScrH() then return end
    if T.view and T.view.frame == FrameNumber() then return end
    T.sequence = T.sequence % #samples + 1
    local sample = samples[T.sequence]
    local jx, jy = sample[1] / view.width, sample[2] / view.height
    T.view = { frame = FrameNumber(), owner = MC.RenderPackRuntime.active, width = view.width, height = view.height,
        origin = Vector( origin.x, origin.y, origin.z ), angles = Angle( angles.p, angles.y, angles.r ),
        fov = fov, jx = jx, jy = jy }
    -- RenderView schedules the replacement after RenderScene returns. Its FOV
    -- is already horizontal, and its offcenter input is in pixels (Y inverted).
    render.RenderView( { origin = origin, angles = angles, fov = fov, aspect = view.aspect,
        x = 0, y = 0, w = view.width, h = view.height, znear = view.znear, zfar = view.zfar,
        znearviewmodel = view.znearviewmodel, zfarviewmodel = view.zfarviewmodel,
        drawhud = true, drawviewmodel = true, drawmonitors = true, dopostprocess = true, bloomtone = view.bloomtone,
        offcenter = { left = -sample[1], right = view.width - sample[1], top = sample[2], bottom = view.height + sample[2] } } )
    return true
end

function T.BeginViewModel()
    if render.GetRenderTarget() ~= nil then return end
    local view = render.GetViewSetup( true )
    if not T.IsView( view ) then return end
    T.EndViewModel()
    cam.Start( { type = "3D", origin = view.origin, angles = view.angles,
        fov = view.fovviewmodel, aspect = view.aspect,
        x = view.x, y = view.y, w = view.width, h = view.height,
        znear = view.znearviewmodel, zfar = view.zfarviewmodel,
        offcenter = { left = 0, right = view.width, top = 0, bottom = view.height } } )
    T.viewModelCamera = true
end

function T.EndViewModel()
    if not T.viewModelCamera then return end
    if render.GetRenderTarget() ~= nil or not T.IsView( render.GetViewSetup( true ) ) then return end
    cam.End3D()
    T.viewModelCamera = nil
end

function T.Prepare( context )
    local c, history = context.scene, context.group.taa
    local world, err = MC.API.Coords.RenderToWorld( c.camera.origin )
    requireValue( world ~= nil, "render_taa_position", tostring( err ) )
    local now, previous = RealTime(), history.previous
    local signature = MC.RenderPackSchema.Canonical( context.settings )
    local camera = { world = MC.World, generation = MC.StateWorldGeneration, owner = MC.RenderPackRuntime.active,
        width = c.width, height = c.height, near = c.near, far = c.far, fov = c.fov, aspect = c.aspect,
        blockSize = c.blockSize, signature = signature, time = now, frame = FrameNumber(),
        x = world.x, y = world.y, z = world.z, right = c.camera.angles:Right(),
        up = c.camera.angles:Up(), forward = c.camera.angles:Forward(),
        scaleX = c.projection:GetField( 1, 4 ), scaleY = c.projection:GetField( 2, 4 ) }
    local valid = previous and previous.owner == camera.owner and previous.world == camera.world
        and previous.generation == camera.generation and previous.blockSize == camera.blockSize
        and previous.width == camera.width and previous.height == camera.height
        and previous.near == camera.near and previous.far == camera.far and previous.signature == signature
        and previous.frame == camera.frame - 1 and now >= previous.time and now - previous.time < 0.25
        and math.abs( previous.fov - camera.fov ) < 5 and previous.forward:Dot( camera.forward ) > 0.8
    if valid then
        local dx, dy, dz = camera.x - previous.x, camera.y - previous.y, camera.z - previous.z
        valid = dx * dx + dy * dy + dz * dz < ( 16 * c.blockSize ) ^ 2
    end
    context.taa = { next = camera, previous = valid and previous or camera, texture = valid and previous.texture or nil }
    if not valid then T.stats.resets = T.stats.resets + 1 end
end

function T.Bind( material, context )
    local data, c, history = context.taa, context.scene, context.group.taa
    local camera, previous = data.next, data.previous
    material:SetFloat( "$c0_x", 1 / c.width ) material:SetFloat( "$c0_y", 1 / c.height )
    material:SetFloat( "$c0_z", data.texture and 1 or 0 ) material:SetFloat( "$c0_w", 0.97 )
    material:SetFloat( "$c1_x", c.jitterX ) material:SetFloat( "$c1_y", c.jitterY )
    material:SetFloat( "$c1_z", camera.scaleX ) material:SetFloat( "$c1_w", camera.scaleY )
    material:SetFloat( "$c2_x", previous.scaleX ) material:SetFloat( "$c2_y", previous.scaleY )
    material:SetFloat( "$c2_z", c.blockSize * 0.15 / 65536 )
    material:SetFloat( "$c2_w", 1 / 65536 )
    local current, old = history.camera, history.previousCamera
    local delta = Vector( camera.x - previous.x, camera.y - previous.y, camera.z - previous.z )
    for row, name in ipairs( { "right", "up", "forward" } ) do
        local a, b = camera[name], previous[name]
        current:SetField( row, 1, a.x ) current:SetField( row, 2, a.y ) current:SetField( row, 3, a.z )
        old:SetField( row, 1, b.x ) old:SetField( row, 2, b.y ) old:SetField( row, 3, b.z )
        old:SetField( row, 4, b:Dot( delta ) )
    end
    material:SetMatrix( "$viewprojmat", current )
    material:SetMatrix( "$invviewprojmat", old )
end

function T.Commit( context, instance )
    local nextFrame = context.taa.next
    nextFrame.texture = instance.screenOutputs[context.group.taa.output].texture
    context.group.taa.previous = nextFrame
    T.stats.resolved = T.stats.resolved + 1
end
