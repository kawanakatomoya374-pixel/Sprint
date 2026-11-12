local P = {}
P.__index = P
local function new(a, b) return setmetatable({a = a, b = b}, P) end
local big = {}
for i = 0, 1999999 do big[#big + 1] = new(i, i + 1) end
local s = 0
for r = 0, 4 do
  for i = 0, 999999 do local t = new(i, r); s = s + t.a end
end
for _, p in ipairs(big) do s = s + p.b end
print(string.format("%d", s), #big)
