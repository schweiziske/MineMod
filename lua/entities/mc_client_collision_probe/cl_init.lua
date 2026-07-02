include( "shared.lua" )

ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

local PROBE_WIRE = Color( 255, 90, 70, 240 )
local PROBE_FILL = Color( 255, 90, 70, 28 )
local PHYSICS_MODEL = "models/hunter/blocks/cube025x025x025.mdl"
local RANDOM_TEST_BASE_CELL = { bx = -27, by = 11, bz = -319 }
local RANDOM_TEST_OFFSETS = {
	{ 1, 0 },
	{ 2, 0 },
	{ -1, 0 },
	{ -2, 0 },
	{ 0, 1 },
	{ 0, 2 },
	{ 0, -1 },
	{ 0, -2 },
}
local RANDOM_TEST_INTERVAL = 5
local NEARBY_TEST_INTERVAL = 0.05
local NEARBY_TEST_RADIUS = 1

local function blockSize()
	return MC and MC.BS or 36.5
end

local function cellWorldMin( bx, by, bz )
	if MC and MC.CellWorldMin then return MC.CellWorldMin( bx, by, bz ) end
	local bs = blockSize()
	return Vector( bx * bs, by * bs, bz * bs )
end

local function pinProbePhysicsObject( ent, phys )
	if not IsValid( ent ) then return false end
	phys = IsValid( phys ) and phys or ent:GetPhysicsObject()
	if not IsValid( phys ) then return false end

	phys:EnableMotion( false )
	phys:SetPos( ent:GetPos() )
	phys:SetAngles( ent:GetAngles() )
	return true
end

local function ensurePhysicsModel( ent )
	if not IsValid( ent ) then return end
	if ent:GetModel() ~= PHYSICS_MODEL then
		ent:SetModel( PHYSICS_MODEL )
	end
end

local function makeBoxConvex( mins, maxs )
	return {
		Vector( mins.x, mins.y, mins.z ),
		Vector( maxs.x, mins.y, mins.z ),
		Vector( mins.x, maxs.y, mins.z ),
		Vector( maxs.x, maxs.y, mins.z ),
		Vector( mins.x, mins.y, maxs.z ),
		Vector( maxs.x, mins.y, maxs.z ),
		Vector( mins.x, maxs.y, maxs.z ),
		Vector( maxs.x, maxs.y, maxs.z ),
	}
end

local function nearbyBoxKey( box )
	return table.concat( { box[1], box[2], box[3], box[4], box[5], box[6] }, ":" )
end

