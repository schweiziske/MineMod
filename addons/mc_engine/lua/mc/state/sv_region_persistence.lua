--[[----------------------------------------------------------------------------
	Directory-based MCB4 persistence adapter.

	New saves live at data/mc/saves/<name>/manifest.json. The legacy persistence
	implementation in sv_world.lua remains available for existing .dat files.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local legacySaveToPath = SV.SaveToPath

local function normalizedPath( path )
	return string.gsub( tostring( path or "" ), "\\", "/" )
end

local function isRegionManifest( path )
	return string.EndsWith( normalizedPath( path ), "/manifest.json" )
end

local function defaultManifestPath()
	return "mc/saves/" .. game.GetMap() .. "/manifest.json"
end

local function legacyDefaultPath()
	return "mc/" .. game.GetMap() .. ".dat"
end

local function saveLazyOverlay( path, slotName, finish )
	local store = SV.ChunkStore
	if not store or not store.IsLazyWorld or not store.IsLazyWorld() or not store.SaveOverlay then return nil end
	local activePath = normalizedPath( store.ManifestPath )
	if activePath ~= "" and string.lower( activePath ) ~= string.lower( normalizedPath( path ) ) then
		if slotName then return finish( false, "lazy_save_as_unsupported" ) end
		path = activePath
	end
	local overlay = store.SaveOverlay()
	local json = util.TableToJSON( overlay )
	if not json then return finish( false, "overlay_json_failed" ) end
	local overlayPath = store.EditOverlayPath or ( string.GetPathFromFilename( path ) .. "edits.json" )
	local written, writeError = SV.WriteStateSaveFile( overlayPath, json )
	if not written then return finish( false, writeError or "overlay_write_failed" ) end
	MsgN( "[MC] saved lazy edit overlay / " .. SV.BlockCount .. " blocks" ..
		( slotName and ( " as \"" .. slotName .. "\" on map " .. game.GetMap() ) or "" ) )
	return finish( true, path, overlay, 0, SV.BlockCount )
end

function SV.SaveToPath( path, slotName )
	if not isRegionManifest( path ) then return legacySaveToPath( path, slotName ) end
	if SV.SaveInProgress then return false, "save_in_progress" end
	SV.SaveInProgress = true
	local isDefault = string.lower( normalizedPath( path ) ) == string.lower( defaultManifestPath() )
	local function finish( ok, ... )
		if ok and isDefault then SV.Dirty = false end
		SV.SaveInProgress = false
		if ok and MC.RunEvent then
			-- Directory MCB4 saves never reach sv_world.lua's finishSave, so
			-- MC.WorldSaved is announced here instead. The lazy-overlay path
			-- can redirect to the store's active manifest, so report the path
			-- actually written (first result) rather than the requested one.
			local writtenPath = ...
			MC.RunEvent( "MC.WorldSaved", writtenPath or path, slotName )
		end
		return ok, ...
	end
	local lazyResult = { saveLazyOverlay( path, slotName, finish ) }
	if lazyResult[1] ~= nil then return unpack( lazyResult ) end
	if not SV.WriteStateRegionSave then return finish( false, "region_save_codec_unavailable" ) end
	local data, chunks, blocks = SV.WriteStateRegionSave( path, slotName )
	if not data then return finish( false, chunks or "region_save_failed" ) end
	MsgN( "[MC] saved " .. chunks .. " chunks / " .. blocks .. " blocks" ..
		( slotName and ( " as \"" .. slotName .. "\" on map " .. game.GetMap() ) or "" ) )
	return finish( true, path, data, chunks, blocks )
end

function SV.DefaultSavePath()
	return defaultManifestPath()
end

function SV.Save( slotName )
	if slotName ~= nil and string.Trim( tostring( slotName ) ) ~= "" and SV.SaveNamed then
		return SV.SaveNamed( slotName )
	end
	return SV.SaveToPath( defaultManifestPath() )
end

function SV.Load()
	local path = file.Exists( defaultManifestPath(), "DATA" ) and defaultManifestPath() or legacyDefaultPath()
	return SV.LoadFromPath( path, false )
end
