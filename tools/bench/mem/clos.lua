local function make(k) return function(x) return x + k end end
local live = {}
for i = 0, 399999 do live[#live + 1] = make(i) end
local s = 0
for r = 0, 4 do
  for i = 0, 299999 do local f = make(i); s = s + f(r) end
end
for _, f in ipairs(live) do s = s + f(1) end
print(string.format("%d", s), #live)
