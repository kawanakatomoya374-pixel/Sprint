local function body(k)
  local i = 0
  while true do coroutine.yield(i + k); i = i + 1 end
end
local cs = {}
for k = 0, 19999 do
  local c = coroutine.create(function() body(k) end)
  coroutine.resume(c)
  cs[#cs + 1] = c
end
local s = 0
for r = 0, 9 do
  for _, c in ipairs(cs) do local _, v = coroutine.resume(c); s = s + v end
end
print(string.format("%d", s), #cs)
