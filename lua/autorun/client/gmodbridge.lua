if SERVER then return end
AddCSLuaFile()
local ok, err = pcall(require, "gmodbridge")
if not ok then
	print("[gmodbridge] require failed:", err)
	return
end

if not gmodbridge then
	print("[gmodbridge] module loaded without global table")
	return
end

GModBridge = GModBridge or {}

local function bridgeLog(...)
	if not gmodbridge or not gmodbridge.log then return end

	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring(select(i, ...))
	end

	pcall(gmodbridge.log, table.concat(parts, "\t"))
end

if not GModBridge.PrintWrapped then
	GModBridge.PrintWrapped = true
	GModBridge.OldPrint = print

	print = function(...)
		bridgeLog(...)
		return GModBridge.OldPrint(...)
	end
end

if not GModBridge.ErrorNoHaltWrapped and ErrorNoHalt then
	GModBridge.ErrorNoHaltWrapped = true
	GModBridge.OldErrorNoHalt = ErrorNoHalt

	ErrorNoHalt = function(...)
		bridgeLog("[ErrorNoHalt]", ...)
		return GModBridge.OldErrorNoHalt(...)
	end
end

hook.Add("Think", "GModBridgePoll", function()
	if not gmodbridge or not gmodbridge.poll then return end

	local pollOk, pollErr = pcall(gmodbridge.poll)
	if not pollOk and not GModBridge.LastPollError then
		GModBridge.LastPollError = tostring(pollErr)
		print("[gmodbridge] poll failed:", pollErr)
	end
end)

concommand.Add("gmodbridge_status", function()
	if gmodbridge and gmodbridge.status then
		print(gmodbridge.status())
	else
		print("[gmodbridge] status unavailable")
	end
end)

print("[gmodbridge] client bridge loaded")
