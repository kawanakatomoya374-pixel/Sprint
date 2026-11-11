local seed, parts = 21, {}
for i = 1, 120000 do
  seed = (seed * 16807) % 2147483647
  parts[i] = "w" .. tostring(seed % 997)
end
local text = table.concat(parts, " ")
local find = string.find
local function count_sub(s, sub)
  local c = 0
  local p = find(s, sub, 1, true)
  while p do
    c = c + 1
    p = find(s, sub, p + #sub, true)
  end
  return c
end
local total = 0
for i = 1, 300 do
  total = total + count_sub(text, "w12")
  total = total + count_sub(text, "99 w")
end
local up = text:upper()
local rep = text:gsub("w1", "WW")
print(total, #up, #rep, up:sub(1, 10))
