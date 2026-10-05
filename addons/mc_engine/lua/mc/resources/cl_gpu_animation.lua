-- Immutable frame storage and per-channel animation tables in the same atlas.
MC.ResourceGPUAnimation = {}
local A = MC.ResourceGPUAnimation
local floor, ceil, max = math.floor, math.ceil, math.max
local channels = {"color", "normal", "orm"}
function A.Sampled(sprite, channel)
	if sprite.overlayPNG then return sprite end
	if channel == "normal" then return sprite.normalSprite or sprite end
	if channel == "orm" then return sprite.specularSprite or sprite end
	return sprite
end
local function unique(sprite)
	local list, slots = {}, {}
	for _, frame in ipairs(sprite.frames) do
		if not slots[frame.index] then
			list[#list+1], slots[frame.index] = frame.index, #list+1
		end
	end
	return {frames=list, slots=slots, sprite=sprite}
end
function A.Layout(sprites, width, height, mip, aniso)
	local items, records, tableSize = {}, {}, 0
	for i, sprite in ipairs(sprites) do
		local record, count, largest = {}, 1, 0
		for _, channel in ipairs(channels) do
			local info = unique(A.Sampled(sprite,channel))
			record[channel], count = info, max(count,#info.frames)
			if info.sprite.animated then largest = max(largest,5+#info.sprite.frames*4) end
		end
		tableSize = tableSize + largest
		record.indices = {}
		for frame=1,count do
			items[#items+1] = {id="mc:gpu_frames/"..i.."/"..frame,width=sprite.width,height=sprite.height}
			record.indices[frame] = #items
		end
		records[i] = record
	end
	local layout, err, id = MC.AtlasLayout.Stitch(items,width,height,mip,aniso)
	if not layout then return nil,err,id end
	local align = 2^layout.mip
	-- Repack until the table covers every aligned cell of the final allocation.
	for attempt=1,16 do
		local cells = layout.width/align * layout.height/align
		-- A square avoids forcing the stitcher to grow a short row wider than
		-- its existing root, and leaves room for the table's own border.
		local tableWidth = ceil(math.sqrt(cells+tableSize)/align)*align
		local tableHeight = tableWidth
		items[#items+1] = {id="mc:gpu_animation/table",width=tableWidth,height=tableHeight}
		local packed, reason, failed = MC.AtlasLayout.Stitch(items,width,height,layout.mip,aniso)
		items[#items] = nil
		if not packed then return nil,reason,failed end
		if packed.width/align*packed.height/align+tableSize <= tableWidth*tableHeight then
			local tableRegion = packed.regions[#items+1]
			local regions = {}
			for i, record in ipairs(records) do
				record.regions = {}
				for n,index in ipairs(record.indices) do record.regions[n]=packed.regions[index] end
				record.indices = nil
				regions[i] = record.regions[1]
			end
			packed.regions = regions
			packed.gpu = {records=records,region=tableRegion,cell=align}
			return packed
		end
		layout = packed
	end
	return nil,"resource_gpu_table_layout"
end
local function u16(n) return string.char(n%256,floor(n/256)%256) end
local function u32(n) return u16(n%65536)..u16(floor(n/65536)) end
local function pair(x,y) return u16(x)..u16(y) end
local function float(n)
	if n==0 then return "\0\0\0\0" end
	local sign = n<0 and 2147483648 or 0
	local m,e = math.frexp(math.abs(n))
	return u32(sign+(e+126)*8388608+floor((m*2-1)*8388608+0.5))
end
-- Tables are raw RGBA8 at mip0. Higher levels are unused, never downsampled.
function A.Table(layout, channel)
	local gpu, data = layout.gpu, {}
	local gridWidth = layout.width/gpu.cell
	local cells = gridWidth*layout.height/gpu.cell
	local cursor = cells
	for i, record in ipairs(gpu.records) do
		local info, r = record[channel], layout.regions[i]
		local sprite = info.sprite
		if sprite.animated then
			local pointer, sequence = cursor, cursor+5
			data[pointer+1],data[pointer+2] = pair(r[1],r[2]),pair(r[3],r[4])
			data[pointer+3],data[pointer+4] = u32(sequence),u32(#sprite.frames)
			data[pointer+5] = float(sprite.interpolate and sprite.duration or -sprite.duration)
			for n,frame in ipairs(sprite.frames) do
				local first = record.regions[info.slots[frame.index]]
				local second = record.regions[info.slots[sprite.frames[n%#sprite.frames+1].index]]
				local at = sequence+(n-1)*4
				data[at+1],data[at+2] = float(frame.start),float(frame.time)
				data[at+3],data[at+4] = pair(first[1],first[2]),pair(second[1],second[2])
			end
			cursor = sequence+#sprite.frames*4
			-- Include the padding used by model UV shrink and edge sampling.
			local pad = layout.padding
			for y=(r[2]-pad)/gpu.cell,(r[2]+r[4]+pad)/gpu.cell-1 do
				for x=(r[1]-pad)/gpu.cell,(r[1]+r[3]+pad)/gpu.cell-1 do
					data[y*gridWidth+x+1]=u32(pointer)
				end
			end
		end
	end
	local r = gpu.region
	assert(cursor<=r[3]*r[4],"resource_gpu_table_overflow")
	for i=1,r[3]*r[4] do if not data[i] then data[i]="\0\0\0\0" end end
	local levels = {table.concat(data)}
	for mip=1,channel=="color" and layout.mip or 0 do
		levels[mip+1]=string.rep("\0",r[3]*r[4]*4/4^mip)
	end
	return levels
end
