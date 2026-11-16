local seed = 7
local function rnd()
  seed = (seed * 1664525 + 1013904223) % 4294967296
  return seed % 1000001
end
local a = {}
for i = 1, 300000 do a[i] = rnd() end
table.sort(a)
local b = {}
for i = 1, #a do local x = a[i]*2 if x % 3 == 0 then b[#b+1] = x end end
local s = 0
for i = 1, #b do s = s + b[i] end
table.sort(a, function(x,y) return x > y end)
print(a[1], #b, s)
