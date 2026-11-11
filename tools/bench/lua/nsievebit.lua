local band, bnot, lshift, rshift = bit.band, bit.bnot, bit.lshift, bit.rshift
local function nsieve(m)
  local words = rshift(m, 5) + 1
  local bits = {}
  for i = 0, words - 1 do bits[i] = -1 end
  local count = 0
  for i = 2, m do
    if band(rshift(bits[rshift(i, 5)], band(i, 31)), 1) ~= 0 then
      count = count + 1
      local j = i + i
      while j <= m do
        local w = rshift(j, 5)
        bits[w] = band(bits[w], bnot(lshift(1, band(j, 31))))
        j = j + i
      end
    end
  end
  return count
end
print(nsieve(8000000))
