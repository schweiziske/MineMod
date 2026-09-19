-- Scheduling presets change admission budgets, never GC/JIT global settings.
-- A section upload remains indivisible and can overshoot the selected budget.
MC.MeshBuildPreset = MC.MeshBuildPreset or CreateClientConVar( "mc_mesh_build_preset", "fast", true, false,
	"Mesh scheduling preset: smooth, fast, loading or custom; manual budget edits select custom" )
local presets = { smooth = { 3, 3, 16 }, fast = { 8, 8, 64 }, loading = { 20, 20, 128 } }
local controls = { MC.MeshBuildFrameMS, MC.ExplosionMeshFrameMS, MC.ExplosionMeshSectionsPerFrame }
local names = { "mc_mesh_build_frame_ms", "mc_explosion_mesh_frame_ms", "mc_explosion_mesh_sections_per_frame" }
local applying = false

function MC.SetMeshBuildPreset( name )
	local values = presets[name]
	if not values and name ~= "custom" then return false, "expected smooth, fast, loading or custom" end
	applying = true
	if values then for i = 1, 3 do controls[i]:SetFloat( values[i] ) end end
	MC.MeshBuildPreset:SetString( name )
	applying = false
	MC.WakeLazyMeshBuilder()
	return true
end

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_mesh_build_preset", function( _, old, new )
		if applying then return end
		local ok, err = MC.SetMeshBuildPreset( new )
		if not ok then
			applying = true
			MC.MeshBuildPreset:SetString( old )
			applying = false
			print( "[MC mesh] " .. err )
		end
	end, "mc_mesh_preset_apply" )
	local function markCustom()
		if not applying then MC.SetMeshBuildPreset( "custom" ) end
	end
	for i = 1, 3 do cvars.AddChangeCallback( names[i], markCustom, "mc_mesh_preset_custom" ) end
end

concommand.Add( "mc_mesh_preset", function( _, _, args )
	if args[1] then
		local ok, err = MC.SetMeshBuildPreset( string.lower( args[1] ) )
		if not ok then print( "[MC mesh] " .. err ) return end
	end
	print( string.format( "[MC mesh] preset=%s total=%.1fms/frame bulk=%.1fms/%d sections; smooth | fast | loading | custom",
		MC.MeshBuildPreset:GetString(), controls[1]:GetFloat(), controls[2]:GetFloat(), controls[3]:GetInt() ) )
end )

-- The new archived preset makes fast effective even for clients that saved
-- the previous 3 ms default. Subsequent manual tuning is preserved as custom.
local ok, err = MC.SetMeshBuildPreset( MC.MeshBuildPreset:GetString() )
if not ok then MC.Fault( "mesh_preset_invalid", "%s", err ) end
