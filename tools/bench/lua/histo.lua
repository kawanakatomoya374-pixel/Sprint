local counts, seed = {}, 31
for i = 1, 2000000 do
  seed = (seed * 16807) % 2147483647
  local k = seed % 256
  counts[k] = (counts[k] or 0) + 1
end
local mx, arg, n = 0, 0, 0
for k, v in pairs(counts) do n = n + 1; if v > mx then mx = v; arg = k end end
print(n, mx, arg)
