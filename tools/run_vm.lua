-- run_vm.lua — deserialize a dumped Luraph/KX stage-2 VM and optionally run it.
--
-- Usage:
--   luajit run_vm.lua <vm.lua> <data.bin> [probe]
--
-- Requires LuaJIT 2.1+ (ffi, bit). No Roblox client is needed: the Roblox
-- surface is mocked and every external call is logged.
--
-- Key point: the VM's dependency slot [2] is Luau's table.pack, not a buffer
-- constructor. If [2] is set to buffer.fromstring, the VM passes a 2.35 MB
-- buffer to unpack() and LuaJIT reports "too many results to unpack". The
-- polyfills below are what make the deserializer work.
io.stdout:setvbuf("no")
local ffi = require("ffi")
local bit = require("bit")

local function u32(x) return x % 4294967296 end
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, arshift, rol, ror, bswap = bit.lshift, bit.rshift, bit.arshift, bit.rol, bit.ror, bit.bswap

local function shl(x, n)
  if n >= 32 or n <= -32 then return 0 end
  if n < 0 then return u32(rshift(x, -n)) end
  return u32(lshift(x, n))
end
local function shr(x, n)
  if n >= 32 or n <= -32 then return 0 end
  if n < 0 then return u32(lshift(x, -n)) end
  return u32(rshift(x, n))
end

bit32 = {}
function bit32.band(a, b, c, d)
  if a == nil then return 4294967295 end
  local r = a
  if b ~= nil then r = band(r, b) end
  if c ~= nil then r = band(r, c) end
  if d ~= nil then r = band(r, d) end
  return u32(r)
end
function bit32.bor(a, b, c, d)
  if a == nil then return 0 end
  local r = a
  if b ~= nil then r = bor(r, b) end
  if c ~= nil then r = bor(r, c) end
  if d ~= nil then r = bor(r, d) end
  return u32(r)
end
function bit32.bxor(a, b, c, d)
  if a == nil then return 0 end
  local r = a
  if b ~= nil then r = bxor(r, b) end
  if c ~= nil then r = bxor(r, c) end
  if d ~= nil then r = bxor(r, d) end
  return u32(r)
end
function bit32.bnot(x) return u32(bnot(x)) end
function bit32.lshift(x, n) return shl(x, n) end
function bit32.rshift(x, n) return shr(x, n) end
function bit32.arshift(x, n)
  if n >= 32 then return band(x, 0x80000000) ~= 0 and 4294967295 or 0 end
  if n <= -32 then return 0 end
  if n < 0 then return u32(lshift(x, -n)) end
  return u32(arshift(x, n))
end
function bit32.lrotate(x, n) return u32(rol(x, n % 32)) end
function bit32.rrotate(x, n) return u32(ror(x, n % 32)) end
function bit32.btest(a, b, c, d)
  local r = a or 0
  if b ~= nil then r = band(r, b) end
  if c ~= nil then r = band(r, c) end
  if d ~= nil then r = band(r, d) end
  return r ~= 0
end
function bit32.extract(n, f, w)
  w = w or 1
  if w >= 32 then return u32(rshift(n, f)) end
  return u32(band(rshift(n, f), lshift(1, w) - 1))
end
function bit32.replace(n, v, f, w)
  w = w or 1
  local mask = (w >= 32) and 4294967295 or (lshift(1, w) - 1)
  local m = lshift(mask, f)
  return u32(bor(band(n, bnot(m)), band(lshift(v, f), m)))
end
function bit32.countlz(n)
  n = u32(n)
  if n == 0 then return 32 end
  local c = 0
  while n < 0x80000000 do n = n * 2; c = c + 1 end
  return c
end
function bit32.countrz(n)
  n = u32(n)
  if n == 0 then return 32 end
  local c = 0
  while n % 2 == 0 do n = math.floor(n / 2); c = c + 1 end
  return c
end
function bit32.byteswap(n) return u32(bswap(n)) end

