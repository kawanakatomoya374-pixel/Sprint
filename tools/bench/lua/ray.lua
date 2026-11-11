local sqrt = math.sqrt
local V = {}
V.__index = V
local function new(x, y, z) return setmetatable({x = x, y = y, z = z}, V) end
function V:sub(o) return new(self.x - o.x, self.y - o.y, self.z - o.z) end
function V:add(o) return new(self.x + o.x, self.y + o.y, self.z + o.z) end
function V:scale(k) return new(self.x * k, self.y * k, self.z * k) end
function V:dot(o) return self.x * o.x + self.y * o.y + self.z * o.z end
local S = {}
S.__index = S
local function sphere(c, r) return setmetatable({c = c, r = r}, S) end
function S:hit(o, d)
  local oc = o:sub(self.c)
  local b = oc:dot(d)
  local c = oc:dot(oc) - self.r * self.r
  local disc = b * b - c
  if disc < 0.0 then return -1.0 end
  return -b - sqrt(disc)
end
local spheres = {sphere(new(0.0, 0.0, 5.0), 1.0), sphere(new(2.0, 0.5, 6.0), 1.2), sphere(new(-2.0, -0.5, 4.0), 0.8), sphere(new(0.0, -101.0, 5.0), 100.0)}
local light, origin = new(5.0, 5.0, -2.0), new(0.0, 0.0, 0.0)
local size, acc = 700, 0.0
for py = 0, size - 1 do
  for px = 0, size - 1 do
    local d0 = new((px - size / 2) / size, (py - size / 2) / size, 1.0)
    local d = d0:scale(1.0 / sqrt(d0:dot(d0)))
    local best, bs = 1e30, nil
    for _, s in ipairs(spheres) do
      local t = s:hit(origin, d)
      if t > 0.0 and t < best then best = t; bs = s end
    end
    if bs then
      local p = origin:add(d:scale(best))
      local n = p:sub(bs.c)
      n = n:scale(1.0 / bs.r)
      local l = light:sub(p)
      l = l:scale(1.0 / sqrt(l:dot(l)))
      local k = n:dot(l)
      if k > 0.0 then acc = acc + k end
    end
  end
end
print(string.format("%d", math.floor(acc)))
