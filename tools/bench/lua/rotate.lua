local sin, cos, floor = math.sin, math.cos, math.floor
local n = 100000
local xs, ys, zs = {}, {}, {}
for i = 0, n - 1 do xs[i + 1] = (i % 100) * 0.5; ys[i + 1] = (i % 37) * 0.25; zs[i + 1] = (i % 11) * 1.5 end
for r = 0, 399 do
  local c, s = cos(r * 0.05), sin(r * 0.05)
  for i = 1, n do
    local x, y, z = xs[i], ys[i], zs[i]
    xs[i] = x * c - y * s
    ys[i] = x * s + y * c
    zs[i] = z * 0.999 + x * 0.001
  end
end
local t = 0.0
for i = 1, n do t = t + xs[i] + ys[i] * 2.0 + zs[i] * 3.0 end
print(string.format("%d", floor(t * 10)))