local Buf = {}
Buf.__index = Buf
local function newbuf(n)
  local b = setmetatable({ n = n, p = ffi.new("uint8_t[?]", math.max(1, n)) }, Buf)
  return b
end
function Buf:check(off, sz)
  if off < 0 or off + sz > self.n then error(("buffer access out of bounds: %d+%d > %d"):format(off, sz, self.n), 2) end
end
local function asint(x) return math.floor(tonumber(x) or 0) end
bit32 = bit32
buffer = {
  create = function(n) return newbuf(asint(n)) end,
  fromstring = function(s) local b = newbuf(#s); ffi.copy(b.p, s, #s); return b end,
  tostring = function(b) return ffi.string(b.p, b.n) end,
  len = function(b) return b.n end,
  copy = function(dst, doff, src, soff, n)
    n = n or (src.n - soff); dst:check(doff, n); src:check(soff, n)
    ffi.copy(dst.p + doff, src.p + soff, n)
  end,
  fill = function(b, off, value, n)
    n = n or (b.n - off); b:check(off, n)
    ffi.fill(b.p + off, n, value % 256)
  end,
}
local function ensurebuf(b, fname, o)
  if getmetatable(b) ~= Buf then
    print(("[buffer.%s] bad buffer type=%s val=%s off=%s"):format(fname, type(b), tostring(b):sub(1,120), tostring(o)))
    print(debug.traceback("", 3))
    error("bad buffer")
  end
end

local function rd(b, off, sz) ensurebuf(b, "rd", off); b:check(off, sz); return ffi.cast("uint8_t*", b.p + off) end
local readers = {
  readi8 = function(b, o) return ffi.cast("int8_t*", b.p + o)[0] end,
  readu8 = function(b, o) return ffi.cast("uint8_t*", b.p + o)[0] end,
  readi16 = function(b, o) return ffi.cast("int16_t*", b.p + o)[0] end,
  readu16 = function(b, o) return ffi.cast("uint16_t*", b.p + o)[0] end,
  readi32 = function(b, o) return ffi.cast("int32_t*", b.p + o)[0] end,
  readu32 = function(b, o) return ffi.cast("uint32_t*", b.p + o)[0] end,
  readf32 = function(b, o) return ffi.cast("float*", b.p + o)[0] end,
  readf64 = function(b, o) return ffi.cast("double*", b.p + o)[0] end,
}
for k, fn in pairs(readers) do
  buffer[k] = function(b, o) ensurebuf(b, "auto", o); b:check(o, (#k == 6) and 1 or 2); return fn(b, o) end
end
buffer.readi8 = function(b, o) ensurebuf(b, "readi8", o); b:check(o, 1); return readers.readi8(b, o) end
buffer.readu8 = function(b, o) ensurebuf(b, "readu8", o); b:check(o, 1); return readers.readu8(b, o) end
buffer.readi16 = function(b, o) b:check(o, 2); return readers.readi16(b, o) end
buffer.readu16 = function(b, o) b:check(o, 2); return readers.readu16(b, o) end
buffer.readi32 = function(b, o) b:check(o, 4); return readers.readi32(b, o) end
buffer.readu32 = function(b, o) b:check(o, 4); return readers.readu32(b, o) end
buffer.readf32 = function(b, o) b:check(o, 4); return readers.readf32(b, o) end
buffer.readf64 = function(b, o) b:check(o, 8); return readers.readf64(b, o) end
buffer.readstring = function(b, o, n) b:check(o, n); return ffi.string(b.p + o, n) end
local writers = {
  writei8 = function(b, o, v) ffi.cast("int8_t*", b.p + o)[0] = v end,
  writeu8 = function(b, o, v) ffi.cast("uint8_t*", b.p + o)[0] = v end,
  writei16 = function(b, o, v) ffi.cast("int16_t*", b.p + o)[0] = v end,
  writeu16 = function(b, o, v) ffi.cast("uint16_t*", b.p + o)[0] = v end,
  writei32 = function(b, o, v) ffi.cast("int32_t*", b.p + o)[0] = v end,
  writeu32 = function(b, o, v) ffi.cast("uint32_t*", b.p + o)[0] = v end,
  writef32 = function(b, o, v) ffi.cast("float*", b.p + o)[0] = v end,
  writef64 = function(b, o, v) ffi.cast("double*", b.p + o)[0] = v end,
}
for k, fn in pairs(writers) do
  local bits = tonumber(k:match("(%d+)"))
  local sz = bits / 8
  buffer[k] = function(b, o, v) ensurebuf(b, "auto", o); b:check(o, sz); return fn(b, o, v) end
end
buffer.writestring = function(b, o, s, n) n = n or #s; b:check(o, n); ffi.copy(b.p + o, s, n) end
-- bit-oriented buffer accessors, 0-based byte offsets, up to 32 bits, LSB-first
buffer.readbits = function(b, o, n, e)
  local v = 0
  for i = 0, n - 1 do
    local byte = buffer.readu8(b, o + math.floor(i / 8))
    if band(byte, lshift(1, i % 8)) ~= 0 then v = bor(v, lshift(1, i)) end
  end
  return v
end
buffer.writebits = function(b, o, n, v, e)
  for i = 0, n - 1 do
    local off = o + math.floor(i / 8)
    local byte = buffer.readu8(b, off)
    if band(v, lshift(1, i)) ~= 0 then byte = bor(byte, lshift(1, i % 8)) else byte = band(byte, bnot(lshift(1, i % 8))) end
    buffer.writeu8(b, off, byte)
  end
end
buffer.readbits = function(b, off, bitoff, bitcount)
  local v = 0
  for i = 0, bitcount - 1 do
    local p = bitoff + i
    local byte = buffer.readu8(b, off + math.floor(p / 8))
    if band(byte, lshift(1, p % 8)) ~= 0 then v = bor(v, lshift(1, i)) end
  end
  return v
end
buffer.writebits = function(b, off, bitoff, bitcount, v)
  for i = 0, bitcount - 1 do
    local p = bitoff + i
    local o = off + math.floor(p / 8)
    local byte = buffer.readu8(b, o)
    if band(v, lshift(1, i)) ~= 0 then byte = bor(byte, lshift(1, p % 8)) else byte = band(byte, bnot(lshift(1, p % 8))) end
    buffer.writeu8(b, o, byte)
  end
end

-- ---------------------------------------------------------------- Roblox mocks
local log = setmetatable({}, { __index = function(t, k) local v = function() end; t[k] = v; return v end })
local function logcall(kind, ...)
  local parts = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    parts[#parts + 1] = type(v) == "string" and ("%q"):format(v:sub(1, 200)) or tostring(v)
  end
  print(("[MOCK %s] %s"):format(kind, table.concat(parts, " ")))
end
local function proxy(name)
  return setmetatable({ __name = name }, {
    __index = function(t, k)
      if k == "Parent" or k == "Name" or k == "ClassName" then return t["_" .. k] end
      local v = setmetatable({ __name = name .. "." .. tostring(k), __parent = t }, getmetatable(t))
      return v
    end,
    __newindex = function(t, k, v) rawset(t, k, v) end,
    __call = function(t, ...) logcall(name, ...); return t end,
    __tostring = function(t) return "[" .. name .. "]" end,
  })
end
local function GameObj(name) return proxy(name) end
game = GameObj("game")
workspace = GameObj("workspace")
script = GameObj("script")
Instance = {
  new = function(cls, parent) logcall("Instance.new", cls); local o = GameObj(cls); o.Parent = parent; return o end,
}
Vector3 = { new = function(x, y, z) return { X = x, Y = y, Z = z, __v3 = true } end }
Vector2 = { new = function(x, y) return { X = x, Y = y } end }
CFrame = { new = function(...) return { __cf = true, args = { ... } } end }
Color3 = { new = function(...) return { __c3 = true, args = { ... } } end, fromRGB = function(...) return { __c3 = true, args = { ... } } end }
UDim = { new = function(x, y) return { __udim = true, x = x, y = y } end }
UDim2 = { new = function(...) return { __udim2 = true, args = { ... } } end, fromOffset = function(...) return { __udim2 = true, args = { ... } } end, fromScale = function(...) return { __udim2 = true, args = { ... } } end }
Rect = { new = function(...) return { __rect = true, args = { ... } } end }
Random = { new = function(seed) return { __random = true, NextInteger = function(_, a, b) return a end, NextNumber = function() return 0 end } end }
Path2DControlPoint = { new = function(...) return { __p2d = true, args = { ... } } end }
vector = {
  create = function(x, y, z) return { X = x or 0, Y = y or 0, Z = z or 0, __vector = true } end,
  zero = { X = 0, Y = 0, Z = 0 }, one = { X = 1, Y = 1, Z = 1 },
  magnitude = function(v) return math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2 + (v.Z or 0) ^ 2) end,
  normalize = function(v) local m = math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2 + (v.Z or 0) ^ 2); if m == 0 then return v end; return { X = v.X / m, Y = v.Y / m, Z = v.Z / m } end,
  dot = function(a, b) return (a.X or 0) * (b.X or 0) + (a.Y or 0) * (b.Y or 0) + (a.Z or 0) * (b.Z or 0) end,
  cross = function(a, b) return { X = a.Y * b.Z - a.Z * b.Y, Y = a.Z * b.X - a.X * b.Z, Z = a.X * b.Y - a.Y * b.X } end,
}

local wait_calls = 0
local function limited_wait(...)
  wait_calls = wait_calls + 1
  if wait_calls <= 30 then print(("[task.wait #%d] %s"):format(wait_calls, tostring((...)))) end
  if wait_calls > 2000 then error("WAIT_LIMIT reached") end
  return 0
end
local function noop() end
task = { wait = limited_wait, spawn = function(f, ...) if type(f) == "function" then pcall(f, ...) end end, defer = function(f, ...) if type(f) == "function" then pcall(f, ...) end end, delay = limited_wait, cancel = noop }
wait = limited_wait
spawn = task.spawn
defer = task.defer
delay = task.delay
typeof = function(v) return type(v) end
identifyexecutor = function() return "research" end
islclosure = function(f) return type(f) == "function" end
iscclosure = function(f) return type(f) == "function" and string.find(tostring(f), "builtin") ~= nil end
getgenv = function() return _G end
getrenv = function() return _G end
getreg = function() return {} end
local rawloadstring = loadstring
loadstring = function(s, name) print("[loadstring] " .. tostring(name) .. " len=" .. #tostring(s)); return rawloadstring(s, name) end
load = rawloadstring

-- debug.info: report C-like info for builtins, real info otherwise
local rawdebug = debug
debug = setmetatable({
  info = function(f, opt)
    local ok, a, b = pcall(rawdebug.getinfo, f)
    if ok and a then
      local src = a.source or "=[C]"
      return src, a.linedefined or -1, a.name or "slnaf", a.currentline or -1
    end
    return "=[C]", -1, "slnaf", -1
  end,
  traceback = rawdebug.traceback,
  getinfo = rawdebug.getinfo,
  getupvalue = rawdebug.getupvalue,
  setupvalue = rawdebug.setupvalue,
  getlocal = rawdebug.getlocal,
  setlocal = rawdebug.setlocal,
  sethook = rawdebug.sethook,
  gethook = rawdebug.gethook,
}, { __index = rawdebug })

-- setfenv that tolerates C functions (the VM probes everything)
local rawsetfenv, rawgetfenv = rawsetfenv or setfenv, rawgetfenv or getfenv
local function safesetfenv(f, env)
  local ok = pcall(rawsetfenv, f, env)
  if not ok then return f end
  return f
end
setfenv = safesetfenv
getfenv = function(f) if f == nil or f == 0 then return _G end local ok, e = pcall(rawgetfenv, f); if ok then return e end; return _G end

_G.bit32 = bit32
_G.buffer = buffer

-- LuaJIT caps unpack at 8000 values; the Roblox VM may unpack constant tables.
-- Log large calls before the cap fires so a bad dependency slot is diagnosable.
local rawunpack = unpack
unpack = function(t, i, j)
  local n = (j or #t) - (i or 1) + 1
  if n > 1000 then
    local mt = getmetatable(t)
    local cnt, first = 0, {}
    for k, v in pairs(t) do
      cnt = cnt + 1
      if cnt <= 6 then first[#first+1] = tostring(k) .. "=" .. tostring(v) end
      if cnt > 200000 then break end
    end
    print(("[unpack] n=%d type=%s mt=%s pairs=%d vals=%s"):format(n, type(t), tostring(mt), cnt, table.concat(first, ",")))
    local inf = debug.getinfo(2, "fSl")
    print(("[unpack] caller src=%s line=%s func=%s"):format(inf and tostring(inf.source) or "?", inf and tostring(inf.currentline) or "?", inf and tostring(inf.func) or "?"))
    if inf and inf.func then
      for k = 1, 32 do
        local name, val = debug.getlocal(2, k)
        if not name then break end
        if type(val) ~= "table" and type(val) ~= "function" then
          print(("  local %d %s = %s"):format(k, tostring(name), tostring(val)))
        else
          print(("  local %d %s = %s"):format(k, tostring(name), tostring(val)))
        end
      end
    end
    return { __unpack_proxy = true, src = t, i = i, j = j, n = n }
  end
  return rawunpack(t, i, j)
end
-- LuaJIT 2.1 has no string.pack/string.unpack (they are Lua 5.3+). The VM's
-- dependency table binds both, so supply working implementations of the Luau
-- formats: i/I[n], f, d, n, c[n], s[n], z, x, with <, >, =, ! prefixes.
local function is_little(endian)
  if endian == ">" then return false end
  if endian == "<" then return true end
  local probe = ffi.new("uint16_t[1]", 1)
  return ffi.cast("uint8_t*", probe)[0] == 1
end
local function bytes_to_num(b, size, little)
  local buf = ffi.new("uint8_t[8]")
  for k = 1, size do
    buf[k - 1] = b:byte(little and k or (size + 1 - k))
  end
  if size == 4 then return ffi.cast("float*", buf)[0] end
  return ffi.cast("double*", buf)[0]
end
local function num_to_bytes(v, size, little)
  local buf = ffi.new("uint8_t[8]")
  if size == 4 then ffi.cast("float*", buf)[0] = v else ffi.cast("double*", buf)[0] = v end
  local out = {}
  for k = 0, size - 1 do
    out[k + 1] = string.char(buf[little and k or (size - 1 - k)])
  end
  return table.concat(out)
end
local function read_int(s, pos, size, signed, little)
  local v = 0
  for k = 0, size - 1 do
    local byte = s:byte(pos + (little and k or (size - 1 - k)))
    if not byte then error("string.unpack: data string too short", 3) end
    v = v + byte * 2 ^ (8 * k)
  end
  if signed and v >= 2 ^ (8 * size - 1) then v = v - 2 ^ (8 * size) end
  return v
end
local function write_int(v, size, little)
  local out = {}
  if v < 0 then v = v + 2 ^ (8 * size) end
  for k = 0, size - 1 do
    out[little and (k + 1) or (size - k)] = string.char(math.floor(v / 2 ^ (8 * k)) % 256)
  end
  return table.concat(out)
end
local function scan_format(fmt)
  local items, i = {}, 1
  while i <= #fmt do
    local c = fmt:sub(i, i)
    if c == " " or c == "\t" then
      i = i + 1
    elseif c == "<" or c == ">" or c == "=" then
      items[#items + 1] = { endian = c }
      i = i + 1
    elseif c == "!" then
      local n = fmt:match("^!(%d+)", i)
      items[#items + 1] = { align = tonumber(n) or 8 }
      i = i + (n and (#n + 1) or 1)
    else
      local spec = c
      local digits = fmt:match("^%d+", i + 1)
      if digits then spec = c .. digits; i = i + #digits end
      items[#items + 1] = { spec = spec }
      i = i + 1
    end
  end
  return items
end
if not string.unpack then
  string.unpack = function(fmt, s, pos)
    pos = pos or 1
    local values, endian = {}, "="
    for _, item in ipairs(scan_format(fmt)) do
      if item.endian then
        endian = item.endian
      elseif item.align then
        -- alignment is advisory here; the VM's formats are byte-packed
      else
        local spec = item.spec
        local c = spec:sub(1, 1)
        if c == "i" or c == "I" then
          local size = tonumber(spec:sub(2)) or 4
          values[#values + 1] = read_int(s, pos, size, c == "i", is_little(endian))
          pos = pos + size
        elseif c == "f" then
          values[#values + 1] = bytes_to_num(s:sub(pos, pos + 3), 4, is_little(endian))
          pos = pos + 4
        elseif c == "d" or c == "n" then
          values[#values + 1] = bytes_to_num(s:sub(pos, pos + 7), 8, is_little(endian))
          pos = pos + 8
        elseif c == "c" then
          local size = tonumber(spec:sub(2)) or 1
          values[#values + 1] = s:sub(pos, pos + size - 1)
          pos = pos + size
        elseif c == "s" then
          local size = tonumber(spec:sub(2)) or 1
          local len = read_int(s, pos, size, false, is_little(endian))
          pos = pos + size
          values[#values + 1] = s:sub(pos, pos + len - 1)
          pos = pos + len
        elseif c == "z" then
          local z = s:find("\0", pos, true) or (#s + 1)
          values[#values + 1] = s:sub(pos, z - 1)
          pos = z + 1
        elseif c == "x" then
          pos = pos + 1
        else
          error("string.unpack: unsupported format '" .. spec .. "'", 3)
        end
      end
    end
    values[#values + 1] = pos
    return table.unpack(values, 1, #values)
  end
end
if not string.pack then
  string.pack = function(fmt, ...)
    local args, ai, out, endian = { ... }, 1, {}, "="
    for _, item in ipairs(scan_format(fmt)) do
      if item.endian then
        endian = item.endian
      elseif item.align then
        -- no padding, matching the byte-packed VM formats
      else
        local spec = item.spec
        local c, v = spec:sub(1, 1), args[ai]
        if c == "i" or c == "I" then
          local size = tonumber(spec:sub(2)) or 4
          out[#out + 1] = write_int(v or 0, size, is_little(endian))
          ai = ai + 1
        elseif c == "f" then
          out[#out + 1] = num_to_bytes(v or 0, 4, is_little(endian))
          ai = ai + 1
        elseif c == "d" or c == "n" then
          out[#out + 1] = num_to_bytes(v or 0, 8, is_little(endian))
          ai = ai + 1
        elseif c == "c" then
          local size = tonumber(spec:sub(2)) or 1
          local str = tostring(v or "")
          out[#out + 1] = (str .. string.rep("\0", size)):sub(1, size)
          ai = ai + 1
        elseif c == "s" then
          local size = tonumber(spec:sub(2)) or 1
          local str = tostring(v or "")
          out[#out + 1] = write_int(#str, size, is_little(endian)) .. str
          ai = ai + 1
        elseif c == "z" then
          out[#out + 1] = tostring(v or "") .. "\0"
          ai = ai + 1
        elseif c == "x" then
          out[#out + 1] = "\0"
        else
          error("string.pack: unsupported format '" .. spec .. "'", 2)
        end
      end
    end
    return table.concat(out)
  end
end

-- Wrap pcall/xpcall so a swallowed error still leaves a traceback in the log.
local rawpcall, rawxpcall = pcall, xpcall
local depth = 0
pcall = function(f, ...)
  return rawpcall(f, ...)
end
xpcall = function(f, h, ...)
  return rawxpcall(f, h, ...)
end

table.pack = table.pack or function(...) return { n = select("#", ...), ... } end
table.create = table.create or function(n, v)
  local t = {}
  for i = 1, n do t[i] = v end
  return t
end
table.clear = table.clear or function(t) for k in pairs(t) do t[k] = nil end end
table.clone = table.clone or function(t) local o = {}; for k, v in pairs(t) do o[k] = v end; return o end
table.move = table.move or function(a1, f, e, t, a2)
  a2 = a2 or a1
  if e >= f then
    if t > e or t <= f or a2 ~= a1 then
      for i = 0, e - f do a2[t + i] = a1[f + i] end
    else
      for i = e - f, 0, -1 do a2[t + i] = a1[f + i] end
    end
  end
  return a2
end
coroutine.close = coroutine.close or function(co) return true end
coroutine.isyieldable = coroutine.isyieldable or function() return false end

table.unpack = table.unpack or unpack
-- ---------------------------------------------------------------- run
local vmPath = arg[1] or "kx_stage2_vm_clean.luajit.lua"
local dataPath = arg[2] or "kx_stage2_data_clean.bin"
local f = assert(io.open(vmPath, "rb")); local vmSrc = f:read("*a"); f:close()
f = assert(io.open(dataPath, "rb")); local data = f:read("*a"); f:close()
print(("[load] vm=%d data=%d"):format(#vmSrc, #data))
local chunk, err = loadstring(vmSrc, "kx_stage2_vm")
if not chunk then print("[compile error] " .. tostring(err)); os.exit(1) end
local probe = arg[3] == "probe"
if probe then
  local p = vmSrc:gsub("^return setmetatable%(", "local __t = setmetatable(", 1)
  local i = p:find(":xS(...)", 1, true)
  if not i then print("[probe] call not found"); os.exit(1) end
  p = p:sub(1, i - 1) .. "; return __t ;"
  if p == vmSrc then print("[probe] replacement failed"); os.exit(1) end
  local pc, perr = loadstring(p, "kx_stage2_vm_probe")
  if not pc then print("[probe compile] " .. tostring(perr)); os.exit(1) end
  local t = pc(data)
  local misses = {}
  setmetatable(t, {
    __index = function(tt, k)
      if type(k) == "number" then
        misses[k] = (misses[k] or 0) + 1
        if misses[k] <= 1 then print("[missing numeric key] " .. tostring(k)) end
        return function(...) return nil end
      end
      return nil
    end,
  })
  local abuf = buffer.fromstring(data)
  local ok, err2 = pcall(function() return t:xS(abuf) end)
  print("[probe run] ok=" .. tostring(ok) .. " err=" .. tostring(err2))
  local list = {}; for k, v in pairs(misses) do list[#list + 1] = tostring(k) .. ":" .. v end
  print("[missing keys] " .. table.concat(list, " "))
  os.exit(0)
end

local abuf = buffer.fromstring(data)
local ok, main_fn = pcall(chunk, abuf)
print("[deserialize] ok=" .. tostring(ok) .. " type=" .. type(main_fn) .. " val=" .. tostring(main_fn))
if not ok then print(debug.traceback()) os.exit(1) end
if type(main_fn) == "function" then
  local ok2, err2 = pcall(main_fn)
  debug.sethook()
  print("[execute] ok=" .. tostring(ok2) .. " err=" .. tostring(err2))
  if not ok2 then print(debug.traceback()) end
else
  print("[execute] deserializer did not return a function")
end
