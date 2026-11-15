local function ok(g, pos, v)
  local r = math.floor(pos / 9)
  local c = pos % 9
  for i = 0, 8 do
    if g[r * 9 + i + 1] == v or g[i * 9 + c + 1] == v then return false end
  end
  local br, bc = r - r % 3, c - c % 3
  for i = 0, 2 do for j = 0, 2 do
    if g[(br + i) * 9 + bc + j + 1] == v then return false end
  end end
  return true
end
local nodes = 0
local function solve(g, pos)
  if pos == 81 then return true end
  if g[pos + 1] ~= 0 then return solve(g, pos + 1) end
  for v = 1, 9 do
    nodes = nodes + 1
    if ok(g, pos, v) then
      g[pos + 1] = v
      if solve(g, pos + 1) then return true end
      g[pos + 1] = 0
    end
  end
  return false
end
local puzzle = "800000000003600000070090200050007000000045700000100030001000068008500010090000400"
local total = 0
for r = 1, 12 do
  local g = {}
  for i = 1, 81 do g[i] = puzzle:byte(i) - 48 end
  solve(g, 0)
  local s = 0
  for i = 1, 81 do s = (s * 7 + g[i]) % 1000003 end
  total = total + s
end
print(total, nodes)
