local n, deg = 250000, 5
local to, wt, seed = {}, {}, 7
for u = 0, n - 1 do
  for k = 1, deg do
    seed = (seed * 16807) % 2147483647
    to[#to + 1] = seed % n
    wt[#wt + 1] = 1 + seed % 100
  end
end
local dist, hk, hv, hn = {}, {}, {}, 0
for i = 0, n - 1 do dist[i] = 1000000000 end
local function push(k, v)
  local i = hn
  hn = hn + 1
  while i > 0 do
    local p = math.floor((i - 1) / 2)
    if hk[p] <= k then break end
    hk[i] = hk[p]; hv[i] = hv[p]
    i = p
  end
  hk[i] = k; hv[i] = v
end
dist[0] = 0
push(0, 0)
local pops = 0
while hn > 0 do
  local k, u = hk[0], hv[0]
  hn = hn - 1
  local lk, lv = hk[hn], hv[hn]
  local i = 0
  while true do
    local c = 2 * i + 1
    if c >= hn then break end
    if c + 1 < hn and hk[c + 1] < hk[c] then c = c + 1 end
    if hk[c] >= lk then break end
    hk[i] = hk[c]; hv[i] = hv[c]
    i = c
  end
  hk[i] = lk; hv[i] = lv
  pops = pops + 1
  if k <= dist[u] then
    for e = u * deg, u * deg + deg - 1 do
      local v = to[e + 1]
      local nd = k + wt[e + 1]
      if nd < dist[v] then dist[v] = nd; push(nd, v) end
    end
  end
end
local s = 0
for i = 0, n - 1 do if dist[i] < 1000000000 then s = s + dist[i] end end
print(string.format("%d", s), pops)
