local seed = 113
local function rnd()
  seed = (seed * 16807) % 2147483647
  return seed / 2147483647.0
end
local function pi_est(n)
  local inside = 0
  for i = 1, n do
    local x = rnd()
    local y = rnd()
    if x * x + y * y <= 1.0 then inside = inside + 1 end
  end
  return inside
end
print(pi_est(6000000))
