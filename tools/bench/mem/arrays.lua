local rows = {}
for i = 0, 1499 do
  local r = {}
  for j = 0, 1999 do r[#r + 1] = i * j % 1000 end
  rows[#rows + 1] = r
end
local s = 0
for k = 0, 399999 do
  local t = {k, k + 1, k + 2, k + 3}
  s = s + t[3]
end
for _, r in ipairs(rows) do for _, x in ipairs(r) do s = s + x end end
print(string.format("%d", s), #rows)
