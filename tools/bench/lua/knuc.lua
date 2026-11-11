local letters = "ACGT"
local seed, parts = 5, {}
for i = 1, 300000 do
  seed = (seed * 16807) % 2147483647
  local r = seed % 4 + 1
  parts[i] = letters:sub(r, r)
end
local dna = table.concat(parts)
local sub = string.sub
local function count(s, k)
  local t = {}
  local n = #s - k + 1
  for i = 1, n do
    local key = sub(s, i, i + k - 1)
    t[key] = (t[key] or 0) + 1
  end
  return t
end
local total = 0
for _, k in ipairs({1, 2, 3, 4, 6, 8}) do
  local t = count(dna, k)
  local best, n = 0, 0
  for key, v in pairs(t) do n = n + 1; if v > best then best = v end end
  total = total + best + n
end
print(total, count(dna, 4)["ACGT"])
