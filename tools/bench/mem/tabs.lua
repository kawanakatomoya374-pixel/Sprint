local live = {}
for i = 0, 149999 do live[#live + 1] = {id = i, name = "n" .. tostring(i % 100), v = i * 2} end
local s = 0
local ring = {}
for i = 0, 1023 do ring[i] = false end
for r = 0, 3 do
  for i = 0, 149999 do local t = {a = i, b = r, c = i + r}; ring[i % 1024] = t; s = s + t.a + t.c end
end
for _, t in ipairs(live) do s = s + t.v end
print(string.format("%d", s), #live)
