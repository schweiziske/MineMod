-- Lua PNG/pixel policy and public GMod file/ITexture APIs; no custom DLL.
-- Source reloads an entire VTF on Download; native can accelerate that upload.
MC.ResourceLuaBackend = MC.ResourceLuaBackend or {state={textures={},sprites={},slots={},serial=0,used=0,resident=0}}
local B, P = MC.ResourceLuaBackend, MC.ResourceLuaPixels
B.kind = "lua"
local ROOT="mc/resourcepacks/runtime"
local state=B.state
local textures,sprites,slots=state.textures,state.sprites,state.slots
local function u16(n) return string.char(n%256,math.floor(n/256)%256) end
local function u32(n) return u16(n%65536)..u16(math.floor(n/65536)) end
local function header(w,h,count,noMip)
	local flags = 4+8+512+1024+8192 + (noMip and 1+256 or 0)
	return "VTF\0"..u32(7)..u32(2)..u32(80)..u16(w)..u16(h)..u32(flags)..u16(1)..u16(0)
		..string.rep("\0",20)..u32(1065353216)..u32(0)..string.char(count)..u32(4294967295).."\0\0"..u16(1)..string.rep("\0",15)
end
function B.BeginBuild(checkpoint) B.decoded={};B.checkpoint=checkpoint end
function B.EndBuild() B.decoded=nil;B.checkpoint=nil end
local function decode(bytes)
	if B.decoded and B.decoded[bytes] then return B.decoded[bytes] end
	local out=MC.ResourcePNG.Decode(bytes,B.checkpoint)
	if B.decoded then B.decoded[bytes]=out end
	return out
end
function B.CreateAtlasSprite(png,options)
	local base=decode(png);local data,overlay,overlayData
	if options.dataPNG then data=decode(options.dataPNG) end
	if options.overlayPNG then overlay=decode(options.overlayPNG) end
	if options.overlayDataPNG then overlayData=decode(options.overlayDataPNG) end
	if data and (data.width~=base.width or data.height~=base.height)
		or overlayData and (not overlay or overlayData.width~=overlay.width or overlayData.height~=overlay.height) then
		return nil,"atlas_material_dimensions"
	end
	local w,h=options.width,options.height
	local bw,bh=options.baseWidth or w,options.baseHeight or h
	if w<1 or h<1 or w%2^options.mip~=0 or h%2^options.mip~=0 or base.width%bw~=0 or base.height%bh~=0
		or overlay and (overlay.width%options.overlayWidth~=0 or overlay.height%options.overlayHeight~=0) then return nil,"atlas_sprite_dimensions" end
	if overlay then
		local bn=base.width/bw*base.height/bh
		local on=overlay.width/options.overlayWidth*overlay.height/options.overlayHeight
		if bn~=on and bn~=1 and on~=1 then return nil,"atlas_compose_frame_count" end
	end
	local sprite={frames={},padding=options.padding,strategy=options.strategy}
	local frameBytes,unique,count=0,{},0
	for level=0,options.mip do frameBytes=frameBytes+w*h*8/4^level end
	for _,index in ipairs(options.frames) do if not unique[index] then unique[index]=true;count=count+1 end end
	if state.used+frameBytes*count>805306368 then return nil,"atlas_sprite_memory_budget" end
	local first,constant,bytes=nil,true,0
	-- Resident GPU frames do not consume this legacy CPU-animation analysis.
	-- Omit the result when not requested; direct callers retain its old meaning.
	if options.detectConstant==false then constant=nil end
	for _,index in ipairs(options.frames) do
		if not sprite.frames[index] then
			local image=P.Compose(base,data,overlay,overlayData,options,index,B.checkpoint)
			local levels=P.Mips(image,options.mip,options.strategy,options.alphaBias,options.item,B.checkpoint)
			for _,level in ipairs(levels) do bytes=bytes+#level.pixels*8 end
			if constant then
				if not first then first=image.pixels
				else for i,p in ipairs(image.pixels) do if p~=first[i] then constant=false break end end end
			end
			sprite.frames[index]=levels
			if B.checkpoint then B.checkpoint("mips") end
		end
	end
	if constant and options.strategy==5 then
		for _,levels in pairs(sprite.frames) do for _,level in ipairs(levels) do for _,p in ipairs(level.pixels) do
			if P.Filter({p,p},{0.5,0.5},5)~=p then constant=false break end
		end end end
	end
	state.serial=state.serial+1;sprite.bytes=bytes;sprites[state.serial]=sprite;state.used=state.used+bytes
	return {id=state.serial,imageWidth=base.width,imageHeight=base.height,constant=constant}
end
function B.SampleAtlasSprite(id,a,b,fraction)
	local sprite=sprites[id]
	if not sprite or not sprite.frames[a] or not sprite.frames[b] or fraction<0 or fraction>1 or fraction~=fraction then return nil,"atlas_sprite_sample" end
	return P.Sample(sprite,a,b,fraction)
end
function B.ReleaseAtlasSprite(id)
	local sprite=sprites[id];if not sprite then return nil,"atlas_sprite_handle" end
	state.used=state.used-sprite.bytes;sprites[id]=nil;return true
