local function step(g, w, hh)
  local nxt = {}
  for y = 0, hh - 1 do
    local row = {}
    for x = 1, w do row[x] = 0 end
    local up, cur, dn = g[(y + hh - 1) % hh + 1], g[y + 1], g[(y + 1) % hh + 1]
    for x = 0, w - 1 do
      local l, r = (x + w - 1) % w + 1, (x + 1) % w + 1
      local n = up[l] + up[x + 1] + up[r] + cur[l] + cur[r] + dn[l] + dn[x + 1] + dn[r]
      if n == 3 or (n == 2 and cur[x + 1] == 1) then row[x + 1] = 1 end
    end
    nxt[y + 1] = row
  end
  return nxt
end
local w, h = 128, 128
local g, seed = {}, 7
for y = 1, h do
  local row = {}
  for x = 1, w do seed = (seed * 16807) % 2147483647; row[x] = (seed % 3 == 0) and 1 or 0 end
  g[y] = row
end
for i = 1, 300 do g = step(g, w, h) end
local alive = 0
for y = 1, h do for x = 1, w do alive = alive + g[y][x] end end
print(alive)
