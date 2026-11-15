local function hanoi(n, src, to, via, counts)
  if n == 0 then return end
  hanoi(n - 1, src, via, to, counts)
  counts[src] = counts[src] + 1
  counts[to] = counts[to] + 2
  hanoi(n - 1, via, to, src, counts)
end
local counts = {0, 0, 0}
for r = 1, 6 do hanoi(22, 1, 3, 2, counts) end
print(counts[1], counts[2], counts[3])
