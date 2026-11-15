local Tree = {}
Tree.__index = Tree
function Tree:insert(k)
  if self.root == nil then self.root = {key = k}; self.size = self.size + 1; return end
  local cur = self.root
  while true do
    if k < cur.key then
      if cur.left == nil then cur.left = {key = k}; self.size = self.size + 1; return end
      cur = cur.left
    elseif k > cur.key then
      if cur.right == nil then cur.right = {key = k}; self.size = self.size + 1; return end
      cur = cur.right
    else return end
  end
end
function Tree:has(k)
  local cur = self.root
  while cur ~= nil do
    if k < cur.key then cur = cur.left elseif k > cur.key then cur = cur.right else return true end
  end
  return false
end
local function height(n)
  if n == nil then return 0 end
  local l, r = height(n.left), height(n.right)
  return 1 + (l > r and l or r)
end
local t = setmetatable({size = 0}, Tree)
local seed = 13
for i = 1, 200000 do
  seed = (seed * 16807) % 2147483647
  t:insert(seed % 1000000)
end
local hits = 0
for i = 1, 400000 do
  seed = (seed * 16807) % 2147483647
  if t:has(seed % 1000000) then hits = hits + 1 end
end
print(t.size, hits, height(t.root))
