local function sor(g, n, iters, omega)
  local o4, om = omega * 0.25, 1.0 - omega
  for p = 1, iters do
    for i = 2, n - 1 do
      local gi, gim, gip = g[i], g[i - 1], g[i + 1]
      for j = 2, n - 1 do
        gi[j] = o4 * (gim[j] + gip[j] + gi[j - 1] + gi[j + 1]) + om * gi[j]
      end
    end
  end
end
local n = 300
local g = {}
for i = 0, n - 1 do
  local row = {}
  for j = 0, n - 1 do row[j + 1] = ((i * 7 + j * 3) % 11) / 11.0 end
  g[i + 1] = row
end
sor(g, n, 100, 1.25)
local s = 0.0
for i = 1, n do for j = 1, n do s = s + g[i][j] end end
print(string.sub(tostring(s), 1, 8))
