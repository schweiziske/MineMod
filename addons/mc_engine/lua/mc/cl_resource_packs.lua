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
		started = job.started, finished = job.finished, bakeSerial = job.bakeSerial }
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

local function apply( name, force )
	if type( name ) ~= "string" then return false, "invalid_texture_pack_name" end
	local entry = findPack( name )
	if not entry then return false, "texture_pack_not_registered" end
	if not entry.available then return false, "missing_atlas_" .. name end
	if MC.TexturePackLeaseOwner() then return false, "texture_pack_controlled_by_mode" end
	if force and not entry.bakeID then return false, "pack_has_no_bake_source" end
	if R.job then
		if R.job.name == name and R.job.force == force then return true, R.job.id end
		return false, "resource_pack_apply_running"
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

function R.ApplyPack( name ) return apply( name, false ) end
function R.ReloadPack( name ) return apply( name, true ) end

function R.CancelApply( id )
	local job = R.job
	if not job or job.id ~= id then return false, "apply_job_not_pending" end
	if job.state ~= "baking" then return false, "apply_job_not_cancellable" end
	local baker = MC.AtlasBaker
	finish( job, "cancelled", "atlas_bake_cancelled" )
	if job.ownsBake and baker.IsBusy() and baker.Status().serial == job.bakeSerial then baker.Cancel() end
	return true
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
