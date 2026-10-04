-- CPU sprite policy for the ordinary GLua backend. No custom module or FFI.
MC.ResourceLuaPixels = {}
local P = MC.ResourceLuaPixels
local floor, sqrt, min, max = math.floor, math.sqrt, math.min, math.max
local band, rshift = bit.band, bit.rshift
local function rgba(p) return band(p,255),band(rshift(p,8),255),band(rshift(p,16),255),rshift(p,24) end
local function pack(r,g,b,a) return r+g*256+b*65536+a*16777216 end
local function byte(x) return max(0,min(255,floor(x+0.5))) end
P.Pack, P.RGBA = pack, rgba
local linear, srgb = {}, {}
for i=0,255 do local x=i/255; linear[i]=floor((x>=0.04045 and ((x+0.055)/1.055)^2.4 or x/12.92)*1023+0.5) end
for i=0,1023 do local x=i/1023; srgb[i]=byte((x>=0.0031308 and 1.055*x^(1/2.4)-0.055 or 12.92*x)*255) end

function P.Filter(pixels, weights, strategy)
	if strategy==5 then
		local x,y,z,ao,height=0,0,0,0,0
		for i,p in ipairs(pixels) do
			local r,g,b,a=rgba(p); local w=weights[i];local nx,ny=r*2/255-1,g*2/255-1
			x,y,z=x+w*nx,y+w*ny,z+w*sqrt(max(0,1-nx*nx-ny*ny));ao,height=ao+w*b,height+w*a
		end
		local length=sqrt(x*x+y*y+z*z)
		if length>1e-8 then x,y=x/length,y/length else x,y=0,0 end
		return pack(byte((x+1)*127.5),byte((y+1)*127.5),byte(ao),byte(height))
	end
	local chosen,best=1,-1
	for i,p in ipairs(pixels) do
		local g=band(rshift(p,8),255);local weight=0
		for j,q in ipairs(pixels) do local qg=band(rshift(q,8),255);if g<230 and qg<230 or g==qg then weight=weight+weights[j] end end
		if weight>best then chosen,best=i,weight end
	end
	local rough,emission,f0,fw,pw,sw,pore,sss=0,0,0,0,0,0,0,0
	for i,p in ipairs(pixels) do
		local r,g,b,a=rgba(p);local w=weights[i]
		rough,emission=rough+w*(255-r)^2,emission+w*(a==255 and 0 or a)
		if g<230 then f0,fw=f0+w*g,fw+w end
		if b<65 then pore,pw=pore+w*b,pw+w else sss,sw=sss+w*b,sw+w end
	end
	local green=band(rshift(pixels[chosen],8),255)
	if green<230 then green=byte(f0/max(fw,1e-8)) end
	local usePores=pw>sw or pw==sw and band(rshift(pixels[1],16),255)<65
	return pack(byte(255-sqrt(rough)),green,usePores and byte(pore/max(pw,1e-8)) or byte(sss/max(sw,1e-8)),emission>0 and byte(emission) or 255)
