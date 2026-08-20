-- Cached Minecraft bitmap-font planes for named map decorations.
if not CLIENT then return end

MC = MC or {}
MC.DecorationRenderer = MC.DecorationRenderer or {}
local R = MC.DecorationRenderer

local cache = R.DecorationMapTextCache or {}
R.DecorationMapTextCache = cache
local serial = 0

local function fontAPI()
	return MC.API and MC.API.Font or nil
end

local function usable( value )
	return value ~= nil and not ( value.IsError and value:IsError() )
end

local function measure( text )
	local font = fontAPI()
	local width = font and font.Measure and font.Measure( text, "default" ) or #text * 6
	return math.max( 0, math.ceil( tonumber( width ) or 0 ) )
end

local function build( text )
	if not ( GetRenderTarget and CreateMaterial and render and render.PushRenderTarget
	and render.PopRenderTarget and render.Clear and cam and cam.Start2D and cam.End2D
	and surface and surface.SetDrawColor and surface.DrawRect ) then
		return nil, "render_target_unavailable"
	end
	local font = fontAPI()
	if not ( font and font.Draw ) then return nil, "font_unavailable" end
	local width = measure( text )
	-- MapRenderer submits the name with Minecraft Font's fixed background
	-- bottom at y + 9.  The engine font API may expose a different line height,
	-- but using it here would change the source-observable map-name geometry.
	local lineHeight = 9
	local maxWidth = render.MaxTextureWidth and render.MaxTextureWidth() or 4096
	if width + 1 > maxWidth then return nil, "name_exceeds_source_texture_limit" end
	serial = serial + 1
	local targetWidth = math.max( 1, width + 1 )
	local targetHeight = lineHeight + 1
	local name = "mc_decoration_map_name_" .. serial
	local target = GetRenderTarget( name, targetWidth, targetHeight )
	if not target then return nil, "render_target_unavailable" end
	local material = CreateMaterial( name .. "_material", "UnlitGeneric", {
		["$basetexture"] = target.GetName and target:GetName() or "color/white",
		["$vertexcolor"] = "1", ["$vertexalpha"] = "1",
		["$translucent"] = "1", ["$nolod"] = "1",
	} )
	if not usable( material ) then return nil, "material_unavailable" end
	if material.SetTexture then material:SetTexture( "$basetexture", target ) end
	local pushed, drawing = false, false
	local ok, err = pcall( function()
		render.PushRenderTarget( target, 0, 0, targetWidth, targetHeight )
		pushed = true
		render.Clear( 0, 0, 0, 0, true, true )
		cam.Start2D()
		drawing = true
		-- Font#prepareText receives Integer.MIN_VALUE as backgroundColor.
		surface.SetDrawColor( 0, 0, 0, 128 )
		surface.DrawRect( 0, 0, targetWidth, targetHeight )
		font.Draw( text, 1, 1, { font = "default", scale = 1,
			color = Color( 255, 255, 255, 255 ), shadow = false } )
		cam.End2D()
		drawing = false
		render.PopRenderTarget()
		pushed = false
	end )
	if drawing then pcall( cam.End2D ) end
	if pushed then pcall( render.PopRenderTarget ) end
	if not ok then return nil, tostring( err ) end
	return { material = material, width = width }
end

function R.ResolveDecorationMapNameMaterial( text )
	if type( text ) ~= "string" or text == "" then return nil, "name_missing" end
	local entry = cache[text]
	if entry then return entry.material, entry.width, entry.error end
	local built, err = build( text )
	entry = built or { error = err }
	cache[text] = entry
	return entry.material, entry.width, entry.error
end
