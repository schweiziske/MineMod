-- PNG framing/CRC, all standard sample types and Adam7. Inflate is bounded by
-- the exact scanline byte count before allocating pixels. No archive reader.
MC.ResourcePNG = {}
local PNG=MC.ResourcePNG
local floor,ceil,min=math.floor,math.ceil,math.min
local function be32(s,i) local a,b,c,d=s:byte(i,i+3);return ((a*256+b)*256+c)*256+d end
local function be16(s,i) local a,b=s:byte(i,i+1);return a*256+b end
local channels={[0]=1,[2]=3,[3]=1,[4]=2,[6]=4}
local depths={[0]={[1]=true,[2]=true,[4]=true,[8]=true,[16]=true},[2]={[8]=true,[16]=true},
	[3]={[1]=true,[2]=true,[4]=true,[8]=true},[4]={[8]=true,[16]=true},[6]={[8]=true,[16]=true}}
local adam={{0,0,8,8},{4,0,8,8},{0,4,4,8},{2,0,4,4},{0,2,2,4},{1,0,2,2},{0,1,1,2}}
function PNG.Decode(bytes,checkpoint)
	if type(bytes)~="string" or #bytes<45 or #bytes>134217728 or bytes:sub(1,8)~="\137PNG\13\10\26\10" then error("atlas_png_header",0) end
	local pos,w,h,depth,kind,interlace=9
	local palette,alpha,idat={},nil,{}
	local ended,complete,paletteSeen=false,false,false
	while pos<=#bytes do
		if pos+11>#bytes then error("atlas_png_truncated_chunk",0) end
		local n=be32(bytes,pos);local tag=bytes:sub(pos+4,pos+7)
		if n>#bytes-pos-11 then error("atlas_png_truncated_chunk",0) end
		if tonumber(util.CRC(bytes:sub(pos+4,pos+7+n)))~=be32(bytes,pos+8+n) then error("atlas_png_crc",0) end
		if not w and tag~="IHDR" then error("atlas_png_ihdr_missing",0) end
		local data=bytes:sub(pos+8,pos+7+n)
		if tag=="IHDR" then
			if w or n~=13 then error("atlas_png_ihdr_invalid",0) end
			w,h,depth,kind=be32(data,1),be32(data,5),data:byte(9),data:byte(10)
			interlace=data:byte(13)
			if w<1 or h<1 or w>16384 or h>16384 or w*h>67108864 then error("atlas_png_pixel_budget",0) end
			if not depths[kind] or not depths[kind][depth] or data:byte(11)~=0 or data:byte(12)~=0 or interlace>1 then error("atlas_png_encoding",0) end
		elseif tag=="PLTE" then
			if paletteSeen or #idat>0 or n==0 or n>768 or n%3~=0 or kind==0 or kind==4 then error("atlas_png_palette",0) end
			paletteSeen=true
			for i=1,n,3 do local r,g,b=data:byte(i,i+2);palette[(i-1)/3]={r,g,b} end
		elseif tag=="tRNS" then
			if alpha or #idat>0 or kind==0 and n~=2 or kind==2 and n~=6 or kind==3 and (not paletteSeen or n>256)
				or kind==4 or kind==6 then error("atlas_png_transparency",0) end
			alpha=data
		elseif tag=="IDAT" then
			if ended or kind==3 and not paletteSeen then error("atlas_png_idat_order",0) end
			idat[#idat+1]=data
		elseif tag=="IEND" then
			if #idat==0 or n~=0 or pos+11~=#bytes then error("atlas_png_iend_invalid",0) end
			complete=true;break
		else
			if #idat>0 then ended=true end
			if bit.band(tag:byte(1),32)==0 then error("atlas_png_unknown_critical_chunk",0) end
		end
		pos=pos+n+12
	end
	if not complete then error("atlas_png_iend_missing",0) end
	local passes=interlace==1 and adam or {{0,0,1,1}}
	local count,maximum=channels[kind],0
	for _,p in ipairs(passes) do
		local pw,ph=math.max(0,ceil((w-p[1])/p[3])),math.max(0,ceil((h-p[2])/p[4]))
		if pw>0 then maximum=maximum+(ceil(pw*count*depth/8)+1)*ph end
	end
	local raw,remaining=MC.ResourceInflate:DecompressZlibBounded(table.concat(idat),maximum,checkpoint)
	if not raw or #raw~=maximum or remaining~=0 then error("atlas_png_inflate:"..tostring(remaining),0) end
	local output={width=w,height=h,pixels={}}
	local cursor,bpp=1,math.max(1,ceil(count*depth/8))
	local maximumSample=2^depth-1
	local transparent
	if alpha and kind==0 then transparent={be16(alpha,1)}
	elseif alpha and kind==2 then transparent={be16(alpha,1),be16(alpha,3),be16(alpha,5)} end
	for _,pass in ipairs(passes) do
		local pw,ph=math.max(0,ceil((w-pass[1])/pass[3])),math.max(0,ceil((h-pass[2])/pass[4]))
		local stride=ceil(pw*count*depth/8);local previous={}
		if pw>0 then for y=0,ph-1 do
			local filter=raw:byte(cursor);cursor=cursor+1
			if filter>4 then error("atlas_png_filter",0) end
			local row={}
			for i=1,stride do
				local value=raw:byte(cursor);cursor=cursor+1
				local a,b,c=row[i-bpp] or 0,previous[i] or 0,previous[i-bpp] or 0
				if filter==1 then value=value+a
				elseif filter==2 then value=value+b
				elseif filter==3 then value=value+floor((a+b)/2)
				elseif filter==4 then
					local p=a+b-c;local pa,pb,pc=math.abs(p-a),math.abs(p-b),math.abs(p-c)
					value=value+(pa<=pb and pa<=pc and a or pb<=pc and b or c)
				end
				row[i]=value%256
			end
			local function sample(i)
				if depth==8 then return row[i+1] end
				if depth==16 then return row[i*2+1]*256+row[i*2+2] end
				local offset=i*depth;return floor(row[floor(offset/8)+1]/2^(8-depth-offset%8))%2^depth
			end
			for x=0,pw-1 do
				local index=x*count;local r,g,b,a=0,0,0,255
				if kind==3 then
					local i=sample(index);local p=palette[i];if not p then error("atlas_png_palette_index",0) end
					r,g,b=p[1],p[2],p[3];if alpha and i<#alpha then a=alpha:byte(i+1) end
				else
					local first=sample(index)
					if kind==0 or kind==4 then
						r=floor(first*255/maximumSample+0.5);g,b=r,r
						if kind==4 then a=floor(sample(index+1)*255/maximumSample+0.5)
						elseif transparent and first==transparent[1] then a=0 end
					else
						local green,blue=sample(index+1),sample(index+2)
						r,g,b=floor(first*255/maximumSample+0.5),floor(green*255/maximumSample+0.5),floor(blue*255/maximumSample+0.5)
						if kind==6 then a=floor(sample(index+3)*255/maximumSample+0.5)
						elseif transparent and first==transparent[1] and green==transparent[2] and blue==transparent[3] then a=0 end
					end
				end
				output.pixels[(pass[2]+y*pass[4])*w+pass[1]+x*pass[3]+1]=r+g*256+b*65536+a*16777216
			end
			previous=row
			if checkpoint and y%64==63 then checkpoint("decode") end
		end end
	end
	return output
end
