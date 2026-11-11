local Circle, Rect, Tri = {}, {}, {}
Circle.__index = Circle; Rect.__index = Rect; Tri.__index = Tri
function Circle:area() return 3.0 * self.r * self.r end
function Rect:area() return self.w * self.h end
function Tri:area() return 0.5 * self.b * self.h end
local shapes = {}
for i = 0, 2999 do
  local k = i % 3
  if k == 0 then shapes[#shapes + 1] = setmetatable({r = 1.0 + i % 5}, Circle)
  elseif k == 1 then shapes[#shapes + 1] = setmetatable({w = 1.0 + i % 4, h = 2.0}, Rect)
  else shapes[#shapes + 1] = setmetatable({b = 3.0, h = 1.0 + i % 7}, Tri) end
end
local total = 0.0
for r = 1, 2000 do
  for i = 1, #shapes do total = total + shapes[i]:area() end
end
print(total)
