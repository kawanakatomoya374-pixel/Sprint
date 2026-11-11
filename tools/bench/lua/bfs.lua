local function bfs(w, h, walls)
  local n = w * h
  local dist = {}
  for i = 1, n do dist[i] = -1 end
  local q, qn, head = {1}, 1, 1
  dist[1] = 0
  while head <= qn do
    local cur = q[head]
    head = head + 1
    local x = (cur - 1) % w
    local y = math.floor((cur - 1) / w)
    local d = dist[cur] + 1
    if x > 0 and dist[cur - 1] < 0 and walls[cur - 1] == 0 then dist[cur - 1] = d; qn = qn + 1; q[qn] = cur - 1 end
    if x < w - 1 and dist[cur + 1] < 0 and walls[cur + 1] == 0 then dist[cur + 1] = d; qn = qn + 1; q[qn] = cur + 1 end
    if y > 0 and dist[cur - w] < 0 and walls[cur - w] == 0 then dist[cur - w] = d; qn = qn + 1; q[qn] = cur - w end
    if y < h - 1 and dist[cur + w] < 0 and walls[cur + w] == 0 then dist[cur + w] = d; qn = qn + 1; q[qn] = cur + w end
  end
  return dist
end
local w, h, walls, seed = 2400, 2000, {}, 11
for i = 1, w * h do seed = (seed * 16807) % 2147483647; walls[i] = (seed % 100 < 22) and 1 or 0 end
walls[1] = 0
local dist = bfs(w, h, walls)
local reach, far = 0, 0
for i = 1, w * h do local d = dist[i]; if d >= 0 then reach = reach + 1; if d > far then far = d end end end
print(reach, far)
