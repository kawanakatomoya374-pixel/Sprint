local floor = math.floor
local function lu(a, n)
  for k = 1, n do
    local rk = a[k]
    local piv = rk[k]
    for i = k + 1, n do
      local ri = a[i]
      local f = ri[k] / piv
      ri[k] = f
      for j = k + 1, n do ri[j] = ri[j] - f * rk[j] end
    end
  end
end
local n, a, seed = 520, {}, 5
for i = 1, n do
  local row = {}
  for j = 1, n do
    seed = (seed * 16807) % 2147483647
    row[j] = seed / 2147483647.0 + ((i == j) and 4.0 or 0.0)
  end
  a[i] = row
end
lu(a, n)
local tr = 0.0
for i = 1, n do tr = tr + a[i][i] end
print(string.format("%d", floor(tr * 100000)))
