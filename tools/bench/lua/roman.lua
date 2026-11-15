local vals = {1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1}
local syms = {"M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"}
local byte, concat = string.byte, table.concat
local function roman(n)
  local out = {}
  for i = 1, 13 do while n >= vals[i] do out[#out + 1] = syms[i]; n = n - vals[i] end end
  return concat(out)
end
local map = {[73] = 1, [86] = 5, [88] = 10, [76] = 50, [67] = 100, [68] = 500, [77] = 1000}
local function unroman(s)
  local total, prev = 0, 0
  for i = #s, 1, -1 do
    local v = map[byte(s, i)]
    if v < prev then total = total - v else total = total + v; prev = v end
  end
  return total
end
local acc = 0
for r = 1, 14 do for n = 1, 3999 do acc = acc + unroman(roman(n)) end end
print(acc)
