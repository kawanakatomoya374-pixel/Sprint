local byte = string.byte
local function parse_array(s, pos, out)
  local n, cur, have = #s, 0, false
  while pos <= n do
    local c = byte(s, pos)
    if c >= 48 and c <= 57 then cur = cur * 10 + (c - 48); have = true
    elseif c == 44 then out[#out + 1] = cur; cur = 0; have = false
    elseif c == 93 then if have then out[#out + 1] = cur end return pos + 1 end
    pos = pos + 1
  end
  return pos
end
local parts, seed = {}, 29
for i = 1, 120000 do seed = (seed * 16807) % 2147483647; parts[i] = tostring(seed % 1000000) end
local text = "[" .. table.concat(parts, ",") .. "]"
local total = 0
for r = 1, 6 do
  local out = {}
  parse_array(text, 2, out)
  local s = 0
  for _, x in ipairs(out) do s = s + x end
  total = total + s % 1000003 + #out
end
print(total)
