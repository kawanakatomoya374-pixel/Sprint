local floor = math.floor
local function bs(a, n, key)
  local lo, hi = 0, n - 1
  while lo <= hi do
    local mid = floor((lo + hi) / 2)
    local v = a[mid + 1]
    if v < key then lo = mid + 1 elseif v > key then hi = mid - 1 else return mid end
  end
  return -1
end
local n, a = 1000000, {}
for i = 0, n - 1 do a[i + 1] = i * 3 end
local seed, found = 43, 0
for q = 1, 3000000 do
  seed = (seed * 16807) % 2147483647
  if bs(a, n, seed % (n * 3)) >= 0 then found = found + 1 end
end
print(found)
