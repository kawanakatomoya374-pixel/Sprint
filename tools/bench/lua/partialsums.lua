local sin, cos, exp, sqrt, floor = math.sin, math.cos, math.exp, math.sqrt, math.floor
local function run(n)
  local a1, a2, a3, a4, a5, a6, a7, a8, a9 = 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
  local k, sgn = 1.0, 1.0
  for i = 0, n - 1 do
    local k2 = k * k
    local k3 = k2 * k
    local sk, ck = sin(k), cos(k)
    a1 = a1 + exp(0.0 - k / 4096.0)
    a2 = a2 + 1.0 / sqrt(k)
    a3 = a3 + 1.0 / (k * (k + 1.0))
    a4 = a4 + 1.0 / (k3 * sk * sk)
    a5 = a5 + 1.0 / (k3 * ck * ck)
    a6 = a6 + 1.0 / k
    a7 = a7 + 1.0 / k2
    a8 = a8 + sgn / k
    a9 = a9 + sgn / (2.0 * k - 1.0)
    sgn = 0.0 - sgn
    k = k + 1.0
  end
  return a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9
end
print(string.format("%d", floor(run(8000000) * 1000000)))
