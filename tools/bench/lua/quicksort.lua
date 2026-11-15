local floor = math.floor
local function qsort(a, lo, hi)
  while lo < hi do
    local p = a[floor((lo + hi) / 2) + 1]
    local i, j = lo, hi
    while i <= j do
      while a[i + 1] < p do i = i + 1 end
      while a[j + 1] > p do j = j - 1 end
      if i <= j then a[i + 1], a[j + 1] = a[j + 1], a[i + 1]; i = i + 1; j = j - 1 end
    end
    if j - lo < hi - i then qsort(a, lo, j); lo = i else qsort(a, i, hi); hi = j end
  end
end
local n, a, seed = 700000, {}, 47
for i = 1, n do seed = (seed * 16807) % 2147483647; a[i] = seed end
qsort(a, 0, n - 1)
local ok = true
for i = 2, n do if a[i - 1] > a[i] then ok = false end end
print(ok, a[1], a[n])
