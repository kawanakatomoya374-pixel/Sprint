local P = {} P.__index = P
local function new(x,y) return setmetatable({x=x,y=y}, P) end
local function run(k) local p = new(3,4) local s = 0 for i = 1, k do s = s + p.x + p.y end return s end
print(run(50000000))
