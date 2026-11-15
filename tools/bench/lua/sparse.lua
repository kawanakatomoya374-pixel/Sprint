local floor = math.floor
local n, per = 4000, 12
local val, col, rowp = {}, {}, {0}
local seed = 3
for i = 1, n do
  for j = 1, per do
    seed = (seed * 16807) % 2147483647
    col[#col + 1] = seed % n + 1
    val[#val + 1] = (seed % 1000) / 1000.0
  end
  rowp[#rowp + 1] = #col
end
local x, y = {}, {}
for i = 1, n do x[i] = 1.0; y[i] = 0.0 end
for r = 1, 900 do
  for i = 1, n do
    local s = 0.0
    for p = rowp[i] + 1, rowp[i + 1] do s = s + val[p] * x[col[p]] end
    y[i] = s
  end
  for i = 1, n do x[i] = y[i] / (1.0 + y[i] * 0.0001) end
end
local t = 0.0
for i = 1, n do t = t + x[i] end
print(string.format("%d", floor(t * 1000)))
