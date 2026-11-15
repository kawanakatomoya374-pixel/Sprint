local band, bor, bxor, bnot, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.lshift, bit.rshift
local function solve(n, cols, d1, d2, all)
  if cols == all then return 1 end
  local cnt = 0
  local avail = band(all, bnot(bor(cols, d1, d2)))
  while avail ~= 0 do
    local b = band(avail, -avail)
    avail = bxor(avail, b)
    cnt = cnt + solve(n, bor(cols, b), band(lshift(bor(d1, b), 1), all), rshift(bor(d2, b), 1), all)
  end
  return cnt
end
local total = 0
for n = 6, 12 do total = total + solve(n, 0, 0, 0, lshift(1, n) - 1) end
print(total)
