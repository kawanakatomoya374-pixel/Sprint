local sqrt, floor = math.sqrt, math.floor
local function is_prime(n)
  if n < 2 then return false end
  if n % 2 == 0 then return n == 2 end
  local i, lim = 3, floor(sqrt(n))
  while i <= lim do
    if n % i == 0 then return false end
    i = i + 2
  end
  return true
end
local function gcd(a, b) while b ~= 0 do a, b = b, a % b end return a end
local c = 0
for n = 1, 399999 do if is_prime(n) then c = c + 1 end end
local g = 0
for a = 1, 1499 do for b = 1, 599 do g = g + gcd(a, b) end end
print(c, g)
