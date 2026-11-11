local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local byte, concat = string.byte, table.concat
local function encode(s, chars)
  local out, k = {}, 0
  local n = #s
  local i = 1
  while i + 2 <= n do
    local a, b, c = byte(s, i, i + 2)
    local v = bor(lshift(a, 16), lshift(b, 8), c)
    out[k + 1] = chars[rshift(v, 18)]
    out[k + 2] = chars[band(rshift(v, 12), 63)]
    out[k + 3] = chars[band(rshift(v, 6), 63)]
    out[k + 4] = chars[band(v, 63)]
    k = k + 4
    i = i + 3
  end
  return concat(out)
end
local chars = {}
for i = 0, 63 do chars[i] = alphabet:sub(i + 1, i + 1) end
local seed, parts = 99, {}
for i = 1, 60000 do seed = (seed * 16807) % 2147483647; parts[i] = tostring(seed) end
local data = concat(parts, ",")
local total, last = 0, ""
for r = 1, 12 do last = encode(data, chars); total = total + #last end
print(total, last:sub(1, 24))
