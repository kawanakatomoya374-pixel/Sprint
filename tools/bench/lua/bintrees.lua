local function make(d)
  if d == 0 then return {false, false} end
  return {make(d - 1), make(d - 1)}
end
local function check(t)
  if not t[1] then return 1 end
  return 1 + check(t[1]) + check(t[2])
end
local maxd = 16
local long_lived = make(maxd)
local total = 0
local d = 4
while d <= maxd do
  local iters = 2 ^ (maxd - d + 4)
  local c = 0
  for i = 1, iters do c = c + check(make(d)) end
  total = total + c
  d = d + 4
end
print(total, check(long_lived))
