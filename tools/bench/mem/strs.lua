local a = {}
for i = 0, 399999 do a[#a + 1] = "item-" .. tostring(i) end
local n = 0
for r = 0, 3 do
  for i = 0, 199999 do local t = "tmp" .. tostring(i) .. "-" .. tostring(r); n = n + #t end
end
for _, s in ipairs(a) do n = n + #s end
print(n, #a)
