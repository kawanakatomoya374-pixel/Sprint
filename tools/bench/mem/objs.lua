local V = {}
V.__index = V
local function new(x, y) return setmetatable({x = x, y = y}, V) end
local live = {}
for i = 0, 599999 do live[#live + 1] = new(i, i + 1) end
local s = 0
for r = 0, 5 do
  for i = 0, 499999 do local t = new(i, r); s = s + t.x + t.y end
end
for _, v in ipairs(live) do s = s + v.y end
print(string.format("%d", s), #live)
