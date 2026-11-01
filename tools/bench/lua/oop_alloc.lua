local P = {} P.__index = P
local function new(x,y) return setmetatable({x=x,y=y}, P) end
local function run(k) local p = new(0,0) for i = 1, k do p = new(i, 2) end return p.x end
print(run(30000000))
