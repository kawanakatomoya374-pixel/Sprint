local seed, parts = 37, {}
for i = 1, 200000 do
  seed = (seed * 16807) % 2147483647
  local run = 1 + seed % 6
  local ch = 97 + math.floor(seed / 7) % 4
  for k = 1, run do parts[#parts + 1] = ch end
end
local function encode(a)
  local out, i, n = {}, 1, #a
  while i <= n do
    local c, j = a[i], i
    while j <= n and a[j] == c do j = j + 1 end
    out[#out + 1] = c; out[#out + 1] = j - i
    i = j
  end
  return out
end
local function decode(e)
  local out, i = {}, 1
  while i <= #e do
    local c, k = e[i], e[i + 1]
    for t = 1, k do out[#out + 1] = c end
    i = i + 2
  end
  return out
end
local total = 0
for r = 1, 8 do local e = encode(parts); local d = decode(e); total = total + #e + #d end
print(total)
