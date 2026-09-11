-- Lua-only, interleaved numeric vertices. No table/Vector/Color per vertex.
-- Published buffers belong to their record; only unpublished scratch may Reset.
MC = MC or {}
local Buffer = {}
MC.RenderVertexBuffer = Buffer
Buffer.VERSION = 1
Buffer.STRIDE = 16
-- xyz, normal xyz, uv, uv1, rgba, normal-present, secondary-uv-present.
local STRIDE = Buffer.STRIDE

function Buffer.New()
	return { vertexBufferVersion = Buffer.VERSION, count = 0 }
end

function Buffer.Count( vertices )
	if not vertices then return 0 end
	if vertices.vertexBufferVersion then return vertices.count end
	return #vertices
end

function Buffer.Reset( vertices )
	-- Clearing numeric slots releases no engine objects. Lua retains array capacity.
	for i = 1, vertices.count * STRIDE do vertices[i] = nil end
	vertices.count = 0
	return vertices
end

function Buffer.PushValues( vertices, x, y, z, normal, u, v, color, u1, v1 )
	local n = vertices.count + 1
	local offset = ( n - 1 ) * STRIDE
	vertices[offset + 1], vertices[offset + 2], vertices[offset + 3] = x, y, z
	vertices[offset + 4] = normal and normal.x or 0
	vertices[offset + 5] = normal and normal.y or 0
	vertices[offset + 6] = normal and normal.z or 0
	vertices[offset + 7], vertices[offset + 8] = u or 0, v or 0
	vertices[offset + 9], vertices[offset + 10] = u1 or 0, v1 or 0
	vertices[offset + 11] = color and color.r or 255
	vertices[offset + 12] = color and color.g or 255
	vertices[offset + 13] = color and color.b or 255
	vertices[offset + 14] = color and color.a or 255
	vertices[offset + 15] = normal and 1 or 0
	vertices[offset + 16] = ( u1 ~= nil or v1 ~= nil ) and 1 or 0
	vertices.count = n
end

function Buffer.PushLegacy( vertices, vertex )
	if vertex.x ~= nil then
		local n = vertices.count + 1
		local offset = ( n - 1 ) * STRIDE
		vertices[offset + 1], vertices[offset + 2], vertices[offset + 3] = vertex.x, vertex.y, vertex.z
		vertices[offset + 4], vertices[offset + 5], vertices[offset + 6] = vertex.nx or 0, vertex.ny or 0, vertex.nz or 0
		vertices[offset + 7], vertices[offset + 8] = vertex.u or 0, vertex.v or 0
		vertices[offset + 9], vertices[offset + 10] = vertex.u1 or 0, vertex.v1 or 0
		vertices[offset + 11], vertices[offset + 12] = vertex.r or 255, vertex.g or 255
		vertices[offset + 13], vertices[offset + 14] = vertex.b or 255, vertex.a or 255
		vertices[offset + 15] = vertex.nx ~= nil and 1 or 0
		vertices[offset + 16] = ( vertex.u1 ~= nil or vertex.v1 ~= nil ) and 1 or 0
		vertices.count = n
	else
		local pos = vertex.pos
		Buffer.PushValues( vertices, pos.x, pos.y, pos.z, vertex.normal,
			vertex.u, vertex.v, vertex.color, vertex.u1, vertex.v1 )
	end
end

-- Destination must be packed and unshared; source may be a pre-migration cache.
function Buffer.AppendRange( target, source, first, count )
	if source.vertexBufferVersion then
		local targetOffset = target.count * STRIDE
		local sourceOffset = ( first - 1 ) * STRIDE
		for i = 1, count * STRIDE do target[targetOffset + i] = source[sourceOffset + i] end
		target.count = target.count + count
	else
		for i = first, first + count - 1 do Buffer.PushLegacy( target, source[i] ) end
	end
end

function Buffer.SetColor( vertices, index, color )
	if not color then return end
	if vertices.vertexBufferVersion then
		local offset = ( index - 1 ) * STRIDE
		vertices[offset + 11], vertices[offset + 12] = color.r or 255, color.g or 255
		vertices[offset + 13], vertices[offset + 14] = color.b or 255, color.a or 255
	else
		local vertex = vertices[index]
		if vertex.x ~= nil then
			vertex.r, vertex.g, vertex.b, vertex.a = color.r or 255, color.g or 255, color.b or 255, color.a or 255
		else
			vertex.color = color
		end
	end
end

-- Cold diagnostic, never called from the frame/build loop.
function Buffer.Validate( vertices )
	if type( vertices ) ~= "table" then return false end
	if not vertices.vertexBufferVersion then return true end
	if vertices.vertexBufferVersion ~= Buffer.VERSION then return false end
	local count = vertices.count
	if type( count ) ~= "number" or count < 0 or count ~= math.floor( count ) then return false end
	if #vertices ~= count * STRIDE then return false end
	for i = 1, count * STRIDE do
		local value = vertices[i]
		if type( value ) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return false end
	end
	return true
end
