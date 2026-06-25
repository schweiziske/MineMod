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

local function bridgeText(...)
	local parts = {}
	for i = 1, select("#", ...) do
		local value = select(i, ...)
		if not (istable(value) and value.r and value.g and value.b) then
			parts[#parts + 1] = tostring(value)
		end
	end
	return table.concat(parts, "\t")
end

local function bridgeLog(...)
	if not gmodbridge or not gmodbridge.log then return end
	pcall(gmodbridge.log, bridgeText(...))
end

local function bridgeTraceback()
	if debug and debug.traceback then
		return debug.traceback("", 3)
	end
	return ""
end

local function bridgeLogError(tag, ...)
	local message = bridgeText(...)
	local trace = bridgeTraceback()
	if trace ~= "" then
		bridgeLog(tag, message, trace)
	else
		bridgeLog(tag, message)
	end
end

if not GModBridge.PrintWrapped then
	GModBridge.PrintWrapped = true
	GModBridge.OldPrint = print

	print = function(...)
		bridgeLog(...)
		return GModBridge.OldPrint(...)
	end
end

if not GModBridge.MsgWrapped and Msg then
	GModBridge.MsgWrapped = true
	GModBridge.OldMsg = Msg

	Msg = function(...)
		bridgeLog("[Msg]", ...)
		return GModBridge.OldMsg(...)
	end
end

if not GModBridge.MsgNWrapped and MsgN then
	GModBridge.MsgNWrapped = true
	GModBridge.OldMsgN = MsgN

	MsgN = function(...)
		bridgeLog("[MsgN]", ...)
		return GModBridge.OldMsgN(...)
	end
end

if not GModBridge.MsgCWrapped and MsgC then
	GModBridge.MsgCWrapped = true
	GModBridge.OldMsgC = MsgC

	MsgC = function(...)
		bridgeLog("[MsgC]", ...)
		return GModBridge.OldMsgC(...)
	end
end

if not GModBridge.ErrorNoHaltWrapped and ErrorNoHalt then
	GModBridge.ErrorNoHaltWrapped = true
	GModBridge.OldErrorNoHalt = ErrorNoHalt

	ErrorNoHalt = function(...)
		bridgeLogError("[ErrorNoHalt]", ...)
		return GModBridge.OldErrorNoHalt(...)
	end
end

if not GModBridge.ErrorWrapped and Error then
	GModBridge.ErrorWrapped = true
	GModBridge.OldError = Error

	Error = function(...)
		bridgeLogError("[Error]", ...)
		return GModBridge.OldError(...)
	end
end

hook.Add("OnLuaError", "GModBridgeLuaError", function(message, realm, stack, name, id)
	local lines = {
		"[LuaError]",
		tostring(message),
		"realm=" .. tostring(realm),
		"name=" .. tostring(name),
		"id=" .. tostring(id),
	}

	if istable(stack) then
		for i, frame in ipairs(stack) do
			if istable(frame) then
				lines[#lines + 1] = string.format(
					"#%d %s:%s %s",
					i,
					tostring(frame.File or frame.file or "?"),
					tostring(frame.Line or frame.line or "?"),
					tostring(frame.Function or frame.func or frame.Name or frame.name or "?")
				)
			else
				lines[#lines + 1] = "#" .. i .. " " .. tostring(frame)
			end
		end
	elseif stack ~= nil then
		lines[#lines + 1] = tostring(stack)
	end

	local trace = bridgeTraceback()
	if trace ~= "" then
		lines[#lines + 1] = trace
	end

	bridgeLog(table.concat(lines, "\n"))
end)

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
RunConsoleCommand("gmodbridge_connect",27670)
