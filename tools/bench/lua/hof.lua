local a = {}
for i = 0, 99999 do a[#a + 1] = i % 1000 end
local function map(t, f) local r = {} for i = 1, #t do r[i] = f(t[i]) end return r end
local function filter(t, f) local r = {} for i = 1, #t do if f(t[i]) then r[#r + 1] = t[i] end end return r end
local function reduce(t, f, acc) for i = 1, #t do acc = f(acc, t[i]) end return acc end
local total = 0
for r = 0, 24 do
  local b = map(a, function(x) return x * 3 + r end)
  local c = filter(b, function(x) return x % 2 == 0 end)
  total = total + reduce(c, function(acc, x) return acc + x end, 0)
end
print(total)
