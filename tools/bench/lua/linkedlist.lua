local function build(n) local h = nil; for i = 0, n - 1 do h = {v = i, next = h} end return h end
local function reverse(h) local prev = nil; while h ~= nil do local nx = h.next; h.next = prev; prev = h; h = nx end return prev end
local function sum(h) local s = 0; while h ~= nil do s = s + h.v; h = h.next end return s end
local total = 0
for r = 1, 40 do
  local l = build(50000)
  l = reverse(l)
  total = total + sum(l)
  l = reverse(l)
  total = total + l.v
end
print(total)
