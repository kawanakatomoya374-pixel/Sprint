local function heapsort(a, n)
  local l = math.floor(n / 2)
  local ir = n - 1
  while true do
    local rra
    if l > 0 then l = l - 1; rra = a[l + 1]
    else
      rra = a[ir + 1]; a[ir + 1] = a[1]; ir = ir - 1
      if ir == 0 then a[1] = rra; return end
    end
    local i, j = l, l * 2 + 1
    while j <= ir do
      if j < ir and a[j + 1] < a[j + 2] then j = j + 1 end
      if rra < a[j + 1] then a[i + 1] = a[j + 1]; i = j; j = j * 2 + 1 else j = ir + 1 end
    end
    a[i + 1] = rra
  end
end
local n = 600000
local a = {}
local seed = 42
for i = 1, n do seed = (seed * 16807) % 2147483647; a[i] = seed / 2147483647.0 end
heapsort(a, n)
local ok = true
for i = 2, n do if a[i - 1] > a[i] then ok = false end end
print(ok, a[1] < a[n])