end
function B.CreateAtlasTexture(w,h,mip,noMip)
	if type(w)~="number" or type(h)~="number" or type(mip)~="number" or w~=math.floor(w) or h~=math.floor(h)
		or mip~=math.floor(mip) or w<1 or h<1 or w>16384 or h>16384 or mip<0 or mip>14
		or bit.band(w,w-1)~=0 or bit.band(h,h-1)~=0 or math.min(w,h)<2^mip then return nil,"atlas_texture_dimensions" end
	if noMip and mip~=0 then return nil,"atlas_texture_nomip_levels" end
	local slot
	for i=1,10 do if not slots[i] then slot=i break end end
	if not slot then return nil,"atlas_lua_slot_budget" end
	-- File textures stop at 32 texels in Source. Replicate very small atlases;
	-- logical dimensions still drive UV snapping and LOD in BindSampling.
	local scale=1
	while not noMip and math.min(w,h)*scale/2^mip<32 do scale=scale*2 end
	local width,height=w*scale,h*scale
	if width>16384 or height>16384 or width*height*16/3>1500000000 then return nil,"atlas_texture_budget" end
	local levels={};local tw,th=width,height
	while true do
		levels[#levels+1]={width=tw,height=th}
		if noMip or tw==1 and th==1 then break end
		tw,th=math.max(1,tw/2),math.max(1,th/2)
	end
	local count=80
	for i=#levels,1,-1 do levels[i].offset=count;count=count+levels[i].width*levels[i].height*4 end
	if state.resident+count>1500000000 then return nil,"atlas_texture_resident_budget" end
	file.CreateDir(ROOT)
	local suffix=noMip and "_nomip" or ""
	local path=ROOT.."/atlas_"..slot..suffix..".vtf"
	local f=file.Open(path,"wb","DATA");if not f then return nil,"atlas_texture_file_open" end
	local ok,err=pcall(function()
		f:Write(header(width,height,#levels,noMip))
		local zero=string.rep("\0",65536)
		local remaining=count-80
		while remaining>0 do local n=math.min(remaining,#zero);f:Write(zero:sub(1,n));remaining=remaining-n end
		local actual=f:Tell();f:Flush()
		if actual~=count or file.Size(path,"DATA")~=count then error("atlas_texture_file_write",0) end
	end)
	if not ok then f:Close();return nil,tostring(err) end
	state.serial=state.serial+1
	local texture={id=state.serial,slot=slot,path=path,file=f,width=w,height=h,scale=scale,mip=mip,levels=levels,size=count,
		noMip=noMip==true,suffix=suffix}
	textures[state.serial],slots[slot]=texture,true
	state.resident=state.resident+count
	return texture
end
function B.UploadAtlasTextureRect(id,x,y,w,h,levels,defer)
	local t=textures[id]
	if not t or x<0 or y<0 or x+w>t.width or y+h>t.height or #levels~=t.mip+1
		or x%2^t.mip~=0 or y%2^t.mip~=0 or w%2^t.mip~=0 or h%2^t.mip~=0 then return nil,"atlas_texture_rect" end
	for i,bytes in ipairs(levels) do if #bytes~=w*h*4/4^(i-1) then return nil,"atlas_texture_rect_bytes" end end
	local f=t.file
	for i,bytes in ipairs(levels) do
		local div=2^(i-1);local tw,th=w/div,h/div;local level=t.levels[i]
		for row=0,th-1 do
			local data=bytes:sub(row*tw*4+1,(row+1)*tw*4)
			if t.scale>1 then
				local expanded={};for p=1,#data,4 do expanded[#expanded+1]=string.rep(data:sub(p,p+3),t.scale) end
				data=table.concat(expanded)
			end
			for repeatRow=0,t.scale-1 do
				f:Seek(level.offset+((y/div*t.scale+row*t.scale+repeatRow)*level.width+x/div*t.scale)*4)
				f:Write(data)
			end
		end
	end
	t.dirty=true
	if defer then return true end
	return B.FlushAtlasTexture(id)
end
function B.FlushAtlasTexture(id)
	local t=textures[id];if not t then return nil,"atlas_texture_handle" end
	t.file:Flush()
	if file.Size(t.path,"DATA")~=t.size then return nil,"atlas_texture_file_changed" end
	if not t.texture then
		local material=CreateMaterial("mc_resource_lua_proxy_"..t.slot..(t.suffix or ""),"UnlitGeneric",{["$basetexture"]="../data/"..t.path})
		t.texture=material:GetTexture("$basetexture")
	end
	if not t.texture or t.texture:IsError() then return nil,"atlas_texture_import" end
	t.texture:Download()
	if t.texture:Width()~=t.width*t.scale or t.texture:Height()~=t.height*t.scale then return nil,"atlas_texture_dimensions" end
	t.name=t.texture:GetName();t.dirty=false
	return true
end
function B.UpdateAtlasSpriteTexture(sprite,id,x,y,a,b,fraction)
	local t=textures[id];local s=sprites[sprite]
	if not t or not s then return nil,"atlas_update_handle" end
	local levels,err=B.SampleAtlasSprite(sprite,a,b,fraction);if not levels then return nil,err end
	local image=s.frames[a][1]
	return B.UploadAtlasTextureRect(id,x,y,image.width+s.padding*2,image.height+s.padding*2,levels,true)
end
B.FlushAtlasTextureUpdates=B.FlushAtlasTexture
function B.BindAtlasTexture(id,materialName,parameter)
	local t=textures[id];if not t or not t.texture then return nil,"atlas_texture_not_uploaded" end
	Material(materialName):SetTexture(parameter,t.texture);return true
end
function B.ReleaseAtlasTexture(id)
	local t=textures[id];if not t then return nil,"atlas_texture_handle" end
	t.file:Close()
	-- Reuse a bounded set of Source texture names, shrinking retired GPU storage.
	file.Write(t.path,header(1,1,1,t.noMip).."\0\0\0\0")
	if t.texture then t.texture:Download() end
	state.resident=state.resident-t.size
	textures[id],slots[t.slot]=nil,nil;return true
end
