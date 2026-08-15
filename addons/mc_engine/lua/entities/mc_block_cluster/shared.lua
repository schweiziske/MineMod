--[[----------------------------------------------------------------------------
	mc_block_cluster : a set of Minecraft blocks captured into one movable
	physics entity by the structure grabber tool (mc_cluster_tool).
	  server -> multiconvex physics from the cluster record, damage, paste-back
	  client -> atlas IMesh built from the same record (requested over net)
------------------------------------------------------------------------------]]

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "MC 方块结构"
ENT.Author    = "schweiziske"
ENT.Spawnable = false
ENT.AdminOnly = false
-- duplicator support lives in sv_block_cluster.lua (RegisterEntityClass);
-- the record rides in the copied entity table and rebuilds everything

local PHYSICS_MODEL = "models/hunter/blocks/cube025x025x025.mdl"

function ENT:SetupDataTables()
	self:NetworkVar( "Int", 0, "BlockCount" )
	-- size is networked separately so clients can set render bounds and do
	-- aim OBB tests before the cell payload arrives
	self:NetworkVar( "Int", 1, "SizeX" )
	self:NetworkVar( "Int", 2, "SizeY" )
	self:NetworkVar( "Int", 3, "SizeZ" )
	self:NetworkVar( "Int", 4, "ClusterMaxHP" )
	self:NetworkVar( "String", 0, "OwnerLabel" )
end

-- Same recipe as mc_chunk (PhysicsInitMultiConvex + EnableCustomCollisions is
-- what makes traces and player movement hit the convex mesh), minus the
-- freeze: clusters are movable props.
function ENT:ApplyClusterPhysics( convexes, frozen )
	self:PhysicsDestroy()
	if self:GetModel() ~= PHYSICS_MODEL then self:SetModel( PHYSICS_MODEL ) end
	self:PhysicsInitMultiConvex( convexes )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )

	local phys = self:GetPhysicsObject()
	if not IsValid( phys ) then return false end
	phys:EnableMotion( frozen ~= true )
	phys:Wake()
	return true
end
