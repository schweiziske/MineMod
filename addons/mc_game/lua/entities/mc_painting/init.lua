AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

function ENT:Initialize()
	self:SetModel( "models/hunter/blocks/cube025x025x025.mdl" )
	self:SetPaintingVariant( "minecraft:kebab" )
	MC.Decoration.HangingInitialize( self, "painting" )
	self.MCDecorationCheckInterval = 0
end

function ENT:SurvivesMinecraft()
	return MC.Decoration.HangingSurvives(
		self, false, self:GetDecorationSupportCells(), false )
end

function ENT:DropMinecraftItem( causedBy )
	if not MC.Decoration.EntityDropsEnabled() then return end
	MC.Decoration.PlayDecorationSound( "entity.painting.break", self, 1, 1 )
	if MC.Decoration.CreativePlayer( causedBy ) then return end
	local stack = MC.NewItemStack and MC.NewItemStack( "minecraft:painting", 1 ) or nil
	if stack then MC.Decoration.SpawnDecorationDrop( self, stack, nil, causedBy ) end
end

function ENT:PlayMinecraftPlacementSound()
	MC.Decoration.PlayDecorationSound( "entity.painting.place", self, 1, 1 )
end

function ENT:HandleMinecraftDecorationAttack( ply, context )
	context = context or {}
	context.removed = self:IsRemoved()
	if context.creative == nil then context.creative = MC.Decoration.CreativePlayer( ply ) end
	local decision = MC.Decoration.BlockAttachedDamageDecision( context )
	if decision.action == "reject" then
		return { handled = true, accepted = false, damageTool = false }
	end
	self:DropMinecraftItem( ply )
	self:Remove()
	return { handled = true, accepted = true, damageTool = false, destroyed = true }
end

function ENT:OnTakeDamage( damageInfo )
	local attacker = damageInfo and damageInfo.GetAttacker and damageInfo:GetAttacker() or nil
	local context = MC.Decoration.DecorationDamageContext( self, damageInfo )
	if MC.Decoration.BlockAttachedIgnoresExplosion( damageInfo, context ) then return 0 end
	context.creative = MC.Decoration.CreativePlayer( attacker )
	context.invulnerable = self.GetNW2Bool and self:GetNW2Bool( "mc_invulnerable", false ) or false
	context.mob = IsValid( attacker ) and (
		( attacker.IsNPC and attacker:IsNPC() ) or ( attacker.IsNextBot and attacker:IsNextBot() )
		or attacker.IsMinecraftMob == true ) or false
	context.mobGriefing = MC.Decoration.MobGriefingEnabled and MC.Decoration.MobGriefingEnabled() or true
	self:HandleMinecraftDecorationAttack( attacker, context )
	return 0
end

function ENT:Think()
	MC.Decoration.HangingTick( self )
	self:NextThink( CurTime() + 0.05 )
	return true
end

function ENT:PhysicsUpdate( physics )
	if not IsValid( physics ) or physics:GetVelocity():LengthSqr() <= 0 then return end
	MC.Decoration.HangingMoveBreak( self )
end
