local sin, exp, floor = math.sin, math.exp, math.floor
local n, k = 200000, 33
local x, h, y = {}, {}, {}
for i = 0, n - 1 do x[i + 1] = sin(i * 0.01) + (i % 7) * 0.1; y[i + 1] = 0.0 end
for j = 0, k - 1 do h[j + 1] = exp(0.0 - j * 0.1) / 10.0 end
for r = 1, 30 do
  for i = k, n - 1 do
    local s = 0.0
    for j = 0, k - 1 do s = s + h[j + 1] * x[i - j + 1] end
    y[i + 1] = s
  end
end
local t = 0.0
for i = 1, n do t = t + y[i] end
print(string.format("%d", floor(t * 1000)))
