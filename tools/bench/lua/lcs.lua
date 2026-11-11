local function lcs(a, b)
  local n, m = #a, #b
  local prev, cur = {}, {}
  for j = 0, m do prev[j + 1] = 0; cur[j + 1] = 0 end
  for i = 1, n do
    local ai = a[i]
    for j = 1, m do
      if ai == b[j] then cur[j + 1] = prev[j] + 1
      elseif prev[j + 1] >= cur[j] then cur[j + 1] = prev[j + 1]
      else cur[j + 1] = cur[j] end
    end
    prev, cur = cur, prev
  end
  return prev[m + 1]
end
local seed, a, b = 17, {}, {}
for i = 1, 9000 do
  seed = (seed * 16807) % 2147483647; a[i] = seed % 4
  seed = (seed * 16807) % 2147483647; b[i] = seed % 4
end
print(lcs(a, b))
