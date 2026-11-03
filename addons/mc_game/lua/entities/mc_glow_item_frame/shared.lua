ENT.Type = "anim"
ENT.Base = "mc_item_frame"
ENT.PrintName = "Minecraft Glow Item Frame"
ENT.Author = "MineMod"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

function ENT:GetFrameItemNameForDrop()
	return "minecraft:glow_item_frame"
end

function ENT:IsGlowMinecraftFrame()
	return true
end

function ENT:FrameSoundEvent( action )
	return "entity.glow_item_frame." .. tostring( action )
end

