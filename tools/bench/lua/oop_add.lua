local P = {} P.__index = P
local function new(x,y) return setmetatable({x=x,y=y}, P) end
function P:add(o) return new(self.x+o.x, self.y+o.y) end
local function run(k) local p, d = new(0,0), new(1,2) for i = 1, k do p = p:add(d) end return p.x end
print(run(30000000))
