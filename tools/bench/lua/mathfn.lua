local sin, cos, sqrt, log, exp, abs, floor = math.sin, math.cos, math.sqrt, math.log, math.exp, math.abs, math.floor
local s = 0.0
for i = 1, 2999999 do
  local x = i * 0.001
  s = s + sin(x) * cos(x) + sqrt(x) + log(x) + exp(-x) + abs(floor(x) - x)
end
print(string.format("%d", floor(s)))
