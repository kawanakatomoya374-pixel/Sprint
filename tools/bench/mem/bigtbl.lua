local t = {}
for i = 0, 1499999 do t[i * 7] = i end
local s = 0
for i = 0, 1499999 do s = s + t[i * 7] end
for r = 0, 2 do
  local u = {}
  for i = 0, 299999 do u["k" .. tostring(i)] = i end
  local c = 0
  for _ in pairs(u) do c = c + 1 end
  s = s + c
end
local n = 0
for _ in pairs(t) do n = n + 1 end
print(string.format("%d", s), n)
