--[[----------------------------------------------------------------------------
	MC Workshop client bridge.

	Steam publishing and downloading happen only in the player's client. The
	server supplies/accepts validated world bundles and remains authoritative for
	permissions and world loading.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.Workshop = MC.Workshop or {}

local W = MC.Workshop
local Client = W.Client or {}
W.Client = Client

local EXPORT_DIR = "mc/workshop_exports"
local OWNED_QUERY_TIMEOUT = 15
local WORKSHOP_DOWNLOAD_TIMEOUT = 300
local WORKSHOP_FILEINFO_TIMEOUT = 10
local WORKSHOP_DOWNLOAD_ATTEMPTS = 5
local PUBLISH_POLL_INTERVAL = 5
local PUBLISH_POLL_ATTEMPTS = 24
local PREVIEW_SIZE = 512
local PREVIEW_CAPTURE_QUALITIES = { 85, 70, 55, 40 }
local PREVIEW_RENDER_HOOK = "PostDrawEffects"

local PreviewRenderTarget = GetRenderTarget and GetRenderTarget( "mc_workshop_preview_512_v1", PREVIEW_SIZE, PREVIEW_SIZE ) or nil
local PreviewSourceMaterial = CreateMaterial and CreateMaterial( "mc_workshop_preview_source_v1", "UnlitGeneric", {
	["$basetexture"] = "color/white",
	["$vertexcolor"] = "1",
	["$vertexalpha"] = "1",
	["$ignorez"] = "1",
	["$nolod"] = "1",
} ) or nil
local PreviewRendering = false

Client.sequence = math.floor( tonumber( Client.sequence ) or ( SysTime() * 1000 ) ) % 4294967295

local function L( key, fallback, vars )
	return MC.T and MC.T( key, fallback, vars ) or fallback
end

local function nextRequestId()
	Client.sequence = ( Client.sequence + 1 ) % 4294967295
	if Client.sequence < 1 then Client.sequence = 1 end
	return Client.sequence
end

local ERROR_TEXT = {
	permission = { "workshop.error_permission", "服务端未批准该创意工坊操作" },
	save_permission = { "workshop.error_permission", "服务端未批准该创意工坊操作" },
	rate_limited = { "workshop.error_rate", "请求太快，请稍后再试" },
	transfer_busy = { "workshop.error_busy", "已有创意工坊传输正在进行" },
	invalid_slot = { "workshop.error_slot", "存档名称无效" },
	workshop_requires_region_save = { "workshop.error_legacy", "旧版存档暂不能发布，请先重新覆盖保存一次" },
	invalid_workshop_id = { "workshop.error_id", "创意工坊 ID 或链接无效" },
	invalid_load_request = { "workshop.error_request", "创意工坊读取请求无效" },
	invalid_bundle_magic = { "workshop.error_not_world", "该物品不是 MC 世界存档" },
	unsupported_bundle_save_version = { "workshop.error_version", "该 MC 世界存档版本不受支持" },
	bundle_crc_mismatch = { "workshop.error_corrupt", "创意工坊世界包校验失败" },
	hash_mismatch = { "workshop.error_corrupt", "创意工坊世界包校验失败" },
	package_mismatch = { "workshop.error_corrupt", "创意工坊世界包校验失败" },
	capture_empty = { "workshop.error_capture_empty", "无法从当前游戏画面拍摄创意工坊封面" },
	capture_too_large = { "workshop.error_capture_too_large", "拍摄到的创意工坊封面超过大小限制" },
	capture_write_failed = { "workshop.error_capture_write", "无法把创意工坊封面写入客户端数据目录" },
	capture_timeout = { "workshop.error_capture_timeout", "等待游戏画面截图超时" },
	capture_size = { "workshop.error_capture_size", "当前游戏画面尺寸太小，无法生成创意工坊封面" },
	workshop_file_unreadable = { "workshop.error_file_unreadable", "无法读取 Steam 下载的创意工坊世界文件" },
	workshop_handle_read_failed = { "workshop.error_file_unreadable", "无法读取 Steam 下载的创意工坊世界文件" },
	workshop_file_too_large = { "workshop.error_file_too_large", "创意工坊世界文件超过服务器允许的大小" },
	shared_write_failed = { "workshop.error_shared_write", "无法写入 Listen Server 共享世界文件" },
	shared_read_failed = { "workshop.error_shared_read", "Listen Server 无法读取共享世界文件" },
	shared_unavailable = { "workshop.error_shared_unavailable", "当前客户端不能使用 Listen Server 共享读取" },
	cache_write_failed = { "workshop.error_cache_write", "无法缓存创意工坊基础世界" },
	timeout = { "workshop.error_timeout", "创意工坊操作超时" },
	load_failed = { "workshop.error_load", "服务端无法读取该世界" },
}

local function errorText( code )
	code = tostring( code or "error" )
	local item = ERROR_TEXT[code]
	if item then return L( item[1], item[2] ) .. " (" .. code .. ")" end
	return L( "workshop.error_generic", "创意工坊操作失败: {err}", { err = code } )
end

local function setStatus( message, isError, pending )
	Client.status = {
		message = tostring( message or "" ),
		isError = isError == true,
		pending = pending == true,
	}
	if MC.SetSaveManagerWorkshopStatus then
		MC.SetSaveManagerWorkshopStatus( Client.status.message, Client.status.isError, Client.status.pending )
	end
	hook.Run( "MC.WorkshopStatus", Client.status.message, Client.status.isError, Client.status.pending )
end

local function clearTimer( name )
	if name and name ~= "" then timer.Remove( name ) end
end

local function clearPublish( keepStatus )
	local publish = Client.publish
	if publish then
		clearTimer( publish.timeoutTimer )
		clearTimer( publish.pollTimer )
		clearTimer( publish.returnTimer )
	end
	Client.publish = nil
	if not keepStatus and Client.status and Client.status.pending then setStatus( "", false, false ) end
end

local function clearImport( keepStatus )
	local import = Client.import
	if import then
		clearTimer( import.timeoutTimer )
		clearTimer( import.downloadTimer )
		clearTimer( import.fileInfoTimer )
		clearTimer( import.downloadRetryTimer )
		if import.sharedPath and file.Exists( import.sharedPath, "DATA" ) then file.Delete( import.sharedPath ) end
	end
	Client.import = nil
	if not keepStatus and Client.status and Client.status.pending then setStatus( "", false, false ) end
end

local function clearBaseDownload()
	local base = Client.baseDownload
	if base then
		clearTimer( base.downloadTimer )
		clearTimer( base.fileInfoTimer )
		clearTimer( base.downloadRetryTimer )
	end
	Client.baseDownload = nil
end

local function setBaseStatus( base, status, err )
	Client.baseStatus = {
		generation = base and base.generation or 0,
		workshopId = base and base.workshopId or nil,
		contentHash = base and base.contentHash or nil,
		packageId = base and base.packageId or nil,
		status = tostring( status or "idle" ),
		error = err and tostring( err ) or nil,
	}
	hook.Run( "MC.WorkshopBaseStatus", Client.baseStatus )
end

function W.ClientCanManage()
	local ply = LocalPlayer()
	if not IsValid( ply ) then return false end
	local cv = GetConVar( "mc_workshop_manage" )
	local mode = cv and math.Clamp( cv:GetInt(), 0, 2 ) or 0
	if mode <= 0 then return ply:IsSuperAdmin() end
	if mode == 1 then return ply:IsAdmin() end
	return true
end

function W.ClientBusy()
	return Client.publish ~= nil or Client.import ~= nil
end

function W.ClientCanShareListenData()
	if game.IsDedicated and game.IsDedicated() then return false end
	local ply = LocalPlayer()
	return IsValid( ply ) and ply.IsListenServerHost and ply:IsListenServerHost()
end

local function collectOwnedIds( data )
	local out = {}
	if not istable( data ) or not istable( data.results ) then return out end
	for _, value in pairs( data.results ) do
		local id = W.NormalizeWorkshopId( istable( value ) and ( value.id or value.wsid ) or value )
		if id then out[id] = true end
	end
	return out
end

local function queryOwnedIds( callback )
	callback = callback or function() end
	if not steamworks or not steamworks.GetList then callback( nil, "steamworks_unavailable" ) return end
	local finished = false
	local timerName = "MC_WorkshopOwnedQuery_" .. tostring( nextRequestId() )
	local function finish( ids, err )
		if finished then return end
		finished = true
		timer.Remove( timerName )
		callback( ids, err )
	end
	timer.Create( timerName, OWNED_QUERY_TIMEOUT, 1, function() finish( nil, "owned_query_timeout" ) end )
	steamworks.GetList( "mine", { "dupe" }, 0, 9999, 0, "1", function( data )
		if not data then finish( nil, "owned_query_failed" ) return end
		finish( collectOwnedIds( data ) )
	end )
end

local function renderCleanWorldPreview( quality )
	if PreviewRendering or not PreviewRenderTarget or not render.RenderView then return false end
	-- Sandbox delegates save thumbnails to engine.WriteSave. There is no public
	-- thumbnail-only variant, so render the equivalent clean scene into our own
	-- target: current camera, no HUD, no VGUI and no first-person model.
	local viewSetup = render.GetViewSetup and render.GetViewSetup() or nil
	local origin = viewSetup and viewSetup.origin or EyePos()
	local angles = viewSetup and viewSetup.angles or EyeAngles()
	local fov = math.Clamp( tonumber( viewSetup and viewSetup.fov ) or 90, 1, 179 )
	if not origin or not angles then return false end
	local drawViewer = false
	if viewSetup then drawViewer = viewSetup.drawviewer == true end

	local view = {
		origin = origin,
		angles = angles,
		x = 0,
		y = 0,
		w = PREVIEW_SIZE,
		h = PREVIEW_SIZE,
		fov = fov,
		aspectratio = 1,
		drawhud = false,
		drawviewmodel = false,
		drawviewer = drawViewer,
		dopostprocess = false,
		drawmonitors = false,
	}
	if viewSetup then
		if tonumber( viewSetup.znear ) then view.znear = viewSetup.znear end
		if tonumber( viewSetup.zfar ) then view.zfar = viewSetup.zfar end
	end

	local pushedRenderTarget = false
	PreviewRendering = true
	local ok, data = pcall( function()
		render.PushRenderTarget( PreviewRenderTarget, 0, 0, PREVIEW_SIZE, PREVIEW_SIZE )
		pushedRenderTarget = true
		render.Clear( 0, 0, 0, 255, true, true )
		render.RenderView( view )
		local captured = render.Capture( {
			format = "jpeg",
			quality = quality,
			x = 0,
			y = 0,
			w = PREVIEW_SIZE,
			h = PREVIEW_SIZE,
			alpha = false,
		} )
		render.PopRenderTarget()
		pushedRenderTarget = false
		return captured
	end )
	if pushedRenderTarget then pcall( render.PopRenderTarget ) end
	PreviewRendering = false
	return ok, data
end

local function captureCenteredPreview( screenWidth, screenHeight, quality )
	local cropSize = math.floor( math.min( screenWidth, screenHeight ) )
	if cropSize < 64 then return false, nil, "capture_size" end
	local cropX = math.floor( ( screenWidth - cropSize ) * 0.5 )
	local cropY = math.floor( ( screenHeight - cropSize ) * 0.5 )
	local directCapture = {
		format = "jpeg",
		quality = quality,
		x = cropX,
		y = cropY,
		w = cropSize,
		h = cropSize,
	}
	local worldOK, worldData = renderCleanWorldPreview( quality )
	if worldOK and isstring( worldData ) and worldData ~= "" then return true, worldData end

	if not PreviewRenderTarget or not PreviewSourceMaterial or PreviewSourceMaterial:IsError()
		or not render.GetScreenEffectTexture or not render.UpdateScreenEffectTexture then
		local ok, data = pcall( render.Capture, directCapture )
		return ok, data
	end

	local sourceTexture = render.GetScreenEffectTexture()
	if not sourceTexture then
		local ok, data = pcall( render.Capture, directCapture )
		return ok, data
	end
	local textureWidth = math.max( tonumber( sourceTexture:Width() ) or 0, 1 )
	local textureHeight = math.max( tonumber( sourceTexture:Height() ) or 0, 1 )
	local u0 = cropX / textureWidth
	local v0 = cropY / textureHeight
	local u1 = ( cropX + cropSize ) / textureWidth
	local v1 = ( cropY + cropSize ) / textureHeight
	local pushedRenderTarget = false
	local drawing2D = false

	local ok, data = pcall( function()
		render.UpdateScreenEffectTexture()
		PreviewSourceMaterial:SetTexture( "$basetexture", sourceTexture )
		render.PushRenderTarget( PreviewRenderTarget, 0, 0, PREVIEW_SIZE, PREVIEW_SIZE )
		pushedRenderTarget = true
		render.Clear( 0, 0, 0, 255, true, true )
		cam.Start2D()
		drawing2D = true
		surface.SetMaterial( PreviewSourceMaterial )
		surface.SetDrawColor( 255, 255, 255, 255 )
		surface.DrawTexturedRectUV( 0, 0, PREVIEW_SIZE, PREVIEW_SIZE, u0, v0, u1, v1 )
		cam.End2D()
		drawing2D = false
		local captured = render.Capture( {
			format = "jpeg",
			quality = quality,
			x = 0,
			y = 0,
			w = PREVIEW_SIZE,
			h = PREVIEW_SIZE,
		} )
		render.PopRenderTarget()
		pushedRenderTarget = false
		return captured
	end )

	if drawing2D then pcall( cam.End2D ) end
	if pushedRenderTarget then pcall( render.PopRenderTarget ) end
	if ok then return true, data end

	-- Older render paths may reject drawing the screen-effect texture into a
	-- custom target. Keep the same centered crop and let JPEG quality constrain
	-- the larger direct capture rather than falling back to the top-left corner.
	local directOK, directData = pcall( render.Capture, directCapture )
	return directOK, directData
end

local function captureWorkshopPreview( token, savedCover, callback )
	callback = callback or function() end
	file.CreateDir( "mc" )
	file.CreateDir( EXPORT_DIR )
	local imagePath = EXPORT_DIR .. "/" .. token .. ".jpg"
	local hookName = "MC_WorkshopCapture_" .. token
	local hudHookName = hookName .. "_hud"
	local viewModelHookName = hookName .. "_viewmodel"
	local handsHookName = hookName .. "_hands"
	local timerName = hookName .. "_timeout"
	local frame = MC.SaveManagerFrame
	local restoreFrame = IsValid( frame ) and frame:IsVisible()
	if restoreFrame then frame:SetVisible( false ) end
	local done = false
	local maxAttempts = #PREVIEW_CAPTURE_QUALITIES
	local function finish( data, err )
		if done then return end
		done = true
		hook.Remove( PREVIEW_RENDER_HOOK, hookName )
		hook.Remove( "HUDShouldDraw", hudHookName )
		hook.Remove( "PreDrawViewModel", viewModelHookName )
		hook.Remove( "PreDrawPlayerHands", handsHookName )
		timer.Remove( timerName )
		if restoreFrame and IsValid( frame ) then
			frame:SetVisible( true )
			frame:MakePopup()
		end
		callback( data, imagePath, err )
	end
	local function persist( data )
		if not isstring( data ) or data == "" or #data > W.MAX_COVER_BYTES then return false end
		file.Write( imagePath, data )
		return file.Exists( imagePath, "DATA" ) and file.Size( imagePath, "DATA" ) == #data
	end
	local function failCapture( err )
		if persist( savedCover ) then
			finish( savedCover )
			return
		end
		finish( nil, err )
	end
	timer.Create( timerName, 8, 1, function() failCapture( "capture_timeout" ) end )
	local frames = 0
	local attempts = 0
	local sawOversizedCapture = false

	-- Capture after the 3D scene has finished but before HUDPaint, Derma and the
	-- GameUI/ESC overlay are composited. Suppress first-person models during the
	-- short capture window so the Workshop cover contains only the world view.
	hook.Add( "HUDShouldDraw", hudHookName, function() return false end )
	hook.Add( "PreDrawViewModel", viewModelHookName, function() return true end )
	hook.Add( "PreDrawPlayerHands", handsHookName, function() return true end )
	hook.Add( PREVIEW_RENDER_HOOK, hookName, function()
		if PreviewRendering then return end
		frames = frames + 1
		if frames < 2 then return end
		attempts = attempts + 1
		local screenWidth, screenHeight = ScrW(), ScrH()
		local captured, data, captureError = captureCenteredPreview(
			screenWidth,
			screenHeight,
			PREVIEW_CAPTURE_QUALITIES[attempts]
		)
		if captureError then failCapture( captureError ) return end
		if not captured or not isstring( data ) or data == "" then
			if attempts >= maxAttempts then
				failCapture( sawOversizedCapture and "capture_too_large" or "capture_empty" )
			end
			return
		end
		if #data > W.MAX_COVER_BYTES then
			sawOversizedCapture = true
			if attempts >= maxAttempts then failCapture( "capture_too_large" ) end
			return
		end
		if not persist( data ) then
			finish( nil, "capture_write_failed" )
			return
		end
		finish( data )
	end )
end

local function bindPublishedId( publish, workshopId )
	workshopId = W.NormalizeWorkshopId( workshopId )
	if not publish or Client.publish ~= publish or not workshopId then
		setStatus( errorText( "invalid_workshop_id" ), true, false )
		clearPublish( true )
		return
	end
	clearTimer( publish.pollTimer )
	clearTimer( publish.returnTimer )
	publish.bindRequestId = nextRequestId()
	publish.workshopId = workshopId
	setStatus( L( "workshop.binding", "正在把创意工坊 ID 写回服务端存档..." ), false, true )
	net.Start( "mc_workshop_bind_id" )
		net.WriteUInt( publish.bindRequestId, 32 )
		net.WriteString( publish.save.name or "" )
		net.WriteString( workshopId )
		net.WriteString( publish.contentHash or "" )
		net.WriteUInt( math.Clamp( publish.archiveBytes or 0, 0, 4294967295 ), 32 )
	net.SendToServer()
end

local function promptPublishedId( publish, candidates )
	if not publish or Client.publish ~= publish then return end
	if publish.promptOpen then return end
	publish.promptOpen = true
	clearTimer( publish.pollTimer )
	clearTimer( publish.returnTimer )
	local candidateText = ""
	if candidates and #candidates > 0 then
		local shown = {}
		for index = 1, math.min( #candidates, 10 ) do shown[#shown + 1] = candidates[index] end
		candidateText = "\n" .. table.concat( shown, ", " )
		if #candidates > #shown then candidateText = candidateText .. " ..." end
	end
	Derma_StringRequest(
		L( "workshop.bind_title", "关联创意工坊 ID" ),
		L( "workshop.bind_prompt", "发布窗口没有把 ID 直接返回游戏。请输入刚发布或更新的 Workshop ID，或粘贴其 Steam 创意工坊链接。" ) .. candidateText,
		publish.knownWorkshopId or candidates and candidates[1] or "",
		function( value ) bindPublishedId( publish, value ) end,
		function()
			setStatus( L( "workshop.bind_cancelled", "发布文件已交给 Steam，但没有关联 Workshop ID" ), true, false )
			clearPublish( true )
		end,
		L( "workshop.bind", "关联" ),
		L( "save.cancel", "取消" )
	)
end

local function resolvePublishedIds( publish, ids )
	if not publish or Client.publish ~= publish then return false end
	if not istable( publish.beforeIds ) then return false end
	local added = {}
	for id in pairs( ids or {} ) do
		if not publish.beforeIds or publish.beforeIds[id] ~= true then added[#added + 1] = id end
	end
	table.sort( added, function( a, b ) return tonumber( a ) < tonumber( b ) end )
	if #added == 1 then bindPublishedId( publish, added[1] ) return true end
	if #added > 1 then promptPublishedId( publish, added ) return true end
	return false
end

local function startPublishPolling( publish )
	if not publish or Client.publish ~= publish then return end
	publish.pollTimer = "MC_WorkshopPublishPoll_" .. publish.token
	publish.returnTimer = "MC_WorkshopPublishReturn_" .. publish.token
	publish.startedAt = CurTime()
	publish.sawGameUI = gui and gui.IsGameUIVisible and gui.IsGameUIVisible() or false

	timer.Create( publish.returnTimer, 1, 0, function()
		if Client.publish ~= publish then timer.Remove( publish.returnTimer ) return end
		local visible = gui and gui.IsGameUIVisible and gui.IsGameUIVisible() or false
		if visible then publish.sawGameUI = true return end
		if publish.sawGameUI and not publish.returnedAt then publish.returnedAt = CurTime() end
	end )

	timer.Create( publish.pollTimer, PUBLISH_POLL_INTERVAL, PUBLISH_POLL_ATTEMPTS, function()
		if Client.publish ~= publish then timer.Remove( publish.pollTimer ) return end
		if publish.pollInFlight then return end
		publish.pollInFlight = true
		queryOwnedIds( function( ids )
			if Client.publish ~= publish then return end
			publish.pollInFlight = false
			if ids and resolvePublishedIds( publish, ids ) then return end
			local returnedFor = publish.returnedAt and ( CurTime() - publish.returnedAt ) or 0
			if publish.knownWorkshopId and returnedFor >= 8 then
				promptPublishedId( publish, { publish.knownWorkshopId } )
				return
			end
			if returnedFor >= 25 or CurTime() - publish.startedAt >= PUBLISH_POLL_INTERVAL * PUBLISH_POLL_ATTEMPTS then
				promptPublishedId( publish )
			end
		end )
	end )
end

local function launchPublisher( publish, bundle, decoded )
	if not publish or Client.publish ~= publish then return end
	captureWorkshopPreview( publish.token, decoded.files["cover.jpg"], function( imageData, imagePath, captureError )
		if Client.publish ~= publish then return end
		if not imageData then
			setStatus( errorText( captureError ), true, false )
			clearPublish( true )
			return
		end
		decoded.files["cover.jpg"] = imageData
		local finalBundle, infoOrError = W.EncodeBundle( decoded.metadata, decoded.files )
		if not finalBundle then
			setStatus( errorText( infoOrError ), true, false )
			clearPublish( true )
			return
		end
		local archive, archiveInfoOrError = W.EncodeWorkshopArchive( finalBundle, decoded.metadata.name )
		if not archive then
			setStatus( errorText( archiveInfoOrError ), true, false )
			clearPublish( true )
			return
		end
		local dataPath = EXPORT_DIR .. "/" .. publish.token .. ".gma"
		file.Write( dataPath, archive )
		if not file.Exists( dataPath, "DATA" ) or file.Size( dataPath, "DATA" ) ~= #archive then
			setStatus( errorText( "export_write_failed" ), true, false )
			clearPublish( true )
			return
		end
		publish.contentHash = archiveInfoOrError.contentHash or W.ContentHash( archive )
		publish.archiveBytes = #archive
		publish.dataPath = dataPath
		publish.imagePath = imagePath
		setStatus( L( "workshop.publisher_open", "正在打开 Garry's Mod 创意工坊发布窗口..." ), false, true )
		RunConsoleCommand( "dupe_publish", "data/" .. dataPath, "data/" .. imagePath )
		startPublishPolling( publish )
	end )
end

function W.PublishSave( save )
	if not W.ClientCanManage() then setStatus( errorText( "permission" ), true, false ) return false end
	if W.ClientBusy() then setStatus( errorText( "transfer_busy" ), true, false ) return false end
	if not istable( save ) or not W.SafeSlotName( save.name ) then setStatus( errorText( "invalid_slot" ), true, false ) return false end
	if not steamworks or not steamworks.GetList then setStatus( errorText( "steamworks_unavailable" ), true, false ) return false end

	local requestId = nextRequestId()
	local publish = {
		requestId = requestId,
		token = tostring( requestId ) .. "_" .. util.CRC( tostring( SysTime() ) .. tostring( save.name ) ),
		save = table.Copy( save ),
		knownWorkshopId = W.NormalizeWorkshopId( save.workshopId ),
	}
	Client.publish = publish
	setStatus( L( "workshop.exporting", "服务端正在导出存档..." ), false, true )
	queryOwnedIds( function( ids )
		if Client.publish ~= publish then return end
		if ids then publish.beforeIds = ids else publish.baselineFailed = true end
	end )
	net.Start( "mc_workshop_export_request" )
		net.WriteUInt( requestId, 32 )
		net.WriteString( save.name )
	net.SendToServer()
	return true
end

net.Receive( "mc_workshop_export_begin", function()
	local requestId = net.ReadUInt( 32 )
	local ok = net.ReadBool()
	local err = net.ReadString()
	local slotName = net.ReadString()
	local expectedParts = net.ReadUInt( 16 )
	local totalBytes = net.ReadUInt( 32 )
	local contentHash = string.lower( net.ReadString() or "" )
	local publish = Client.publish
	if not publish or publish.requestId ~= requestId then return end
	if not ok then
		setStatus( errorText( err ), true, false )
		clearPublish( true )
		return
	end
	if W.SafeSlotName( slotName ) ~= W.SafeSlotName( publish.save.name ) or expectedParts < 1
		or totalBytes < 17 or totalBytes > W.MAX_BUNDLE_BYTES or not W.IsContentHash( contentHash ) then
		setStatus( errorText( "invalid_export_header" ), true, false )
		clearPublish( true )
		return
	end
	publish.expectedParts = expectedParts
	publish.totalBytes = totalBytes
	publish.serverHash = contentHash
	publish.receivedParts = 0
	publish.receivedBytes = 0
	publish.parts = {}
	publish.timeoutTimer = "MC_WorkshopExportTimeout_" .. publish.token
	local exportTimeout = math.Clamp( 60 + totalBytes / 50000, 300, W.EXPORT_TIMEOUT_MAX )
	timer.Create( publish.timeoutTimer, exportTimeout, 1, function()
		if Client.publish == publish then
			setStatus( errorText( "timeout" ), true, false )
			clearPublish( true )
		end
	end )
end )

net.Receive( "mc_workshop_export_part", function()
	local requestId = net.ReadUInt( 32 )
	local index = net.ReadUInt( 16 )
	local len = net.ReadUInt( 16 )
	local chunk = net.ReadData( len )
	local publish = Client.publish
	if not publish or publish.requestId ~= requestId or not publish.parts then return end
	if index < 1 or index > publish.expectedParts or len < 1 or len > W.EXPORT_PART_BYTES
		or not chunk or #chunk ~= len then
		setStatus( errorText( "invalid_export_part" ), true, false )
		clearPublish( true )
		return
	end
	if publish.parts[index] then return end
	publish.parts[index] = chunk
	publish.receivedParts = publish.receivedParts + 1
	publish.receivedBytes = publish.receivedBytes + len
	if publish.receivedBytes > publish.totalBytes then
		setStatus( errorText( "size_mismatch" ), true, false )
		clearPublish( true )
		return
	end
	if publish.receivedParts < publish.expectedParts then return end

	clearTimer( publish.timeoutTimer )
	local bundle = table.concat( publish.parts )
	publish.parts = nil
	if #bundle ~= publish.totalBytes or W.ContentHash( bundle ) ~= publish.serverHash then
		setStatus( errorText( "hash_mismatch" ), true, false )
		clearPublish( true )
		return
	end
	local decoded, decodeError = W.DecodeBundle( bundle )
	if not decoded then
		setStatus( errorText( decodeError ), true, false )
		clearPublish( true )
		return
	end
	setStatus( L( "workshop.capturing", "正在隐藏界面并拍摄创意工坊封面..." ), false, true )
	launchPublisher( publish, bundle, decoded )
end )

net.Receive( "mc_workshop_bind_result", function()
	local requestId = net.ReadUInt( 32 )
	local ok = net.ReadBool()
	local err = net.ReadString()
	local slotName = net.ReadString()
	local workshopId = net.ReadString()
	local publish = Client.publish
	if not publish or publish.bindRequestId ~= requestId then return end
	if ok then
		setStatus( L( "workshop.publish_done", "已发布并关联 Workshop ID {id}", { id = workshopId } ), false, false )
		if publish.dataPath and file.Exists( publish.dataPath, "DATA" ) then file.Delete( publish.dataPath ) end
		if publish.imagePath and file.Exists( publish.imagePath, "DATA" ) then file.Delete( publish.imagePath ) end
		MC.SaveManagerPendingSelection = slotName
	else
		setStatus( errorText( err ), true, false )
	end
	clearPublish( true )
end )

local function readOpenWorkshopHandle( handle, seekToStart )
	if handle == nil or handle == false then return nil end
	local sizeOK, size = pcall( function() return tonumber( handle:Size() ) or -1 end )
	if not sizeOK or size < 17 then return nil, "workshop_handle_read_failed" end
	if size > W.MAX_WORKSHOP_ARCHIVE_BYTES then return nil, "workshop_file_too_large" end
	local readOK, data = pcall( function()
		if seekToStart then handle:Seek( 0 ) end
		return handle:Read( size )
	end )
	if readOK and isstring( data ) and #data == size then return data end
	return nil, "workshop_handle_read_failed"
end

local function writeDataBinary( path, data, errorCode )
	errorCode = tostring( errorCode or "shared_write_failed" )
	if not isstring( path ) or path == "" or not isstring( data ) then return false, errorCode end
	file.CreateDir( string.GetPathFromFilename( path ) )
	local handle = file.Open( path, "wb", "DATA" )
	if not handle then return false, errorCode end
	handle:Write( data )
	handle:Close()
	if not file.Exists( path, "DATA" ) or file.Size( path, "DATA" ) ~= #data then
		file.Delete( path )
		return false, errorCode
	end
	return true
end

local function readWorkshopFile( path, temporaryHandle, workshopId )
	local data, handleError = readOpenWorkshopHandle( temporaryHandle, true )
	if data then return data end

	path = string.gsub( tostring( path or "" ), "\\", "/" )
	workshopId = W.NormalizeWorkshopId( workshopId )
	local candidates, candidateKeys = {}, {}
	local directories, directoryKeys = {}, {}
	local function addCandidate( candidatePath, pathId )
		candidatePath = string.gsub( tostring( candidatePath or "" ), "\\", "/" )
		if candidatePath == "" then return end
		local key = tostring( pathId ) .. ":" .. string.lower( candidatePath )
		if candidateKeys[key] then return end
		candidateKeys[key] = true
		candidates[#candidates + 1] = { candidatePath, pathId }
	end
	local function addDirectory( directory, pathId )
		directory = string.gsub( tostring( directory or "" ), "\\", "/" )
		directory = string.gsub( directory, "/+$", "" )
		if directory == "" then return end
		local key = tostring( pathId ) .. ":" .. string.lower( directory )
		if directoryKeys[key] then return end
		directoryKeys[key] = true
		directories[#directories + 1] = { directory, pathId }
	end

	addCandidate( path, "MOD" )
	addCandidate( path, "GAME" )
	if string.StartWith( string.lower( path ), "data/" ) then addCandidate( string.sub( path, 6 ), "DATA" ) end

	local lowerPath = string.lower( path )
	local workshopAt = string.find( lowerPath, "workshop/content/4000/", 1, true )
	if workshopAt then
		local workshopSuffix = string.sub( path, workshopAt )
		local contentSuffix = string.sub( workshopSuffix, #"workshop/" + 1 )
		for _, pathId in ipairs( { "GAME", "MOD" } ) do
			addCandidate( workshopSuffix, pathId )
			addCandidate( contentSuffix, pathId )
			addDirectory( string.match( workshopSuffix, "^(.*)/[^/]+$" ) or workshopSuffix, pathId )
			addDirectory( string.match( contentSuffix, "^(.*)/[^/]+$" ) or contentSuffix, pathId )
		end
	end
	if workshopId then
		for _, pathId in ipairs( { "GAME", "MOD" } ) do
			addDirectory( "workshop/content/4000/" .. workshopId, pathId )
			addDirectory( "content/4000/" .. workshopId, pathId )
		end
	end
	if path ~= "" and not string.match( lowerPath, "%.[a-z0-9]+$" ) then
		addDirectory( path, "GAME" )
		addDirectory( path, "MOD" )
	end

	for _, directory in ipairs( directories ) do
		local findOK, files = pcall( file.Find, directory[1] .. "/*", directory[2] )
		if findOK then
			for _, name in ipairs( files or {} ) do
				local lowerName = string.lower( name )
				if string.EndsWith( lowerName, ".gma" ) or string.EndsWith( lowerName, ".dat" ) or string.EndsWith( lowerName, ".mcws" ) then
					addCandidate( directory[1] .. "/" .. name, directory[2] )
				end
			end
		end
	end

	local bestError = handleError
	for _, candidate in ipairs( candidates ) do
		local openOK, handle = pcall( file.Open, candidate[1], "rb", candidate[2] )
		if openOK and handle then
			data, handleError = readOpenWorkshopHandle( handle, false )
			pcall( function() handle:Close() end )
			if data then return data end
			if handleError == "workshop_file_too_large" then bestError = handleError end
		end
	end
	MsgN( string.format( "[MC Workshop] unable to read Steam download result for %s (path=%s, handle=%s, candidates=%d)",
		tostring( workshopId or "unknown" ), path, tostring( temporaryHandle ~= nil and temporaryHandle ~= false ), #candidates ) )
	return nil, bestError or "workshop_file_unreadable"
end

local function normalizeSteamFileId( value )
	if isstring( value ) then
		value = string.Trim( value )
		if string.match( value, "^%d+$" ) and value ~= "0" then return value end
	end
	local number = tonumber( value )
	if not number or number <= 0 then return nil end
	return string.format( "%.0f", number )
end

local function logWorkshopFileInfo( workshopId, info )
	if not istable( info ) then
		MsgN( string.format( "[MC Workshop] FileInfo %s returned no result", tostring( workshopId ) ) )
		return
	end
	MsgN( string.format(
		"[MC Workshop] FileInfo %s: fileid=%s size=%s installed=%s disabled=%s error=%s",
		tostring( workshopId ), tostring( info.fileid ), tostring( info.size ), tostring( info.installed ),
		tostring( info.disabled ), tostring( info.error )
	) )
end

local function acceptWorkshopBundle( import, payload )
	if Client.import ~= import then return end
	clearTimer( import.downloadTimer )
	clearTimer( import.fileInfoTimer )
	clearTimer( import.downloadRetryTimer )

	local worldBundle, archiveInfoOrError = W.DecodeWorkshopArchive( payload )
	if not worldBundle then
		setStatus( errorText( archiveInfoOrError ), true, false )
		clearImport( true )
		return
	end
	local decoded, decodeError = W.DecodeBundle( worldBundle )
	if not decoded then
		setStatus( errorText( decodeError ), true, false )
		clearImport( true )
		return
	end
	import.payload = payload
	import.bundle = worldBundle
	import.decoded = decoded
	import.archiveInfo = archiveInfoOrError
	import.contentHash = W.ContentHash( payload )
	setStatus( L( "workshop.awaiting_approval", "世界包已校验，正在等待服务端批准读取..." ), false, true )
	net.Start( "mc_workshop_load_request" )
		net.WriteUInt( import.requestId, 32 )
		net.WriteString( import.workshopId )
		net.WriteUInt( #payload, 32 )
		net.WriteString( import.contentHash )
		net.WriteString( decoded.metadata.name or "workshop_" .. import.workshopId )
		net.WriteString( decoded.metadata.map or "" )
		net.WriteUInt( math.Clamp( decoded.metadata.blocks or 0, 0, 4294967295 ), 32 )
		net.WriteUInt( math.Clamp( decoded.metadata.chunks or 0, 0, 4294967295 ), 32 )
		net.WriteBool( import.sharedLocal == true )
	net.SendToServer()
	import.timeoutTimer = "MC_WorkshopApprovalTimeout_" .. tostring( import.requestId )
	timer.Create( import.timeoutTimer, 30, 1, function()
		if Client.import == import then
			setStatus( errorText( "timeout" ), true, false )
			clearImport( true )
		end
	end )
end

local function failWorkshopDownload( import, readError )
	if Client.import ~= import then return end
	setStatus( errorText( readError or "workshop_file_unreadable" ), true, false )
	clearImport( true )
end

local function downloadWorkshopThroughLegacyHandle( import, readError )
	if Client.import ~= import or import.legacyDownloadStarted then return end
	import.legacyDownloadStarted = true
	local fileId = normalizeSteamFileId( import.fileInfo and import.fileInfo.fileid )
	if not fileId or not steamworks.Download then
		MsgN( string.format( "[MC Workshop] no legacy content file handle is available for %s", import.workshopId ) )
		failWorkshopDownload( import, readError )
		return
	end

	MsgN( string.format( "[MC Workshop] DownloadUGC failed for %s; downloading content fileid=%s into cache", import.workshopId, fileId ) )
	steamworks.Download( fileId, false, function( path )
		if Client.import ~= import then return end
		MsgN( string.format( "[MC Workshop] legacy content download %s returned path=%s", fileId, tostring( path ) ) )
		local bundle, legacyReadError = readWorkshopFile( path, nil, import.workshopId )
		if not bundle then
			failWorkshopDownload( import, legacyReadError or readError )
			return
		end
		acceptWorkshopBundle( import, bundle )
	end )
end

local function downloadWorkshopUGCAttempt( import, attempt )
	if Client.import ~= import then return end
	import.downloadAttempt = attempt
	MsgN( string.format( "[MC Workshop] DownloadUGC %s attempt %d/%d", import.workshopId, attempt, WORKSHOP_DOWNLOAD_ATTEMPTS ) )
	steamworks.DownloadUGC( import.workshopId, function( path, temporaryHandle )
		if Client.import ~= import then return end
		local bundle, readError = readWorkshopFile( path, temporaryHandle, import.workshopId )
		if bundle then
			acceptWorkshopBundle( import, bundle )
			return
		end

		MsgN( string.format( "[MC Workshop] DownloadUGC %s attempt %d failed (path=%s, handle=%s, error=%s)",
			import.workshopId, attempt, tostring( path ), tostring( temporaryHandle ~= nil and temporaryHandle ~= false ), tostring( readError ) ) )
		if attempt >= WORKSHOP_DOWNLOAD_ATTEMPTS then
			downloadWorkshopThroughLegacyHandle( import, readError )
			return
		end

		local delay = math.min( attempt, 4 )
		import.downloadRetryTimer = "MC_WorkshopDownloadRetry_" .. tostring( import.requestId )
		timer.Create( import.downloadRetryTimer, delay, 1, function()
			downloadWorkshopUGCAttempt( import, attempt + 1 )
		end )
	end )
end

local function startWorkshopDownload( import )
	if Client.import ~= import or import.downloadStarted then return end
	import.downloadStarted = true
	clearTimer( import.fileInfoTimer )
	import.downloadRetryTimer = "MC_WorkshopDownloadRetry_" .. tostring( import.requestId )
	timer.Create( import.downloadRetryTimer, 0.3, 1, function()
		downloadWorkshopUGCAttempt( import, 1 )
	end )
end

local function baseDownloadActive( base )
	return Client.baseRequirement == base and Client.baseDownload == base
end

local function reportBaseReady( base, ready, actualHash, err )
	if Client.baseRequirement ~= base then return end
	actualHash = string.lower( tostring( actualHash or "" ) )
	net.Start( "mc_workshop_base_ready" )
		net.WriteUInt( base.generation, 32 )
		net.WriteString( base.workshopId )
		net.WriteString( actualHash )
		net.WriteBool( ready == true )
		net.WriteString( tostring( err or "" ) )
	net.SendToServer()
	if ready then
		Client.baseReady = {
			generation = base.generation,
			workshopId = base.workshopId,
			contentHash = base.contentHash,
			packageId = base.packageId,
			archiveBytes = base.archiveBytes,
			cachePath = base.cachePath,
		}
		setBaseStatus( base, "ready" )
		MsgN( string.format( "[MC Workshop] base READY %s hash=%s", base.workshopId, base.contentHash ) )
	else
		Client.baseReady = nil
		setBaseStatus( base, "failed", err )
		MsgN( string.format( "[MC Workshop] base %s failed: %s", base.workshopId, tostring( err or "base_not_ready" ) ) )
	end
end

local function failBaseDownload( base, err, actualHash )
	if not baseDownloadActive( base ) then return end
	clearBaseDownload()
	reportBaseReady( base, false, actualHash, err or "workshop_file_unreadable" )
end

local function validateBasePayload( base, payload, softFail, alreadyCached )
	if not baseDownloadActive( base ) then return end
	local function reject( err, actualHash )
		if softFail then return false, err, actualHash end
		failBaseDownload( base, err, actualHash )
		return false, err, actualHash
	end
	if not isstring( payload ) or #payload < 17 or #payload > W.MAX_WORKSHOP_ARCHIVE_BYTES then
		return reject( "invalid_workshop_archive_size" )
	end
	if base.archiveBytes > 0 and #payload ~= base.archiveBytes then
		return reject( "size_mismatch" )
	end
	local actualHash
	if not base.packageId then
		actualHash = W.ContentHash( payload )
		if actualHash ~= base.contentHash then
			return reject( "hash_mismatch", actualHash )
		end
	end
	local bundle, archiveInfoOrError = W.DecodeWorkshopArchive( payload )
	if not bundle then
		return reject( archiveInfoOrError, actualHash )
	end
	local decoded, decodeError = W.DecodeBundle( bundle )
	if not decoded then
		return reject( decodeError, actualHash )
	end
	if base.packageId then
		if not istable( archiveInfoOrError ) or archiveInfoOrError.packageId ~= base.packageId then
			return reject( "package_mismatch" )
		end
		actualHash = W.WorkshopPackageContentHash( archiveInfoOrError.packageId )
		if actualHash ~= base.contentHash then return reject( "hash_mismatch", actualHash ) end
	end

	local cachePath = W.WorkshopArchiveCachePath( base.workshopId, base.contentHash )
	if not alreadyCached then
		local wrote, writeError
		if cachePath then
			wrote, writeError = writeDataBinary( cachePath, payload, "cache_write_failed" )
		else
			wrote, writeError = false, "cache_write_failed"
		end
		if not wrote then
			return reject( writeError or "cache_write_failed", actualHash )
		end
	end
	base.cachePath = cachePath
	base.decodedMetadata = decoded.metadata
	base.archiveInfo = archiveInfoOrError
	clearBaseDownload()
	reportBaseReady( base, true, actualHash )
	return true
end

local function readCachedBase( base )
	local cachePath = W.WorkshopArchiveCachePath( base.workshopId, base.contentHash )
	if not cachePath or not file.Exists( cachePath, "DATA" ) then return false end
	local handle = file.Open( cachePath, "rb", "DATA" )
	if not handle then file.Delete( cachePath ) return false end
	local payload = readOpenWorkshopHandle( handle, false )
	handle:Close()
	if not payload then file.Delete( cachePath ) return false end
	base.cachePath = cachePath
	local accepted = validateBasePayload( base, payload, true, true )
	if accepted then return true end
	file.Delete( cachePath )
	base.cachePath = nil
	return false
end

local function downloadBaseThroughLegacyHandle( base, readError )
	if not baseDownloadActive( base ) or base.legacyDownloadStarted then return end
	base.legacyDownloadStarted = true
	local fileId = normalizeSteamFileId( base.fileInfo and base.fileInfo.fileid )
	if not fileId or not steamworks.Download then
		failBaseDownload( base, readError )
		return
	end
	steamworks.Download( fileId, false, function( path )
		if not baseDownloadActive( base ) then return end
		local payload, legacyError = readWorkshopFile( path, nil, base.workshopId )
		if not payload then
			failBaseDownload( base, legacyError or readError )
			return
		end
		validateBasePayload( base, payload )
	end )
end

local function downloadBaseUGCAttempt( base, attempt )
	if not baseDownloadActive( base ) then return end
	base.downloadAttempt = attempt
	steamworks.DownloadUGC( base.workshopId, function( path, temporaryHandle )
		if not baseDownloadActive( base ) then return end
		local payload, readError = readWorkshopFile( path, temporaryHandle, base.workshopId )
		if payload then
			validateBasePayload( base, payload )
			return
		end
		if attempt >= WORKSHOP_DOWNLOAD_ATTEMPTS then
			downloadBaseThroughLegacyHandle( base, readError )
			return
		end
		base.downloadRetryTimer = "MC_WorkshopBaseRetry_" .. tostring( base.generation )
		timer.Create( base.downloadRetryTimer, math.min( attempt, 4 ), 1, function()
			downloadBaseUGCAttempt( base, attempt + 1 )
		end )
	end )
end

local function startBaseDownload( base )
	if not baseDownloadActive( base ) or base.downloadStarted then return end
	base.downloadStarted = true
	clearTimer( base.fileInfoTimer )
	base.downloadRetryTimer = "MC_WorkshopBaseRetry_" .. tostring( base.generation )
	timer.Create( base.downloadRetryTimer, 0.3, 1, function()
		downloadBaseUGCAttempt( base, 1 )
	end )
end

local function beginBaseRequirement( base )
	clearBaseDownload()
	Client.baseDownload = base
	setBaseStatus( base, "checking" )

	local import = Client.import
	if import and import.workshopId == base.workshopId and import.contentHash == base.contentHash and import.payload then
		validateBasePayload( base, import.payload )
		return
	end
	if readCachedBase( base ) then return end
	if not steamworks or not steamworks.DownloadUGC then
		failBaseDownload( base, "steamworks_unavailable" )
		return
	end

	setBaseStatus( base, "downloading" )
	base.downloadTimer = "MC_WorkshopBaseTimeout_" .. tostring( base.generation )
	timer.Create( base.downloadTimer, WORKSHOP_DOWNLOAD_TIMEOUT, 1, function()
		if baseDownloadActive( base ) then failBaseDownload( base, "timeout" ) end
	end )
	if steamworks.FileInfo then
		base.fileInfoTimer = "MC_WorkshopBaseFileInfo_" .. tostring( base.generation )
		timer.Create( base.fileInfoTimer, WORKSHOP_FILEINFO_TIMEOUT, 1, function()
			if baseDownloadActive( base ) then startBaseDownload( base ) end
		end )
		local ok = pcall( steamworks.FileInfo, base.workshopId, function( info )
			if not baseDownloadActive( base ) then return end
			base.fileInfo = info
			logWorkshopFileInfo( base.workshopId, info )
			startBaseDownload( base )
		end )
		if not ok then startBaseDownload( base ) end
	else
		startBaseDownload( base )
	end
end

function W.ImportWorkshopId( workshopId )
	workshopId = W.NormalizeWorkshopId( workshopId )
	if not workshopId then setStatus( errorText( "invalid_workshop_id" ), true, false ) return false end
	if not W.ClientCanManage() then setStatus( errorText( "permission" ), true, false ) return false end
	if W.ClientBusy() then setStatus( errorText( "transfer_busy" ), true, false ) return false end
	if not steamworks or not steamworks.DownloadUGC then setStatus( errorText( "steamworks_unavailable" ), true, false ) return false end

	local import = {
		requestId = nextRequestId(),
		workshopId = workshopId,
		sharedLocal = W.ClientCanShareListenData(),
	}
	Client.import = import
	setStatus( L( "workshop.downloading", "正在从创意工坊下载 {id}...", { id = workshopId } ), false, true )
	import.downloadTimer = "MC_WorkshopDownloadTimeout_" .. tostring( import.requestId )
	timer.Create( import.downloadTimer, WORKSHOP_DOWNLOAD_TIMEOUT, 1, function()
		if Client.import == import then
			setStatus( errorText( "timeout" ), true, false )
			clearImport( true )
		end
	end )

	if steamworks.FileInfo then
		import.fileInfoTimer = "MC_WorkshopFileInfoTimeout_" .. tostring( import.requestId )
		timer.Create( import.fileInfoTimer, WORKSHOP_FILEINFO_TIMEOUT, 1, function()
			if Client.import ~= import then return end
			MsgN( string.format( "[MC Workshop] FileInfo %s timed out; continuing with DownloadUGC", workshopId ) )
			startWorkshopDownload( import )
		end )
		local ok, fileInfoError = pcall( steamworks.FileInfo, workshopId, function( info )
			if Client.import ~= import then return end
			import.fileInfo = info
			logWorkshopFileInfo( workshopId, info )
			startWorkshopDownload( import )
		end )
		if not ok then
			MsgN( string.format( "[MC Workshop] FileInfo %s raised an error: %s", workshopId, tostring( fileInfoError ) ) )
			startWorkshopDownload( import )
		end
	else
		startWorkshopDownload( import )
	end
	return true
end

function W.PromptImport()
	if W.ClientBusy() then setStatus( errorText( "transfer_busy" ), true, false ) return end
	Derma_StringRequest(
		L( "workshop.import_title", "读取创意工坊世界" ),
		L( "workshop.import_prompt", "输入 Workshop ID 或 Steam 创意工坊链接。客户端会先下载并校验，服务端批准后才接收和读取。" ),
		"",
		function( value )
			local workshopId = W.NormalizeWorkshopId( value )
			if not workshopId then
				W.ImportWorkshopId( value )
				return
			end
			if not game.IsDedicated or not game.IsDedicated() then
				W.ImportWorkshopId( workshopId )
				return
			end

			Derma_Query(
				L( "workshop.import_dedicated_body",
					"当前连接的是专用服务器。完整 GMA 将由你的客户端从 Steam 下载并校验，再通过游戏网络上传给服务器。大世界可能消耗较多上行流量，并需要数分钟。是否继续？" ),
				L( "workshop.import_dedicated_title", "专用服务器传输: {id}", { id = workshopId } ),
				L( "workshop.import_dedicated_continue", "继续传输" ),
				function() W.ImportWorkshopId( workshopId ) end,
				L( "save.cancel", "取消" )
			)
		end,
		nil,
		L( "workshop.import", "读取创意工坊" ),
		L( "save.cancel", "取消" )
	)
end

net.Receive( "mc_workshop_load_approval", function()
	local requestId = net.ReadUInt( 32 )
	local approved = net.ReadBool()
	local token = net.ReadString()
	local err = net.ReadString()
	local import = Client.import
	if not import or import.requestId ~= requestId then return end
	clearTimer( import.timeoutTimer )
	if not approved then
		setStatus( errorText( err ), true, false )
		clearImport( true )
		return
	end
	if token == "" or not import.payload then
		setStatus( errorText( "approval_mismatch" ), true, false )
		clearImport( true )
		return
	end

	import.token = token
	if import.sharedLocal then
		local ply = LocalPlayer()
		local sharedPath = IsValid( ply ) and W.ListenSharedArchivePath( ply:SteamID64(), import.requestId, import.contentHash ) or nil
		if not sharedPath then
			setStatus( errorText( "shared_unavailable" ), true, false )
			clearImport( true )
			return
		end
		import.sharedPath = sharedPath
		setStatus( L( "workshop.reading_shared", "服务端已批准，正在通过 Listen Server 共享目录读取并再次校验世界包..." ), false, true )
		local wrote, writeError = writeDataBinary( sharedPath, import.payload )
		net.Start( "mc_workshop_shared_ready" )
			net.WriteUInt( import.requestId, 32 )
			net.WriteString( token )
			net.WriteString( import.workshopId )
			net.WriteUInt( #import.payload, 32 )
			net.WriteString( import.contentHash )
			net.WriteBool( wrote == true )
			net.WriteString( wrote and "" or tostring( writeError or "shared_write_failed" ) )
		net.SendToServer()
		if not wrote then
			setStatus( errorText( writeError ), true, false )
			clearImport( true )
			return
		end
		import.timeoutTimer = "MC_WorkshopSharedTimeout_" .. tostring( import.requestId )
		timer.Create( import.timeoutTimer, 120, 1, function()
			if Client.import == import then
				setStatus( errorText( "timeout" ), true, false )
				clearImport( true )
			end
		end )
		return
	end

	local parts = math.ceil( #import.payload / W.UPLOAD_PART_BYTES )
	setStatus( L( "workshop.uploading", "服务端已批准，正在上传并再次校验世界包..." ), false, true )
	net.Start( "mc_workshop_upload_begin" )
		net.WriteUInt( import.requestId, 32 )
		net.WriteString( token )
		net.WriteString( import.workshopId )
		net.WriteUInt( #import.payload, 32 )
		net.WriteUInt( parts, 16 )
		net.WriteString( import.contentHash )
	net.SendToServer()

	local part = 1
	local function sendNextPart()
		if Client.import ~= import or part > parts then return end
		local first = ( part - 1 ) * W.UPLOAD_PART_BYTES + 1
		local chunk = string.sub( import.payload, first, first + W.UPLOAD_PART_BYTES - 1 )
		net.Start( "mc_workshop_upload_part" )
			net.WriteUInt( import.requestId, 32 )
			net.WriteString( token )
			net.WriteUInt( part, 16 )
			net.WriteUInt( #chunk, 16 )
			net.WriteData( chunk, #chunk )
		net.SendToServer()
		part = part + 1
		if part <= parts then timer.Simple( W.UPLOAD_PART_INTERVAL, sendNextPart ) end
	end
	sendNextPart()
	import.timeoutTimer = "MC_WorkshopUploadTimeout_" .. tostring( import.requestId )
	local uploadTimeout = math.Clamp( 90 + #import.payload / 100000, 330, W.UPLOAD_TIMEOUT_MAX + 30 )
	timer.Create( import.timeoutTimer, uploadTimeout, 1, function()
		if Client.import == import then
			setStatus( errorText( "timeout" ), true, false )
			clearImport( true )
		end
	end )
end )

net.Receive( "mc_workshop_upload_result", function()
	local requestId = net.ReadUInt( 32 )
	local ok = net.ReadBool()
	local err = net.ReadString()
	local slotName = net.ReadString()
	local workshopId = net.ReadString()
	local import = Client.import
	if not import or import.requestId ~= requestId then return end
	if ok then
		setStatus( L( "workshop.import_done", "已从创意工坊读取: {name}", { name = slotName } ), false, false )
		MC.SaveManagerPendingSelection = slotName
	else
		setStatus( errorText( err ), true, false )
	end
	clearImport( true )
end )

net.Receive( "mc_workshop_base_announce", function()
	local generation = net.ReadUInt( 32 )
	local active = net.ReadBool()
	if not active then
		clearBaseDownload()
		Client.baseRequirement = nil
		Client.baseReady = nil
		setBaseStatus( nil, "inactive" )
		return
	end

	local workshopId = W.NormalizeWorkshopId( net.ReadString() )
	local contentHash = string.lower( net.ReadString() or "" )
	local archiveBytes = net.ReadUInt( 32 )
	local slotName = W.SafeSlotName( net.ReadString() )
	local rawPackageId = net.ReadString()
	local packageId = rawPackageId ~= "" and W.SafeSlotName( rawPackageId ) or nil
	if generation < 1 or not workshopId or not W.IsContentHash( contentHash )
		or archiveBytes > W.MAX_WORKSHOP_ARCHIVE_BYTES or not slotName
		or rawPackageId ~= "" and not packageId
		or packageId and W.WorkshopPackageContentHash( packageId ) ~= contentHash then
		MsgN( "[MC Workshop] rejected invalid base announcement" )
		return
	end

	local current = Client.baseRequirement
	if current and current.generation == generation and current.workshopId == workshopId
		and current.contentHash == contentHash and current.packageId == packageId then
		local ready = Client.baseReady
		if ready and ready.generation == generation and ready.contentHash == contentHash then
			reportBaseReady( current, true, contentHash )
		elseif Client.baseDownload ~= current then
			timer.Simple( 0, function()
				if Client.baseRequirement == current then beginBaseRequirement( current ) end
			end )
		end
		return
	end

	clearBaseDownload()
	local base = {
		generation = generation,
		workshopId = workshopId,
		contentHash = contentHash,
		archiveBytes = archiveBytes,
		slotName = slotName,
		packageId = packageId,
	}
	Client.baseRequirement = base
	Client.baseReady = nil
	timer.Simple( 0, function()
		if Client.baseRequirement == base then beginBaseRequirement( base ) end
	end )
end )

function W.GetClientBaseReadiness()
	local status = Client.baseStatus or { status = "inactive" }
	return table.Copy( status )
end

function W.ViewFile( workshopId )
	workshopId = W.NormalizeWorkshopId( workshopId )
	if not workshopId then setStatus( errorText( "invalid_workshop_id" ), true, false ) return false end
	if not steamworks or not steamworks.ViewFile then setStatus( errorText( "steamworks_unavailable" ), true, false ) return false end
	steamworks.ViewFile( workshopId )
	return true
end

MC.PublishSaveToWorkshop = W.PublishSave
MC.PromptWorkshopImport = W.PromptImport
MC.ImportWorkshopSave = W.ImportWorkshopId
MC.ViewWorkshopFile = W.ViewFile
MC.CanManageWorkshop = W.ClientCanManage
MC.WorkshopBusy = W.ClientBusy
MC.WorkshopBaseReadiness = W.GetClientBaseReadiness
