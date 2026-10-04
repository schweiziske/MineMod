-- Resource-pack policy belongs to Lua. Sources only expose indexed bytes.
-- All work here runs to completion: no coroutine, timer or per-frame budget.
MC = MC or {}
MC.ResourcePackRules = MC.ResourcePackRules or {}
local R = MC.ResourcePackRules
R.VERSION = 1
function R.Hash(bytes)
	if mcmesh and mcmesh.HashResourceBytes then
		local digest,err=mcmesh.HashResourceBytes(bytes)
		if not digest then error("resource_hash_native:"..tostring(err),0) end
		return digest
	end
	return util.SHA256(bytes)
end
function R.Array(value, limit)
	if type(value) ~= "table" or #value > limit then return false end
	local n = #value
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key > n or key ~= math.floor(key) then return false end
	end
	for i = 1, n do if value[i] == nil then return false end end
	return true
end
-- Audit before the engine decoder: duplicate keys (including escaped aliases),
-- recursion and entry budgets must not disappear during JSONToTable conversion.
function R.DecodeJSON(bytes)
	if type(bytes) ~= "string" or #bytes == 0 or #bytes > 1048576 then return nil, "resource_pack_metadata_budget" end
	if not bytes:match("^[ \t\r\n]*{") then return nil, "resource_pack_json_object" end
	local function audit()
		local pos, nodes = 1, 0
		local function skip()
			local _, last = bytes:find("^[ \t\r\n]*", pos) pos = last + 1
		end
		local function quoted()
			local first = pos
			assert(bytes:sub(pos, pos) == '"', "resource_pack_json_string")
			pos = pos + 1
			while pos <= #bytes do
				local at = bytes:find('[\\"]', pos)
				assert(at, "resource_pack_json_string")
				if bytes:sub(at, at) == '"' then pos = at + 1 return bytes:sub(first, at) end
				pos = at + 2
			end
			error("resource_pack_json_string", 0)
		end
		local value
		value = function(depth)
			nodes = nodes + 1
			assert(depth <= 32 and nodes <= 65536, "resource_pack_json_budget")
			skip()
			local c = bytes:sub(pos, pos)
			if c == '"' then quoted()
			elseif c == "{" or c == "[" then
				pos = pos + 1 skip()
				local ending, keys = c == "{" and "}" or "]", {}
				if bytes:sub(pos, pos) == ending then pos = pos + 1 return end
				while true do
					if c == "{" then
						local raw = quoted()
						local decoded = util.JSONToTable("[" .. raw .. "]", true, true)
						assert(type(decoded) == "table" and type(decoded[1]) == "string", "resource_pack_json_key")
						assert(not keys[decoded[1]], "resource_pack_json_duplicate_key") keys[decoded[1]] = true
						skip() assert(bytes:sub(pos, pos) == ":", "resource_pack_json_colon") pos = pos + 1
					end
					value(depth + 1) skip()
					local delimiter = bytes:sub(pos, pos) pos = pos + 1
					if delimiter == ending then break end
					assert(delimiter == ",", "resource_pack_json_delimiter") skip()
				end
			else
				local token = bytes:match("^[^,}%] \t\r\n]+", pos)
				assert(token and (token == "true" or token == "false" or token == "null" or token:match("^%-?%d")), "resource_pack_json_value")
				pos = pos + #token
			end
		end
		value(0) skip() assert(pos > #bytes, "resource_pack_json_trailing")
		local parsed = util.JSONToTable(bytes, true, true)
		assert(type(parsed) == "table", "resource_pack_json_object")
		return parsed
	end
	local ok, result = pcall(audit)
	if not ok then return nil, tostring(result) end
	return result
end
local function need(ok, reason) if not ok then error(reason, 0) end end
local function number(v)
	need(type(v) == "number" and v >= 0 and v <= 2147483647 and v == math.floor(v), "resource_pack_format_integer")
	return v
end
local function format(v, minor)
	if type(v) == "table" then
		need(R.Array(v, 256) and #v >= 1, "resource_pack_format_array")
		for _, part in ipairs(v) do number(part) end
		return { number(v[1]), v[2] or minor }
	end
	return { number(v), minor }
end
local function less(a, b) return a[1] < b[1] or a[1] == b[1] and a[2] < b[2] end
function R.Contains(range, target) return not less(target, range.minimum) and not less(range.maximum, target) end
local function legacy(v)
	if type(v) == "table" then
		if v.min_inclusive ~= nil then return number(v.min_inclusive), number(v.max_inclusive) end
		need(R.Array(v, 2) and #v == 2, "resource_pack_legacy_range")
		return number(v[1]), number(v[2])
	end
	local n = number(v)
	return n, n
end
local function range(v, pack, requireOld)
	need(type(v) == "table", "resource_pack_format_object")
	need((v.min_format ~= nil) == (v.max_format ~= nil), "resource_pack_format_pair_required")
	local oldKey = pack and "supported_formats" or "formats"
	local old, main = v[oldKey] ~= nil, pack and v.pack_format ~= nil
	local mainFormat, low, high
	if main then mainFormat = number(v.pack_format) end
	if old then low, high = legacy(v[oldKey]) need(low <= high, "resource_pack_reversed_format_range") end
	need(not requireOld or old, "resource_pack_overlay_legacy_required")
	local result
	if v.min_format ~= nil then
		result = { minimum = format(v.min_format, 0), maximum = format(v.max_format, 2147483647) }
		need(not less(result.maximum, result.minimum), "resource_pack_reversed_format_range")
		if result.minimum[1] > 64 and not requireOld then
			need(not old, "resource_pack_deprecated_supported_formats")
		else
			need(old, "resource_pack_legacy_range_required")
			need(low == result.minimum[1] and (high == result.maximum[1] or high == 64), "resource_pack_legacy_range_mismatch")
			need(not pack or main, "resource_pack_legacy_pack_format_required")
		end
	elseif old then
		need(high <= 64, "resource_pack_new_format_fields_required")
		need(not pack or main, "resource_pack_legacy_pack_format_required")
		result = { minimum = {low, 0}, maximum = {high, 0} }
	else
		need(main, "resource_pack_format_missing")
		need(mainFormat <= 64, "resource_pack_new_format_fields_required")
		result = { minimum = {mainFormat, 0}, maximum = {mainFormat, 0} }
	end
	if main then need(mainFormat >= result.minimum[1] and mainFormat <= result.maximum[1], "resource_pack_format_outside_range") end
	return result
end
function R.FormatRange(value, pack)
	local ok, result = pcall(range, value, pack ~= false, false)
	if not ok then return nil, result end
	return result
end

function R.Identifier(id)
	if type(id) ~= "string" or #id > 512 then return nil, "resource_identifier_invalid" end
	local ns, path = id:match("^([a-z0-9_.%-]+):([a-z0-9_./%-]+)$")
	if not ns or ns == "." or ns == ".." or path:sub(1, 1) == "/" or path:sub(-1) == "/"
		or path:find("//", 1, true) then return nil, "resource_identifier_invalid" end
	for part in path:gmatch("[^/]+") do if part == "." or part == ".." then return nil, "resource_identifier_invalid" end end
	return ns, path
end

-- A bounded Java-regex subset, NOT a Lua-pattern translation. NFA evaluation
-- is O(pattern * path); unsupported constructs reject the descriptor.
local function pattern(source)
	need(type(source) == "string" and #source <= 256, "resource_pack_filter_pattern_budget")
	local i, atoms = 1, {}
	if source:sub(i, i) == "^" then i = i + 1 end
	local function literal()
		local c = source:sub(i, i) i = i + 1
		need(c ~= "", "resource_pack_filter_pattern_invalid")
		if c == "\\" then
			c = source:sub(i, i) i = i + 1
			need(c ~= "" and not c:match("[%w]"), "resource_pack_filter_escape_unsupported")
		end
		need(c:byte() < 128, "resource_pack_filter_unicode_unsupported")
		return c:byte()
	end
	while i <= #source do
		local c = source:sub(i, i)
		if c == "$" and i == #source then break end
		local atom = { chars = {}, minimum = 1, maximum = 1 }
		if c == "." then
			for b = 0, 127 do atom.chars[b] = true end
			i = i + 1
		elseif c == "[" then
			i = i + 1
			local negate = source:sub(i, i) == "^"
			if negate then i = i + 1 end
			need(i <= #source and source:sub(i, i) ~= "]", "resource_pack_filter_class_invalid")
			while i <= #source and source:sub(i, i) ~= "]" do
				local first = literal()
				if source:sub(i, i) == "-" and i < #source and source:sub(i + 1, i + 1) ~= "]" then
					i = i + 1
					local last = literal()
					need(first <= last, "resource_pack_filter_class_invalid")
					for b = first, last do atom.chars[b] = true end
				else atom.chars[first] = true end
			end
			need(source:sub(i, i) == "]", "resource_pack_filter_class_invalid")
			i = i + 1
			if negate then for b = 0, 127 do atom.chars[b] = not atom.chars[b] end end
		else
			need(not ("(){}|*+?^$"):find(c, 1, true), "resource_pack_filter_construct_unsupported")
			atom.chars[literal()] = true
		end
		c = source:sub(i, i)
		if c == "*" or c == "+" or c == "?" then
			atom.minimum, atom.maximum = c == "+" and 1 or 0, c == "?" and 1 or 513
			i = i + 1
		end
		atoms[#atoms + 1] = atom
	end
	return function(value)
		if #value > 512 then return false end
		local previous = {[0] = true}
		for _, atom in ipairs(atoms) do
			local nextState = {}
			for pos = 0, #value do
				if atom.minimum == 0 and previous[pos] then nextState[pos] = true end
				if pos > 0 and atom.chars[value:byte(pos)] and (previous[pos - 1] or atom.maximum > 1 and nextState[pos - 1]) then
					nextState[pos] = true
				end
			end
			previous = nextState
		end
		return previous[#value] == true
	end
end
function R.Pattern(value)
	local ok, result = pcall(pattern, value)
	if not ok then return nil, result end
	return result
end

local function text(value, depth)
	need(depth <= 16, "resource_pack_description_depth")
	local output = ""
	if type(value) == "string" then output = value
	elseif type(value) == "table" then
		if value[1] ~= nil then
			for _, child in ipairs(value) do output = output .. text(child, depth + 1) end
		else
			local body = value.text or value.fallback or value.translate
			if body ~= nil then output = text(body, depth + 1) end
			if value.extra ~= nil then output = output .. text(value.extra, depth + 1) end
		end
	else need(false, "resource_pack_description_component") end
	need(#output <= 8192 and not output:find("%z"), "resource_pack_description_budget")
	return output
end

local function descriptor(metadata, entries, target)
	need(type(metadata) == "table" and type(metadata.pack) == "table", "resource_pack_metadata_section_missing")
	local result = { formats = range(metadata.pack, true), overlays = {}, filters = {}, unsupported = {} }
	result.formatMatches = R.Contains(result.formats, target)
	need(metadata.pack.description ~= nil, "resource_pack_description_missing")
	result.description = text(metadata.pack.description, 0)
	if metadata.overlays ~= nil then
		need(type(metadata.overlays) == "table" and type(metadata.overlays.entries) == "table", "resource_pack_overlay_entries")
		local list, requireOld = metadata.overlays.entries, false
		need(R.Array(list, 256), "resource_pack_overlay_budget")
		for _, entry in ipairs(list) do
			need(type(entry) == "table", "resource_pack_overlay_entry")
			if entry.min_format ~= nil and format(entry.min_format, 0)[1] <= 64 then requireOld = true end
			if entry.formats ~= nil and legacy(entry.formats) <= 64 then requireOld = true end
		end
		for _, entry in ipairs(list) do
			local dir = entry.directory
			need(type(dir) == "string" and #dir <= 240 and dir:match("^[a-zA-Z0-9_.%-]+$")
				and dir ~= "." and dir ~= "..", "resource_pack_overlay_directory")
			if R.Contains(range(entry, false, requireOld), target) then result.overlays[#result.overlays + 1] = dir .. "/" end
		end
	end
	if metadata.filter ~= nil then
		need(type(metadata.filter) == "table" and type(metadata.filter.block) == "table", "resource_pack_filter_block")
		need(R.Array(metadata.filter.block, 256), "resource_pack_filter_budget")
		for _, entry in ipairs(metadata.filter.block) do
			need(type(entry) == "table", "resource_pack_filter_entry")
			local ns, path = entry.namespace, entry.path
			if ns == nil then ns = ".*" end
			if path == nil then path = ".*" end
			result.filters[#result.filters + 1] = { namespace = pattern(ns), path = pattern(path) }
		end
	end
	local unsupported = {}
	for path in pairs(entries) do
		for _, kind in ipairs({"models/", "blockstates/", "lang/", "sounds/", "font/", "optifine/"}) do
			if path:find("/" .. kind, 1, true) then unsupported[kind] = true end
		end
		if path:match("/sounds%.json$") then unsupported["sounds/"] = true end
	end
	for kind in pairs(unsupported) do result.unsupported[#result.unsupported + 1] = kind end
	table.sort(result.unsupported)
	return result
end
function R.Descriptor(metadata, entries, target)
	local ok, result = pcall(descriptor, metadata, entries, target)
	if not ok then return nil, result end
	return result
end

local function find(pack, path)
	for i = #pack.rules.overlays, 1, -1 do
		local candidate = pack.rules.overlays[i] .. path
		if pack.entries[candidate] then return candidate end
	end
	if pack.entries[path] then return path end
end
local function filtered(pack, ns, path)
	for _, rule in ipairs(pack.rules.filters) do if rule.namespace(ns) and rule.path(path) then return true end end
	return false
end
function R.Resolve(packs, id)
	local ns, path = R.Identifier(id)
	if not ns then return nil, path end
	local asset, result = "assets/" .. ns .. "/" .. path
	for i, pack in ipairs(packs) do
		local location = find(pack, asset)
		if location then
			if not result then result = { id = id, provider = pack.id, index = i, path = location, overridden = {} }
			else result.overridden[#result.overridden + 1] = { provider = pack.id, path = location } end
		end
		if filtered(pack, ns, path) then break end
	end
	if not result then return nil, "resource_not_found:" .. id end
	-- Lower metadata must never attach to a replacement supplied above it.
	for i = 1, result.index do
		local pack = packs[i]
		local location = find(pack, asset .. ".mcmeta")
		if location then result.metadataProvider, result.metadataIndex, result.metadataPath = pack.id, i, location break end
		if filtered(pack, ns, path .. ".mcmeta") then break end
	end
	return result
end
