local band, bxor, lshift, rshift = bit.band, bit.bxor, bit.lshift, bit.rshift
local function u(x) if x < 0 then return x + 4294967296 end return x end
local function popcount(x)
  local c = 0
  while x ~= 0 do x = band(x, x - 1); c = c + 1 end
  return c
end
local tab = {}
for i = 0, 255 do
  local c = i
  for k = 1, 8 do
    if band(c, 1) ~= 0 then c = u(bxor(0xEDB88320, rshift(c, 1))) else c = rshift(c, 1) end
  end
  tab[i] = c
end
local x, pc, crc = 2463534242, 0, 0xFFFFFFFF
for i = 1, 3000000 do
  x = u(bxor(x, lshift(x, 13)))
  x = u(bxor(x, rshift(x, 17)))
  x = u(bxor(x, lshift(x, 5)))
  pc = pc + popcount(x)
  crc = u(bxor(tab[band(bxor(crc, x), 255)], rshift(crc, 8)))
end
print(pc, u(bxor(crc, 0xFFFFFFFF)))
