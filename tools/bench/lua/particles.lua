local P = {}
P.__index = P
function P:step(dt)
  self.x = self.x + self.vx * dt
  self.y = self.y + self.vy * dt
  if self.x < 0.0 or self.x > 100.0 then self.vx = 0.0 - self.vx end
  if self.y < 0.0 or self.y > 100.0 then self.vy = 0.0 - self.vy end
end
local ps, seed = {}, 41
for i = 1, 5000 do
  seed = (seed * 16807) % 2147483647
  local a = (seed % 1000) / 10.0
  seed = (seed * 16807) % 2147483647
  local b = (seed % 1000) / 10.0
  ps[i] = setmetatable({x = a, y = b, vx = (seed % 7) - 3.0, vy = (seed % 5) - 2.0}, P)
end
for r = 1, 600 do for i = 1, #ps do ps[i]:step(0.1) end end
local sx, sy = 0.0, 0.0
for i = 1, #ps do sx = sx + ps[i].x; sy = sy + ps[i].y end
print(string.format("%d", sx * 100), string.format("%d", sy * 100))
