local t, x, hits = {}, 1, 0
for i = 0, 1999999 do
  x = (x * 16807) % 2147483647
  local k = x % 600011
  local v = t[k]
  if v == nil then t[k] = i else hits = hits + 1; t[k] = v + 1 end
end
local s, n = 0, 0
for k, v in pairs(t) do s = s + v % 7; n = n + 1 end
print(hits, n, s)
