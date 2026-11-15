local sin, exp, floor = math.sin, math.exp, math.floor
local function f(x) return sin(x) * exp(0.0 - x * 0.1) + 1.0 end
local function trapezoid(a, b, n)
  local h = (b - a) / n
  local s = (f(a) + f(b)) * 0.5
  for i = 1, n - 1 do s = s + f(a + i * h) end
  return s * h
end
local t = 0.0
for r = 0, 149 do t = t + trapezoid(0.0, 20.0 + r, 80000) end
print(string.format("%d", floor(t * 100000)))
