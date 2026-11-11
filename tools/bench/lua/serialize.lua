local function ser(v, out)
  local tv = type(v)
  if tv == "nil" then out[#out + 1] = "nil"
  elseif tv == "number" then out[#out + 1] = tostring(v)
  elseif tv == "string" then out[#out + 1] = '"'; out[#out + 1] = v; out[#out + 1] = '"'
  elseif v[1] ~= nil or #v > 0 then
    out[#out + 1] = "["
    for i = 1, #v do
      if i > 1 then out[#out + 1] = "," end
      ser(v[i], out)
    end
    out[#out + 1] = "]"
  else
    out[#out + 1] = "{"
    local first = true
    for _, k in ipairs({"a", "b", "c"}) do
      local x = v[k]
      if x ~= nil then
        if not first then out[#out + 1] = "," end
        first = false
        out[#out + 1] = k; out[#out + 1] = ":"
        ser(x, out)
      end
    end
    out[#out + 1] = "}"
  end
end
local function build(d, seed)
  if d == 0 then return seed end
  return {a = build(d - 1, seed + 1), b = {seed, "s" .. tostring(seed), build(d - 1, seed + 2)}, c = "x"}
end
local tree = build(14, 1)
local total = 0
for r = 1, 4 do
  local out = {}
  ser(tree, out)
  total = total + #table.concat(out)
end
print(total)
