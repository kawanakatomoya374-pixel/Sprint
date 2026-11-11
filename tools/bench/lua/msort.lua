local function merge_sort(a, tmp, lo, hi)
  if hi - lo < 2 then return end
  local mid = math.floor((lo + hi) / 2)
  merge_sort(a, tmp, lo, mid)
  merge_sort(a, tmp, mid, hi)
  local i, j, k = lo, mid, lo
  while i < mid and j < hi do
    if a[i + 1] <= a[j + 1] then tmp[k + 1] = a[i + 1]; i = i + 1
    else tmp[k + 1] = a[j + 1]; j = j + 1 end
    k = k + 1
  end
  while i < mid do tmp[k + 1] = a[i + 1]; i = i + 1; k = k + 1 end
  while j < hi do tmp[k + 1] = a[j + 1]; j = j + 1; k = k + 1 end
  for x = lo, hi - 1 do a[x + 1] = tmp[x + 1] end
end
local n, a, tmp, seed = 1500000, {}, {}, 3
for i = 1, n do seed = (seed * 16807) % 2147483647; a[i] = seed; tmp[i] = 0 end
merge_sort(a, tmp, 0, n)
local ok = true
for i = 2, n do if a[i - 1] > a[i] then ok = false end end
print(ok, a[1], a[n])
