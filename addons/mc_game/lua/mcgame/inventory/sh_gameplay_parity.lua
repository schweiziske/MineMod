-- Vanilla container input is the normal gameplay contract. Keep the query for
-- consumers, but do not leave shipped fixes behind an archived opt-in switch.

MC = MC or {}
MC.GameplayParity = MC.GameplayParity or {}

function MC.GameplayParityInventoryClicksEnabled()
	return true
end

