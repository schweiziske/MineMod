-- Client atlas-pack catalog and apply coordinator. No VGUI dependencies.
-- Prepared sources and published atlases share one request/status interface.
MC.ResourcePacks = MC.ResourcePacks or {}
local R = MC.ResourcePacks
R.jobs, R.serial = R.jobs or {}, R.serial or 0
local HOOK = "mc_resource_pack_apply"

function R.ListPacks()
	local entries, byName = MC.ListTexturePacks(), {}
	for _, entry in ipairs( entries ) do
		entry.available = entry.runtime == true or entry.inheritBase == true or entry.name == MC.TexturePackName()
		if not entry.available and entry.opaquePath then
			entry.available = file.Exists( "materials/" .. entry.opaquePath:gsub( "%.png$", "" ) .. ".png", "GAME" )
		end
		byName[entry.name] = entry
		if entry.name == "default" then
			entry.resourceSource, entry.sourceOwner = true, "texturepack.default"
			entry.available = MC.ResourceGeneration.Available()
		end
	end
	for _, source in ipairs( MC.AtlasBaker.ListSourcePacks() ) do
		local entry = byName[source.name]
		if entry and entry.owner == source.owner then
			entry.bakeID, entry.sourceOwner, entry.prepared, entry.pbr = source.bakeID, source.owner, source.prepared, source.pbr
			entry.title, entry.description, entry.preview = source.title, source.description, source.preview
			entry.available = entry.available or source.prepared
		elseif not entry then
			source.available, source.sourceOwner = source.prepared, source.owner
			entries[#entries + 1], byName[source.name] = source, source
		end
	end
	if MC.ResourceRepository then
		local repository = MC.ResourceRepository
		if repository.revision == 0 then repository.Refresh() end
		for _, source in ipairs(repository.GetCatalog().entries) do
			if source.id ~= "mc_default_raw" then
				local entry = byName[source.id]
				if entry then
					for key, value in pairs(source) do entry[key] = value end
				else
					entry = source
					entries[#entries+1] = entry
				end
				entry.available = not entry.error and MC.ResourceGeneration.Available()
			end
		end
		if byName.default and repository.baseError then
			byName.default.available, byName.default.error = false, repository.baseError
		end
	end
	return entries
end

local function findPack( name )
	for _, entry in ipairs( R.ListPacks() ) do if entry.name == name then return entry end end
end

function R.GetSelection()
	return { preference = MC.TexturePack:GetString(), active = MC.TexturePackName(), leaseOwner = MC.TexturePackLeaseOwner() }
end

function R.IsApplying() return R.job ~= nil end

function R.GetApplyStatus( id )
	if id == nil then id = R.lastId end
	if id == nil then return { state = "idle" } end
	if type( id ) ~= "number" or id < 1 or id ~= math.floor( id ) then return nil, "invalid_apply_job" end
	local job = R.jobs[id]
	if not job then return nil, "apply_job_not_found" end
	local status = { id = job.id, name = job.name, state = job.state, error = job.error, rebuilt = job.rebuilt,
		started = job.started, finished = job.finished, bakeSerial = job.bakeSerial,
		phase = job.phase, prepareMS = job.prepareMS, buildMS = job.buildMS, cacheError = job.cacheError,
		completed=job.completed,total=job.total,yields=job.yields,raw=job.raw }
	if job.state == "baking" then
		local bake = MC.AtlasBaker.Status()
		if bake.serial == job.bakeSerial then
			status.phase, status.loaded, status.sources, status.drawn, status.tiles = bake.state, bake.loaded, bake.sources, bake.drawn, bake.tiles
		end
	end
	return status
end

local function changed( job )
	local status = R.GetApplyStatus( job.id )
	hook.Run( "MC.ResourcePackApplyChanged", status )
end

local function finish( job, state, err )
	job.state, job.error, job.finished = state, err, SysTime()
	if job.bootstrap and (err == "texture_pack_selection_changed" or err == "texture_pack_controlled_by_mode"
		or err == "resource_apply_cancelled" and not job.cancelRequested) then
		R.defaultAttempt = nil
	end
	if R.job == job then R.job = nil end
	changed( job )
	if state == "ready" then
		local status = R.GetApplyStatus( job.id )
		hook.Run( "MC.ResourcePackApplied", status )
	end
end

local function commit( job )
	-- Revalidate only across the asynchronous boundary, never in draw loops.
	local selection = R.GetSelection()
	if selection.leaseOwner then finish( job, "failed", "texture_pack_controlled_by_mode" ) return end
	if selection.preference ~= job.preference and selection.preference ~= job.name then
		finish( job, "cancelled", "texture_pack_selection_changed" ) return
	end
	if job.rebuilt then
		local entry = findPack( job.name )
		if not entry or not entry.runtime or entry.owner ~= job.sourceOwner then
			finish( job, "failed", "atlas_bake_not_registered" )
			MC.Fault( "resource_pack_bake_publish", "Completed atlas %s is not registered", job.name )
			return
		end
	end
	job.state = "applying"
	local ok, err = MC.SetTexturePackPreference( job.name )
	if not ok then
		finish( job, "failed", tostring( err ) )
		MC.Fault( "resource_pack_apply", "Could not select %s: %s", job.name, tostring( err ) )
		return
	end
	finish( job, "ready" )
end

local RAW_OWNER = "mc.resourcepacks.runtime"
R.rawGenerations = R.rawGenerations or {}
local function retireRaw(generation)
	-- The default is the required fallback and stays resident across selections.
	if generation.pack == "default" then return true end
	if R.activeGeneration == generation then return false end
	if MC.TexturePackName() == generation.pack then return false end
	if MC.TexturePackDefinitionOwner(generation.pack) == RAW_OWNER then
		local ok, err = MC.UnregisterTexturePack(generation.pack, RAW_OWNER)
		if not ok then return false, err end
	end
	local ok, err = MC.UnregisterAtlasProfile(generation.profile, generation.owner or RAW_OWNER)
	if not ok then return false, err end
	ok, err = MC.ResourceGeneration.Release(generation)
	if not ok then return false, err end
	R.rawGenerations[generation] = nil
	return true
end

local function beginRaw(name, entry, options, force)
	local repository = MC.ResourceRepository
	if options ~= nil and type(options) ~= "table" then return false, "resource_compile_arguments" end
	options = table.Copy(options or {})
	local ids = name == "default" and {} or {name}
	local selection, err = repository.ValidateSelection(ids, repository.revision, options.confirmed)
	if not selection then return false, err end
	R.serial = R.serial + 1
	local job = {id=R.serial, name=name, preference=MC.TexturePack:GetString(), previousPack=MC.TexturePackName(), state="baking", raw=true, force=force,
		started=SysTime(), sourceOwner=name == "default" and "texturepack.default" or RAW_OWNER,
		title=entry.title, description=entry.description, preview=entry.preview,
		catalogRevision=repository.revision, selection=selection, options=options,
		previousGeneration=R.activeGeneration}
	R.jobs[job.id], R.job, R.lastId = job, job, job.id
	R.jobs[job.id-32] = nil
	changed(job)
	return true, job.id
end

local function applyRaw(job)
	if MC.TexturePackLeaseOwner() then return nil, "texture_pack_controlled_by_mode" end
	if MC.TexturePack:GetString() ~= job.preference then return nil, "texture_pack_selection_changed" end
	local before = SysTime()
	local nextPresentation=before+5
	local function checkpoint(phase,completed,total)
		if completed then job.phase,job.completed,job.total=phase,completed,total end
		if SysTime()<nextPresentation then return end
		job.yields=(job.yields or 0)+1
		changed(job)
		coroutine.yield()
		-- No GPU state is held at these boundaries. Revalidate the request on
		-- resume, before touching or publishing any candidate textures.
		if job.cancelRequested or MC.TexturePackLeaseOwner() or MC.TexturePack:GetString()~=job.preference
			or MC.ResourceRepository.revision~=job.catalogRevision then error("resource_apply_cancelled",0) end
		nextPresentation=SysTime()+5
	end
	local plan, reason = MC.ResourceCompiler.PrepareTiles(job.selection, job.catalogRevision, job.options, checkpoint)
	if not plan then return nil, reason end
	job.prepareMS = (SysTime()-before)*1000
	local generation
	before = SysTime()
	generation, reason = MC.ResourceGeneration.Build(plan, checkpoint)
	if not generation then return nil, reason end
	job.buildMS = (SysTime()-before)*1000
	job.candidate = generation
	generation.pack, generation.profile = job.name, "mc_resource_layout_" .. generation.slot
	generation.owner = job.sourceOwner
	local color
	color, reason = MC.ResourceGeneration.Texture(generation)
	if not color then return nil, reason end
	local item
	item, reason = MC.ResourceGeneration.Texture(generation, "item")
	if not item then return nil, reason end
	local maps
	if plan.pbr then
		maps = {colorSpace="srgb"}
		for _, channel in ipairs({"normal", "orm"}) do
			maps[channel], reason = MC.ResourceGeneration.Texture(generation, channel)
			if not maps[channel] then return nil, reason end
		end
	end
	local regions = {} for i, region in ipairs(plan.layout.regions) do regions[i-1] = region end
	local ok
	ok, reason = MC.RegisterAtlasProfile(generation.profile, {W=plan.layout.width, H=plan.layout.height,
		MIP=plan.layout.mip, INSET=0, REGIONS=regions, tiles=plan.byTile, fallback=plan.byTile[MC.Tiles.missing or 0] or 0}, job.sourceOwner)
	if not ok then return nil, reason end
	job.profileRegistered = true
	job.previousDefinition = MC.TexturePackDefinitions[job.name]
	if job.previousDefinition and job.previousDefinition.owner ~= job.sourceOwner then return nil, "resource_pack_name_owned" end
	ok, reason = MC.RegisterTexturePack(job.name, {title=job.title or job.name, description=job.description, preview=job.preview,
		runtimeTexture=color, runtimeIconTexture=item, runtimePBR=maps,
		atlasProfile=generation.profile}, job.sourceOwner, true)
	if not ok then return nil, reason end
	job.packRegistered = true
	local runtime = MC.RenderPackRuntime
	if not runtime or not runtime.BeginAtlasTransition then return nil, "resource_pack_runtime_unavailable" end
	ok, reason = runtime.BeginAtlasTransition()
	if not ok then return nil, reason end
	job.transition = true
	job.switchAttempted = true
	ok, reason = MC.SetTexturePack(job.name)
	if not ok then return nil, reason end
	generation.startedAt, generation.byTile = CurTime(), plan.byTile
	R.activeGeneration = generation
	job.state, job.phase, job.bindingStarted = "applying", "waiting_meshes", SysTime()
	changed(job)
	return true
end

local function publishRaw(job)
	local generation = job.candidate
	if MC.PrepareResourcePackAnimations then
		local prepared, err = MC.PrepareResourcePackAnimations()
		if not prepared then return nil, err end
	end
	if not job.bootstrap then
		local ok, reason = MC.SetTexturePackPreference(job.name)
		if not ok then return nil, reason end
	end
	R.rawGenerations[generation] = true
	job.candidate, job.rebuilt, job.phase = nil, true, nil
	MC.RenderPackRuntime.EndAtlasTransition()
	if generation.cache then
		local cached, err = generation.cache:Commit()
		job.cacheError = not cached and err or nil
		generation.cache:Close()
		generation.cache = nil
	end
	if not job.bootstrap then
		file.CreateDir("mc/resourcepacks")
		file.Write("mc/resourcepacks/selection.json", util.TableToJSON({name=job.name, options=job.options}))
	end
	for previous in pairs(R.rawGenerations) do
		if previous ~= generation then
			-- Same-name replacement has already installed the new definition.
			if previous.pack == generation.pack then
				local removed, err = MC.UnregisterAtlasProfile(previous.profile, previous.owner or RAW_OWNER)
				if not removed then error("resource_profile_retire:" .. tostring(err), 0) end
				local released, releaseError = MC.ResourceGeneration.Release(previous)
				if not released then error("resource_generation_retire:" .. tostring(releaseError), 0) end
				R.rawGenerations[previous] = nil
			else
				local retired, err = retireRaw(previous)
				if not retired then error("resource_generation_retire:" .. tostring(err), 0) end
			end
		end
	end
	return true
end

local function discardRaw(job)
	if not job.candidate then return end
	-- A strict fault in one restore operation must not prevent the remaining
	-- ownership cleanup. Report only after the candidate is detached/released.
	local failures = {}
	local function restore(fn, ...)
		local called, ok, err = pcall(fn, ...)
		if not called or not ok then failures[#failures+1] = tostring(called and err or ok) end
	end
	if job.packRegistered then
		if job.previousDefinition then
			restore(MC.RegisterTexturePack, job.name, job.previousDefinition, job.sourceOwner, true)
		end
	end
	R.activeGeneration = job.previousGeneration
	if job.switchAttempted then
		-- Respect a mode/user takeover while a mesh candidate was pending.
		local target = job.previousPack
		if MC.TexturePackLeaseOwner() or MC.TexturePack:GetString() ~= job.preference then target = MC.TexturePackName() end
		restore(MC.SetTexturePack, target)
	end
	if job.packRegistered and not job.previousDefinition then restore(MC.UnregisterTexturePack, job.name, job.sourceOwner) end
	if job.transition then
		restore(MC.RenderPackRuntime.ResetAtlasBindings)
		if MC.TexturePackPending then
			MC.RenderPackRuntime.EndAtlasTransition()
			R.recovering = nil
		else R.recovering = true end
	end
	if job.profileRegistered then restore(MC.UnregisterAtlasProfile, job.candidate.profile, job.sourceOwner) end
	restore(MC.ResourceGeneration.Release, job.candidate)
	job.candidate = nil
	return #failures == 0, table.concat(failures, "; ")
end

local function apply( name, force, options )
	if type( name ) ~= "string" then return false, "invalid_texture_pack_name" end
	local entry = findPack( name )
	if not entry then return false, "texture_pack_not_registered" end
	if not entry.available then return false, entry.error or "missing_atlas_" .. name end
	if MC.TexturePackLeaseOwner() then return false, "texture_pack_controlled_by_mode" end
	if force and not entry.bakeID and not entry.resourceSource then return false, "pack_has_no_bake_source" end
	if R.job then
		if R.job.name == name and R.job.force == force then return true, R.job.id end
		return false, "resource_pack_apply_running"
	end
	if entry.resourceSource and (name ~= "default" or force or not entry.runtime) then
		return beginRaw(name, entry, options, force)
	end
	local rebuild = entry.bakeID ~= nil and ( force or not entry.runtime )
	local preference = MC.TexturePack:GetString()
	local baker, ownsBake = MC.AtlasBaker, false
	if rebuild then
		if baker.IsBusy() then
			if baker.Status().pack ~= name then return false, "bake_already_running" end
		else
			local ok, err = baker.Start( entry.bakeID )
			if not ok then return false, err end
			ownsBake = true
		end
	end
	R.serial = R.serial + 1
	local job = { id = R.serial, name = name, preference = preference, sourceOwner = entry.sourceOwner,
		state = rebuild and "baking" or "applying", rebuilt = rebuild, force = force, started = SysTime(), ownsBake = ownsBake }
	if rebuild then job.bakeSerial = baker.Status().serial end
	R.jobs[job.id], R.job, R.lastId = job, job, job.id
	R.jobs[job.id - 32] = nil
	if rebuild then changed( job ) else commit( job ) end
	return true, job.id
end

function R.ApplyPack( name, options ) return apply( name, false, options ) end
function R.ReloadPack( name, options ) return apply( name, true, options ) end

function R.CancelApply( id )
	local job = R.job
	if not job or job.id ~= id then return false, "apply_job_not_pending" end
	if job.raw and job.state=="building" then job.cancelRequested=true return true end
	if job.state ~= "baking" then return false, "apply_job_not_cancellable" end
	if job.raw then finish(job, "cancelled", "resource_apply_cancelled") return true end
	local baker = MC.AtlasBaker
	finish( job, "cancelled", "atlas_bake_cancelled" )
	if job.ownsBake and baker.IsBusy() and baker.Status().serial == job.bakeSerial then baker.Cancel() end
	return true
end

-- Archived ConVars can arrive after Lua startup. Attempt each preference once
-- per explicit catalog revision. Missing/broken packs keep the default usable
-- without erasing the saved name or retrying a failed bake every frame.
function R.RestorePreference()
	if R.job or R.recovering or MC.TexturePackLeaseOwner() or not MC.ResourceRepository then return end
	local repository = MC.ResourceRepository
	if repository.revision == 0 then repository.Refresh() end
	local default = MC.TexturePackDefinitions.default
	if default and default.pending then
		if R.defaultAttempt == repository.revision then return end
		R.defaultAttempt = repository.revision
		local ok, err = R.ApplyPack("default")
		if ok then R.job.bootstrap = true
		else
			R.restoreError = tostring(err)
			MC.Fault("resource_default_bake", "%s", tostring(err))
		end
		return
	end
	local name = MC.TexturePack:GetString()
	if MC.TexturePackDefinitions[name] then
		if MC.TexturePackName() ~= name then
			local ok, err = MC.SetTexturePack(name)
			if not ok then MC.Fault("resource_preference_restore", "%s", tostring(err)) end
		end
		return
	end
	local attempt = name .. ":" .. repository.revision
	if R.restoreAttempt == attempt then return end
	R.restoreAttempt = attempt
	local entry = repository.byID[name]
	if not entry then return end
	local options
	local bytes = file.Read("mc/resourcepacks/selection.json", "DATA")
	if bytes and #bytes <= 65536 then
		local saved = MC.ResourcePackRules.DecodeJSON(bytes)
		if saved and saved.name == name and type(saved.options) == "table" then options = saved.options end
	end
	local ok, err = R.ApplyPack(name, options)
	if not ok then R.restoreError = tostring(err) end
end

-- Autorefresh must not leave a request dependent on an obsolete completion closure.
if R.job then R.CancelApply( R.job.id ) end
hook.Add( "MC.AtlasBakeChanged", HOOK, function( status )
	local job = R.job
	if not job or status.serial ~= job.bakeSerial then return end
	if status.state == "ready" then commit( job )
	elseif status.state == "failed" then finish( job, "failed", status.error )
	elseif status.state == "cancelled" then finish( job, "cancelled", "atlas_bake_cancelled" ) end
end )

-- Run continuously, allowing one presentation frame only after five seconds
-- of work. Geometry retains its own scheduler and commit boundary.
hook.Add("PostRender", HOOK, function()
	local job = R.job
	if job and job.raw then
		local ok, applied, err
		if job.state == "baking" or job.state=="building" then
			job.state = "building"
			if not job.worker then job.worker=coroutine.create(function() return applyRaw(job) end) end
			ok,applied,err=coroutine.resume(job.worker)
			if ok and coroutine.status(job.worker)~="dead" then applied=true
			else job.worker=nil end
		else
			ok = true
			if MC.TexturePackLeaseOwner() then applied, err = false, "texture_pack_controlled_by_mode"
			elseif MC.TexturePack:GetString() ~= job.preference then applied, err = false, "texture_pack_selection_changed"
			elseif SysTime()-job.bindingStarted > 60 then applied, err = false, "resource_pack_mesh_timeout"
			else
				applied, err = MC.RenderPackRuntime.AtlasTransitionStatus()
				if applied then
					ok, applied, err = pcall(publishRaw, job)
					if ok and applied then finish(job, "ready") end
				elseif applied == nil then applied = true end
			end
		end
		if not ok or not applied then
			local restored, restoreError = discardRaw(job)
			local reason = ok and err or applied
			if type(reason) == "table" then reason = reason.message or reason.code end
			finish(job, reason=="resource_apply_cancelled" and "cancelled" or "failed", tostring(reason))
			if job.bootstrap then MC.Fault("resource_default_bake", "%s", tostring(reason)) end
			if restored == false then MC.Fault("resource_pack_restore", "%s", restoreError) end
			if not ok and reason~="resource_apply_cancelled" then MC.Fault("resource_pack_apply_internal", "%s", tostring(reason)) end
		end
	end
	if R.recovering then
		local ready, err = MC.RenderPackRuntime.AtlasTransitionStatus()
		if ready ~= nil then
			R.recovering = nil
			MC.RenderPackRuntime.EndAtlasTransition()
			if not ready then MC.Fault("resource_pack_render_restore", "%s", tostring(err)) end
		end
	end
	local active = R.activeGeneration
	if active and (MC.TexturePackName() == active.pack or MC.TexturePackDefinitionOwner(MC.TexturePackName()) ~= RAW_OWNER
		and MC.Material and MC.Material:GetTexture("$basetexture"):GetName() == active.texture.name) then
		local ok, err = MC.ResourceGeneration.Update(active, (CurTime()-active.startedAt)*20)
		if not ok then MC.Fault("resource_pack_animation", "%s", tostring(err)) end
	elseif active then
		if MC.RenderPackRuntime and MC.RenderPackRuntime.ResetAtlasBindings then MC.RenderPackRuntime.ResetAtlasBindings() end
		R.activeGeneration = nil
		local retired, err = retireRaw(active)
		if not retired then MC.Fault("resource_pack_retire", "%s", tostring(err)) end
	end
	-- SetTexturePack may already have rebound the active generation. Retire the
	-- detached selection only after its material bundles have been discarded.
	if not R.job and not R.recovering then
		for generation in pairs(R.rawGenerations) do
			if generation ~= R.activeGeneration and generation.pack ~= "default" then
				local reset, resetError = MC.RenderPackRuntime.ResetAtlasBindings()
				if not reset then MC.Fault("resource_pack_retire_bindings", "%s", tostring(resetError)) break end
				local retired, err = retireRaw(generation)
				if not retired then MC.Fault("resource_pack_retire", "%s", tostring(err)) end
			end
		end
	end
	R.RestorePreference()
end)

hook.Add("HUDPaint", "mc_resource_pack_loading", function()
	if not MC.TexturePackPending and not (MC.RenderPackRuntime and MC.RenderPackRuntime.atlasTransition) then return end
	local message = MC.TexturePackPending and "正在从 PNG 烘焙默认材质包…" or "正在准备材质包网格…"
	local status = R.lastId and R.jobs[R.lastId]
	if MC.TexturePackPending and status and (status.state == "failed" or status.state == "cancelled") then
		message = "默认材质包未就绪：" .. tostring(status.error)
	elseif MC.TexturePackPending and R.restoreError then
		message = "默认材质包未就绪：" .. R.restoreError
	end
	draw.SimpleText(message, "DermaDefaultBold", ScrW()/2, ScrH()/2,
		color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)
