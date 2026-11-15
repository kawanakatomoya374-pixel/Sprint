local seed, rows = 23, {}
for i = 1, 40000 do
  local cells = {}
  for j = 1, 8 do seed = (seed * 16807) % 2147483647; cells[j] = tostring(seed % 100000) end
  rows[i] = table.concat(cells, ",")
end
local text = table.concat(rows, "\n")
local total = 0
for r = 1, 3 do
  for line in text:gmatch("[^\n]+") do
    local f, n = {}, 0
    for cell in line:gmatch("[^,]+") do n = n + 1; f[n] = cell end
    total = total + tonumber(f[1]) + tonumber(f[4]) - tonumber(f[8])
  end
end
print(total, #text)
