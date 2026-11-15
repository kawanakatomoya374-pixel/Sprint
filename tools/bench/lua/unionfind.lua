local function find(p, x)
  local r = x
  while p[r] ~= r do r = p[r] end
  while p[x] ~= r do local nx = p[x]; p[x] = r; x = nx end
  return r
end
local n, p, sz = 800000, {}, {}
for i = 0, n - 1 do p[i] = i; sz[i] = 1 end
local seed, comps = 11, n
for i = 1, 1500000 do
  seed = (seed * 16807) % 2147483647
  local a = seed % n
  seed = (seed * 16807) % 2147483647
  local b = seed % n
  local ra, rb = find(p, a), find(p, b)
  if ra ~= rb then
    if sz[ra] < sz[rb] then ra, rb = rb, ra end
    p[rb] = ra
    sz[ra] = sz[ra] + sz[rb]
    comps = comps - 1
  end
end
print(comps)
