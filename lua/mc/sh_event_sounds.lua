-- Shared Java sound-event selection and playback helpers.

MC = MC or {}

local function candidateWeight( candidate )
	return math.max( 1, math.floor( tonumber( candidate and candidate.weight ) or 1 ) )
end

function MC.JavaSoundEventCandidates( eventName )
	return MC.GeneratedEventSounds and MC.GeneratedEventSounds[tostring( eventName or "" )] or nil
end

function MC.SelectJavaSoundEvent( eventName, randomInteger )
	local candidates = MC.JavaSoundEventCandidates( eventName )
	if not candidates or #candidates == 0 then return nil end
	local totalWeight = 0
	for _, candidate in ipairs( candidates ) do totalWeight = totalWeight + candidateWeight( candidate ) end
	local choice = randomInteger and randomInteger( totalWeight ) or math.random( totalWeight )
	choice = math.Clamp( math.floor( tonumber( choice ) or 1 ), 1, totalWeight )
	for _, candidate in ipairs( candidates ) do
		choice = choice - candidateWeight( candidate )
		if choice <= 0 then return candidate end
	end
	return candidates[#candidates]
end

function MC.PlayJavaSoundEvent( eventName, pos, volume, pitch, soundLevel )
	local candidate = MC.SelectJavaSoundEvent( eventName )
	if not candidate or not candidate.sound or not sound or not sound.Play then return false end
	local finalVolume = math.max( 0, ( tonumber( volume ) or 1 ) * ( tonumber( candidate.volume ) or 1 ) )
	local finalPitch = math.Clamp( math.floor(
		( tonumber( pitch ) or 1 ) * ( tonumber( candidate.pitch ) or 1 ) * 100 + 0.5
	), 1, 255 )
	sound.Play( candidate.sound, pos, tonumber( soundLevel ) or 72, finalPitch, finalVolume )
	return true, candidate
end
