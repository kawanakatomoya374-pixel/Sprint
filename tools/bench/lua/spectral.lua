local function a(i, j) return 1.0 / (math.floor((i + j) * (i + j + 1) / 2) + i + 1) end
local function mul_av(n, v, out)
  for i = 0, n - 1 do
    local s = 0.0
    for j = 0, n - 1 do s = s + a(i, j) * v[j + 1] end
    out[i + 1] = s
  end
end
local function mul_atv(n, v, out)
  for i = 0, n - 1 do
    local s = 0.0
    for j = 0, n - 1 do s = s + a(j, i) * v[j + 1] end
    out[i + 1] = s
  end
end
local function mul_atav(n, v, out, tmp) mul_av(n, v, tmp); mul_atv(n, tmp, out) end
local n = 1500
local u, v, tmp = {}, {}, {}
for i = 1, n do u[i] = 1.0; v[i] = 0.0; tmp[i] = 0.0 end
for i = 1, 10 do mul_atav(n, u, v, tmp); mul_atav(n, v, u, tmp) end
local vbv, vv = 0.0, 0.0
for i = 1, n do vbv = vbv + u[i] * v[i]; vv = vv + v[i] * v[i] end
print(string.format("%d", math.floor(math.sqrt(vbv / vv) * 1000000000)))
