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

concommand.Add("gmodbridge_connect", function(_, _, args)
	if not gmodbridge or not gmodbridge.connect then
		print("[gmodbridge] connect unavailable")
		return
	end

	local port = tonumber(args and args[1]) or 27670
	local connectOk, result = pcall(gmodbridge.connect, port)
	if connectOk then
		print("[gmodbridge]", result)
	else
		print("[gmodbridge] connect failed:", result)
	end
end)

print("[gmodbridge] client bridge loaded")
RunConsoleCommand("gmodbridge_connect",27671)
