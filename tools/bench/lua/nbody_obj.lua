local sqrt = math.sqrt
local bodies = {
  {x=0.0,y=0.0,z=0.0,vx=0.0,vy=0.0,vz=0.0,mass=39.47},
  {x=4.84,y=-1.16,z=-0.10,vx=0.606,vy=2.81,vz=-0.02,mass=0.037},
  {x=8.34,y=4.12,z=-0.4,vx=-1.01,vy=1.82,vz=0.008,mass=0.011},
  {x=12.89,y=-15.11,z=-0.22,vx=1.08,vy=0.868,vz=-0.01,mass=0.0017},
  {x=15.37,y=-25.9,z=0.179,vx=0.979,vy=0.594,vz=-0.034,mass=0.002}}
local function advance(bs, dt)
  local n = #bs
  for i = 1, n do
    local bi = bs[i]
    for j = i + 1, n do
      local bj = bs[j]
      local dx, dy, dz = bi.x - bj.x, bi.y - bj.y, bi.z - bj.z
      local d2 = dx * dx + dy * dy + dz * dz
      local mag = dt / (d2 * sqrt(d2))
      bi.vx = bi.vx - dx * bj.mass * mag; bi.vy = bi.vy - dy * bj.mass * mag; bi.vz = bi.vz - dz * bj.mass * mag
      bj.vx = bj.vx + dx * bi.mass * mag; bj.vy = bj.vy + dy * bi.mass * mag; bj.vz = bj.vz + dz * bi.mass * mag
    end
  end
  for i = 1, n do
    local b = bs[i]
    b.x = b.x + dt * b.vx; b.y = b.y + dt * b.vy; b.z = b.z + dt * b.vz
  end
end
for i = 1, 300000 do advance(bodies, 0.01) end
print(string.format("%d", bodies[1].x * 100000), string.format("%d", bodies[2].y * 100000))
