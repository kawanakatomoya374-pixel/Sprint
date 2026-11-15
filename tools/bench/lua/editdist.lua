local function dist(a, b)
  local n, m = #a, #b
  local prev, cur = {}, {}
  for j = 0, m do prev[j + 1] = j; cur[j + 1] = 0 end
  local byte = string.byte
  for i = 1, n do
    cur[1] = i
    local ca = byte(a, i)
    for j = 1, m do
      local cost = (ca == byte(b, j)) and 0 or 1
      local x, y, z = prev[j + 1] + 1, cur[j] + 1, prev[j] + cost
      if y < x then x = y end
      if z < x then x = z end
      cur[j + 1] = x
    end
    prev, cur = cur, prev
  end
  return prev[m + 1]
end
local seed, s1, s2 = 9, {}, {}
for i = 1, 2500 do
  seed = (seed * 16807) % 2147483647; s1[i] = string.char(97 + seed % 6)
  seed = (seed * 16807) % 2147483647; s2[i] = string.char(97 + seed % 6)
end
print(dist(table.concat(s1), table.concat(s2)))
