
-- lua-MessagePack 0.5.2
-- Copyright (c) 2012-2019 Francois Perrad. MIT License.
-- https://fperrad.frama.io/lua-MessagePack/
-- Modified by Cosmin Apreutesei. Public Domain.

local jit = require'jit'

local assert = assert
local error = error
local pairs = pairs
local pcall = pcall
local setmetatable = setmetatable
local tostring = tostring
local type = type
local char = string.char
local format = string.format
local floor = math.floor
local frexp = math.frexp
local ldexp = math.ldexp
local huge = math.huge
local tconcat = table.concat

local maxinteger = 9007199254740991
local mininteger = -maxinteger

local m = {}

local packers = setmetatable({}, {
	__index = function (t, k)
		if k == 1 then return end   -- allows ipairs
		error('pack \'' .. k .. '\' is unimplemented')
	end
})
m.packers = packers

packers['nil'] = function (buffer)
	buffer[#buffer+1] = char(0xC0)              -- nil
end

packers['boolean'] = function (buffer, bool)
	if bool then
		buffer[#buffer+1] = char(0xC3)          -- true
	else
		buffer[#buffer+1] = char(0xC2)          -- false
	end
end

packers['string_compat'] = function (buffer, str)
	local n = #str
	if n <= 0x1F then
		buffer[#buffer+1] = char(0xA0 + n)      -- fixstr
	elseif n <= 0xFFFF then
		buffer[#buffer+1] = char(0xDA,          -- str16
								 floor(n / 0x100),
								 n % 0x100)
	elseif n <= 4294967295.0 then
		buffer[#buffer+1] = char(0xDB,          -- str32
								 floor(n / 0x1000000),
								 floor(n / 0x10000) % 0x100,
								 floor(n / 0x100) % 0x100,
								 n % 0x100)
	else
		error'overflow in pack \'string_compat\''
	end
	buffer[#buffer+1] = str
end

packers['_string'] = function (buffer, str)
	local n = #str
	if n <= 0x1F then
		buffer[#buffer+1] = char(0xA0 + n)      -- fixstr
	elseif n <= 0xFF then
		buffer[#buffer+1] = char(0xD9,          -- str8
								 n)
	elseif n <= 0xFFFF then
		buffer[#buffer+1] = char(0xDA,          -- str16
								 floor(n / 0x100),
								 n % 0x100)
	elseif n <= 4294967295.0 then
		buffer[#buffer+1] = char(0xDB,          -- str32
								 floor(n / 0x1000000),
								 floor(n / 0x10000) % 0x100,
								 floor(n / 0x100) % 0x100,
								 n % 0x100)
	else
		error'overflow in pack \'string\''
	end
	buffer[#buffer+1] = str
end

packers['binary'] = function (buffer, str)
	local n = #str
	if n <= 0xFF then
		buffer[#buffer+1] = char(0xC4,          -- bin8
								 n)
	elseif n <= 0xFFFF then
		buffer[#buffer+1] = char(0xC5,          -- bin16
								 floor(n / 0x100),
								 n % 0x100)
	elseif n <= 4294967295.0 then
		buffer[#buffer+1] = char(0xC6,          -- bin32
								 floor(n / 0x1000000),
								 floor(n / 0x10000) % 0x100,
								 floor(n / 0x100) % 0x100,
								 n % 0x100)
	else
		error'overflow in pack \'binary\''
	end
	buffer[#buffer+1] = str
end

local set_string = function (str)
	if str == 'string_compat' then
		packers['string'] = packers['string_compat']
	elseif str == 'string' then
		packers['string'] = packers['_string']
	elseif str == 'binary' then
		packers['string'] = packers['binary']
	else
		assert(false)
	end
end
m.set_string = set_string

packers['map'] = function (buffer, tbl, n)
	if n <= 0x0F then
		buffer[#buffer+1] = char(0x80 + n)      -- fixmap
	elseif n <= 0xFFFF then
		buffer[#buffer+1] = char(0xDE,          -- map16
								 floor(n / 0x100),
								 n % 0x100)
	elseif n <= 4294967295.0 then
		buffer[#buffer+1] = char(0xDF,          -- map32
								 floor(n / 0x1000000),
								 floor(n / 0x10000) % 0x100,
								 floor(n / 0x100) % 0x100,
								 n % 0x100)
	else
		error'overflow in pack \'map\''
	end
	for k, v in pairs(tbl) do
		packers[type(k)](buffer, k)
		packers[type(v)](buffer, v)
	end
end

packers['array'] = function (buffer, tbl, n)
	if n <= 0x0F then
		buffer[#buffer+1] = char(0x90 + n)      -- fixarray
	elseif n <= 0xFFFF then
		buffer[#buffer+1] = char(0xDC,          -- array16
								 floor(n / 0x100),
								 n % 0x100)
	elseif n <= 4294967295.0 then
		buffer[#buffer+1] = char(0xDD,          -- array32
								 floor(n / 0x1000000),
								 floor(n / 0x10000) % 0x100,
								 floor(n / 0x100) % 0x100,
								 n % 0x100)
	else
		error'overflow in pack \'array\''
	end
	for i = 1, n do
		local v = tbl[i]
		packers[type(v)](buffer, v)
	end
end

m.N = function() end

local set_array = function (array)
	if array == 'without_hole' then
		packers['_table'] = function (buffer, tbl)
			local is_map, n, max = false, tbl[m.N], 0
			if n then
				is_map = false
			else
				n = 0
				for k in pairs(tbl) do
					if type(k) == 'number' and k > 0 then
						if k > max then
							max = k
						end
					else
						is_map = true
					end
					n = n + 1
				end
				if max ~= n then    -- there are holes
					is_map = true
				end
			end
			if is_map then
				packers['map'](buffer, tbl, n)
			else
				packers['array'](buffer, tbl, n)
			end
		end
	elseif array == 'with_hole' then
		packers['_table'] = function (buffer, tbl)
			local is_map, n, max = false, 0, 0
			for k in pairs(tbl) do
				if type(k) == 'number' and k > 0 then
					if k > max then
						max = k
					end
				else
					is_map = true
				end
				n = n + 1
			end
			if is_map then
				packers['map'](buffer, tbl, n)
			else
				packers['array'](buffer, tbl, max)
			end
		end
	elseif array == 'always_as_map' then
		packers['_table'] = function(buffer, tbl)
			local n = 0
			for k in pairs(tbl) do
				n = n + 1
			end
			packers['map'](buffer, tbl, n)
		end
	else
		assert(false)
	end
end
m.set_array = set_array

packers['table'] = function (buffer, tbl)
	packers['_table'](buffer, tbl)
end

packers['unsigned'] = function (buffer, n)
	if n >= 0 then
		if n <= 0x7F then
			buffer[#buffer+1] = char(n)         -- fixnum_pos
		elseif n <= 0xFF then
			buffer[#buffer+1] = char(0xCC,      -- uint8
									 n)
		elseif n <= 0xFFFF then
			buffer[#buffer+1] = char(0xCD,      -- uint16
									 floor(n / 0x100),
									 n % 0x100)
		elseif n <= 4294967295.0 then
			buffer[#buffer+1] = char(0xCE,      -- uint32
									 floor(n / 0x1000000),
									 floor(n / 0x10000) % 0x100,
									 floor(n / 0x100) % 0x100,
									 n % 0x100)
		else
			buffer[#buffer+1] = char(0xCF,      -- uint64
									 0,         -- only 53 bits from double
									 floor(n / 0x1000000000000) % 0x100,
									 floor(n / 0x10000000000) % 0x100,
									 floor(n / 0x100000000) % 0x100,
									 floor(n / 0x1000000) % 0x100,
									 floor(n / 0x10000) % 0x100,
									 floor(n / 0x100) % 0x100,
									 n % 0x100)
		end
	else
		if n >= -0x20 then
			buffer[#buffer+1] = char(0x100 + n) -- fixnum_neg
		elseif n >= -0x80 then
			buffer[#buffer+1] = char(0xD0,      -- int8
									 0x100 + n)
		elseif n >= -0x8000 then
			n = 0x10000 + n
			buffer[#buffer+1] = char(0xD1,      -- int16
									 floor(n / 0x100),
									 n % 0x100)
		elseif n >= -0x80000000 then
			n = 4294967296.0 + n
			buffer[#buffer+1] = char(0xD2,      -- int32
									 floor(n / 0x1000000),
									 floor(n / 0x10000) % 0x100,
									 floor(n / 0x100) % 0x100,
									 n % 0x100)
		else
			buffer[#buffer+1] = char(0xD3,      -- int64
									 0xFF,      -- only 53 bits from double
									 floor(n / 0x1000000000000) % 0x100,
									 floor(n / 0x10000000000) % 0x100,
									 floor(n / 0x100000000) % 0x100,
									 floor(n / 0x1000000) % 0x100,
									 floor(n / 0x10000) % 0x100,
									 floor(n / 0x100) % 0x100,
									 n % 0x100)
		end
	end
end

packers['integer'] = packers['unsigned']

packers['float'] = function (buffer, n)
	local sign = 0
	if n < 0.0 then
		sign = 0x80
		n = -n
	end
	local mant, expo = frexp(n)
	if mant ~= mant then
		buffer[#buffer+1] = char(0xCA,  -- nan
								 0xFF, 0x88, 0x00, 0x00)
	elseif mant == huge or expo > 0x80 then
		if sign == 0 then
			buffer[#buffer+1] = char(0xCA,      -- inf
									 0x7F, 0x80, 0x00, 0x00)
		else
			buffer[#buffer+1] = char(0xCA,      -- -inf
									 0xFF, 0x80, 0x00, 0x00)
		end
	elseif (mant == 0.0 and expo == 0) or expo < -0x7E then
		buffer[#buffer+1] = char(0xCA,  -- zero
								 sign, 0x00, 0x00, 0x00)
	else
		expo = expo + 0x7E
		mant = floor((mant * 2.0 - 1.0) * ldexp(0.5, 24))
		buffer[#buffer+1] = char(0xCA,
								 sign + floor(expo / 0x2),
								 (expo % 0x2) * 0x80 + floor(mant / 0x10000),
								 floor(mant / 0x100) % 0x100,
								 mant % 0x100)
	end
end

packers['double'] = function (buffer, n)
	local sign = 0
	if n < 0.0 then
		sign = 0x80
		n = -n
	end
	local mant, expo = frexp(n)
	if mant ~= mant then
		buffer[#buffer+1] = char(0xCB,  -- nan
								 0xFF, 0xF8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
	elseif mant == huge or expo > 0x400 then
		if sign == 0 then
			buffer[#buffer+1] = char(0xCB,      -- inf
									 0x7F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
		else
			buffer[#buffer+1] = char(0xCB,      -- -inf
									 0xFF, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
		end
	elseif (mant == 0.0 and expo == 0) or expo < -0x3FE then
		buffer[#buffer+1] = char(0xCB,  -- zero
								 sign, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
	else
		expo = expo + 0x3FE
		mant = floor((mant * 2.0 - 1.0) * ldexp(0.5, 53))
		buffer[#buffer+1] = char(0xCB,
								 sign + floor(expo / 0x10),
								 (expo % 0x10) * 0x10 + floor(mant / 0x1000000000000),
								 floor(mant / 0x10000000000) % 0x100,
								 floor(mant / 0x100000000) % 0x100,
								 floor(mant / 0x1000000) % 0x100,
								 floor(mant / 0x10000) % 0x100,
								 floor(mant / 0x100) % 0x100,
								 mant % 0x100)
	end
end

local set_number = function (number)
	if number == 'float' then
		packers['number'] = function (buffer, n)
			if floor(n) == n and n < maxinteger and n > mininteger then
				packers['integer'](buffer, n)
			else
				packers['float'](buffer, n)
			end
		end
	elseif number == 'double' then
		packers['number'] = function (buffer, n)
			if floor(n) == n and n < maxinteger and n > mininteger then
				packers['integer'](buffer, n)
			else
				packers['double'](buffer, n)
			end
		end
	else
		assert(false)
	end
end
m.set_number = set_number

for k = 0, 4 do
	local n = floor(2^k)
	local fixext = 0xD4 + k
	packers['fixext' .. tostring(n)] = function (buffer, tag, data)
		assert(#data == n, 'bad length for fixext' .. tostring(n))
		buffer[#buffer+1] = char(fixext,
								 tag < 0 and tag + 0x100 or tag)
		buffer[#buffer+1] = data
	end
end

packers['ext'] = function (buffer, tag, data)
	local n = #data
	if n <= 0xFF then
		buffer[#buffer+1] = char(0xC7,          -- ext8
								 n,
								 tag < 0 and tag + 0x100 or tag)
	elseif n <= 0xFFFF then
		buffer[#buffer+1] = char(0xC8,          -- ext16
								 floor(n / 0x100),
								 n % 0x100,
								 tag < 0 and tag + 0x100 or tag)
	elseif n <= 4294967295.0 then
		buffer[#buffer+1] = char(0xC9,          -- ext&32
								 floor(n / 0x1000000),
								 floor(n / 0x10000) % 0x100,
								 floor(n / 0x100) % 0x100,
								 n % 0x100,
								 tag < 0 and tag + 0x100 or tag)
	else
		error'overflow in pack \'ext\''
	end
	buffer[#buffer+1] = data
end

function m.pack (data)
	local buffer = {}
	packers[type(data)](buffer, data)
	return tconcat(buffer)
end

function m.pack_args(...)
	local buffer = {}
	packers.array(buffer, {...}, select('#', ...))
	return tconcat(buffer)
end

local unpackers         -- forward declaration

local function unpack_cursor(c)
	local s, i, j = c.s, c.i, c.j
	if i > j then
		c:underflow(i)
		s, i, j = c.s, c.i, c.j
	end
	local val = s:byte(i)
	c.i = i+1
	return unpackers[val](c, val)
end
m.unpack_cursor = unpack_cursor

local function unpack_str(c, n)
	local s, i, j = c.s, c.i, c.j
	local e = i+n-1
	if e > j or n < 0 then
		c:underflow(e)
		s, i, j = c.s, c.i, c.j
		e = i+n-1
	end
	c.i = i+n
	return s:sub(i, e)
end

local function unpack_array(c, n)
	local t = {}
	for i = 1, n do
		t[i] = unpack_cursor(c)
	end
	return t
end

local function unpack_map(c, n)
	local t = {}
	for i = 1, n do
		local k = unpack_cursor(c)
		local val = unpack_cursor(c)
		if k == nil or k ~= k then
			k = m.sentinel
		end
		if k ~= nil then
			t[k] = val
		end
	end
	return t
end

local function unpack_float (c)
	local s, i, j = c.s, c.i, c.j
	if i+3 > j then
		c:underflow(i+3)
		s, i, j = c.s, c.i, c.j
	end
	local b1, b2, b3, b4 = s:byte(i, i+3)
	local sign = b1 > 0x7F
	local expo = (b1 % 0x80) * 0x2 + floor(b2 / 0x80)
	local mant = ((b2 % 0x80) * 0x100 + b3) * 0x100 + b4
	if sign then
		sign = -1
	else
		sign = 1
	end
	local n
	if mant == 0 and expo == 0 then
		n = sign * 0.0
	elseif expo == 0xFF then
		if mant == 0 then
			n = sign * huge
		else
			n = 0.0/0.0
		end
	else
		n = sign * ldexp(1.0 + mant / 0x800000, expo - 0x7F)
	end
	c.i = i+4
	return n
end

local function unpack_double (c)
	local s, i, j = c.s, c.i, c.j
	if i+7 > j then
		c:underflow(i+7)
		s, i, j = c.s, c.i, c.j
	end
	local b1, b2, b3, b4, b5, b6, b7, b8 = s:byte(i, i+7)
	local sign = b1 > 0x7F
	local expo = (b1 % 0x80) * 0x10 + floor(b2 / 0x10)
	local mant = ((((((b2 % 0x10) * 0x100 + b3) * 0x100 + b4) * 0x100 + b5) * 0x100 + b6) * 0x100 + b7) * 0x100 + b8
	if sign then
		sign = -1
	else
		sign = 1
	end
	local n
	if mant == 0 and expo == 0 then
		n = sign * 0.0
	elseif expo == 0x7FF then
		if mant == 0 then
			n = sign * huge
		else
			n = 0.0/0.0
		end
	else
		n = sign * ldexp(1.0 + mant / 4503599627370496.0, expo - 0x3FF)
	end
	c.i = i+8
	return n
end

local function unpack_uint8 (c)
	local s, i, j = c.s, c.i, c.j
	if i > j then
		c:underflow(i)
		s, i, j = c.s, c.i, c.j
	end
	local b1 = s:byte(i)
	c.i = i+1
	return b1
end

local function unpack_uint16 (c)
	local s, i, j = c.s, c.i, c.j
	if i+1 > j then
		c:underflow(i+1)
		s, i, j = c.s, c.i, c.j
	end
	local b1, b2 = s:byte(i, i+1)
	c.i = i+2
	return b1 * 0x100 + b2
end

local function unpack_uint32 (c)
	local s, i, j = c.s, c.i, c.j
	if i+3 > j then
		c:underflow(i+3)
		s, i, j = c.s, c.i, c.j
	end
	local b1, b2, b3, b4 = s:byte(i, i+3)
	c.i = i+4
	return ((b1 * 0x100 + b2) * 0x100 + b3) * 0x100 + b4
end

local function unpack_uint64 (c)
	local s, i, j = c.s, c.i, c.j
	if i+7 > j then
		c:underflow(i+7)
		s, i, j = c.s, c.i, c.j
	end
	local b1, b2, b3, b4, b5, b6, b7, b8 = s:byte(i, i+7)
	c.i = i+8
	return ((((((b1 * 0x100 + b2) * 0x100 + b3) * 0x100 + b4) * 0x100 + b5) * 0x100 + b6) * 0x100 + b7) * 0x100 + b8
end

local function unpack_int8 (c)
	local s, i, j = c.s, c.i, c.j
	if i > j then
		c:underflow(i)
		s, i, j = c.s, c.i, c.j
	end
	local b1 = s:byte(i)
	c.i = i+1
	if b1 < 0x80 then
		return b1
	else
		return b1 - 0x100
	end
end

local function unpack_int16 (c)
	local s, i, j = c.s, c.i, c.j
	if i+1 > j then
		c:underflow(i+1)
		s, i, j = c.s, c.i, c.j
	end
	local b1, b2 = s:byte(i, i+1)
	c.i = i+2
	if b1 < 0x80 then
		return b1 * 0x100 + b2
	else
		return ((b1 - 0xFF) * 0x100 + (b2 - 0xFF)) - 1
	end
end

local function unpack_int32 (c)
	local s, i, j = c.s, c.i, c.j
	if i+3 > j then
		c:underflow(i+3)
		s, i, j = c.s, c.i, c.j
	end
	local b1, b2, b3, b4 = s:byte(i, i+3)
	c.i = i+4
	if b1 < 0x80 then
		return ((b1 * 0x100 + b2) * 0x100 + b3) * 0x100 + b4
	else
		return ((((b1 - 0xFF) * 0x100 + (b2 - 0xFF)) * 0x100 + (b3 - 0xFF)) * 0x100 + (b4 - 0xFF)) - 1
	end
end

local function unpack_int64 (c)
	local s, i, j = c.s, c.i, c.j
	if i+7 > j then
		c:underflow(i+7)
		s, i, j = c.s, c.i, c.j
	end
	local b1, b2, b3, b4, b5, b6, b7, b8 = s:byte(i, i+7)
	c.i = i+8
	if b1 < 0x80 then
		return ((((((b1 * 0x100 + b2) * 0x100 + b3) * 0x100 + b4) * 0x100 + b5) * 0x100 + b6) * 0x100 + b7) * 0x100 + b8
	else
		return ((((((((b1 - 0xFF) * 0x100 + (b2 - 0xFF)) * 0x100 + (b3 - 0xFF)) * 0x100 + (b4 - 0xFF)) * 0x100 + (b5 - 0xFF)) * 0x100 + (b6 - 0xFF)) * 0x100 + (b7 - 0xFF)) * 0x100 + (b8 - 0xFF)) - 1
	end
end

function m.build_ext (tag, data)
	return nil
end

local function unpack_ext (c, n, tag)
	local s, i, j = c.s, c.i, c.j
	local e = i+n-1
	if e > j or n < 0 then
		c:underflow(e)
		s, i, j = c.s, c.i, c.j
		e = i+n-1
	end
	c.i = i+n
	return m.build_ext(tag, s:sub(i, e))
end

unpackers = setmetatable({
	[0xC0] = function () return nil end,
	[0xC2] = function () return false end,
	[0xC3] = function () return true end,
	[0xC4] = function (c) return unpack_str(c, unpack_uint8(c)) end,    -- bin8
	[0xC5] = function (c) return unpack_str(c, unpack_uint16(c)) end,   -- bin16
	[0xC6] = function (c) return unpack_str(c, unpack_uint32(c)) end,   -- bin32
	[0xC7] = function (c) return unpack_ext(c, unpack_uint8(c), unpack_int8(c)) end,
	[0xC8] = function (c) return unpack_ext(c, unpack_uint16(c), unpack_int8(c)) end,
	[0xC9] = function (c) return unpack_ext(c, unpack_uint32(c), unpack_int8(c)) end,
	[0xCA] = unpack_float,
	[0xCB] = unpack_double,
	[0xCC] = unpack_uint8,
	[0xCD] = unpack_uint16,
	[0xCE] = unpack_uint32,
	[0xCF] = unpack_uint64,
	[0xD0] = unpack_int8,
	[0xD1] = unpack_int16,
	[0xD2] = unpack_int32,
	[0xD3] = unpack_int64,
	[0xD4] = function (c) return unpack_ext(c, 1, unpack_int8(c)) end,
	[0xD5] = function (c) return unpack_ext(c, 2, unpack_int8(c)) end,
	[0xD6] = function (c) return unpack_ext(c, 4, unpack_int8(c)) end,
	[0xD7] = function (c) return unpack_ext(c, 8, unpack_int8(c)) end,
	[0xD8] = function (c) return unpack_ext(c, 16, unpack_int8(c)) end,
	[0xD9] = function (c) return unpack_str(c, unpack_uint8(c)) end,
	[0xDA] = function (c) return unpack_str(c, unpack_uint16(c)) end,
	[0xDB] = function (c) return unpack_str(c, unpack_uint32(c)) end,
	[0xDC] = function (c) return unpack_array(c, unpack_uint16(c)) end,
	[0xDD] = function (c) return unpack_array(c, unpack_uint32(c)) end,
	[0xDE] = function (c) return unpack_map(c, unpack_uint16(c)) end,
	[0xDF] = function (c) return unpack_map(c, unpack_uint32(c)) end,
}, {
	__index = function (t, k)
		if k < 0xC0 then
			if k < 0x80 then
				return function (c, val) return val end
			elseif k < 0x90 then
				return function (c, val) return unpack_map(c, val % 0x10) end
			elseif k < 0xA0 then
				return function (c, val) return unpack_array(c, val % 0x10) end
			else
				return function (c, val) return unpack_str(c, val % 0x20) end
			end
		elseif k > 0xDF then
			return function (c, val) return val - 0x100 end
		else
			return function () error('unpack \'' .. format('%#x', k) .. '\' is unimplemented') end
		end
	end
})

local function cursor_string(str)
	return {
		s = str,
		i = 1,
		j = #str,
		underflow = function() error 'missing bytes' end,
	}
end

local function cursor_loader (ld)
	return {
		s = '',
		i = 1,
		j = 0,
		underflow = function (self, e)
						self.s = self.s:sub(self.i)
						e = e - self.i + 1
						self.i = 1
						self.j = 0
						while e > self.j do
							local chunk = ld()
							if not chunk then
								error 'missing bytes'
							end
							self.s = self.s .. chunk
							self.j = #self.s
						end
					end,
	}
end

function m.unpack(s)
	local cursor = cursor_string(s)
	local data = unpack_cursor(cursor)
	if cursor.i <= cursor.j then
		return nil, 'extra bytes'
	end
	return data
end

function m.unpacker(src)
	local cursor = cursor_string(src)
	return function()
		if cursor.i <= cursor.j then
			return cursor.i, unpack_cursor(cursor)
		end
	end
end

set_string'string_compat'
set_number'double'
set_array'without_hole'

return m