local function buildNearbyMergedBoxes( centerBx, centerBy, centerBz )
	local size = NEARBY_TEST_RADIUS * 2 + 1
	local function idx( x, y, z ) return x + y * size + z * size * size end
	local originBx = centerBx - NEARBY_TEST_RADIUS
	local originBy = centerBy - NEARBY_TEST_RADIUS
	local originBz = centerBz - NEARBY_TEST_RADIUS
	local solid = {}
	local shapeGroups = {}

	local function addShapeBox( lx, ly, lz, box )
		local key = nearbyBoxKey( box )
		local group = shapeGroups[key]
		if not group then
			group = {
				cells = {},
				fx0 = box[1], fy0 = box[2], fz0 = box[3],
				fx1 = box[4], fy1 = box[5], fz1 = box[6],
				fullX = box[1] <= 0 and box[4] >= 1,
				fullY = box[2] <= 0 and box[5] >= 1,
				fullZ = box[3] <= 0 and box[6] >= 1,
			}
			shapeGroups[key] = group
		end
		group.cells[idx( lx, ly, lz )] = true
	end

	for lz = 0, size - 1 do
		for ly = 0, size - 1 do
			for lx = 0, size - 1 do
				local bx = originBx + lx
				local by = originBy + ly
				local bz = originBz + lz
				local id = MC.GetBlock( bx, by, bz )
				if id and id ~= 0 then
					local block = MC.Blocks and MC.Blocks[id] or nil
					if not block or block.solid ~= false then
						local orient = MC.GetBlockOrient( bx, by, bz ) or 0
						if MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient ) then
							solid[idx( lx, ly, lz )] = true
						else
							local boxes = MC.GetBlockCollisionBoxes( id, orient, bx, by, bz )
							if ( not boxes or #boxes == 0 ) and MC.BlockBoxes then
								boxes = MC.BlockBoxes( id, orient, bx, by, bz )
							end
							for _, box in ipairs( boxes or {} ) do
								addShapeBox( lx, ly, lz, box )
							end
						end
					end
				end
			end
		end
	end

	local boxes = {}
	local visited = {}

	for z = 0, size - 1 do
		for y = 0, size - 1 do
			for x = 0, size - 1 do
				local i0 = idx( x, y, z )
				if solid[i0] and not visited[i0] then
					local x1 = x + 1
					while x1 < size do
						local i = idx( x1, y, z )
						if not solid[i] or visited[i] then break end
						x1 = x1 + 1
					end

					local y1 = y + 1
					while y1 < size do
						local ok = true
						for xx = x, x1 - 1 do
							local i = idx( xx, y1, z )
							if not solid[i] or visited[i] then ok = false break end
						end
						if not ok then break end
						y1 = y1 + 1
					end

					local z1 = z + 1
					while z1 < size do
						local ok = true
						for yy = y, y1 - 1 do
							for xx = x, x1 - 1 do
								local i = idx( xx, yy, z1 )
								if not solid[i] or visited[i] then ok = false break end
							end
							if not ok then break end
						end
						if not ok then break end
						z1 = z1 + 1
					end

					for zz = z, z1 - 1 do
						for yy = y, y1 - 1 do
							for xx = x, x1 - 1 do
								visited[idx( xx, yy, zz )] = true
							end
						end
					end
					boxes[#boxes + 1] = { x, y, z, x1, y1, z1 }
				end
			end
		end
	end

	local function addMergedShapeGroup( group )
		local seen = {}
		for z = 0, size - 1 do
			for y = 0, size - 1 do
				for x = 0, size - 1 do
					local i0 = idx( x, y, z )
					if group.cells[i0] and not seen[i0] then
						local x1 = x + 1
						if group.fullX then
							while x1 < size do
								local i = idx( x1, y, z )
								if not group.cells[i] or seen[i] then break end
								x1 = x1 + 1
							end
						end

						local y1 = y + 1
						if group.fullY then
							while y1 < size do
								local ok = true
								for xx = x, x1 - 1 do
									local i = idx( xx, y1, z )
									if not group.cells[i] or seen[i] then ok = false break end
								end
								if not ok then break end
								y1 = y1 + 1
							end
						end

						local z1 = z + 1
						if group.fullZ then
							while z1 < size do
								local ok = true
								for yy = y, y1 - 1 do
									for xx = x, x1 - 1 do
										local i = idx( xx, yy, z1 )
										if not group.cells[i] or seen[i] then ok = false break end
									end
									if not ok then break end
								end
								if not ok then break end
								z1 = z1 + 1
							end
						end

						for zz = z, z1 - 1 do
							for yy = y, y1 - 1 do
								for xx = x, x1 - 1 do
									seen[idx( xx, yy, zz )] = true
								end
							end
						end

						boxes[#boxes + 1] = {
							x + group.fx0,
							y + group.fy0,
							z + group.fz0,
							( x1 - 1 ) + group.fx1,
							( y1 - 1 ) + group.fy1,
							( z1 - 1 ) + group.fz1,
						}
					end
				end
			end
		end
	end

	for _, group in pairs( shapeGroups ) do
		addMergedShapeGroup( group )
	end

	return boxes, originBx, originBy, originBz
end

local function rebuildNearbyPlayerCollision( ent, centerBx, centerBy, centerBz, signature )
	if not IsValid( ent ) then return false end
	if not ( MC and MC.GetBlock and MC.GetBlockOrient and MC.GetBlockCollisionBoxes ) then return false end

	local bs = blockSize()
	local boxes, originBx, originBy, originBz = buildNearbyMergedBoxes( centerBx, centerBy, centerBz )
	local origin = cellWorldMin( originBx, originBy, originBz )
	local convexes = {}
	local boundsMins
	local boundsMaxs

	for _, box in ipairs( boxes or {} ) do
		local mins = Vector( box[1] * bs, box[2] * bs, box[3] * bs )
		local maxs = Vector( box[4] * bs, box[5] * bs, box[6] * bs )
		convexes[#convexes + 1] = makeBoxConvex( mins, maxs )
		if boundsMins then
			boundsMins.x = math.min( boundsMins.x, mins.x )
			boundsMins.y = math.min( boundsMins.y, mins.y )
			boundsMins.z = math.min( boundsMins.z, mins.z )
			boundsMaxs.x = math.max( boundsMaxs.x, maxs.x )
			boundsMaxs.y = math.max( boundsMaxs.y, maxs.y )
			boundsMaxs.z = math.max( boundsMaxs.z, maxs.z )
		else
			boundsMins = Vector( mins.x, mins.y, mins.z )
			boundsMaxs = Vector( maxs.x, maxs.y, maxs.z )
		end
	end

	ent:PhysicsDestroy()
	ensurePhysicsModel( ent )
	ent:SetPos( origin )
	ent:SetAngles( angle_zero )
	ent:SetRenderBounds( boundsMins or vector_origin, boundsMaxs or vector_origin )
	ent.ProbeBlockSize = bs
	ent.ProbeDrawMins = boundsMins or vector_origin
	ent.ProbeDrawMaxs = boundsMaxs or vector_origin
	ent.NearbyProbeOrigin = origin
	ent.NearbyProbeSignature = signature
	ent.NearbyProbeConvexCount = #convexes

	if #convexes == 0 then
		print( string.format( "[MC probe nearby] rebuilt empty around %d %d %d", centerBx, centerBy, centerBz ) )
		return false
	end

	ent:PhysicsInitMultiConvex( convexes )
	ent:SetMoveType( MOVETYPE_VPHYSICS )
	ent:SetSolid( SOLID_VPHYSICS )
	ent:SetCollisionGroup( COLLISION_GROUP_NONE )
	ent:EnableCustomCollisions( true )
	local phys = ent:GetPhysicsObject()
	if IsValid( phys ) then
		pinProbePhysicsObject( ent, phys )
		phys:Wake()
	end

	print( string.format( "[MC probe nearby] rebuilt center=%d %d %d boxes=%d convexes=%d phys=%s origin=%s", centerBx, centerBy, centerBz, #( boxes or {} ), #convexes, tostring( IsValid( phys ) ), tostring( origin ) ) )
	return IsValid( phys )
end

local function nearbyPlayerCollisionSignature()
	if not ( MC and MC.WorldToCell and MC.GetBlock and MC.GetBlockOrient ) then return nil end
	local ply = LocalPlayer()
	if not IsValid( ply ) then return nil end

	local centerBx, centerBy, centerBz = MC.WorldToCell( ply:GetPos() )
	local parts = { tostring( centerBx ), tostring( centerBy ), tostring( centerBz ) }
	for bz = centerBz - NEARBY_TEST_RADIUS, centerBz + NEARBY_TEST_RADIUS do
		for by = centerBy - NEARBY_TEST_RADIUS, centerBy + NEARBY_TEST_RADIUS do
			for bx = centerBx - NEARBY_TEST_RADIUS, centerBx + NEARBY_TEST_RADIUS do
				local id = MC.GetBlock( bx, by, bz ) or 0
				local orient = id ~= 0 and ( MC.GetBlockOrient( bx, by, bz ) or 0 ) or 0
				parts[#parts + 1] = tostring( id ) .. ":" .. tostring( orient )
			end
		end
	end
	return table.concat( parts, "|" ), centerBx, centerBy, centerBz
end

local function runNearbyPlayerCollisionStep( ent )
	if not IsValid( ent ) then return false end
	local signature, centerBx, centerBy, centerBz = nearbyPlayerCollisionSignature()
	if not signature then return false end

	if ent.NearbyProbeSignature ~= signature then
		if ( not IsValid( MC.ClientCollisionProbeEntity ) ) and MC and MC.RequestServerCollisionProbe then
			MC.RequestServerCollisionProbe( centerBx, centerBy, centerBz )
		end
		return rebuildNearbyPlayerCollision( ent, centerBx, centerBy, centerBz, signature )
	end

	if ent.NearbyProbeOrigin then
		ent:SetPos( ent.NearbyProbeOrigin )
		ent:SetAngles( angle_zero )
		pinProbePhysicsObject( ent )
	end
	return true
end

local function randomProbeCell()
	local offset = RANDOM_TEST_OFFSETS[ math.random( #RANDOM_TEST_OFFSETS ) ]
	return RANDOM_TEST_BASE_CELL.bx + offset[1],
		RANDOM_TEST_BASE_CELL.by + offset[2],
		RANDOM_TEST_BASE_CELL.bz
end

local function forceProbeEntityTransform( ent, bx, by, bz )
	if not IsValid( ent ) then return false end

	ent.RandomProbeTargetCell = { bx = bx, by = by, bz = bz }
	ent:SetPos( cellWorldMin( bx, by, bz ) )
	ent:SetAngles( angle_zero )
	pinProbePhysicsObject( ent )
	return true
end

local function applyProbeCellLocal( ent, bx, by, bz )
	if MC and MC.SetPendingClientCollisionProbeCell then
		MC.SetPendingClientCollisionProbeCell( bx, by, bz )
	end

	if IsValid( ent ) and ent.ApplyProbeCell then
		if MC and MC.ApplyPendingClientCollisionProbe then
			local ok = MC.ApplyPendingClientCollisionProbe( ent )
			forceProbeEntityTransform( ent, bx, by, bz )
			return ok
		end
		local ok = ent:ApplyProbeCell( bx, by, bz ) ~= false
		forceProbeEntityTransform( ent, bx, by, bz )
		return ok
	end

	if MC and MC.RequestServerCollisionProbe then
		MC.RequestServerCollisionProbe( bx, by, bz )
	end
	return false
end

local function runRandomProbeStep( ent )
	local bx, by, bz = randomProbeCell()
	local ok = applyProbeCellLocal( ent, bx, by, bz )
	print( string.format( "[MC probe random] cell=%d %d %d ok=%s", bx, by, bz, tostring( ok ) ) )
	return ok
end

MC = MC or {}

function MC.StartClientCollisionProbeRandomTest()
	MC.ClientCollisionProbeRandomTestEnabled = true

	local ent = MC.ClientCollisionProbeEntity
	if IsValid( ent ) then
		ent.NextRandomProbeTime = CurTime() + RANDOM_TEST_INTERVAL
		runRandomProbeStep( ent )
	else
		runRandomProbeStep( nil )
	end

	print( "[MC probe random] started" )
end

function MC.StopClientCollisionProbeRandomTest()
	MC.ClientCollisionProbeRandomTestEnabled = false
	if IsValid( MC.ClientCollisionProbeEntity ) then
		MC.ClientCollisionProbeEntity.NextRandomProbeTime = nil
	end
	print( "[MC probe random] stopped" )
end

concommand.Add( "mc_client_collision_probe_random_test", function()
	MC.StartClientCollisionProbeRandomTest()
end, nil, "Randomly move the client collision probe around -27 11 -319 every five seconds." )

concommand.Add( "mc_client_collision_probe_random_test_stop", function()
	MC.StopClientCollisionProbeRandomTest()
end, nil, "Stop the random client collision probe test." )

function MC.StartClientCollisionProbeNearbyTest()
	MC.ClientCollisionProbeNearbyTestEnabled = true
	MC.ClientCollisionProbeRandomTestEnabled = false
	local ent = MC.ClientCollisionProbeEntity
	if IsValid( ent ) then
		ent.NextNearbyProbeTime = 0
	elseif MC.RequestServerCollisionProbe and MC.WorldToCell then
		local ply = LocalPlayer()
		if IsValid( ply ) then
			MC.RequestServerCollisionProbe( MC.WorldToCell( ply:GetPos() ) )
		end
	end
	print( "[MC probe nearby] started" )
end

function MC.StopClientCollisionProbeNearbyTest()
	MC.ClientCollisionProbeNearbyTestEnabled = false
	if IsValid( MC.ClientCollisionProbeEntity ) then
		MC.ClientCollisionProbeEntity.NextNearbyProbeTime = nil
		MC.ClientCollisionProbeEntity.NearbyProbeOrigin = nil
	end
	print( "[MC probe nearby] stopped" )
end

concommand.Add( "mc_client_collision_probe_nearby_test", function()
	MC.StartClientCollisionProbeNearbyTest()
end, nil, "Build probe collision from the 3x3x3 blocks around the local player every 0.05 seconds when changed." )

concommand.Add( "mc_client_collision_probe_nearby_test_stop", function()
	MC.StopClientCollisionProbeNearbyTest()
end, nil, "Stop the nearby player collision probe test." )

function ENT:Initialize()
	self:SetModel( PHYSICS_MODEL )
	self:DrawShadow( false )
	self:SetRenderMode( RENDERMODE_TRANSALPHA )
	self:SetColor( Color( 255, 90, 70, 80 ) )
	MC.ClientCollisionProbeEntity = self
	timer.Simple( 0, function()
		if not IsValid( self ) then return end
		if MC and MC.ApplyPendingClientCollisionProbe then MC.ApplyPendingClientCollisionProbe( self ) end
	end )
end

function ENT:ApplyProbeCell( bx, by, bz )
	bx, by, bz = math.floor( tonumber( bx ) or 0 ), math.floor( tonumber( by ) or 0 ), math.floor( tonumber( bz ) or 0 )

	local bs = blockSize()
	self.ProbeCell = { bx = bx, by = by, bz = bz }
	self.ProbeBlockSize = bs
	self.ProbeDrawMins = Vector( 0, 0, 0 )
	self.ProbeDrawMaxs = Vector( bs, bs, bs )
	self.NearbyProbeOrigin = nil
	self.NearbyProbeSignature = nil

	self:PhysicsDestroy()
	ensurePhysicsModel( self )
	self:SetPos( cellWorldMin( bx, by, bz ) )
	self:SetAngles( angle_zero )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:SetCollisionGroup( COLLISION_GROUP_NONE )
	self:EnableCustomCollisions( true )
	self:SetCollisionBounds( Vector( 0, 0, 0 ), Vector( bs, bs, bs ) )
	self:SetRenderBounds( Vector( 0, 0, 0 ), Vector( bs, bs, bs ) )
	self:PhysicsInitBox( Vector( 0, 0, 0 ), Vector( bs, bs, bs ) )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )

	local phys = self:GetPhysicsObject()
	if IsValid( phys ) then
		pinProbePhysicsObject( self, phys )
		phys:Wake()
		return true
	end

	return false
end



function ENT:PhysicsUpdate( phys )
	pinProbePhysicsObject( self, phys )
end

function ENT:Think()
	MC.ClientCollisionProbeEntity = self
	if not MC.ClientCollisionProbeNearbyTestEnabled and MC and MC.ApplyPendingClientCollisionProbe then
		MC.ApplyPendingClientCollisionProbe( self )
	end

	if MC.ClientCollisionProbeNearbyTestEnabled then
		self.NextNearbyProbeTime = self.NextNearbyProbeTime or 0
		if CurTime() >= self.NextNearbyProbeTime then
			runNearbyPlayerCollisionStep( self )
			self.NextNearbyProbeTime = CurTime() + NEARBY_TEST_INTERVAL
		elseif self.NearbyProbeOrigin then
			self:SetPos( self.NearbyProbeOrigin )
			self:SetAngles( angle_zero )
			pinProbePhysicsObject( self )
		end
	elseif MC.ClientCollisionProbeRandomTestEnabled then
		self.NextRandomProbeTime = self.NextRandomProbeTime or 0
		if CurTime() >= self.NextRandomProbeTime then
			runRandomProbeStep( self )
			self.NextRandomProbeTime = CurTime() + RANDOM_TEST_INTERVAL
		end

		local target = self.RandomProbeTargetCell
		if target then
			forceProbeEntityTransform( self, target.bx, target.by, target.bz )
		end
	end

	pinProbePhysicsObject( self )
	self:NextThink( CurTime() )
	return true
end

function ENT:DrawTranslucent()
	local bs = self.ProbeBlockSize or blockSize()
	local mins = self.ProbeDrawMins or Vector( 0, 0, 0 )
	local maxs = self.ProbeDrawMaxs or Vector( bs, bs, bs )

	render.SetColorMaterial()
	render.DrawBox( self:GetPos(), self:GetAngles(), mins, maxs, PROBE_FILL, true )
	
	render.DrawWireframeBox( self:GetPos(), self:GetAngles(), mins, maxs, PROBE_WIRE, true )
end

function ENT:Draw()
	self:DrawTranslucent()
end
