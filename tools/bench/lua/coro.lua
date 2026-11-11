local function gen(n)
  return coroutine.wrap(function() for i = 0, n - 1 do coroutine.yield(i) end end)
end
local function filter_odd(src)
  return coroutine.wrap(function()
    for v in src do if v % 2 == 1 then coroutine.yield(v) end end
  end)
end
local sum = 0
for v in filter_odd(gen(1500000)) do sum = sum + v end
print(sum)
