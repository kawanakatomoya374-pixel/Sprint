local function compress(data)
  local dict = {}
  for i = 0, 255 do dict["c" .. i] = i end
  local nxt, out, w = 256, {}, ""
  for i = 1, #data do
    local c = data:sub(i, i)
    local wc = w .. c
    local key = "w" .. wc
    if (dict[key] or -1) >= 0 or #wc == 1 then
      w = wc
    else
      local code
      if #w == 1 then code = w:byte(1) else code = dict["w" .. w] end
      out[#out + 1] = code
      dict[key] = nxt
      nxt = nxt + 1
      w = c
    end
  end
  if #w > 0 then out[#out + 1] = (#w == 1) and w:byte(1) or dict["w" .. w] end
  return out
end
local letters, seed, parts = "abcdefgh", 17, {}
for i = 1, 60000 do
  seed = (seed * 16807) % 2147483647
  local k = seed % 8 + 1
  parts[i] = letters:sub(k, k)
end
local text = table.concat(parts)
local total, last = 0, 0
for r = 1, 3 do local o = compress(text); total = total + #o; last = o[#o] end
print(total, last)
