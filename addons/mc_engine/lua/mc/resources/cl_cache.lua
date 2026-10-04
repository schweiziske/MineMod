-- Rebuildable CPU mip cache. Only the two most recently committed generations
-- are retained; no GPU handles, material names or unvalidated plans are stored.
MC.ResourceCache = MC.ResourceCache or {}
local C = MC.ResourceCache
local ROOT, LIMIT = "mc/resourcepacks/cache", 134217728
local VERSION = "MCRC2" -- Bump when native pixel/filter semantics change.
local Cache = {} Cache.__index = Cache

local function dimensions(sprite, layout, level)
	local divisor = 2^level
	return (math.max(1,math.floor(sprite.width/divisor)) + math.floor(layout.padding/divisor)*2)
		* (math.max(1,math.floor(sprite.height/divisor)) + math.floor(layout.padding/divisor)*2)*4
end

local function decode(cache, bytes)
	if #bytes > LIMIT or bytes:sub(1,#VERSION+1) ~= VERSION .. "\n" then return false end
	local keyStart, hashStart, dataStart = #VERSION+2, #VERSION+67, #VERSION+132
	if bytes:sub(keyStart,keyStart+63) ~= cache.key or bytes:sub(keyStart+64,keyStart+64) ~= "\n"
		or bytes:sub(hashStart+64,hashStart+64) ~= "\n" then return false end
	local data = bytes:sub(dataStart)
	if MC.ResourcePackRules.Hash(data) ~= bytes:sub(hashStart,hashStart+63) then return false end
	local cursor, records = 1, {}
	while cursor <= #data do
		local ending = data:find("\n",cursor,true)
		if not ending or ending-cursor > 200 then return false end
		local header = data:sub(cursor,ending-1)
		local index, channel, sizes = header:match("^(%d+):([a-z]+):([%d,]+)$")
		index = tonumber(index)
		local sprite = index and cache.plan.sprites[index]
		if not sprite or sprite.animated or channel ~= "color" and
			(not cache.plan.pbr or channel ~= "normal" and channel ~= "orm") then return false end
		local id = index .. ":" .. channel
		if records[id] then return false end
		local levels = {} cursor=ending+1
		for size in sizes:gmatch("%d+") do
			local count = tonumber(size)
			if #levels > cache.plan.layout.mip or count ~= dimensions(sprite,cache.plan.layout,#levels)
				or cursor+count-1 > #data then return false end
			levels[#levels+1] = data:sub(cursor,cursor+count-1)
			cursor = cursor+count
		end
		if #levels ~= cache.plan.layout.mip+1 then return false end
		records[id] = levels
	end
	cache.records = records
	return true
end

function C.Open(plan,backend)
	-- Lua doubles and the native float policy may differ by one color byte.
	-- Keep cache identities independent so warm/cold output remains stable.
	local variant=backend=="lua" and ":lua-pixels-1:" or ""
	local cache = setmetatable({plan=plan,key=MC.ResourcePackRules.Hash(VERSION .. variant .. plan.key),records={},bytes=0,state="miss",hits=0},Cache)
	cache.path = ROOT .. "/" .. cache.key .. ".dat"
	local size = file.Size(cache.path,"DATA")
	if size and size > 0 and size <= LIMIT then
		local bytes = file.Read(cache.path,"DATA")
		if bytes and decode(cache,bytes) then cache.state="hit"
		else cache.state="corrupt" file.Delete(cache.path) end
	end
	return cache
end

function Cache:Get(index,channel)
	local levels = self.records[index .. ":" .. channel]
	if levels then self.hits=self.hits+1 end
	return levels
end

function Cache:Put(index,channel,levels)
	if self.state == "oversize" then return end
	local id = index .. ":" .. channel
	if self.records[id] then return end
	for _, bytes in ipairs(levels) do self.bytes=self.bytes+#bytes end
	if self.bytes > LIMIT-1048576 then self.records={} self.state="oversize" return end
	self.records[id]=levels
end

function Cache:Commit()
	if self.state == "oversize" then return true end
	file.CreateDir(ROOT)
	if self.state ~= "hit" then
		local parts = {}
		for id,levels in pairs(self.records) do
			local sizes={} for i,bytes in ipairs(levels) do sizes[i]=#bytes end
			parts[#parts+1]=id .. ":" .. table.concat(sizes,",") .. "\n"
			for _,bytes in ipairs(levels) do parts[#parts+1]=bytes end
		end
		local data=table.concat(parts)
		local bytes=VERSION .. "\n" .. self.key .. "\n" .. MC.ResourcePackRules.Hash(data) .. "\n" .. data
		local pending=ROOT .. "/" .. self.key .. ".pending.dat"
		file.Write(pending,bytes)
		if file.Read(pending,"DATA") ~= bytes then file.Delete(pending) return false,"resource_cache_write" end
		file.Rename(pending,self.path)
		if file.Size(self.path,"DATA") ~= #bytes then file.Delete(pending) return false,"resource_cache_publish" end
	end
	-- The tiny index is advisory. Ignore malformed entries and never use them
	-- as paths; pruning only visits our own content-addressed file names.
	local previous=file.Read(ROOT .. "/current.txt","DATA")
	if previous==self.key then previous=file.Read(ROOT .. "/previous.txt","DATA") end
	if not previous or not previous:match("^[a-f0-9]+$") or #previous~=64 then previous=nil end
	file.Write(ROOT .. "/current.txt",self.key)
	file.Write(ROOT .. "/previous.txt",previous or "")
	local files=file.Find(ROOT .. "/*","DATA")
	for _,name in ipairs(files) do
		local key=name:match("^([a-f0-9]+)%.dat$")
		if key and #key==64 and key~=self.key and key~=previous then file.Delete(ROOT .. "/" .. name) end
		if name:match("^[a-f0-9]+%.pending%.dat$") then file.Delete(ROOT .. "/" .. name) end
	end
	self.state="committed"
	return true
end

function Cache:Close()
	self.plan,self.records=nil,{}
end
