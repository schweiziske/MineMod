-- Client-only eye-in-fluid presentation.

MC = MC or {}

local WaterColorModify = {
	["$pp_colour_addr"] = 0,
	["$pp_colour_addg"] = 0.015,
	["$pp_colour_addb"] = 0.055,
	["$pp_colour_brightness"] = -0.04,
	["$pp_colour_contrast"] = 0.86,
	["$pp_colour_colour"] = 0.72,
	["$pp_colour_mulr"] = 0,
	["$pp_colour_mulg"] = 0.08,
	["$pp_colour_mulb"] = 0.18,
}

local LavaColorModify = {
	["$pp_colour_addr"] = 0.08,
	["$pp_colour_addg"] = 0.025,
	["$pp_colour_addb"] = 0,
	["$pp_colour_brightness"] = -0.025,
	["$pp_colour_contrast"] = 1.08,
	["$pp_colour_colour"] = 0.62,
	["$pp_colour_mulr"] = 0.22,
	["$pp_colour_mulg"] = 0.04,
	["$pp_colour_mulb"] = 0,
}

local EyeLiquid
local WasUnderwater = false
local UNDERWATER_SOUND_EVENT = "Player.AmbientUnderWater"

local function sampleEyeLiquid()
	local ply = LocalPlayer()
	if not IsValid( ply ) then return nil end
	return MC.PlayerEyeLiquid( ply )
end

hook.Add( "Think", "mc_liquid_underwater_state", function()
	local ply = LocalPlayer()
	EyeLiquid = IsValid( ply ) and sampleEyeLiquid() or nil
	local underwater = EyeLiquid and EyeLiquid.kind == "water" or false
	if underwater == WasUnderwater then return end
	WasUnderwater = underwater
	if not IsValid( ply ) then return end
	if underwater then
		ply:EmitSound( UNDERWATER_SOUND_EVENT )
	else
		ply:StopSound( UNDERWATER_SOUND_EVENT )
	end
end )

hook.Add( "RenderScreenspaceEffects", "mc_liquid_underwater", function()
	local liquid = EyeLiquid
	if not liquid then return end
	local lava = liquid.kind == "lava"
	DrawColorModify( lava and LavaColorModify or WaterColorModify )
	DrawMotionBlur( 0.025, lava and 0.45 or 0.32, 0.015 )
end )

hook.Add( "HUDPaint", "mc_liquid_underwater_overlay", function()
	local liquid = EyeLiquid
	if not liquid then return end
	if liquid.kind == "lava" then
		surface.SetDrawColor( 255, 92, 20, 58 )
	else
		surface.SetDrawColor( 34, 104, 190, 46 )
	end
	surface.DrawRect( 0, 0, ScrW(), ScrH() )
end )

hook.Add( "ShutDown", "mc_liquid_underwater_sound_cleanup", function()
	local ply = LocalPlayer()
	if IsValid( ply ) then ply:StopSound( UNDERWATER_SOUND_EVENT ) end
end )
