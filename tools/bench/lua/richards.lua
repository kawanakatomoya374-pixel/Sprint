local function class(parent) local c = {}; c.__index = c; if parent then setmetatable(c, {__index = parent}) end return c end
local Task = class()
function Task.new(cls, id, prio) return setmetatable({id = id, prio = prio, count = 0, state = 0}, cls) end
function Task:run(n) return 0 end
local Idle, Worker, Handler, Device = class(Task), class(Task), class(Task), class(Task)
function Idle:run(n) self.count = self.count + 1; return (n * 3 + 1) % 1009 end
function Worker:run(n) self.count = self.count + 2; return (n + self.prio) % 1013 end
function Handler:run(n) self.count = self.count + 3; return (n * self.prio + 7) % 1019 end
function Device:run(n) self.count = self.count + 1; return bit.bxor(n, self.id) end
local tasks = {}
for i = 0, 39 do
  local k = i % 4
  if k == 0 then tasks[#tasks + 1] = Task.new(Idle, i, i % 5)
  elseif k == 1 then tasks[#tasks + 1] = Task.new(Worker, i, i % 7)
  elseif k == 2 then tasks[#tasks + 1] = Task.new(Handler, i, i % 3 + 1)
  else tasks[#tasks + 1] = Task.new(Device, i, i % 2) end
end
local acc, n = 0, 1
for r = 1, 120000 do for i = 1, #tasks do n = tasks[i]:run(n); acc = acc + n end end
print(acc, tasks[1].count, tasks[6].count)