end
local function solidify(image,dark,checkpoint)
	local w,h,p=image.width,image.height,image.pixels
	if dark then
		local darkest,brightness=4294967295,math.huge
		for x=0,w-1 do for y=0,h-1 do local value=p[y*w+x+1];local r,g,b,a=rgba(value)
			if a>0 and r+g+b<brightness then darkest,brightness=value,r+g+b end
		end end
		local r,g,b=rgba(darkest);local fill=pack(floor(3*r/4),floor(3*g/4),floor(3*b/4),0)
		for i,value in ipairs(p) do if rshift(value,24)==0 then p[i]=fill end end
		return
	end
	local queue,nearest={},{}
	for x=0,w-1 do for y=0,h-1 do local i=y*w+x+1;if rshift(p[i],24)>0 then queue[#queue+1]=i;nearest[i]=p[i] end end end
	local head=1
	local function visit(i,value) if not nearest[i] then nearest[i]=value;queue[#queue+1]=i end end
	while head<=#queue do
		local i=queue[head];head=head+1;local x,y=(i-1)%w,floor((i-1)/w);local value=nearest[i]
		if x+1<w then visit(i+1,value) end;if x>0 then visit(i-1,value) end
		if y+1<h then visit(i+w,value) end;if y>0 then visit(i-w,value) end
		if checkpoint and head%65536==0 then checkpoint("mips") end
	end
	for i,value in ipairs(p) do if rshift(value,24)==0 then p[i]=band(nearest[i] or 0,16777215) end end
end
local function coverage(image,reference,scale,checkpoint)
	local p,w,h=image.pixels,image.width,image.height
	if w==1 or h==1 then return 0 end
	local count=0
	for y=0,h-2 do for x=0,w-2 do
		local i=y*w+x+1
		local a,b,c,d=min(rshift(p[i],24)/255*scale,1),min(rshift(p[i+1],24)/255*scale,1),
			min(rshift(p[i+w],24)/255*scale,1),min(rshift(p[i+w+1],24)/255*scale,1)
		for sy=0,3 do for sx=0,3 do local fx,fy=(sx+0.5)/4,(sy+0.5)/4
			if a*(1-fx)*(1-fy)+b*fx*(1-fy)+c*(1-fx)*fy+d*fx*fy>reference then count=count+1 end
		end end
	end
		if checkpoint and y%64==63 then checkpoint("mips") end
	end
	return count/(16*(w-1)*(h-1))
end
function P.Mips(image,mip,strategy,bias,item,checkpoint)
	if strategy==0 then
		strategy=1;for _,p in ipairs(image.pixels) do if rshift(p,24)==0 then strategy=2 break end end
	end
	local cutout=strategy>=2 and strategy<=4
	if cutout and not item then solidify(image,strategy==4,checkpoint) end
	local reference=strategy==3 and 0.3 or 0.5
	local original=cutout and coverage(image,reference,1,checkpoint) or 0
	local levels={image}
	for level=1,mip do
		local prev=levels[level];local out={width=prev.width/2,height=prev.height/2,pixels={}}
		local p,items=prev.pixels,{}
		for y=0,out.height-1 do for x=0,out.width-1 do
			local i=y*2*prev.width+x*2+1
			items[1],items[2],items[3],items[4]=p[i],p[i+1],p[i+prev.width],p[i+prev.width+1]
			local value
			if strategy>=5 then value=P.Filter(items,{0.25,0.25,0.25,0.25},strategy)
			else
				local r,g,b,a=0,0,0,0
				for _,v in ipairs(items) do local vr,vg,vb,va=rgba(v)
					if strategy~=4 or va>0 then r,g,b=r+linear[vr],g+linear[vg],b+linear[vb];a=a+(strategy==4 and linear[va] or va) end
				end
				value=pack(srgb[floor(r/4)],srgb[floor(g/4)],srgb[floor(b/4)],strategy==4 and srgb[floor(a/4)] or floor(a/4))
			end
			out.pixels[y*out.width+x+1]=value
		end
			if checkpoint and y%64==63 then checkpoint("mips") end
		end
		if cutout then
			local low,high,scale,best,bestError=0,4,1,1,math.huge
			for attempt=1,5 do
				local actual=coverage(out,reference,scale,checkpoint);local err=math.abs(actual-original)
				if err<bestError then best,bestError=scale,err end
				if actual<original then low=scale elseif actual>original then high=scale else break end
				scale=(low+high)/2
			end
			for i,pixel in ipairs(out.pixels) do
				out.pixels[i]=band(pixel,16777215)+floor(max(0,min(1,rshift(pixel,24)/255*best+bias+0.025))*255)*16777216
			end
		end
		levels[level+1]=out
	end
	return levels
end

function P.Compose(base,data,overlay,overlayData,options,frame,checkpoint)
	local w,h=options.width,options.height
	local bw,bh=options.baseWidth or w,options.baseHeight or h
	local ow,oh=options.overlayWidth or w,options.overlayHeight or h
	local strategy=options.strategy
	local tint=options.tint or {255,255,255}
	local function origin(image,fw,fh)
		local columns=image.width/fw;local n=columns*image.height/fh
		if n~=1 and frame>=n then error("atlas_compose_frame_count",0) end
		local index=n==1 and 0 or frame
		return (index%columns)*fw,floor(index/columns)*fh
	end
	local bx,by=origin(base,bw,bh);local ox,oy
	if overlay then ox,oy=origin(overlay,ow,oh) end
	local neutral=strategy==5 and pack(128,128,255,255) or pack(0,10,0,255)
	local out={width=w,height=h,pixels={}}
	for y=0,h-1 do for x=0,w-1 do
		local bi=(by+floor(y*bh/h))*base.width+bx+floor(x*bw/w)+1
		local value=base.pixels[bi]
		if not overlay then
			if strategy>=5 then value=data and data.pixels[bi] or neutral
			else local r,g,b,a=rgba(value);value=pack(floor((r*tint[1]+127)/255),floor((g*tint[2]+127)/255),floor((b*tint[3]+127)/255),a) end
		else
			local oi=(oy+floor(y*oh/h))*overlay.width+ox+floor(x*ow/w)+1
			local r,g,b,a=rgba(overlay.pixels[oi]);local br,bg,bb,ba=rgba(value)
			if strategy>=5 then
				local aw=a/255;local bwgt=ba/255*(1-aw);local sum=aw+bwgt
				value=P.Filter({data and data.pixels[bi] or neutral,overlayData and overlayData.pixels[oi] or neutral},
					{sum>0 and bwgt/sum or 1,sum>0 and aw/sum or 0},strategy)
			else
				r,g,b=floor((r*tint[1]+127)/255),floor((g*tint[2]+127)/255),floor((b*tint[3]+127)/255)
				local alpha=a*255+ba*(255-a)
				local function blend(v,bv) if alpha==0 then return bv end return floor((v*a*255+bv*ba*(255-a)+alpha/2)/alpha) end
				value=pack(blend(r,br),blend(g,bg),blend(b,bb),floor((alpha+127)/255))
			end
		end
		out.pixels[y*w+x+1]=value
	end
		if checkpoint and y%64==63 then checkpoint("mips") end
	end
	return out
end
function P.Sample(sprite,current,nextFrame,fraction)
	local output={}
	for level,a in ipairs(sprite.frames[current]) do
		local b=sprite.frames[nextFrame][level];local pad=sprite.padding/2^(level-1);local rows={}
		for y=0,a.height-1 do
			local row={}
			for x=0,a.width-1 do
				local i=y*a.width+x+1;local value=a.pixels[i]
				if current~=nextFrame and fraction>0 then
					if sprite.strategy>=5 then value=P.Filter({value,b.pixels[i]},{1-fraction,fraction},sprite.strategy)
					else
						local r,g,blue,alpha=rgba(value);local qr,qg,qb,qa=rgba(b.pixels[i])
						value=pack(byte(r+(qr-r)*fraction),byte(g+(qg-g)*fraction),byte(blue+(qb-blue)*fraction),byte(alpha+(qa-alpha)*fraction))
					end
				end
				row[#row+1]=string.char(rgba(value))
			end
			rows[#rows+1]=string.rep(row[1],pad)..table.concat(row)..string.rep(row[#row],pad)
		end
		output[level]=string.rep(rows[1],pad)..table.concat(rows)..string.rep(rows[#rows],pad)
	end
	return output
end
