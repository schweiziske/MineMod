--[[----------------------------------------------------------------------------
	Authoritative dropped ItemStack spawning.

	Dropped items are transient Garry's Mod entities; persistent inventories and
	containers remain plain tables. The entity only networks the small visual
	identity while the complete stack (including components) stays server-side.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV

local function randomVelocity()
	return Vector(
		math.Rand( -45, 45 ),
		math.Rand( -45, 45 ),
		math.Rand( 55, 95 )
	)
end

function SV.SpawnItemDrop( position, input, actor, options )
	local stack, stackError = MC.NormalizeItemStack( input )
	if not stack then return nil, stackError or "invalid_stack" end
	if not position then return nil, "invalid_position" end
	options = istable( options ) and options or {}

	local ent = ents.Create( "mc_item_drop" )
	if not IsValid( ent ) then return nil, "item_drop_entity_unavailable" end
	ent:SetPos( position + Vector(
		math.Rand( -3, 3 ),
		math.Rand( -3, 3 ),
		math.Rand( 1, 5 )
	) )
	ent:Spawn()
	ent:Activate()
	local accepted, setError = ent:SetDropStack( stack )
	if accepted ~= true then
		ent:Remove()
		return nil, setError or "item_drop_stack_rejected"
	end
	ent:SetPickupDelay( tonumber( options.pickupDelay ) or 0.5 )
	ent.MCDropActor = IsValid( actor ) and actor or nil

	local velocity = options.velocity
	if not isvector( velocity ) then velocity = randomVelocity() end
	local physics = ent:GetPhysicsObject()
	if IsValid( physics ) then
		physics:SetVelocity( velocity )
		physics:AddAngleVelocity( VectorRand() * 120 )
	end
	return ent
end
